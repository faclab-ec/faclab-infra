#!/usr/bin/env bash
# The production stack of Faclab on its server (S8.1): docker compose with compose.yaml, the env file
# of the environment (env/<environment>.env) and the secrets (/etc/faclab/secrets.env and the files
# of /etc/faclab/secrets). Run it with sudo from the faclab-infra checkout: it reads /etc/faclab.
#
#   stack.sh install-secrets <environment>  move what secrets.sh push left in ~/.faclab-incoming to
#                                           /etc/faclab, with owners and modes, and remember the
#                                           environment
#   stack.sh build                          build the images one at a time (caddy, and core,
#                                           invoicing and web when IMAGES_FROM=git)
#   stack.sh migrate                        invoicing's role and database, core's roles and
#                                           database (db_roles), and both migrations
#   stack.sh up                             start or update every service and wait until healthy
#   stack.sh install                        build, migrate and up: the first installation
#   stack.sh postgres-password              give the postgres superuser the password of
#                                           /etc/faclab/secrets/postgres_password (rotation)
#   stack.sh status                         containers, and the Collector's health_check
#   stack.sh logs [service...]              follow the logs
#   stack.sh compose <args...>              any docker compose command on the stack
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ETC="${FACLAB_ETC:-/etc/faclab}"
SECRET_FILES="$ETC/secrets"
# The user of the core and invoicing images: the secrets they read from a file belong to it
APP_UID=10001
MIN_COMPOSE=2.24

die() {
  echo "stack.sh: $*" >&2
  exit 1
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

# The value of a variable of the env file (the last one wins, as for docker compose)
env_value() {
  sed -n "s/^$1=//p" "$(env_file)" | tail -n 1
}

images_from_git() {
  [ "$(env_value IMAGES_FROM)" = git ]
}

compose() {
  local files=(-f "$HERE/compose.yaml")
  if images_from_git; then
    files+=(-f "$HERE/compose.build.yml")
  fi
  [ -f "$ETC/secrets.env" ] || die "$ETC/secrets.env doesn't exist: run secrets.sh push and install-secrets"
  FACLAB_SECRET_FILES="$SECRET_FILES" docker compose "${files[@]}" \
    --env-file "$(env_file)" --env-file "$ETC/secrets.env" "$@"
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

build() {
  # One at a time: building the web and core together doesn't fit in a small server
  local services=(caddy)
  if images_from_git; then
    services+=(core-api invoicing-api web)
  fi
  for service in "${services[@]}"; do
    echo "Building $service..."
    compose build "$service"
  done
}

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
    sed -n '2,21p' "${BASH_SOURCE[0]}"
    exit 1
  }
  shift
  need_root
  check_compose
  case "$command" in
    install-secrets) install_secrets "$@" ;;
    build) build ;;
    migrate) migrate ;;
    up) up ;;
    install)
      build
      migrate
      up
      status
      ;;
    postgres-password) postgres_password ;;
    status) status ;;
    logs) compose logs -f --tail=100 "$@" ;;
    compose) compose "$@" ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
