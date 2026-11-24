#!/usr/bin/env bash
# Validates the production stack without a server (S8.1): CI runs it, and so can anyone from the
# root of faclab-infra. Docker is the only requirement.
#
# - compose.yaml with each env file (staging and the production example) and its versions file
#   (versions/<environment>.env), the tasks included, against secrets.env.example and placeholder
#   files; its images, the published ones of each version (S8.2);
# - both versions files against the compatibility matrix (COMPATIBILITY.md, compat.py);
# - the edge Caddy: its image and its Caddyfile in both TLS modes, formatted;
# - PostgreSQL with pgBackRest (S8.3): its image and that pgbackrest.conf reads without warnings; and
#   that the production example keeps the TLS verification of the backups' storage;
# - the Collector with the production overlay, and that the overlay's metrics pipeline is the base
#   one without postgresql/invoicing;
# - that no secret file is versioned.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEPLOY="$ROOT/deploy/production"
cd "$ROOT"

PLACEHOLDERS="$(mktemp -d)"
# Its own project name: the networks and volumes it creates are never the stack's (faclab)
PROJECT=faclab-ci
cleanup() {
  docker compose -p "$PROJECT" -f "$DEPLOY/compose.yaml" --env-file "$DEPLOY/env/staging.env" \
    --env-file "$DEPLOY/secrets.env.example" --env-file "$DEPLOY/versions/staging.env" \
    down --volumes --remove-orphans > /dev/null 2>&1 || true
  rm -rf "$PLACEHOLDERS"
}
trap cleanup EXIT
for file in postgres_password jwt_private_key.pem secret_encryption_keys; do
  echo placeholder > "$PLACEHOLDERS/$file"
done
export FACLAB_SECRET_FILES="$PLACEHOLDERS"

# compose <environment> <compose args...>: with its env file (production: the example) and versions
compose() {
  local environment="$1" env_file
  shift
  env_file="$DEPLOY/env/$environment.env"
  [ -f "$env_file" ] || env_file="$DEPLOY/env/$environment.env.example"
  docker compose -p "$PROJECT" -f "$DEPLOY/compose.yaml" --env-file "$env_file" \
    --env-file "$DEPLOY/secrets.env.example" --env-file "$DEPLOY/versions/$environment.env" "$@"
}

# version <environment> <name>: from versions/<environment>.env
version() {
  sed -n "s/^$2=//p" "$DEPLOY/versions/$1.env" | tail -n 1
}

echo "== compose.yaml"
for environment in staging production; do
  compose "$environment" --profile tasks config -q
  # Each service runs the image its release workflow published for that version (S8.2), which
  # carries the version as SERVICE_VERSION; and every service exports to the Collector, not to
  # localhost (OBSERVABILITY.md §10)
  rendered="$(compose "$environment" --profile tasks config)"
  for expected in "OTEL_OTLP_ENDPOINT: http://collector:4317" \
    "OTEL_EXPORTER_OTLP_ENDPOINT: http://collector:4317" \
    "image: ghcr.io/faclab-ec/faclab-caddy:$(version "$environment" INFRA_VERSION)" \
    "image: ghcr.io/faclab-ec/faclab-postgres:$(version "$environment" INFRA_VERSION)" \
    "image: ghcr.io/faclab-ec/faclab-api:$(version "$environment" CORE_VERSION)" \
    "image: ghcr.io/faclab-ec/faclab-invoicing:$(version "$environment" INVOICING_VERSION)" \
    "image: ghcr.io/faclab-ec/faclab-web:$(version "$environment" WEB_VERSION)"; do
    if ! grep -qF "$expected" <<< "$rendered"; then
      echo "compose.yaml with $environment lost '$expected'" >&2
      exit 1
    fi
  done
  if grep -E 'image: (faclab-local/|.*:latest$)' <<< "$rendered"; then
    echo "compose.yaml with $environment: images are published versions, never local nor latest" >&2
    exit 1
  fi
  echo "ok: $environment (published images of its versions, the Collector's endpoint)"
done

