#!/usr/bin/env bash
# The end-to-end suite of Faclab (S9.1) against the real system, thrown away at the end: builds the
# images from the sibling repositories, starts e2e/compose.yaml, seeds it, runs faclab-web's
# `test:e2e:full` and checks nothing was left behind in the queues. Guide: e2e/README.md.
#
#   e2e/run.sh [--keep] [--sri simulator|celcer] [--inject-contract-regression] [-- playwright args]
#
# --sri celcer uses the SRI test environment with your certificate: E2E_P12_PATH, E2E_P12_PASSWORD and
# E2E_RUC (the certificate's) are required.
# --inject-contract-regression applies regressions/contract-sales-confirmed.patch to a copy of
# faclab-core and succeeds only if the suite catches it.
set -euo pipefail

E2E_ROOT=$(cd "$(dirname "$0")" && pwd)
WORKSPACE=$(cd "$E2E_ROOT/../.." && pwd)

export E2E_CORE_DIR=${E2E_CORE_DIR:-$WORKSPACE/faclab-core}
export E2E_INVOICING_DIR=${E2E_INVOICING_DIR:-$WORKSPACE/faclab-invoicing}
export E2E_WEB_DIR=${E2E_WEB_DIR:-$WORKSPACE/faclab-web}
export E2E_WEB_PORT=${E2E_WEB_PORT:-18080}
export E2E_API_PORT=${E2E_API_PORT:-18000}
export E2E_INVOICING_PORT=${E2E_INVOICING_PORT:-18173}
ARTIFACTS=${E2E_ARTIFACTS_DIR:-$E2E_ROOT/artifacts}

KEEP=false
SRI=simulator
INJECT=false
PLAYWRIGHT_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=true ;;
    --sri)
      SRI=${2:?--sri needs simulator or celcer}
      shift
      ;;
    --inject-contract-regression) INJECT=true ;;
    --)
      shift
      PLAYWRIGHT_ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

step() { printf '\n==> %s\n' "$*"; }
fail() {
  echo "e2e: $*" >&2
  exit 1
}

for dir in "$E2E_CORE_DIR" "$E2E_INVOICING_DIR" "$E2E_WEB_DIR"; do
  [[ -f "$dir/Dockerfile" ]] || fail "no repository at $dir"
done
[[ -d "$E2E_WEB_DIR/node_modules/@playwright" ]] ||
  fail "run 'npm ci && npx playwright install chromium' in $E2E_WEB_DIR first"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/faclab-e2e.XXXXXX")
# Made up for this run only
hex() { openssl rand -hex "$1"; }
export E2E_DB_PASSWORD E2E_ADMIN_USERNAME E2E_ADMIN_PASSWORD E2E_CERTIFICATE_PASSWORD_KEY
export E2E_STORAGE_KEY_ID E2E_STORAGE_SECRET E2E_GARAGE_RPC_SECRET E2E_GARAGE_ADMIN_TOKEN
E2E_DB_PASSWORD=$(hex 16)
E2E_ADMIN_USERNAME='admin'
E2E_ADMIN_PASSWORD="E2e!$(hex 12)"
E2E_CERTIFICATE_PASSWORD_KEY=$(openssl rand -base64 32)
E2E_STORAGE_KEY_ID="GK$(hex 16)"
E2E_STORAGE_SECRET=$(hex 32)
E2E_GARAGE_RPC_SECRET=$(hex 32)
E2E_GARAGE_ADMIN_TOKEN=$(hex 32)

export E2E_RUC E2E_P12_PATH E2E_P12_PASSWORD E2E_SEQUENCE_START
case "$SRI" in
  simulator)
    # Made up, with a valid check digit: no real company
    E2E_RUC=1799999990001
    E2E_P12_PASSWORD=$(hex 12)
    E2E_P12_PATH="$WORK/certificate.p12"
    E2E_SEQUENCE_START=""
    # A throwaway self-signed certificate naming the RUC in serialNumber, in the PKCS#12 flavour
    # node-forge reads (3DES, SHA-1)
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
      -subj "/C=EC/O=Faclab E2E/CN=Faclab E2E/serialNumber=$E2E_RUC" \
      -keyout "$WORK/key.pem" -out "$WORK/certificate.pem" 2>/dev/null
    openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/certificate.pem" -out "$E2E_P12_PATH" \
      -passout env:E2E_P12_PASSWORD -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
    ;;
  celcer)
    : "${E2E_RUC:?--sri celcer needs E2E_RUC}"
    : "${E2E_P12_PATH:?--sri celcer needs E2E_P12_PATH}"
    : "${E2E_P12_PASSWORD:?--sri celcer needs E2E_P12_PASSWORD}"
    export E2E_SRI_RECEPTION_WSDL="" E2E_SRI_AUTHORIZATION_WSDL=""
    # The SRI keeps every number it authorized: start where no earlier run was
    E2E_SEQUENCE_START=${E2E_SEQUENCE_START:-$(($(date +%s) % 900000000))}
    ;;
  *) fail "--sri must be simulator or celcer" ;;
