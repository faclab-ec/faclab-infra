#!/usr/bin/env bash
# SigNoz local for the Faclab services: SigNoz's own Docker Compose plus
# observability/docker-compose.signoz.yml, which joins its OTel collector to faclab_network.
#
#   scripts/signoz.sh up       start SigNoz (clones it first when SIGNOZ_DIR doesn't exist)
#   scripts/signoz.sh down     stop it; the data volumes stay
#   scripts/signoz.sh status   containers and endpoints
#   scripts/signoz.sh config   validate the combined compose files (CI)
#
# SIGNOZ_DIR: SigNoz checkout (default ../Telemetry, next to this repo).
# SIGNOZ_VERSION: tag cloned when SIGNOZ_DIR doesn't exist (default v0.118.0).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNOZ_VERSION="${SIGNOZ_VERSION:-v0.118.0}"
SIGNOZ_DIR="${SIGNOZ_DIR:-$ROOT/../Telemetry}"
COMPOSE_DIR="$SIGNOZ_DIR/deploy/docker"

ensure_signoz() {
  if [[ -f "$COMPOSE_DIR/docker-compose.yaml" ]]; then
    return
  fi
  echo "SigNoz not found in $SIGNOZ_DIR: cloning $SIGNOZ_VERSION (deploy/ only)"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$SIGNOZ_VERSION" \
    --filter=blob:none --sparse \
    https://github.com/SigNoz/signoz.git "$SIGNOZ_DIR"
  git -C "$SIGNOZ_DIR" sparse-checkout set deploy
}

compose() {
  # The project directory is SigNoz's (first file): its .env and relative paths apply
  docker compose \
    -f "$COMPOSE_DIR/docker-compose.yaml" \
    -f "$ROOT/observability/docker-compose.signoz.yml" \
    "$@"
}

# Until its first admin account exists, SigNoz gives the collector no pipelines and nothing
# listens on 4317/4318 ("cannot create agent without orgId")
setup_reminder() {
  local version=""
  for _ in $(seq 1 30); do
    version="$(curl -fsS --max-time 2 http://localhost:8080/api/v1/version 2>/dev/null)" && break
    sleep 2
  done
  if [[ "$version" == *'"setupCompleted":false'* ]]; then
    echo "First run: create the admin account at http://localhost:8080;" \
      "until then the collector accepts no data."
  fi
}

endpoints() {
  cat <<EOF
SigNoz UI: http://localhost:8080
OTLP from the host: http://localhost:4317 (gRPC), http://localhost:4318 (HTTP)
OTLP from containers on faclab_network: http://signoz-otel-collector:4317
EOF
}

case "${1:-}" in
  up)
    ensure_signoz
    docker network inspect faclab_network >/dev/null 2>&1 ||
      docker network create faclab_network >/dev/null
    compose up -d
    endpoints
    setup_reminder
    ;;
  down)
    compose down
    ;;
  status)
    compose ps
    endpoints
    setup_reminder
    ;;
  config)
    ensure_signoz
    compose config -q
    echo "SigNoz compose with the faclab_network overlay is valid"
    ;;
  *)
    echo "Usage: $0 up|down|status|config" >&2
    exit 1
    ;;
esac
