#!/usr/bin/env bash
# The backups of the production stack (S8.3, deploy/production/RESPALDOS.md), on its server, as
# root. The systemd timers of deploy/production/systemd run it: stack.sh deploy installs them when the
# environment has BACKUPS=on. It reaches the stack through stack.sh compose.
#
#   backups.sh full | incr        a full or an incremental backup of PostgreSQL (pgBackRest), noted
#                                 with the versions deployed
#   backups.sh objects            the copy of the object storage outside the server: every object
#                                 missing or changed there (daily)
#   backups.sh objects-recent     the same, only objects written in the last 24 hours (every 5 min)
#   backups.sh report             the state of the backups, as metrics to the Collector (every 5 min)
#   backups.sh status             the same, for a person: backups, WAL archiving, last runs, timers
#   backups.sh healthy            exit 0 when no job is late or failed and WAL archiving works; 1 and
#                                 the offending lines when not; 3 when BACKUPS is off (the heartbeat
#                                 of S8.6, scripts/heartbeats.sh)
#   backups.sh check              that WAL archiving works end to end (pgbackrest check)
#   backups.sh install-timers     install and enable the timers of this checkout; the first full
#                                 backup, in the background, when there is none
#   backups.sh remove-timers      disable and remove them
#
# Each job leaves its result in $STATE/last-<job>.json; report turns those and pgBackRest's info into
# the metrics faclab.backup.* that the alerts respaldo-fallido, respaldo-atrasado and
# wal-sin-archivar read (observability/runbooks/respaldos.md).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="$HERE/scripts/stack.sh"
ETC="${FACLAB_ETC:-/etc/faclab}"
STATE="${FACLAB_BACKUP_STATE:-/var/lib/faclab/backups}"
LOCKS="${FACLAB_BACKUP_LOCKS:-/run}"
DEPLOY_LOCK="${FACLAB_DEPLOY_LOCK:-/run/faclab-deploy.lock}"
UNITS="${FACLAB_SYSTEMD_UNITS:-/etc/systemd/system}"
TIMERS=(full incr objects objects-recent report)
JOBS=(full incr objects objects-recent)
# The Collector's OTLP/HTTP receiver for internal tasks, reached from the postgres container: no
# route of Caddy leads there
COLLECTOR_URL="http://collector:4319/v1/metrics"
# Late, in seconds: incrementals are daily and the full backup weekly (a day of margin each); the
# objects are copied every 5 minutes
MAX_AGE_ANY=$((26 * 3600))
MAX_AGE_FULL=$((8 * 86400))
MAX_AGE_OBJECTS=3600

die() {
  echo "backups.sh: $*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" = 0 ] || die "run it with sudo: the stack and its secrets are root's"
}

compose() {
  "$STACK" compose "$@"
}

# A command in the postgres container, as postgres: pgBackRest refuses to run as root
pg() {
  compose exec -T -u postgres postgres "$@"
}

pgbackrest() {
  pg pgbackrest --stanza=faclab "$@"
}

# The value of a variable in the environment's env file (on when unset)
backups_setting() {
  local environment file value
  environment="$(cat "$ETC/environment" 2> /dev/null)" || die "no environment yet: stack.sh install-secrets"
  file="$HERE/env/$environment.env"
  value="$(sed -n 's/^BACKUPS=//p' "$file" 2> /dev/null | tail -n 1)"
  printf '%s' "${value:-on}"
}

# record <job> <ok|failed> <seconds>: the result of a run, keeping the time of the last good one
record() {
  local job="$1" result="$2" seconds="$3" file="$STATE/last-$1.json" now last_ok=""
  now="$(date +%s)"
  if [ -f "$file" ]; then
    last_ok="$(jq -r '.last_ok // empty' "$file" 2> /dev/null || true)"
  fi
  [ "$result" = ok ] && last_ok="$now"
  install -d -m 0700 "$STATE"
  jq -n --arg job "$job" --arg result "$result" --argjson at "$now" --argjson seconds "$seconds" \
    --argjson last_ok "${last_ok:-null}" \
    '{job: $job, result: $result, at: $at, seconds: $seconds, last_ok: $last_ok}' > "$file.tmp"
  chmod 0600 "$file.tmp"
  mv "$file.tmp" "$file"
}

# run_job <job> <lock> <wait seconds> <function...>: one run of a lock at a time, after any
# deployment in progress (it may recreate postgres), its result recorded and reported. A wait of 0
# skips the run while another holds the lock: the next timer comes soon
run_job() {
  local job="$1" lock="$2" wait="$3" start status
  shift 3
  exec 8> "$LOCKS/faclab-backup-$lock.lock"
  if [ "$wait" = 0 ]; then
    flock -n 8 || {
      echo "backups.sh: another $lock job is running; skipping this $job"
      return 0
    }
  else
    flock -w "$wait" 8 || die "another $lock job held the lock for ${wait}s"
  fi
  flock -w 3600 "$DEPLOY_LOCK" true || die "a deployment held $DEPLOY_LOCK for an hour"

  start="$(date +%s)"
  echo "== $job  [$(date -u +%Y-%m-%dT%H:%M:%SZ)]"
  set +e
  "$@"
  status=$?
  set -e
  if [ "$status" = 0 ]; then
    record "$job" ok "$(($(date +%s) - start))"
    echo "== $job: ok in $(($(date +%s) - start))s"
  else
    record "$job" failed "$(($(date +%s) - start))"
    echo "== $job: FAILED (exit $status) after $(($(date +%s) - start))s" >&2
  fi
  # The alert doesn't wait for the next report
  report || echo "backups.sh: the report after $job failed" >&2
  return "$status"
}

