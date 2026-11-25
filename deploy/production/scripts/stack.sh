#!/usr/bin/env bash
# The production stack of Faclab on its server (S8.1, S8.2): docker compose with compose.yaml, the
# env file of the environment (env/<environment>.env), the secrets (/etc/faclab/secrets.env and the
# files of /etc/faclab/secrets) and the deployed versions (/etc/faclab/deployments/current.env). Run
# it with sudo from the faclab-infra checkout: it reads /etc/faclab.
#
#   stack.sh install-secrets <environment>  move what secrets.sh push left in ~/.faclab-incoming to
#                                           /etc/faclab, with owners and modes, and remember the
#                                           environment
#   stack.sh deploy <infra> <core> <invoicing> <web>
#                                           deploy those versions (tags published in GHCR): the
#                                           checkout at v<infra>, images pinned by digest, a backup
#                                           of both databases, migrations (down too, to an older
#                                           version), the services in order (infra, invoicing, core,
#                                           web), each checked healthy, and an automatic rollback to
#                                           what ran before if anything fails (exit 3)
#   stack.sh rollback                       deploy the previous versions (deployments)
#   stack.sh deployments                    what runs, what ran before, and the history
#   stack.sh backups                        the backups taken before each deployment
#   stack.sh restore-predeploy <id> --yes   replace both databases with that backup and deploy the
#                                           versions that ran then (what was written since is lost)
#   stack.sh restore <time|latest> --yes [<infra> <core> <invoicing> <web>]
#                                           point-in-time recovery from the repository outside the
#                                           server (S8.3, RESPALDOS.md): PostgreSQL as it was at that
#                                           time ('2026-11-24 15:30:00-05:00') or up to the last WAL
#                                           archived, then the versions noted in the backup used (or
#                                           those given) deployed over it. On a clean server too
#   stack.sh restore-objects --yes          copy the archive of the object storage back into Garage
#   stack.sh authorize-ci "<public key>"    let that SSH key run only remote.sh (the CI's key)
#   stack.sh migrate                        roles, databases and migrations of the deployed versions
#   stack.sh up                             start or update every service and wait until healthy
#   stack.sh postgres-password              give the postgres superuser the password of
#                                           /etc/faclab/secrets/postgres_password (rotation)
#   stack.sh status                         containers, the Collector's health_check and versions
#   stack.sh logs [service...]              follow the logs
#   stack.sh compose <args...>              any docker compose command on the stack
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$HERE/scripts/stack.sh"
ETC="${FACLAB_ETC:-/etc/faclab}"
SECRET_FILES="$ETC/secrets"
STATE="$ETC/deployments"
BACKUPS="${FACLAB_BACKUPS:-/var/backups/faclab/predeploy}"
LOCK="${FACLAB_DEPLOY_LOCK:-/run/faclab-deploy.lock}"
# The user of the core and invoicing images: the secrets they read from a file belong to it
APP_UID=10001
MIN_COMPOSE=2.24
WAIT_TIMEOUT="${DEPLOY_WAIT_TIMEOUT:-300}"
SOAK_SECONDS="${DEPLOY_SOAK_SECONDS:-20}"
KEEP_BACKUPS="${DEPLOY_KEEP_BACKUPS:-5}"
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

# The order of a deployment: infra (what faclab-infra runs from third-party images and the edge
# Caddy), then invoicing, core and web (ADR-0011, S8.2)
INFRA_SERVICES=(postgres kafka kafka-topics object-storage docker-socket-proxy collector caddy)
APP_SERVICES=(invoicing-api invoicing-worker core-api core-worker web)
# Long-running: what must stay up after a deployment
RUNNING_SERVICES=(postgres kafka object-storage docker-socket-proxy collector caddy "${APP_SERVICES[@]}")
# Service, the version variable of its image
VERSIONED=(caddy:INFRA postgres:INFRA invoicing-api:INVOICING invoicing-worker:INVOICING core-api:CORE core-worker:CORE web:WEB)

die() {
  echo "stack.sh: $*" >&2
  exit 1
}

# A heading with the time (UTC): how long each step takes is in the log
step() {
  printf '\n== %s  [%s]\n' "$*" "$(date -u +%H:%M:%S)"
}

need_root() {
  [ "$(id -u)" = 0 ] || die "run it with sudo: the secrets in $ETC are root's"
}