esac

if $INJECT; then
  step "Copying faclab-core and injecting the contract regression"
  mkdir "$WORK/core"
  git -C "$E2E_CORE_DIR" ls-files -z --cached --others --exclude-standard |
    tar -C "$E2E_CORE_DIR" --null -T - -cf - | tar -xf - -C "$WORK/core"
  (cd "$WORK/core" && git apply "$E2E_ROOT/regressions/contract-sales-confirmed.patch") ||
    fail "the regression patch no longer applies: update it"
  export E2E_CORE_DIR="$WORK/core"
fi

compose() { docker compose -p faclab-e2e -f "$E2E_ROOT/compose.yaml" "$@"; }

query() { compose exec -T postgres psql -U postgres -d "$1" -tAc "$2"; }

STARTED=false
cleanup() {
  local status=$?
  if $STARTED; then
    if [[ $status -ne 0 ]]; then
      mkdir -p "$ARTIFACTS"
      compose logs --no-color --timestamps >"$ARTIFACTS/compose.log" 2>&1 || true
      echo "e2e: logs of the services in $ARTIFACTS/compose.log" >&2
    fi
    if $KEEP; then
      # The throwaway credentials, to run the suite again against this stack
      (umask 077 && env | grep '^E2E_' >"$E2E_ROOT/.env.run")
      cp "$E2E_P12_PATH" "$E2E_ROOT/.certificate.p12"
      sed -i.bak "s|^E2E_P12_PATH=.*|E2E_P12_PATH=$E2E_ROOT/.certificate.p12|" "$E2E_ROOT/.env.run"
      rm -f "$E2E_ROOT/.env.run.bak"
      echo "e2e: stack left running (http://localhost:$E2E_WEB_PORT); variables in e2e/.env.run."
      echo "     Remove it with: docker compose -p faclab-e2e down -v"
    else
      compose down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

step "Removing a stack left from an earlier run"
compose down --volumes --remove-orphans >/dev/null 2>&1 || true
rm -rf "$ARTIFACTS"

step "Building the images"
compose build

step "Starting the system and seeding it"
STARTED=true
compose up --detach --wait --wait-timeout 300

step "Running the suite (SRI: $SRI)"
suite_status=0
(cd "$E2E_WEB_DIR" &&
  E2E_WEB_URL="http://localhost:$E2E_WEB_PORT" \
    E2E_API_URL="http://localhost:$E2E_API_PORT" \
    E2E_SRI="$SRI" \
    E2E_INVOICING_URL="http://localhost:$E2E_INVOICING_PORT" \
    npm run test:e2e:full -- ${PLAYWRIGHT_ARGS[@]+"${PLAYWRIGHT_ARGS[@]}"}) || suite_status=$?

step "Checking the queues"
outbox_failed=$(query faclab "SELECT count(*) FROM outbox_messages WHERE status = 'failed'")
core_dead=$(query faclab "SELECT count(*) FROM dead_letters")
invoicing_dead=$(query faclab_invoicing "SELECT count(*) FROM dead_letters")
echo "outbox failed: $outbox_failed · core dead letters: $core_dead · invoicing dead letters: $invoicing_dead"

if $INJECT; then
  rejected=$(query faclab_invoicing "SELECT count(*) FROM dead_letters WHERE topic = 'sales.confirmed'")
  if [[ $suite_status -ne 0 && $rejected -gt 0 ]]; then
    step "The suite caught the injected contract regression"
    exit 0
  fi
  fail "the injected regression went unnoticed (suite exit $suite_status, rejected messages $rejected)"
fi

[[ $suite_status -eq 0 ]] || exit "$suite_status"
[[ $outbox_failed -eq 0 && $core_dead -eq 0 && $invoicing_dead -eq 0 ]] ||
  fail "messages were left unprocessed"
step "The whole flow works"