# A backup of PostgreSQL, noted with what ran then: a restore deploys those versions by default
pg_backup() {
  local type="$1" current="$ETC/deployments/current.env" name value notes=()
  for name in infra core invoicing web; do
    value="$(sed -n "s/^${name^^}_VERSION=//p" "$current" 2> /dev/null | tail -n 1)"
    [ -z "$value" ] || notes+=("--annotation=$name=$value")
  done
  pgbackrest backup --type="$type" "${notes[@]}"
}

objects_copy() {
  compose run --rm --no-deps objects-backup "$1"
}

#
# Report
#

# The metrics as OTLP/HTTP JSON, from lines "<name> <unit> <attribute=value or -> <integer>"
metrics_json() {
  jq -R -s --arg ns "$(date +%s)000000000" '
    [split("\n")[] | select(length > 0) | split(" ")]
    | group_by(.[0])
    | map({
        name: .[0][0],
        unit: .[0][1],
        gauge: {dataPoints: map(
          {timeUnixNano: $ns, asInt: .[3]}
          + (if .[2] == "-" then {} else
              {attributes: [(.[2] | split("=")) as $kv | {key: $kv[0], value: {stringValue: $kv[1]}}]}
            end))}
      })
    | {resourceMetrics: [{
        resource: {attributes: [{key: "service.name", value: {stringValue: "faclab-backups"}}]},
        scopeMetrics: [{scope: {name: "faclab-backups"}, metrics: .}]
      }]}'
}

# A field of a job's state: result, at, seconds, last_ok (empty when it never ran)
state() {
  jq -r ".$2 // empty" "$STATE/last-$1.json" 2> /dev/null || true
}

# info_ok <json>: pgBackRest could read the repository (status 0, or 2: a stanza without backups)
info_ok() {
  jq -e '.[0].status.code == 0 or .[0].status.code == 2' <<< "$1" > /dev/null 2>&1
}

# The lines metrics_json reads
measure() {
  local now info last_full last_any count archiver archived failed pending job objects_ok
  now="$(date +%s)"
  # pgBackRest answers 0 even when the repository doesn't: its JSON says how it went (0 backups
  # found, 2 a stanza without backups, anything else an error)
  if info="$(pgbackrest info --output=json 2> /dev/null)" && info_ok "$info"; then
    last_full="$(jq '[.[0].backup[]? | select(.type == "full") | .timestamp.stop] | max // empty' <<< "$info")"
    last_any="$(jq '[.[0].backup[]? | .timestamp.stop] | max // empty' <<< "$info")"
    count="$(jq '[.[0].backup[]?] | length' <<< "$info")"
    echo "faclab.backup.count 1 - ${count:-0}"
  else
    # The repository doesn't answer: its backups may well be there. The last good runs this server
    # recorded tell how late they are; the failure itself shows in the jobs and the WAL
    last_full="$(state full last_ok)"
    last_any="$(printf '%s\n%s\n' "$last_full" "$(state incr last_ok)" | sort -n | tail -n 1)"
  fi
  [ -z "$last_full" ] || echo "faclab.backup.age s faclab.backup.kind=full $((now - last_full))"
  [ -z "$last_any" ] || echo "faclab.backup.age s faclab.backup.kind=any $((now - last_any))"
  late "$last_full" "$MAX_AGE_FULL" full "$now"
  late "$last_any" "$MAX_AGE_ANY" incr "$now"

  objects_ok="$(printf '%s\n%s\n' "$(state objects last_ok)" "$(state objects-recent last_ok)" | sort -n | tail -n 1)"
  [ -z "$objects_ok" ] || echo "faclab.backup.objects.age s - $((now - objects_ok))"
  late "$objects_ok" "$MAX_AGE_OBJECTS" objects "$now"

  for job in "${JOBS[@]}"; do
    if [ "$(state "$job" result)" = failed ]; then
      echo "faclab.backup.failed 1 faclab.backup.job=$job 1"
    else
      echo "faclab.backup.failed 1 faclab.backup.job=$job 0"
    fi
  done

  # The archiver: failing while its last failure is newer than its last success. And the segments
  # waiting for it (pg_wal/archive_status/*.ready)
  archiver="$(pg psql -X -qtA -F ' ' -d postgres -c "select coalesce(extract(epoch from last_archived_time)::bigint, 0), coalesce(extract(epoch from last_failed_time)::bigint, 0) from pg_stat_archiver")"
  read -r archived failed <<< "$archiver"
  echo "faclab.backup.wal.failing 1 - $([ "$failed" -gt "$archived" ] && echo 1 || echo 0)"
  # shellcheck disable=SC2016 # $PGDATA expands in the container
  pending="$(pg sh -c 'ls "$PGDATA/pg_wal/archive_status" | grep -c "\.ready$" || true')"
  echo "faclab.backup.wal.pending 1 - ${pending:-0}"
}