check_compose() {
  local version
  version="$(docker compose version --short 2> /dev/null)" || die "docker compose isn't installed"
  if [ "$(printf '%s\n%s\n' "$MIN_COMPOSE" "${version#v}" | sort -V | head -n 1)" != "$MIN_COMPOSE" ]; then
    die "docker compose $version is too old: $MIN_COMPOSE or later reads several --env-file"
  fi
}

environment() {
  [ -f "$ETC/environment" ] || die "no environment yet: run stack.sh install-secrets <environment>"
  cat "$ETC/environment"
}

env_file() {
  local file
  file="$HERE/env/$(environment).env"
  [ -f "$file" ] || die "$file doesn't exist (copy it from env/production.env.example)"
  printf '%s' "$file"
}

# file_value <file> <name>: the value of a variable (the last one wins, as for docker compose)
file_value() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

env_value() {
  file_value "$(env_file)" "$1"
}

versions_of() {
  printf 'infra %s, core %s, invoicing %s, web %s' "$(file_value "$1" INFRA_VERSION)" \
    "$(file_value "$1" CORE_VERSION)" "$(file_value "$1" INVOICING_VERSION)" "$(file_value "$1" WEB_VERSION)"
}

# docker compose on the stack, with the versions of $VERSIONS (by default, the deployed ones)
compose() {
  local versions="${VERSIONS:-$STATE/current.env}"
  [ -f "$ETC/secrets.env" ] || die "$ETC/secrets.env doesn't exist: run secrets.sh push and install-secrets"
  [ -f "$versions" ] || die "nothing deployed yet ($STATE/current.env): deploy first (README, \"Despliegue\")"
  FACLAB_SECRET_FILES="$SECRET_FILES" docker compose -f "$HERE/compose.yaml" \
    --env-file "$(env_file)" --env-file "$ETC/secrets.env" --env-file "$versions" "$@"
}

repo_owner() {
  stat -c %U "$REPO"
}

# git as the owner of the checkout: as root it would leave files of root in it
repo_git() {
  runuser -u "$(repo_owner)" -- git -C "$REPO" "$@"
}

checkout_infra() {
  echo "faclab-infra: checking out v$1"
  # Tags may be published again (a pre-release), hence --force
  repo_git fetch --quiet --tags --force origin
  repo_git -c advice.detachedHead=false checkout --quiet --detach "refs/tags/v$1"
  echo "faclab-infra at v$1 ($(repo_git rev-parse --short HEAD))"
}

# One deployment at a time. The lock passes to what this script runs or execs (FACLAB_DEPLOY_LOCKED)
take_lock() {
  [ -z "${FACLAB_DEPLOY_LOCKED:-}" ] || return 0
  exec 9> "$LOCK"
  flock -n 9 || die "another deployment is running (lock $LOCK)"
  export FACLAB_DEPLOY_LOCKED=1
}

valid_version() {
  [[ "$1" =~ $SEMVER ]] || die "'$1' isn't a version (X.Y.Z or X.Y.Z-rc.N)"
}

#
# Images
#

image_name() {
  local registry
  registry="$(env_value IMAGE_REGISTRY)"
  case "$1" in
    INFRA) printf '%s/faclab-caddy' "${registry:-ghcr.io/faclab-ec}" ;;
    POSTGRES) printf '%s/faclab-postgres' "${registry:-ghcr.io/faclab-ec}" ;;
    CORE) printf '%s/faclab-api' "${registry:-ghcr.io/faclab-ec}" ;;
    INVOICING) printf '%s/faclab-invoicing' "${registry:-ghcr.io/faclab-ec}" ;;
    WEB) printf '%s/faclab-web' "${registry:-ghcr.io/faclab-ec}" ;;
  esac
}

# The image of a version, pulled and pinned by its digest: name:version@sha256:...
pin_image() {
  local reference="$1:$2" digests digest
  docker pull --quiet "$reference" > /dev/null || die "can't pull $reference: is that version published?"
  digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$reference")"
  digest="$(sed -n "s|^$1@||p" <<< "$digests" | sed -n 1p)"
  [ -n "$digest" ] || die "$reference has no digest from $1"
  printf '%s@%s' "$reference" "$digest"
}

# write_versions <file> <infra> <core> <invoicing> <web>: what compose reads for those versions
write_versions() {
  local file="$1" infra="$2" core="$3" invoicing="$4" web="$5" caddy_image core_image
  local invoicing_image web_image postgres_image=""
  # Assignments, not printf arguments: a failed pull has to stop the script
  caddy_image="$(pin_image "$(image_name INFRA)" "$infra")"
  # PostgreSQL with pgBackRest since the stack of S8.3; an older one runs the official image
  if grep -q 'faclab-postgres' "$HERE/compose.yaml"; then
    postgres_image="$(pin_image "$(image_name POSTGRES)" "$infra")"
  fi
  core_image="$(pin_image "$(image_name CORE)" "$core")"
  invoicing_image="$(pin_image "$(image_name INVOICING)" "$invoicing")"
  web_image="$(pin_image "$(image_name WEB)" "$web")"
  {
    printf '# Versions of a deployment (stack.sh), %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'INFRA_VERSION=%s\nCORE_VERSION=%s\nINVOICING_VERSION=%s\nWEB_VERSION=%s\n' \
      "$infra" "$core" "$invoicing" "$web"
    printf 'CADDY_IMAGE=%s\nCORE_IMAGE=%s\nINVOICING_IMAGE=%s\nWEB_IMAGE=%s\n' \
      "$caddy_image" "$core_image" "$invoicing_image" "$web_image"
    [ -z "$postgres_image" ] || printf 'POSTGRES_IMAGE=%s\n' "$postgres_image"
  } > "$file.tmp"
  mv "$file.tmp" "$file"
}

# Every image but those of the deployed and the previous versions: the published ones and those
# S8.1 built on the server
prune_images() {
  local keep=() file name id kept
  for file in "$STATE/current.env" "$STATE/previous.env"; do
    [ -f "$file" ] || continue
    for name in CADDY_IMAGE POSTGRES_IMAGE CORE_IMAGE INVOICING_IMAGE WEB_IMAGE; do
      [ -n "$(file_value "$file" "$name")" ] || continue
      id="$(docker image inspect --format '{{.Id}}' "$(file_value "$file" "$name")" 2> /dev/null || true)"
      [ -n "$id" ] && keep+=("$id")
    done
  done
  kept="$(printf '%s\n' "${keep[@]}")"
  docker image ls --no-trunc --format '{{.Repository}} {{.ID}}' |
    awk -v registry="$(image_name CORE | sed 's|/[^/]*$||')/" \
      'index($1, registry) == 1 || index($1, "faclab-local/") == 1 { print $2 }' | sort -u |
    while read -r id; do
      # A here-string, not a pipe into grep -q: a SIGPIPE would read as "not kept"
      if ! grep -qxF "$id" <<< "$kept"; then
        docker image rm --force "$id" > /dev/null 2>&1 || true
      fi
    done
}

#
# Databases
#

postgres_running() {
  local running
  running="$(compose ps --status running --services 2> /dev/null || true)"
  grep -qx postgres <<< "$running"
}

psql_value() {
  compose exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres -d "$1" -tAqc "$2"
}

db_exists() {
  [ "$(psql_value postgres "select 1 from pg_database where datname = '$1'")" = 1 ]
}

