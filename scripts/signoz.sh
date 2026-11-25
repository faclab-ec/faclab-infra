#!/usr/bin/env bash
# SigNoz local for the Faclab services (S7.5), installed with Foundry: `foundryctl forge` turns
# observability/signoz/casting.yaml into a Docker Compose deployment under
# observability/signoz/pours/, which this script runs. SigNoz's ingester joins faclab_network as
# signoz-otel-collector, without host ports: the services export to the Faclab collector
# (docker-compose.yml, S7.4), which forwards to it.
#
#   scripts/signoz.sh up       forge and start SigNoz
#   scripts/signoz.sh down     stop it; the data volumes stay
#   scripts/signoz.sh status   containers and endpoints
#   scripts/signoz.sh config   forge and validate the generated compose file (CI)
#   scripts/signoz.sh check    validate the dashboards, alerts and runbooks offline (CI)
#   scripts/signoz.sh sync     create or update the channels, dashboards and alerts in SigNoz
#   scripts/signoz.sh verify   run every panel and alert query against SigNoz
#   scripts/signoz.sh retention  set and read back the retention of logs, traces and metrics (D-7)
#
# sync and verify take SIGNOZ_URL and SIGNOZ_API_KEY from the environment or .env (see
# scripts/signoz-sync.py and the README).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNOZ_HOME="$ROOT/observability/signoz"
CASTING="$SIGNOZ_HOME/casting.yaml"
POURS="$SIGNOZ_HOME/pours"
COMPOSE_FILE="$POURS/deployment/compose.yaml"

# foundryctl, pinned: the release archive is checked against these digests (from the release's
# foundry_<version>_checksums.txt) before it is unpacked into .foundry/
FOUNDRY_VERSION="0.5.0"
FOUNDRY_DIR="$ROOT/.foundry/v$FOUNDRY_VERSION"
FOUNDRYCTL="$FOUNDRY_DIR/foundryctl"

foundry_sha256() {
  case "$1" in
    darwin_amd64) echo "18f83860602ac0a4ef05e8b51901945d155a71b2932af369e2ad6a73bf414b1d" ;;
    darwin_arm64) echo "00bb738457239ef6dce3844964214c9a10182cc2dde670ff071edb0752e69115" ;;
    linux_amd64) echo "b2f21e0cf12e9fa0f32dcaf414ec97823b32a29c3252bee23b896d158af2c650" ;;
    linux_arm64) echo "0482f952b706c46d4030df825bf6abde7cadacde4a35d121ab93098025e7a194" ;;
    *) return 1 ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

ensure_foundry() {
  if [[ -x "$FOUNDRYCTL" ]]; then
    return
  fi
  local os arch platform expected tmp
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
  esac
  platform="${os}_${arch}"
  if ! expected="$(foundry_sha256 "$platform")"; then
    echo "foundryctl $FOUNDRY_VERSION has no pinned build for $platform" >&2
    exit 1
  fi
  tmp="$(mktemp -d)"
  echo "Downloading foundryctl v$FOUNDRY_VERSION ($platform)"
  curl -fsSL -o "$tmp/foundry.tar.gz" \
    "https://github.com/SigNoz/foundry/releases/download/v$FOUNDRY_VERSION/foundry_${platform}.tar.gz"
  if [[ "$(sha256_of "$tmp/foundry.tar.gz")" != "$expected" ]]; then
    rm -rf "$tmp"
    echo "foundryctl archive checksum mismatch; not installing it" >&2
    exit 1
  fi
  tar -xzf "$tmp/foundry.tar.gz" -C "$tmp"
  mkdir -p "$FOUNDRY_DIR"
  mv "$tmp/foundry_${platform}/bin/foundryctl" "$FOUNDRYCTL"
  chmod +x "$FOUNDRYCTL"
  rm -rf "$tmp"
}

# The forge only writes files (pours/ and casting.yaml.lock, both ignored by git). Foundry's
# anonymous usage ledger and update check stay off
forge() {
  ensure_foundry
  "$FOUNDRYCTL" --no-ledger --no-updater --format text \
    forge -f "$CASTING" -p "$POURS" >/dev/null
}

compose() {
  local env_args=()
  # The ${VAR:-default} values of the casting (SMTP, external URL) come from faclab-infra's .env
  if [[ -f "$ROOT/.env" ]]; then
    env_args=(--env-file "$ROOT/.env")
  fi
  docker compose "${env_args[@]}" -f "$COMPOSE_FILE" "$@"
}

ensure_network() {
  docker network inspect faclab_network >/dev/null 2>&1 ||
    docker network create faclab_network >/dev/null
}

# Until its first admin account exists, SigNoz gives its ingester no pipelines and it accepts
# nothing from the Faclab collector
setup_reminder() {
  local version=""
  for _ in $(seq 1 60); do
    version="$(curl -fsS --max-time 2 http://localhost:8080/api/v1/version 2>/dev/null)" && break
    sleep 2
  done
  if [[ "$version" == *'"setupCompleted":false'* ]]; then
    echo "First run: create the admin account at http://localhost:8080;" \
      "until then SigNoz accepts no data."
  fi
}

endpoints() {
  cat <<EOF
SigNoz UI: http://localhost:8080
The services export to the Faclab collector (docker compose up -d collector):
  from the host: http://localhost:4317 (gRPC), http://localhost:4318 (browser, OTLP/HTTP)
  from containers on faclab_network: http://collector:4317
It forwards to SigNoz's ingester at signoz-otel-collector:4317 (faclab_network only).
EOF
}

case "${1:-}" in
  up)
    ensure_network
    forge
    compose up -d
    endpoints
    setup_reminder
    ;;
  down)
    forge
    compose down
    ;;
  status)
    forge
    compose ps
    endpoints
    setup_reminder
    ;;
  config)
    forge
    compose config -q
    echo "SigNoz compose forged from observability/signoz/casting.yaml is valid"
    ;;
  check | sync | verify | retention)
    exec python3 "$ROOT/scripts/signoz-sync.py" "$@"
    ;;
  *)
    echo "Usage: $0 up|down|status|config|check|sync|verify|retention" >&2
    exit 1
    ;;
esac
