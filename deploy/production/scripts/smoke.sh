#!/usr/bin/env bash
# Smoke test of a Faclab deployment from outside the server (S8.1): what a browser or an integrator
# sees through Caddy. It doesn't log in nor write anything; the sale and its invoice are checked by
# hand (README, "Prueba de humo").
#
#   smoke.sh <app domain> <api domain> [--cacert <root.crt>] [--rate-limit]
#
# --cacert: the root of Caddy's internal CA (staging). --rate-limit also sends a burst to
# /api/auth/login until it gets 429 (that IP then waits a minute to log in).
set -euo pipefail

APP="${1:?usage: smoke.sh <app domain> <api domain> [--cacert file] [--rate-limit]}"
API="${2:?usage: smoke.sh <app domain> <api domain> [--cacert file] [--rate-limit]}"
shift 2
CURL=(curl -sS --max-time 20)
RATE_LIMIT=false
while [ $# -gt 0 ]; do
  case "$1" in
    --cacert)
      CURL+=(--cacert "${2:?--cacert needs a file}")
      shift 2
      ;;
    --rate-limit)
      RATE_LIMIT=true
      shift
      ;;
    *)
      echo "smoke.sh: unknown option $1" >&2
      exit 2
      ;;
  esac
done

FAILED=0
pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  FAILED=$((FAILED + 1))
}

# check <description> <expected status> <curl arguments...>
check() {
  local description="$1" expected="$2" status
  shift 2
  status="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$@" || true)"
  if [ "$status" = "$expected" ]; then
    pass "$description ($status)"
  else
    fail "$description: expected $expected, got $status"
  fi
}

# header <description> <url> <header name> <expected substring>
header() {
  local value
  value="$("${CURL[@]}" -o /dev/null -D - "$2" | tr -d '\r' | grep -i "^$3:" || true)"
  if [[ "$value" == *"$4"* ]]; then
    pass "$1"
  else
    fail "$1: '$3' was '${value:-missing}'"
  fi
}

# served_by <description> <url> core|invoicing: both answer 403 PERMISSION_DENIED without a token;
# Starlette (core) sends JSON as application/json and Fastify (invoicing) adds charset=utf-8, which
# tells which one Caddy routed the request to
served_by() {
  local headers status content_type
  headers="$("${CURL[@]}" -o /dev/null -D - "$2" | tr -d '\r' || true)"
  status="$(printf '%s\n' "$headers" | sed -n 's/^HTTP[^ ]* \([0-9]*\).*/\1/p' | tail -n 1)"
  content_type="$(printf '%s\n' "$headers" | grep -i '^content-type:' | tail -n 1)"
  if [ "$status" != 403 ]; then
    fail "$1: expected 403 without a token, got ${status:-nothing}"
  elif [ "$3" = invoicing ] && [[ "$content_type" == *charset=utf-8* ]]; then
    pass "$1 (403, invoicing)"
  elif [ "$3" = core ] && [[ "$content_type" != *charset=utf-8* ]]; then
    pass "$1 (403, core)"
  else
    fail "$1: answered by the wrong service ($content_type)"
  fi
}

# A body of <size> bytes for POST tests
body_of() {
  head -c "$1" /dev/zero | tr '\0' 'a'
}

echo "TLS and redirection"
check "http://$APP redirects to https" 308 "http://$APP/"
check "http://$API redirects to https" 308 "http://$API/"
if "${CURL[@]}" -o /dev/null --tlsv1.2 "https://$API/.well-known/jwks.json"; then
  pass "certificate of $API is trusted"
else
  fail "certificate of $API isn't trusted (staging: --cacert with Caddy's root)"
fi

echo "Web ($APP)"
check "index" 200 "https://$APP/"
check "SPA route (/pos)" 200 "https://$APP/pos"
header "HSTS" "https://$APP/" Strict-Transport-Security "max-age="
header "CSP" "https://$APP/" Content-Security-Policy "default-src 'self'"
header "X-Frame-Options" "https://$APP/" X-Frame-Options DENY
config="$("${CURL[@]}" "https://$APP/config.js" || true)"
if [[ "$config" == *"\"apiBaseUrl\":\"https://$API\""* ]]; then
  pass "config.js points at https://$API"
else
  fail "config.js doesn't point at https://$API"
fi

echo "Browser telemetry (/otlp)"
now="$(date +%s)000000000"
span="{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"faclab-web\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"5b8efff798038103d269b633813fc60c\",\"spanId\":\"eee19b7ec3c1b174\",\"name\":\"smoke\",\"kind\":1,\"startTimeUnixNano\":\"$now\",\"endTimeUnixNano\":\"$now\"}]}]}]}"
check "a faclab-web span is accepted" 200 -X POST -H 'Content-Type: application/json' \
  --data "$span" "https://$APP/otlp/v1/traces"
check "a body over 1 MiB is refused" 413 -X POST -H 'Content-Type: application/json' \
  --data-binary @<(body_of 1100000) "https://$APP/otlp/v1/traces"

echo "API ($API)"
jwks="$("${CURL[@]}" "https://$API/.well-known/jwks.json" || true)"
if [[ "$jwks" == *'"kty":"OKP"'* ]]; then
  pass "JWKS publishes an Ed25519 key"
else
  fail "JWKS doesn't publish an Ed25519 key"
fi
served_by "/api/auth/me without a token" "https://$API/api/auth/me" core
served_by "/api/v1/products without a token" "https://$API/api/v1/products" core
served_by "/api/invoicing/status without a token" "https://$API/api/invoicing/status" invoicing
served_by "/api/v1/invoices without a token" "https://$API/api/v1/invoices" invoicing
served_by "/api/company-config without a token" "https://$API/api/company-config" invoicing
check "core: the public OpenAPI" 200 "https://$API/openapi/public.json"
check "readiness isn't public" 404 "https://$API/health/ready"
header "HSTS" "https://$API/.well-known/jwks.json" Strict-Transport-Security "max-age="
check "a body over 2 MiB is refused" 413 -X POST -H 'Content-Type: application/json' \
  --data-binary @<(body_of 2200000) "https://$API/api/admin/products"

if [ "$RATE_LIMIT" = true ]; then
  echo "Limit by IP"
  got_429=false
  for _ in $(seq 1 60); do
    status="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      --data '{}' "https://$API/api/auth/login" || true)"
    if [ "$status" = 429 ]; then
      got_429=true
      break
    fi
  done
  if [ "$got_429" = true ]; then
    pass "a burst to /api/auth/login gets 429"
  else
    fail "60 requests to /api/auth/login never got 429"
  fi
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED check(s) failed"
  exit 1
fi
echo "Every check passed"
