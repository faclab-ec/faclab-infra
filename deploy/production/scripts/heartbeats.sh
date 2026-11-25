#!/usr/bin/env bash
# Heartbeats of the production stack (S8.6, deploy/production/README.md, "Latidos y sondeos"), on its
# server, as root. They watch what matters most without a telemetry backend: each check looks at one
# thing and tells an external heartbeat service (Healthchecks.io or any that takes a ping URL) how it
# went. The service alerts when a ping says `fail` and also when pings stop (a dead server, a stopped
# timer: what no probe from inside can report).
#
#   heartbeats.sh stack            every service runs, none is unhealthy and the one-shot ones exited 0
#   heartbeats.sh backup           no backup job is late or failed and WAL archiving works
#   heartbeats.sh outbox           the outbox has no message in `failed`
#   heartbeats.sh disk             the disk of Docker's data is under 80 % full
#   heartbeats.sh status           what each check says now, without pinging
#   heartbeats.sh install-timers   install and enable the timers (every 5 minutes, one per check)
#   heartbeats.sh remove-timers    disable and remove them
#
# HEARTBEAT_BASE_URL (in /etc/faclab/secrets.env, a secret: it carries the service's key, e.g.
# https://hc-ping.com/<ping key>) is where pings go: <base>/<slug>, or <base>/<slug>/fail with the
# reason as the body. The slug is the name of the check above, prefixed `faclab-`. The checks must
# exist in the service with those slugs (the README says how). Without the URL nothing is sent.
# The URL never reaches a command line, the output nor the logs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${FACLAB_STACK:-$HERE/scripts/stack.sh}"
BACKUPS_SH="${FACLAB_BACKUPS_SH:-$HERE/scripts/backups.sh}"
ETC="${FACLAB_ETC:-/etc/faclab}"
UNITS="${FACLAB_SYSTEMD_UNITS:-/etc/systemd/system}"
CHECKS=(stack backup outbox disk)
# The services that run once and exit (restart: "no" in compose.yaml): exiting with 0 is their normal
# end. Any other service that isn't running is down, even if it exited with 0 (a stop by hand)
ONE_SHOT=(kafka-topics objects-backup core-migrate invoicing-migrate)
DISK_MAX_PERCENT=80

die() {
  echo "heartbeats.sh: $*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" = 0 ] || die "run it with sudo: the stack and its secrets are root's"
}

# Each check prints why it failed (or what it skipped) and returns 0 (good), 1 (bad) or 3 (it doesn't
# apply in this environment, nothing to tell the service)

# docker compose ps prints one JSON object per line
check_stack() {
  local bad
  command -v jq > /dev/null || die "jq is missing (provision-vps.sh installs it)"
  bad="$("$STACK" compose ps --all --format json |
    jq -rs --argjson oneshot "$(printf '%s\n' "${ONE_SHOT[@]}" | jq -R . | jq -s .)" '.[] | . as $c | select(
        (($c.State == "running") and (($c.Health // "") != "unhealthy"))
        or (($c.State == "exited") and ($c.ExitCode == 0) and (($oneshot | index($c.Service)) != null))
        | not
      ) | "\($c.Service): \($c.State) \($c.Health // "") exit \($c.ExitCode)"')"
  [ -z "$bad" ] || {
    printf '%s\n' "$bad"
    return 1
  }
}

# backups.sh healthy answers 3 when BACKUPS is off
check_backup() {
  local code=0
  "$BACKUPS_SH" healthy || code=$?
  return "$code"
}

check_outbox() {
  local count
  # The CLI's own count line, wherever the logs of its start fall around it
  count="$("$STACK" compose exec -T core-worker python -m src.background.cli outbox-failed --limit 1 |
    grep -E '^[0-9]+ failed message\(s\)$' | tail -n 1 || true)"
  case "$count" in
    "0 failed message(s)") ;;
    "")
      echo "outbox: the CLI gave no answer (stack.sh logs core-worker)"
      return 1
      ;;
    *)
      echo "outbox: $count (make outbox-failed, runbook mensajes-fallidos)"
      return 1
      ;;
  esac
}