# The revision of core's schema, or nothing (no database or no migrations yet)
core_revision() {
  postgres_running && db_exists faclab || return 0
  psql_value faclab "select version_num from alembic_version" 2> /dev/null || true
}

# The migrations of faclab-invoicing run on its database, in order
invoicing_applied() {
  postgres_running && db_exists faclab_invoicing || return 0
  psql_value faclab_invoicing "select name from pgmigrations order by run_on, id" 2> /dev/null || true
}

# What the images of a versions file know: core's head and invoicing's migrations
core_head() {
  VERSIONS="$1" compose run --rm --no-deps core-migrate alembic heads | awk 'NR == 1 { print $1 }'
}

core_knows() {
  local output
  if output="$(VERSIONS="$1" compose run --rm --no-deps core-migrate alembic show "$2" 2>&1)"; then
    return 0
  fi
  if grep -q "Can't locate revision" <<< "$output"; then
    return 1
  fi
  printf '%s\n' "$output" >&2
  die "couldn't ask the core image of $(versions_of "$1") about revision $2"
}

invoicing_migrations() {
  VERSIONS="$1" compose run --rm --no-deps --entrypoint ls invoicing-migrate migrations |
    sed -n 's/\.\(sql\|js\|cjs\|ts\)$//p'
}

# schema_down_to <to> <with>: when the database is ahead of what the images of <to> know (an older
# version), take it back to their head with the images of <with>, which know both. Running in order:
# core, then invoicing
schema_down_to() {
  local to="$1" with="$2" revision head applied known extra last
  revision="$(VERSIONS="$with" core_revision)"
  if [ -n "$revision" ] && ! core_knows "$to" "$revision"; then
    head="$(core_head "$to")"
    echo "faclab-core: schema $revision back to $head (alembic downgrade, images of $(versions_of "$with"))"
    VERSIONS="$with" compose run --rm --no-deps core-migrate alembic downgrade "$head"
  fi

  applied="$(VERSIONS="$with" invoicing_applied)"
  [ -n "$applied" ] || return 0
  known="$(invoicing_migrations "$to")"
  extra="$(grep -cvxF -f <(printf '%s\n' "$known") <<< "$applied" || true)"
  [ "$extra" -gt 0 ] || return 0
  # node-pg-migrate down N reverts the last N: they must be the unknown ones
  last="$(tail -n "$extra" <<< "$applied")"
  if grep -qxF -f <(printf '%s\n' "$known") <<< "$last"; then
    die "faclab-invoicing: the migrations $(versions_of "$to") doesn't know aren't the last ones run"
  fi
  echo "faclab-invoicing: $extra migrations down (node-pg-migrate, images of $(versions_of "$with")):"
  awk '{ print "  " $0 }' <<< "$last"
  VERSIONS="$with" compose run --rm --no-deps invoicing-migrate \
    node node_modules/node-pg-migrate/bin/node-pg-migrate.js -m migrations down "$extra"
}

# Roles, databases and migrations up with the images of $VERSIONS (idempotent)
migrate() {
  local admin_url
  echo "Starting PostgreSQL..."
  compose up -d --wait postgres

  # Idempotent; it also applies a new INVOICING_DB_PASSWORD
  echo "faclab-invoicing: role and database..."
  compose exec -T postgres /docker-entrypoint-initdb.d/init-invoicing-db.sh

  # The superuser only reaches this one run, never a service's environment
  echo "faclab-core: roles and database (db_roles)..."
  admin_url="postgresql://postgres:$(cat "$SECRET_FILES/postgres_password")@postgres:5432/postgres"
  DATABASE_URL_ADMIN="$admin_url" compose run --rm --no-deps -e DATABASE_URL_ADMIN \
    core-migrate python -m src.shared.infra.db_roles

  echo "faclab-core: migrations..."
  compose run --rm --no-deps core-migrate
  echo "faclab-invoicing: migrations..."
  compose run --rm --no-deps invoicing-migrate

  # Idempotent. A repository out of reach doesn't fail the deployment: the WAL waits in pg_wal and
  # the alerts wal-sin-archivar and respaldo-atrasado say so (RESPALDOS.md)
  if backups_on; then
    echo "pgBackRest: stanza in the repository..."
    if backup_stanza; then
      wal_archiving on
    else
      echo "stack.sh: WARNING: pgBackRest couldn't create or check its stanza, so WAL isn't archived yet: deploy again once the repository answers (backups.sh status)" >&2
    fi
  else
    wal_archiving off
  fi
}

#
# Backups (S8.3, RESPALDOS.md)
#

backups_on() {
  [ "$(env_value BACKUPS)" != off ]
}

backup_stanza() {
  local attempt output=""
  for attempt in $(seq 1 10); do
    if output="$(compose exec -T -u postgres postgres pgbackrest --stanza=faclab stanza-create 2>&1)"; then
      echo "pgBackRest: the stanza faclab is ready"
      return 0
    fi
    # The archiving of the first segments may hold the stanza's lock for a moment
    grep -q 'unable to acquire lock' <<< "$output" || break
    [ "$attempt" = 10 ] || sleep 3
  done
  printf '%s\n' "$output" >&2
  return 1
}