# The S3 stand-in of staging and the drills (S8.3), with placeholder keys
STANDIN_DIR="$PLACEHOLDERS" STANDIN_ROOT_ACCESS_KEY=placeholder STANDIN_ROOT_SECRET_KEY=placeholder \
  docker compose -f "$DEPLOY/drill/compose.yaml" config -q
echo "ok: drill/compose.yaml"

echo "== Versions against the compatibility matrix"
for environment in staging production; do
  python3 "$DEPLOY/scripts/compat.py" "$DEPLOY/versions/$environment.env"
done

echo "== Caddy"
STAGING=staging
compose "$STAGING" build -q caddy
for mode in acme internal; do
  output="$(compose "$STAGING" run --rm --no-deps -e CADDY_TLS_MODE="$mode" -e ACME_EMAIL=ops@example.com \
    caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"
  if ! grep -q "Valid configuration" <<< "$output"; then
    printf '%s\n' "$output" >&2
    exit 1
  fi
  echo "ok: Caddyfile with CADDY_TLS_MODE=$mode"
done
compose "$STAGING" run --rm --no-deps caddy caddy fmt --diff /etc/caddy/Caddyfile > /dev/null ||
  {
    echo "caddy/Caddyfile isn't formatted: caddy fmt --overwrite" >&2
    exit 1
  }

echo "== PostgreSQL with pgBackRest"
compose "$STAGING" build -q postgres
compose "$STAGING" run --rm --no-deps -T -u postgres postgres pgbackrest version
# pgBackRest warns about an option it doesn't know in pgbackrest.conf. A repository on the
# container's disk stands for the bucket: the configuration is read, nothing leaves
output="$(compose "$STAGING" run --rm --no-deps -T -u postgres -e PGBACKREST_REPO1_TYPE=posix \
  -e PGBACKREST_REPO1_PATH=/tmp/repository postgres pgbackrest --stanza=faclab info 2>&1)"
if grep -qE 'WARN|ERROR' <<< "$output"; then
  printf '%s\n' "$output" >&2
  echo "postgres/pgbackrest.conf: pgBackRest doesn't read it cleanly" >&2
  exit 1
fi
echo "ok: pgbackrest.conf"
# Only a stand-in with a self-signed certificate turns it off (staging, RESPALDOS.md)
if grep -q '^BACKUP_S3_VERIFY_TLS=n' "$DEPLOY/env/production.env.example"; then
  echo "env/production.env.example: the backups' storage keeps its TLS verification" >&2
  exit 1
fi
echo "ok: production verifies the TLS of the backups' storage"

echo "== Collector"
compose "$STAGING" run --rm --no-deps collector validate \
  --config=/etc/otelcol-contrib/config.yaml --config=/etc/otelcol-contrib/production.yaml \
  --feature-gates=receiver.postgresql.separateSchemaAttr
# The receivers of the metrics pipeline, in order, from each file
metrics_receivers() {
  docker run --rm -i mikefarah/yq:4 '.service.pipelines.metrics.receivers | join(" ")' < "$1"
}
base="$(metrics_receivers observability/otel-collector/config.yaml)"
overlay="$(metrics_receivers "$DEPLOY/otel-collector.yaml")"
expected="$(printf '%s\n' "$base" | tr ' ' '\n' | grep -vx 'postgresql/invoicing' | paste -sd ' ' -)"
if [ "$overlay" != "$expected" ]; then
  echo "otel-collector.yaml: the metrics receivers must be the base ones without postgresql/invoicing" >&2
  echo "  base:     $base" >&2
  echo "  overlay:  $overlay" >&2
  exit 1
fi
echo "ok: metrics receivers ($overlay)"

echo "== No secrets in the repository"
if git ls-files | grep -E '(^|/)secrets\.env$|\.sops\.ya?ml$|\.pem$|(^|/)\.sops\.yaml$|age.*key.*\.txt$'; then
  echo "those files must never be versioned (deploy/production/README.md, Secretos)" >&2
  exit 1
fi
echo "ok"