check_disk() {
  local path=/var/lib/docker used
  [ -d "$path" ] || path=/
  used="$(df -P "$path" | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"
  if [ "${used:-100}" -ge "$DISK_MAX_PERCENT" ]; then
    echo "disk: ${used}% of $path used (limit ${DISK_MAX_PERCENT}%, runbook disco)"
    return 1
  fi
}

# The base ping URL, from the environment (tests) or the secrets file; empty when there is none
base_url() {
  if [ -n "${HEARTBEAT_BASE_URL:-}" ]; then
    printf '%s' "$HEARTBEAT_BASE_URL"
    return
  fi
  sed -n 's/^HEARTBEAT_BASE_URL=//p' "$ETC/secrets.env" 2> /dev/null | tail -n 1
}

# ping <slug> [fail <reason>]: curl reads its URL from stdin, so it isn't in the process list, and
# its answer is dropped: the URL is a secret and curl may print it in an error
ping_service() {
  local slug="$1" url="$2" kind="${3:-}" reason="${4:-}" target
  target="$url/faclab-$slug"
  [ "$kind" != fail ] || target="$target/fail"
  if ! printf 'url = "%s"\n' "$target" |
    curl -fsS -K - --max-time 15 --retry 2 --data-raw "$reason" -o /dev/null 2> /dev/null; then
    die "the heartbeat service didn't take the ping of $slug"
  fi
}

run_check() {
  local name="$1" url output code=0
  case "$name" in
    stack | backup | outbox | disk) ;;
    *) die "unknown check: $name (${CHECKS[*]})" ;;
  esac
  output="$("check_$name" 2>&1)" || code=$?
  if [ "$code" = 3 ]; then
    echo "$name: skipped ($output)"
    return 0
  fi
  url="$(base_url)"
  if [ "${2:-}" = --print ]; then
    # status: what the check says, without pinging
    if [ "$code" = 0 ]; then echo "$name: ok"; else echo "$name: FAILING: $output"; fi
    return 0
  fi
  [ -n "$url" ] || {
    echo "$name: no HEARTBEAT_BASE_URL, nothing sent"
    return 0
  }
  if [ "$code" = 0 ]; then
    ping_service "$name" "$url"
    echo "$name: ok"
  else
    ping_service "$name" "$url" fail "$output"
    echo "$name: FAILING: $output" >&2
    return 1
  fi
}

install_timers() {
  local unit name
  [ -d "$UNITS" ] || die "$UNITS doesn't exist: is this a systemd host?"
  for unit in "$HERE"/systemd/faclab-heartbeat@*; do
    name="$(basename "$unit")"
    sed "s|@SCRIPTS@|$HERE/scripts|g" "$unit" > "$UNITS/$name.tmp"
    chmod 0644 "$UNITS/$name.tmp"
    mv "$UNITS/$name.tmp" "$UNITS/$name"
  done
  systemctl daemon-reload
  for name in "${CHECKS[@]}"; do
    systemctl enable --now --quiet "faclab-heartbeat@$name.timer"
  done
  echo "Heartbeat timers enabled (systemctl list-timers 'faclab-heartbeat@*')"
}

remove_timers() {
  local name
  for name in "${CHECKS[@]}"; do
    systemctl disable --now --quiet "faclab-heartbeat@$name.timer" 2> /dev/null || true
  done
  rm -f "$UNITS"/faclab-heartbeat@*
  systemctl daemon-reload
  echo "Heartbeat timers removed"
}

main() {
  local command="${1:-}"
  [ -n "$command" ] || {
    sed -n '2,24p' "${BASH_SOURCE[0]}"
    exit 1
  }
  shift
  case "$command" in
    status)
      local name
      for name in "${CHECKS[@]}"; do run_check "$name" --print; done
      ;;
    install-timers) need_root && install_timers ;;
    remove-timers) need_root && remove_timers ;;
    *) need_root && run_check "$command" ;;
  esac
}

# Sourced by the tests, which call the functions; run as a script otherwise
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