# late <time of the last good one or empty> <max age> <job> <now>
late() {
  local value=0
  if [ -z "$1" ] || [ $(($4 - $1)) -gt "$2" ]; then
    value=1
  fi
  echo "faclab.backup.overdue 1 faclab.backup.job=$3 $value"
}

report() {
  local lines
  lines="$(measure)"
  metrics_json <<< "$lines" |
    compose exec -T postgres curl -fsS --max-time 10 -H 'Content-Type: application/json' \
      --data-binary @- -o /dev/null "$COLLECTOR_URL"
  if [ "${1:-}" = --print ]; then
    printf '%s\n' "$lines"
  fi
}

status() {
  local job
  echo "== pgBackRest"
  pgbackrest info || true
  echo
  echo "== WAL archiving (pg_stat_archiver)"
  pg psql -X -q -d postgres -c "select archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time from pg_stat_archiver" || true
  echo "== Last runs"
  for job in "${JOBS[@]}"; do
    if [ -f "$STATE/last-$job.json" ]; then
      jq -r '"\(.job): \(.result) at \(.at | todate) in \(.seconds)s; last ok \(if .last_ok then (.last_ok | todate) else "never" end)"' \
        "$STATE/last-$job.json"
    else
      echo "$job: never ran"
    fi
  done
  echo
  echo "== Timers"
  systemctl list-timers --all 'faclab-backup@*' --no-pager || true
  echo
  echo "== Metrics of the last report"
  measure
}

# healthy: the lines of measure that say something is wrong (overdue, failed, WAL failing)
healthy() {
  local lines bad
  lines="$(measure)"
  bad="$(grep -E '^faclab\.backup\.(overdue|failed|wal\.failing) .* 1$' <<< "$lines" || true)"
  [ -z "$bad" ] || {
    printf '%s\n' "$bad"
    return 1
  }
}

install_timers() {
  local unit name code
  [ -d "$UNITS" ] || die "$UNITS doesn't exist: is this a systemd host?"
  for unit in "$HERE"/systemd/faclab-backup@*; do
    name="$(basename "$unit")"
    sed "s|@SCRIPTS@|$HERE/scripts|g" "$unit" > "$UNITS/$name.tmp"
    chmod 0644 "$UNITS/$name.tmp"
    mv "$UNITS/$name.tmp" "$UNITS/$name"
  done
  systemctl daemon-reload
  for name in "${TIMERS[@]}"; do
    systemctl enable --now --quiet "faclab-backup@$name.timer"
  done
  echo "Backup timers enabled (systemctl list-timers 'faclab-backup@*')"
  # Status 2: the stanza exists and has no backup yet
  code="$(pgbackrest info --output=json 2> /dev/null | jq '.[0].status.code' || echo unknown)"
  if [ "$code" = 2 ]; then
    systemctl start --no-block faclab-backup@full.service
    echo "No backup in the repository yet: the first full backup started (journalctl -u faclab-backup@full)"
  fi
}

remove_timers() {
  local name
  for name in "${TIMERS[@]}"; do
    systemctl disable --now --quiet "faclab-backup@$name.timer" 2> /dev/null || true
  done
  rm -f "$UNITS"/faclab-backup@*
  systemctl daemon-reload
  echo "Backup timers removed"
}

main() {
  local command="${1:-}"
  [ -n "$command" ] || {
    sed -n '2,20p' "${BASH_SOURCE[0]}"
    exit 1
  }
  shift
  need_root
  command -v jq > /dev/null || die "jq is missing (provision-vps.sh installs it)"
  case "$command" in
    full | incr)
      [ "$(backups_setting)" = on ] || die "BACKUPS isn't on in this environment"
      # A full backup may take hours: an incremental waits for it, and the other way round
      run_job "$command" postgres 21600 pg_backup "$command"
      ;;
    objects)
      [ "$(backups_setting)" = on ] || die "BACKUPS isn't on in this environment"
      run_job objects objects 21600 objects_copy copy
      ;;
    objects-recent)
      [ "$(backups_setting)" = on ] || die "BACKUPS isn't on in this environment"
      run_job objects-recent objects 0 objects_copy recent
      ;;
    report)
      if [ "$(backups_setting)" != on ]; then
        echo "BACKUPS is off in this environment: nothing to report"
        return 0
      fi
      report "$@"
      ;;
    status) status ;;
    healthy)
      if [ "$(backups_setting)" != on ]; then
        echo "BACKUPS is off in this environment"
        return 3
      fi
      healthy
      ;;
    check) pgbackrest check ;;
    install-timers) install_timers ;;
    remove-timers) remove_timers ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