# wal_archiving <on|off>: PostgreSQL's archiving, in postgresql.auto.conf (ALTER SYSTEM). archive_mode
# needs a restart, only when it changes; the command and its timeout, a reload. archive_timeout is
# the RPO: a segment leaves at most that long after a write, even with little traffic
wal_archiving() {
  local mode="$1" timeout current
  timeout="$(env_value POSTGRES_ARCHIVE_TIMEOUT)"
  timeout="${timeout:-60}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || die "POSTGRES_ARCHIVE_TIMEOUT must be a number of seconds"
  current="$(psql_value postgres "select current_setting('archive_mode') || '|' || current_setting('archive_command') || '|' || setting from pg_settings where name = 'archive_timeout'")"
  if [ "$current" = "$mode|pgbackrest --stanza=faclab archive-push %p|$timeout" ]; then
    echo "PostgreSQL: WAL archiving $mode"
    return 0
  fi
  psql_value postgres "alter system set archive_command = 'pgbackrest --stanza=faclab archive-push %p'" > /dev/null
  psql_value postgres "alter system set archive_timeout = '$timeout'" > /dev/null
  psql_value postgres "alter system set archive_mode = '$mode'" > /dev/null
  current="${current%%|*}"
  if [ "$current" = "$mode" ]; then
    # The command and its timeout only need a reload
    psql_value postgres "select pg_reload_conf()" > /dev/null
    echo "PostgreSQL: WAL archiving $mode, its settings reloaded"
    return 0
  fi
  echo "PostgreSQL: WAL archiving $current -> $mode, restarting it..."
  compose restart postgres
  compose up -d --wait postgres
}

# The timers of scripts/backups.sh, installed or removed as BACKUPS says, after a deployment
backup_timers() {
  if backups_on; then
    "$HERE/scripts/backups.sh" install-timers ||
      echo "stack.sh: WARNING: the backup timers couldn't be installed: run scripts/backups.sh install-timers" >&2
  elif compgen -G '/etc/systemd/system/faclab-backup@*' > /dev/null; then
    "$HERE/scripts/backups.sh" remove-timers || true
  fi
}

# The timers of scripts/heartbeats.sh (S8.6): installed when HEARTBEAT_BASE_URL is set in secrets.env,
# removed when it isn't. Without the heartbeat service there is nothing for them to tell
heartbeat_timers() {
  local url
  url="$(sed -n 's/^HEARTBEAT_BASE_URL=//p' "$ETC/secrets.env" 2> /dev/null | tail -n 1)"
  if [ -n "$url" ]; then
    "$HERE/scripts/heartbeats.sh" install-timers ||
      echo "stack.sh: WARNING: the heartbeat timers couldn't be installed: run scripts/heartbeats.sh install-timers" >&2
  elif compgen -G '/etc/systemd/system/faclab-heartbeat@*' > /dev/null; then
    "$HERE/scripts/heartbeats.sh" remove-timers || true
  fi
}

# The databases before a deployment, in $BACKUPS/<id> (root, 0600), with the versions that ran then.
# S8.3 brings the real backups (PITR, off the server); this one is for going back from a deployment
backup() {
  local id="$1" dir="$BACKUPS/$1" db size need=0 free
  if ! postgres_running; then
    echo "No database running yet: nothing to back up"
    return 0
  fi
  for db in faclab faclab_invoicing; do
    if db_exists "$db"; then
      size="$(psql_value postgres "select pg_database_size('$db')")"
      need=$((need + size))
    fi
  done
  install -d -m 0700 "$BACKUPS"
  free="$(df --output=avail -B1 "$BACKUPS" | tail -n 1)"
  # A dump is smaller than its database; the database's size plus 1 GB keeps the disk breathing
  [ "$free" -gt $((need + 1073741824)) ] ||
    die "not enough disk in $BACKUPS for the backup ($((need / 1048576)) MB of databases, $((free / 1048576)) MB free)"

  install -d -m 0700 "$dir"
  for db in faclab faclab_invoicing; do
    db_exists "$db" || continue
    compose exec -T postgres pg_dump -U postgres -Fc "$db" > "$dir/$db.dump"
    chmod 0600 "$dir/$db.dump"
  done
  if [ -f "$STATE/current.env" ]; then
    install -m 0600 "$STATE/current.env" "$dir/versions.env"
  fi
  echo "Backup $id: $(du -sh "$dir" | cut -f1) in $dir"

  find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | head -n "-$KEEP_BACKUPS" |
    while read -r old; do
      rm -rf "${BACKUPS:?}/$old"
    done
}

#
# Services
#

# answers <url>: a 2xx from inside the proxy network (caddy reaches core, invoicing, web, collector)
answers() {
  local attempt
  for attempt in $(seq 1 20); do
    if compose exec -T caddy wget -q -O /dev/null -T 5 "$1" 2> /dev/null; then
      echo "  ok: $1"
      return 0
    fi
    [ "$attempt" = 20 ] || sleep 3
  done
  echo "  $1 didn't answer 2xx" >&2
  return 1
}

up_group() {
  compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" --no-deps "$@"
}

# bring_up <versions file>: the services in order, each group checked before the next
bring_up() {
  local VERSIONS="$1" recreate=() started
  step "infra (faclab-infra $(file_value "$1" INFRA_VERSION))"
  : "${CHANGE_STARTED:=$(date -u +%s)}"
  up_group "${INFRA_SERVICES[@]}"
  answers http://collector:13133/
  # PostgreSQL started during this change (a new image with faclab-infra, or archiving turned on):
  # the applications that kept running hold pooled connections to the server that stopped, and each
  # would fail one request. They start again with new ones
  started="$(docker inspect --format '{{.State.StartedAt}}' "$(compose ps -q postgres)")"
  if [ "$(date -u -d "$started" +%s)" -ge "$CHANGE_STARTED" ]; then
    echo "PostgreSQL restarted during this change: the applications start again too"
    recreate=(--force-recreate)
  fi

  step "faclab-invoicing $(file_value "$1" INVOICING_VERSION)"
  up_group "${recreate[@]}" invoicing-api invoicing-worker
  answers http://invoicing-api:3173/health

  step "faclab-core $(file_value "$1" CORE_VERSION)"
  up_group "${recreate[@]}" core-api core-worker
  answers http://core-api:8080/health/ready

  step "faclab-web $(file_value "$1" WEB_VERSION)"
  up_group web
  answers http://web:8080/health

  # Services no longer in compose.yaml
  compose up -d --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"
}

