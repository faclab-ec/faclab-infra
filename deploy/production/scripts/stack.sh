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
VERSIONED=(caddy:INFRA invoicing-api:INVOICING invoicing-worker:INVOICING core-api:CORE core-worker:CORE web:WEB)

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
  local invoicing_image web_image
  # Assignments, not printf arguments: a failed pull has to stop the script
  caddy_image="$(pin_image "$(image_name INFRA)" "$infra")"
  core_image="$(pin_image "$(image_name CORE)" "$core")"
  invoicing_image="$(pin_image "$(image_name INVOICING)" "$invoicing")"
  web_image="$(pin_image "$(image_name WEB)" "$web")"
  {
    printf '# Versions of a deployment (stack.sh), %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'INFRA_VERSION=%s\nCORE_VERSION=%s\nINVOICING_VERSION=%s\nWEB_VERSION=%s\n' \
      "$infra" "$core" "$invoicing" "$web"
    printf 'CADDY_IMAGE=%s\nCORE_IMAGE=%s\nINVOICING_IMAGE=%s\nWEB_IMAGE=%s\n' \
      "$caddy_image" "$core_image" "$invoicing_image" "$web_image"
  } > "$file.tmp"
  mv "$file.tmp" "$file"
}

# Every image but those of the deployed and the previous versions: the published ones and those
# S8.1 built on the server
prune_images() {
  local keep=() file name id kept
  for file in "$STATE/current.env" "$STATE/previous.env"; do
    [ -f "$file" ] || continue
    for name in CADDY_IMAGE CORE_IMAGE INVOICING_IMAGE WEB_IMAGE; do
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
  local VERSIONS="$1"
  step "infra (faclab-infra $(file_value "$1" INFRA_VERSION))"
  up_group "${INFRA_SERVICES[@]}"
  answers http://collector:13133/

  step "faclab-invoicing $(file_value "$1" INVOICING_VERSION)"
  up_group invoicing-api invoicing-worker
  answers http://invoicing-api:3173/health

  step "faclab-core $(file_value "$1" CORE_VERSION)"
  up_group core-api core-worker
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
    sed -n '2,30p' "$SCRIPT"
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
