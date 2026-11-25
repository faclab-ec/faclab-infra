#!/usr/bin/env bash
# Tests of heartbeats.sh (S8.6) without a server, Docker nor the heartbeat service: a local HTTP
# receiver stands for it and fake stack.sh and backups.sh answer what each case needs. CI runs it
# from ci-validate.sh; so can anyone: deploy/production/scripts/test-heartbeats.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
PORT_FILE="$WORK/port"
LOG="$WORK/pings.log"
SECRET="s3cr3t-ping-key"
PASS=0
trap 'kill "${SERVER_PID:-0}" 2> /dev/null || true; wait "${SERVER_PID:-0}" 2> /dev/null || true; rm -rf "$WORK"' EXIT

# The receiver: every request as "<method> <path> <body>"; it answers 200
cat > "$WORK/receiver.py" <<'PY'
import http.server, sys

log, port_file = sys.argv[1], sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_request(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode().replace("\n", " | ")
        with open(log, "a") as out:
            out.write(f"{self.command} {self.path} {body}\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")
    do_GET = do_POST = do_HEAD = do_request
    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
open(port_file, "w").write(str(server.server_address[1]))
server.serve_forever()
PY
: > "$LOG"
python3 "$WORK/receiver.py" "$LOG" "$PORT_FILE" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
[ -s "$PORT_FILE" ] || { echo "the test receiver didn't start" >&2; exit 1; }
BASE="http://127.0.0.1:$(cat "$PORT_FILE")/$SECRET"

# Fake stack.sh: `compose ps` prints $FAKE_PS, `compose exec ... outbox-failed` prints $FAKE_OUTBOX
cat > "$WORK/stack.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ps --all"*) printf '%s\n' "$FAKE_PS" ;;
  *outbox-failed*) printf 'noise\n%s\nlog after\n' "$FAKE_OUTBOX" ;;
  *) exit 2 ;;
esac
SH
# Fake backups.sh healthy: $FAKE_BACKUP_CODE, and the lines in $FAKE_BACKUP_LINES
cat > "$WORK/backups.sh" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_BACKUP_LINES:-}" ] || printf '%s\n' "$FAKE_BACKUP_LINES"
exit "${FAKE_BACKUP_CODE:-0}"
SH
chmod +x "$WORK/stack.sh" "$WORK/backups.sh"

export FACLAB_STACK="$WORK/stack.sh" FACLAB_BACKUPS_SH="$WORK/backups.sh" FACLAB_ETC="$WORK/etc"
mkdir -p "$WORK/etc"
GOOD_PS='{"Service":"core-api","State":"running","Health":"healthy","ExitCode":0}
{"Service":"kafka-topics","State":"exited","Health":"","ExitCode":0}'
BAD_PS='{"Service":"core-api","State":"running","Health":"healthy","ExitCode":0}
{"Service":"core-worker","State":"running","Health":"unhealthy","ExitCode":0}
{"Service":"invoicing-api","State":"restarting","Health":"","ExitCode":1}'
STOPPED_PS='{"Service":"core-api","State":"running","Health":"healthy","ExitCode":0}
{"Service":"core-worker","State":"exited","Health":"","ExitCode":0}'
export FAKE_PS="$GOOD_PS" FAKE_OUTBOX="0 failed message(s)" FAKE_BACKUP_CODE=0 FAKE_BACKUP_LINES=""

# shellcheck source=heartbeats.sh
# shellcheck disable=SC1091 # shellcheck can't follow a variable path
source "$TESTS_DIR/heartbeats.sh"

fail() {
  echo "FAIL: $*" >&2
  echo "--- pings received:" >&2
  cat "$LOG" >&2
  exit 1
}
ok() {
  PASS=$((PASS + 1))
  echo "ok: $1"
}

# expect <name> <exit code> <ping path> <body fragment or ->, then the check's arguments
expect() {
  local name="$1" want_code="$2" want_path="$3" want_body="$4" out code=0
  shift 4
  : > "$LOG"
  out="$("$@" 2>&1)" || code=$?
  [ "$code" = "$want_code" ] || fail "$name: exit $code, wanted $want_code ($out)"
  if [ "$want_path" = none ]; then
    [ ! -s "$LOG" ] || fail "$name: sent a ping and shouldn't have"
  else
    grep -qE "^(GET|POST) /$SECRET$want_path( |\$)" "$LOG" || fail "$name: no ping to $want_path"
    [ "$want_body" = - ] || grep -qF "$want_body" "$LOG" || fail "$name: the body lacks '$want_body'"
  fi
  # The key of the URL is a secret: never in what the script prints
  ! grep -qF "$SECRET" <<< "$out" || fail "$name: the output shows the ping key"
  ok "$name"
}

export HEARTBEAT_BASE_URL="$BASE"

expect "stack: all running or exited 0" 0 /faclab-stack - run_check stack
FAKE_PS="$BAD_PS" expect "stack: unhealthy and restarting containers" 1 /faclab-stack/fail "core-worker" run_check stack
FAKE_PS="$BAD_PS" expect "stack: names every bad container" 1 /faclab-stack/fail "invoicing-api" run_check stack

FAKE_PS="$STOPPED_PS" expect "stack: a service stopped by hand (exit 0) is down" 1 /faclab-stack/fail "core-worker" run_check stack

expect "outbox: none failed" 0 /faclab-outbox - run_check outbox
FAKE_OUTBOX="Traceback: no database" expect "outbox: the CLI gives no count" 1 /faclab-outbox/fail "no answer" run_check outbox
FAKE_OUTBOX="3 failed message(s)" expect "outbox: some failed" 1 /faclab-outbox/fail "3 failed message(s)" run_check outbox

expect "backup: healthy" 0 /faclab-backup - run_check backup
FAKE_BACKUP_CODE=1 FAKE_BACKUP_LINES="faclab.backup.overdue 1 faclab.backup.job=full 1" \
  expect "backup: late" 1 /faclab-backup/fail "overdue" run_check backup
FAKE_BACKUP_CODE=3 FAKE_BACKUP_LINES="BACKUPS is off in this environment" \
  expect "backup: off in this environment, no ping" 0 none - run_check backup

DISK_MAX_PERCENT=101 expect "disk: under the limit" 0 /faclab-disk - run_check disk
DISK_MAX_PERCENT=0 expect "disk: over the limit" 1 /faclab-disk/fail "used" run_check disk

HEARTBEAT_BASE_URL="" expect "no URL: nothing is sent" 0 none - run_check stack

# The service is down: the failure is reported without the URL
HEARTBEAT_BASE_URL="http://127.0.0.1:9/$SECRET" expect "service unreachable" 1 none - run_check stack
# (die exits: in a subshell, so the test goes on)
unreachable="$( (HEARTBEAT_BASE_URL="http://127.0.0.1:9/$SECRET" run_check stack) 2>&1)" || true
grep -q "didn't take the ping" <<< "$unreachable" || fail "an unreachable service isn't reported: $unreachable"
ok "service unreachable: reported"

# status: what each check says, without pinging
: > "$LOG"
status_out="$(FAKE_OUTBOX="1 failed message(s)" DISK_MAX_PERCENT=101 bash -c "source '$TESTS_DIR/heartbeats.sh'; for c in stack outbox; do run_check \$c --print; done")"
grep -q "stack: ok" <<< "$status_out" || fail "status output: $status_out"
grep -q "outbox: FAILING" <<< "$status_out" || fail "status output: $status_out"
[ ! -s "$LOG" ] || fail "status sent a ping"
ok "status: prints without pinging"

echo "$PASS heartbeat tests passed"