# What a browser and an integrator reach, the version of each container and, after a while, that
# nothing restarted nor turned unhealthy
final_checks() {
  local VERSIONS="$1" app api entry service variable expected container label before after
  step "Checks"
  app="$(env_value APP_DOMAIN)"
  api="$(env_value API_DOMAIN)"
  curl -fsSk --max-time 10 --resolve "$api:443:127.0.0.1" -o /dev/null \
    "https://$api/.well-known/jwks.json" || {
    echo "  https://$api/.well-known/jwks.json didn't answer through Caddy" >&2
    return 1
  }
  curl -fsSk --max-time 10 --resolve "$app:443:127.0.0.1" -o /dev/null "https://$app/config.js" || {
    echo "  https://$app/config.js didn't answer through Caddy" >&2
    return 1
  }
  echo "  ok: Caddy routes $api and $app"

  for entry in "${VERSIONED[@]}"; do
    service="${entry%%:*}"
    variable="${entry#*:}_VERSION"
    expected="$(file_value "$1" "$variable")"
    container="$(compose ps -q "$service")"
    label="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$container")"
    if [ "$label" != "$expected" ]; then
      echo "  $service runs $label, not $expected" >&2
      return 1
    fi
  done
  echo "  ok: every container runs its version"

  before="$(service_states)"
  sleep "$SOAK_SECONDS"
  after="$(service_states)"
  if [ "$before" != "$after" ] || grep -qv ' running \(healthy\|-\) ' <<< "$after"; then
    echo "  something changed in ${SOAK_SECONDS}s (service state health restarts):" >&2
    printf '%s\n' "$after" >&2
    return 1
  fi
  echo "  ok: ${SOAK_SECONDS}s later, every service running, healthy and without restarts"
}

service_states() {
  local service container
  for service in "${RUNNING_SERVICES[@]}"; do
    container="$(compose ps -q "$service")"
    if [ -z "$container" ]; then
      echo "$service missing - -"
      continue
    fi
    printf '%s %s\n' "$service" "$(docker inspect --format \
      '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.RestartCount}}' "$container")"
  done
}

#
# Deployments
#

record() {
  install -d -m 0700 "$STATE"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$STATE/history.log"
}

at_tag() {
  local tags
  tags="$(repo_git tag --points-at HEAD)"
  grep -qxF "v$1" <<< "$tags"
}


# The schema back to what the target knows, the migrations, the services and the checks
change_to() {
  local target="$1"
  # bring_up compares PostgreSQL's start with it
  CHANGE_STARTED="$(date -u +%s)"
  if [ -f "$STATE/current.env" ]; then
    schema_down_to "$target" "$STATE/current.env"
  fi
  step "Migrations"
  VERSIONS="$target" migrate
  bring_up "$target"
  final_checks "$target"
}

