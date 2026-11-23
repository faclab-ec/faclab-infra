#!/usr/bin/env bash
# Validates the production stack without a server (S8.1): CI runs it, and so can anyone from the
# root of faclab-infra. Docker is the only requirement.
#
# - compose.yaml with each env file (staging and the production example), with and without
#   compose.build.yml, the tasks included, against secrets.env.example and placeholder files;
# - the edge Caddy: its image and its Caddyfile in both TLS modes, formatted;
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
    --env-file "$DEPLOY/secrets.env.example" down --volumes --remove-orphans > /dev/null 2>&1 || true
  rm -rf "$PLACEHOLDERS"
}
trap cleanup EXIT
for file in postgres_password jwt_private_key.pem secret_encryption_keys; do
  echo placeholder > "$PLACEHOLDERS/$file"
done
export FACLAB_SECRET_FILES="$PLACEHOLDERS"

# compose <env file> <compose args...>
compose() {
  local env_file="$1"
  shift
  docker compose -p "$PROJECT" -f "$DEPLOY/compose.yaml" --env-file "$env_file" \
    --env-file "$DEPLOY/secrets.env.example" "$@"
}

STAGING_ENV="$DEPLOY/env/staging.env"

echo "== compose.yaml"
for env_file in "$DEPLOY/env/staging.env" "$DEPLOY/env/production.env.example"; do
  compose "$env_file" --profile tasks config -q
  compose "$env_file" -f "$DEPLOY/compose.build.yml" --profile tasks config -q
  echo "ok: $(basename "$env_file")"
done

# What S7.6 asked of the deployment (OBSERVABILITY.md §10): each image built with its version, and
# every service exporting to the Collector, not to localhost
rendered="$(compose "$STAGING_ENV" -f "$DEPLOY/compose.build.yml" --profile tasks config)"
for expected in "OTEL_OTLP_ENDPOINT: http://collector:4317" \
  "OTEL_EXPORTER_OTLP_ENDPOINT: http://collector:4317" "SERVICE_VERSION:"; do
  if ! grep -qF "$expected" <<< "$rendered"; then
    echo "compose.yaml or compose.build.yml lost '$expected'" >&2
    exit 1
  fi
done
if [ "$(grep -c 'SERVICE_VERSION:' <<< "$rendered")" -lt 3 ]; then
  echo "compose.build.yml must pass SERVICE_VERSION to the core, invoicing and web builds" >&2
  exit 1
fi
echo "ok: SERVICE_VERSION and the Collector's endpoint"

echo "== Caddy"
STAGING="$STAGING_ENV"
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