deploy() {
  local infra="${1:-}" core="${2:-}" invoicing="${3:-}" web="${4:-}"
  local target="$STATE/target.env" current="$STATE/current.env" id status
  [ $# = 4 ] || die "usage: stack.sh deploy <infra> <core> <invoicing> <web>"
  for version in "$@"; do valid_version "$version"; done
  take_lock
  # The stack of that faclab-infra version, under the lock: its compose.yaml and this script's
  # version, which takes over (the lock passes on)
  if ! at_tag "$infra"; then
    checkout_infra "$infra"
    exec "$SCRIPT" deploy "$@"
  fi
  install -d -m 0700 "$STATE"

  step "Images"
  write_versions "$target" "$infra" "$core" "$invoicing" "$web"
  # The third-party images too: a registry that fails stops it here, before anything changes
  VERSIONS="$target" compose pull --quiet --ignore-buildable
  echo "Deploying: $(versions_of "$target")"
  if [ -f "$current" ]; then
    echo "Running:   $(versions_of "$current")"
  else
    echo "Running:   nothing deployed by stack.sh yet, so there is no automatic rollback"
  fi

  id="$(date -u +%Y%m%dT%H%M%SZ)"
  step "Backup"
  VERSIONS="$target" backup "$id"

  set +e
  (
    set -e
    change_to "$target"
  )
  status=$?
  set -e
  if [ "$status" = 0 ]; then
    [ -f "$current" ] && mv "$current" "$STATE/previous.env"
    mv "$target" "$current"
    record "${FACLAB_DEPLOY_KIND:-deployed}" "$(versions_of "$current") (backup $id)"
    step "Pruning images of older versions"
    prune_images
    step "Backups"
    backup_timers
    heartbeat_timers
    printf '\nDeployed: %s (%ss)\n' "$(versions_of "$current")" "$SECONDS"
    return 0
  fi

  printf '\nstack.sh: the deployment of %s failed\n' "$(versions_of "$target")" >&2
  if [ "${FACLAB_DEPLOY_KIND:-}" = restore ]; then
    # The databases are the backup's: the versions that ran before it wouldn't fit them
    record failed "restore of $(versions_of "$target") (backup $id)"
    die "the restored databases are in place, but their versions didn't start: check stack.sh status and the log, and deploy them again"
  fi
  if [ ! -f "$current" ]; then
    record failed "$(versions_of "$target") (backup $id, nothing to roll back to)"
    die "there is no previous deployment to go back to. The databases before it are in backup $id"
  fi
  automatic_rollback "$target" "$current" "$id"
}

automatic_rollback() {
  local target="$1" previous="$2" id="$3" status
  step "Automatic rollback to $(versions_of "$previous")"
  set +e
  (
    set -e
    schema_down_to "$previous" "$target"
  )
  status=$?
  set -e
  if [ "$status" != 0 ]; then
    record rollback-failed "$(versions_of "$target") -> $(versions_of "$previous"): schema (backup $id)"
    die "the schema couldn't go back to what $(versions_of "$previous") knows, and some services may run the new versions. Restore the databases as they were before this deployment, and those versions: sudo stack.sh restore-predeploy $id --yes"
  fi

  set +e
  if [ "$(file_value "$previous" INFRA_VERSION)" != "$(file_value "$target" INFRA_VERSION)" ]; then
    # The stack of the previous version, with its own script: a child, after the checkout
    checkout_infra "$(file_value "$previous" INFRA_VERSION)"
    "$SCRIPT" apply "$previous"
  else
    (
      set -e
      bring_up "$previous"
      final_checks "$previous"
    )
  fi
  status=$?
  set -e
  if [ "$status" != 0 ]; then
    record rollback-failed "$(versions_of "$target") -> $(versions_of "$previous"): services (backup $id)"
    die "the rollback failed too: check stack.sh status. The databases before the deployment are in backup $id"
  fi
  record rolled-back "$(versions_of "$target") failed, $(versions_of "$previous") runs again (backup $id)"
  rm -f "$target"
  echo "stack.sh: rolled back. $(versions_of "$previous") runs again, as before the deployment" >&2
  exit 3
}

# The services of a versions file, without migrations: what the rollback asks of the previous
# version of this script when faclab-infra changed too
apply() {
  local file="${1:?usage: stack.sh apply <versions file>}"
  take_lock
  bring_up "$file"
  final_checks "$file"
}

rollback() {
  local previous="$STATE/previous.env"
  take_lock
  [ -f "$previous" ] || die "there is no previous deployment ($previous)"
  echo "Rolling back to $(versions_of "$previous")"
  # A deployment of those versions (it checks out their faclab-infra; the lock passes on)
  export FACLAB_DEPLOY_KIND=rollback
  deploy "$(file_value "$previous" INFRA_VERSION)" "$(file_value "$previous" CORE_VERSION)" \
    "$(file_value "$previous" INVOICING_VERSION)" "$(file_value "$previous" WEB_VERSION)"
}

deployments() {
  local file
  for file in current previous; do
    if [ -f "$STATE/$file.env" ]; then
      printf '%-9s %s\n' "$file:" "$(versions_of "$STATE/$file.env")"
    fi
  done
  if [ -f "$STATE/history.log" ]; then
    echo
    tail -n 20 "$STATE/history.log"
  fi
}

list_backups() {
  local dir
  [ -d "$BACKUPS" ] || return 0
  for dir in "$BACKUPS"/*/; do
    [ -d "$dir" ] || continue
    if [ -f "$dir/versions.env" ]; then
      printf '%s  %s  %s\n' "$(basename "$dir")" "$(du -sh "$dir" | cut -f1)" "$(versions_of "$dir/versions.env")"
    else
      printf '%s  %s  (before the first deployment by stack.sh)\n' "$(basename "$dir")" "$(du -sh "$dir" | cut -f1)"
    fi
  done
}

# The databases of a backup and the versions that ran when it was taken: the applications stop, both
# databases are created again from the dumps, and those versions are deployed over them (a new
# backup first, migrations that have nothing to do, the services in order and the checks)
restore_predeploy() {
  local id="${1:-}" dir db versions saved
  [ -n "$id" ] || die "usage: stack.sh restore-predeploy <id> --yes (stack.sh backups lists them)"
  dir="$BACKUPS/$id"
  [ -d "$dir" ] || die "there is no backup $id (stack.sh backups)"
  [ "${2:-}" = --yes ] ||
    die "it replaces both databases with backup $id: everything written since is lost. Add --yes"
  take_lock
  versions="$STATE/current.env"
  [ -f "$dir/versions.env" ] && versions="$dir/versions.env"
  # The versions to start, kept apart: deploy rotates the backups and moves current.env
  saved="$STATE/restore.env"
  install -m 0600 "$versions" "$saved"

  step "Stopping the applications"
  VERSIONS="$versions" compose stop "${APP_SERVICES[@]}"
  for db in faclab faclab_invoicing; do
    [ -f "$dir/$db.dump" ] || continue
    step "Restoring $db from backup $id"
    VERSIONS="$versions" compose exec -T postgres dropdb -U postgres --if-exists --force "$db"
    # -C creates it again from the dump: owner, privileges and settings included
    VERSIONS="$versions" compose exec -T postgres pg_restore -U postgres --exit-on-error -C -d postgres < "$dir/$db.dump"
  done
  record restored "databases of backup $id"

  if [ ! -f "$dir/versions.env" ]; then
    die "databases restored; backup $id has no versions (taken before the first deployment by stack.sh): the applications stay stopped until you deploy the versions that ran then"
  fi
  export FACLAB_DEPLOY_KIND=restore
  deploy "$(file_value "$saved" INFRA_VERSION)" "$(file_value "$saved" CORE_VERSION)" \
    "$(file_value "$saved" INVOICING_VERSION)" "$(file_value "$saved" WEB_VERSION)"
}

# The versions noted in the backup a restore to <target> starts from (pgBackRest takes the newest
# one that ended before it): "infra core invoicing web", empty fields when it has no notes. Asked
# with the postgres image of what runs, or of versions/<environment>.env on a clean server
restore_versions() {
  local target="$1" versions="$STATE/current.env" info epoch infra
  if [ ! -f "$versions" ]; then
    versions="$HERE/versions/$(environment).env"
  fi
  if [ ! -f "$versions" ]; then
    # Only its PostgreSQL image reads the repository: the faclab-infra tag checked out says which
    infra="$(repo_git describe --tags --exact-match HEAD 2> /dev/null)" ||
      die "nothing says which faclab-infra to read the repository with: check out a tag (git checkout vX.Y.Z) or pass the four versions"
    versions="$(mktemp)"
    printf 'INFRA_VERSION=%s\nCORE_VERSION=%s\nINVOICING_VERSION=%s\nWEB_VERSION=%s\n' \
      "${infra#v}" "${infra#v}" "${infra#v}" "${infra#v}" > "$versions"
  fi
  info="$(VERSIONS="$versions" compose run --rm --no-deps -T -u postgres postgres \
    pgbackrest --stanza=faclab info --output=json)" ||
    die "pgBackRest couldn't read the repository (its endpoint, bucket and keys are in env/ and secrets.env)"
  # It answers 0 even when the repository doesn't: the status of its JSON says it
  if ! jq -e '.[0].status.code == 0' <<< "$info" > /dev/null; then
    jq -r '"pgBackRest: " + (.[0].status.message // "?") + ([.[0].repo[]?.status.message] | map("; " + .) | join(""))' <<< "$info" >&2
    die "the repository has no backup to restore from"
  fi
  if [ "$target" = latest ]; then
    epoch=99999999999
  else
    epoch="$(date -d "$target" +%s)" || die "'$target' isn't a time: '2026-11-24 15:30:00-05:00'"
  fi
  jq -r --argjson target "$epoch" '
    [.[0].backup[]? | select(.timestamp.stop <= $target)] | last // {}
    | "Backup \(.label // "none") of \(.timestamp.stop // 0 | todate)" as $which
    | (.annotation // {}) | "\(.infra // "") \(.core // "") \(.invoicing // "") \(.web // "")\t\($which)"' <<< "$info"
}

# Waits until PostgreSQL replayed the WAL up to the target and promoted itself (RESTORE_TIMEOUT)
wait_recovery() {
  local waited=0 timeout="${RESTORE_TIMEOUT:-7200}" state
  while true; do
    state="$(psql_value postgres "select pg_is_in_recovery() || ' ' || coalesce(pg_last_xact_replay_timestamp()::text, '-')" 2> /dev/null || true)"
    if [ "${state%% *}" = false ]; then
      echo "PostgreSQL promoted after ${waited}s"
      return 0
    fi
    [ "$waited" -lt "$timeout" ] || die "PostgreSQL still recovering after ${timeout}s (stack.sh logs postgres)"
    if [ $((waited % 60)) = 0 ]; then
      echo "  recovering: last transaction replayed ${state#* }"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

# Point-in-time recovery (S8.3, RESPALDOS.md): PostgreSQL from the repository outside the server, as
# it was at <target> or up to the last WAL archived (latest), and the versions that ran then
# deployed over it. On a clean server (after install-secrets) the database is created from the
# backup; on this one, pgBackRest rewrites only what differs (--delta). What was written after the
# target is lost
restore() {
  local target="${1:-}" infra core invoicing web which versions revision applied known args
  if [ -z "$target" ] || [ "${2:-}" != --yes ]; then
    die "usage: stack.sh restore <'YYYY-MM-DD HH:MM:SS-05:00' | latest> --yes [<infra> <core> <invoicing> <web>]. It replaces both databases: what was written after that time is lost"
  fi
  shift 2
  take_lock
  if [ $# = 4 ]; then
    for version in "$@"; do valid_version "$version"; done
    infra="$1" core="$2" invoicing="$3" web="$4"
  elif [ $# = 0 ]; then
    IFS=$'\t' read -r versions which <<< "$(restore_versions "$target")"
    read -r infra core invoicing web <<< "$versions"
    [ -n "$web" ] ||
      die "$which has no versions noted: pass them (stack.sh restore '$target' --yes <infra> <core> <invoicing> <web>)"
    echo "$which: infra $infra, core $core, invoicing $invoicing, web $web"
  else
    die "usage: stack.sh restore <time|latest> --yes [<infra> <core> <invoicing> <web>]"
  fi
  # The stack of that faclab-infra version, as deploy does
  if ! at_tag "$infra"; then
    checkout_infra "$infra"
    exec "$SCRIPT" restore "$target" --yes "$infra" "$core" "$invoicing" "$web"
  fi
  install -d -m 0700 "$STATE"
  versions="$STATE/restore.env"

  step "Images"
  write_versions "$versions" "$infra" "$core" "$invoicing" "$web"
  VERSIONS="$versions" compose pull --quiet --ignore-buildable

  step "Stopping the applications and PostgreSQL"
  VERSIONS="$versions" compose stop "${APP_SERVICES[@]}" postgres
  # With the container stopped, a postmaster.pid left by a PostgreSQL that died (the server a restore
  # is for) means nothing, and pgBackRest would refuse to restore over it
  VERSIONS="$versions" compose run --rm --no-deps -T -u postgres --entrypoint rm postgres \
    -f /var/lib/postgresql/data/postmaster.pid

  step "Restoring PostgreSQL ($target)"
  args=(--delta)
  [ "$target" = latest ] || args+=(--type=time "--target=$target" --target-action=promote)
  # A server that only restores (a drill) must not archive into the repository it comes from: the
  # restored postgresql.auto.conf would keep archiving on
  backups_on || args+=(--archive-mode=off)
  VERSIONS="$versions" compose run --rm --no-deps -T -u postgres postgres \
    pgbackrest --stanza=faclab restore "${args[@]}"

  step "Replaying the WAL"
  VERSIONS="$versions" compose up -d --no-deps postgres
  VERSIONS="$versions" wait_recovery

  # The images must know the schema the databases came back with
  revision="$(VERSIONS="$versions" core_revision)"
  if [ -n "$revision" ] && ! core_knows "$versions" "$revision"; then
    die "core $core doesn't know revision $revision of the restored database: the applications stay stopped. Restore again with the versions that ran at $target"
  fi
  applied="$(VERSIONS="$versions" invoicing_applied)"
  known="$(invoicing_migrations "$versions")"
  if [ -n "$applied" ] && grep -qvxF -f <(printf '%s\n' "$known") <<< "$applied"; then
    die "invoicing $invoicing doesn't know every migration of the restored database: the applications stay stopped. Restore again with the versions that ran at $target"
  fi
  record restored "PostgreSQL at $target (pgBackRest)"

  export FACLAB_DEPLOY_KIND=restore
  deploy "$infra" "$core" "$invoicing" "$web"
  # A new timeline begins: a full backup of it, in the background
  if backups_on; then
    systemctl start --no-block faclab-backup@full.service &&
      echo "A full backup of the restored databases started (journalctl -u faclab-backup@full)"
  fi
  echo "Next: stack.sh restore-objects --yes, and the checks of RESPALDOS.md (sequences of the SRI)"
}

# The archive of the object storage (authorized XML, RIDE, logos) back into Garage: the latest
# version of each object, over what has the same key
restore_objects() {
  [ "${1:-}" = --yes ] ||
    die "usage: stack.sh restore-objects --yes (it writes the archive's objects into Garage, over those with the same key)"
  compose up -d --wait --no-deps object-storage
  step "Copying the archive into Garage"
  compose run --rm --no-deps objects-backup restore
  compose run --rm --no-deps objects-backup count
}

authorize_ci() {
  local key="${1:-}" type blob owner home file tmp
  read -r type blob _ <<< "$key"
  case "$type" in
    ssh-ed25519 | ecdsa-sha2-* | sk-ssh-ed25519@openssh.com) ;;
    *) die "usage: stack.sh authorize-ci \"ssh-ed25519 AAAA...\" (an Ed25519 or ECDSA public key)" ;;
  esac
  [ -n "$blob" ] || die "the key has no body"
  owner="$(repo_owner)"
  home="$(getent passwd "$owner" | cut -d: -f6)"
  file="$home/.ssh/authorized_keys"
  tmp="$(mktemp)"
  # One CI key at a time: the line that ends in faclab-ci is replaced
  grep -v ' faclab-ci$' "$file" > "$tmp" || true
  printf 'restrict,command="%s/scripts/remote.sh" %s %s faclab-ci\n' "$HERE" "$type" "$blob" >> "$tmp"
  install -m 0600 -o "$owner" -g "$owner" "$tmp" "$file"
  rm -f "$tmp"
  echo "That key of $owner can only run remote.sh (deploy, rollback, status, deployments): no shell nor forwarding"
}

install_secrets() {
  local target="${1:?usage: stack.sh install-secrets <environment>}"
  local home incoming
  [ -f "$HERE/env/$target.env" ] || die "$HERE/env/$target.env doesn't exist"
  home="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"
  incoming="$home/.faclab-incoming"
  for file in secrets.env secrets/postgres_password secrets/jwt_private_key.pem secrets/secret_encryption_keys; do
    [ -s "$incoming/$file" ] || die "$incoming/$file is missing or empty: run secrets.sh push first"
  done

  # The directory blocks the host's users; inside a container each file is checked by itself
  install -d -m 0700 -o root -g root "$ETC" "$SECRET_FILES"
  install -m 0600 -o root -g root "$incoming/secrets.env" "$ETC/secrets.env"
  # postgres' entrypoint reads it as root before switching to the postgres user
  install -m 0400 -o root -g root "$incoming/secrets/postgres_password" "$SECRET_FILES/postgres_password"
  install -m 0400 -o "$APP_UID" -g "$APP_UID" "$incoming/secrets/jwt_private_key.pem" \
    "$SECRET_FILES/jwt_private_key.pem"
  install -m 0400 -o "$APP_UID" -g "$APP_UID" "$incoming/secrets/secret_encryption_keys" \
    "$SECRET_FILES/secret_encryption_keys"
  printf '%s\n' "$target" > "$ETC/environment"
  chmod 0644 "$ETC/environment"
  rm -rf "$incoming"
  echo "Secrets of $target installed in $ETC."
}

up() {
  compose up -d --remove-orphans --wait --wait-timeout 600
}

# The image reads postgres_password only when it creates the database: a new one reaches the role
# through ALTER ROLE, over stdin (never in a command line). Hex, so it needs no quoting
postgres_password() {
  local password
  password="$(cat "$SECRET_FILES/postgres_password")"
  [[ "$password" =~ ^[0-9a-f]+$ ]] || die "postgres_password must be hex (secrets.sh generate hex)"
  printf "ALTER ROLE postgres PASSWORD '%s';\n" "$password" |
    compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres
  echo "postgres: password changed"
}

status() {
  compose ps --all
  echo "deployed: $(versions_of "$STATE/current.env")"
  # The Collector's image has no shell for a Docker healthcheck: ask its health_check extension
  # from caddy, which shares the proxy network with it
  if compose exec -T caddy wget -q -O /dev/null http://collector:13133/ 2> /dev/null; then
    echo "collector: healthy (health_check :13133)"
  else
    echo "collector: NOT healthy (health_check :13133 didn't answer)"
    return 1
  fi
}

main() {
  local command="${1:-}"
  [ -n "$command" ] || {
    sed -n '2,36p' "$SCRIPT"
    exit 1
  }
  shift
  need_root
  check_compose
  case "$command" in
    install-secrets) install_secrets "$@" ;;
    deploy) deploy "$@" ;;
    rollback) rollback ;;
    apply) apply "$@" ;;
    deployments) deployments ;;
    backups) list_backups ;;
    restore-predeploy) restore_predeploy "$@" ;;
    restore) restore "$@" ;;
    restore-objects) restore_objects "$@" ;;
    authorize-ci) authorize_ci "$@" ;;
    migrate) migrate ;;
    up) up ;;
    postgres-password) postgres_password ;;
    status) status ;;
    logs) compose logs -f --tail=100 "$@" ;;
    compose) compose "$@" ;;
    build | install) die "'$command' is gone since S8.2: images come from GHCR; deploy with scripts/deploy.sh (README, \"Despliegue\")" ;;
    *) die "unknown command: $command" ;;
  esac
}

# On one line: a deployment may check out another version of this file while it runs, and bash
# reads a script as it goes
main "$@"; exit $?
