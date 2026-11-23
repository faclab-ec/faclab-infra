#!/usr/bin/env bash
# The S3 stand-in of drill/compose.yaml (S8.3, deploy/production/RESPALDOS.md), on the machine that
# hosts the staging VMs: where staging's backups go until the first VPS brings the real provider.
# Its keys and certificate live in $STANDIN_DIR (~/.config/faclab/drill), never in the repository.
#
#   standin.sh up               the keys and the certificate the first time; then start it and
#                               create its buckets, users and policies (idempotent)
#   standin.sh down             stop it; the buckets stay in its volumes
#   standin.sh secret <name>    print one value, to pipe into secrets.sh set <environment> <name>:
#                               BACKUP_PG_ACCESS_KEY_ID, BACKUP_PG_SECRET_ACCESS_KEY,
#                               BACKUP_OBJECTS_ACCESS_KEY_ID or BACKUP_OBJECTS_SECRET_ACCESS_KEY
#   standin.sh aws <args...>    the AWS CLI against it as its root, or as the documents' key with
#                               AS=objects (the Object Lock checks of the drill)
#
# Like the real provider: pgBackRest's bucket without lock (pgBackRest deletes what expires) and its
# key limited to it; the documents' bucket with versioning and Object Lock in compliance mode for
# RETENTION_DAYS (1 here, the legal term on the provider), and its key may write and read but never
# delete. Settings: STANDIN_DIR, STANDIN_PORT (9000), PG_BUCKET (faclab-staging-pgbackrest),
# OBJECTS_BUCKET (faclab-staging-comprobantes), RETENTION_DAYS (1).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${STANDIN_DIR:-$HOME/.config/faclab/drill}"
PORT="${STANDIN_PORT:-9000}"
PG_BUCKET="${PG_BUCKET:-faclab-staging-pgbackrest}"
OBJECTS_BUCKET="${OBJECTS_BUCKET:-faclab-staging-comprobantes}"
RETENTION_DAYS="${RETENTION_DAYS:-1}"
AWS_IMAGE=amazon/aws-cli:2.39.5
VGW_IMAGE=versity/versitygw:v1.10.0
NETWORK=faclab-drill_default
ENDPOINT=https://s3:7070

die() {
  echo "standin.sh: $*" >&2
  exit 1
}

openssl_bin() {
  local candidate
  for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
    command -v "$candidate" > /dev/null 2>&1 && {
      printf '%s' "$candidate"
      return
    }
  done
  die "no openssl"
}

# Keys and certificate, the first time only: the buckets' data depends on them
prepare() {
  local openssl
  openssl="$(openssl_bin)"
  install -d -m 0700 "$DIR" "$DIR/tls"
  if [ ! -f "$DIR/standin.env" ]; then
    (
      umask 077
      {
        printf 'STANDIN_ROOT_ACCESS_KEY=faclabroot\n'
        printf 'STANDIN_ROOT_SECRET_KEY=%s\n' "$("$openssl" rand -hex 20)"
        printf 'PG_ACCESS_KEY=faclabpg\n'
        printf 'PG_SECRET_KEY=%s\n' "$("$openssl" rand -hex 20)"
        printf 'OBJECTS_ACCESS_KEY=faclabobjects\n'
        printf 'OBJECTS_SECRET_KEY=%s\n' "$("$openssl" rand -hex 20)"
      } > "$DIR/standin.env"
    )
    echo "Keys of the stand-in in $DIR/standin.env"
  fi
  if [ ! -f "$DIR/tls/cert.pem" ]; then
    # Names: the VMs reach the Mac as host.orb.internal; the setup container, as s3
    (
      umask 077
      "$openssl" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 825 \
        -subj /CN=faclab-s3-standin -keyout "$DIR/tls/key.pem" -out "$DIR/tls/cert.pem" \
        -addext "subjectAltName=DNS:host.orb.internal,DNS:localhost,DNS:s3" 2> /dev/null
    )
    echo "Self-signed certificate in $DIR/tls"
  fi
}

value() {
  sed -n "s/^$1=//p" "$DIR/standin.env" | tail -n 1
}

compose() {
  STANDIN_DIR="$DIR" STANDIN_PORT="$PORT" docker compose -f "$HERE/compose.yaml" \
    --env-file "$DIR/standin.env" "$@"
}

# The AWS CLI in the stand-in's network; the secret goes through the environment, never argv
aws() {
  local key secret
  if [ "${AS:-root}" = objects ]; then
    key="$(value OBJECTS_ACCESS_KEY)" secret="$(value OBJECTS_SECRET_KEY)"
  else
    key="$(value STANDIN_ROOT_ACCESS_KEY)" secret="$(value STANDIN_ROOT_SECRET_KEY)"
  fi
  AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" docker run --rm -i --network "$NETWORK" \
    -v "$DIR/tls:/tls:ro" -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=us-east-1 \
    "$AWS_IMAGE" --endpoint-url "$ENDPOINT" --ca-bundle /tls/cert.pem "$@"
}

admin() {
  ADMIN_ACCESS_KEY_ID="$(value STANDIN_ROOT_ACCESS_KEY)" ADMIN_SECRET_ACCESS_KEY="$(value STANDIN_ROOT_SECRET_KEY)" \
    docker run --rm --network "$NETWORK" -e ADMIN_ACCESS_KEY_ID -e ADMIN_SECRET_ACCESS_KEY "$VGW_IMAGE" \
    admin --endpoint-url "$ENDPOINT/admin" --allow-insecure "$@"
}

# policy <bucket> <access key> <actions...>: what that key may do in that bucket, nothing else
policy() {
  local bucket="$1" key="$2" actions
  shift 2
  actions="$(printf '"s3:%s",' "$@")"
  aws s3api put-bucket-policy --bucket "$bucket" --policy "$(printf \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["%s"]},"Action":[%s],"Resource":["arn:aws:s3:::%s","arn:aws:s3:::%s/*"]}]}' \
    "$key" "${actions%,}" "$bucket" "$bucket")"
}

up() {
  local attempt users name
  prepare
  compose up -d --wait
  for attempt in $(seq 1 20); do
    aws s3api list-buckets > /dev/null 2>&1 && break
    [ "$attempt" != 20 ] || die "the stand-in doesn't answer (docker compose -p faclab-drill logs)"
    sleep 1
  done

  users="$(admin list-users)"
  for name in PG OBJECTS; do
    if ! grep -qw "$(value "${name}_ACCESS_KEY")" <<< "$users"; then
      admin create-user --access "$(value "${name}_ACCESS_KEY")" --secret "$(value "${name}_SECRET_KEY")" --role user
    fi
  done

  if ! aws s3api head-bucket --bucket "$PG_BUCKET" > /dev/null 2>&1; then
    aws s3api create-bucket --bucket "$PG_BUCKET" > /dev/null
  fi
  policy "$PG_BUCKET" "$(value PG_ACCESS_KEY)" ListBucket GetBucketLocation GetObject PutObject DeleteObject

  if ! aws s3api head-bucket --bucket "$OBJECTS_BUCKET" > /dev/null 2>&1; then
    aws s3api create-bucket --bucket "$OBJECTS_BUCKET" --object-lock-enabled-for-bucket > /dev/null
  fi
  aws s3api put-object-lock-configuration --bucket "$OBJECTS_BUCKET" --object-lock-configuration \
    "{\"ObjectLockEnabled\":\"Enabled\",\"Rule\":{\"DefaultRetention\":{\"Mode\":\"COMPLIANCE\",\"Days\":$RETENTION_DAYS}}}"
  # Write and read, never delete: a changed object is a new version, kept RETENTION_DAYS
  policy "$OBJECTS_BUCKET" "$(value OBJECTS_ACCESS_KEY)" ListBucket ListBucketVersions GetBucketLocation \
    GetBucketVersioning GetBucketObjectLockConfiguration GetObject GetObjectVersion GetObjectRetention PutObject

  echo "Stand-in ready on port $PORT (https, self-signed):"
  echo "  $PG_BUCKET: pgBackRest's, for the key $(value PG_ACCESS_KEY)"
  echo "  $OBJECTS_BUCKET: the documents', versioning and Object Lock (COMPLIANCE, $RETENTION_DAYS days), for the key $(value OBJECTS_ACCESS_KEY)"
}

secret() {
  case "${1:-}" in
    BACKUP_PG_ACCESS_KEY_ID) value PG_ACCESS_KEY ;;
    BACKUP_PG_SECRET_ACCESS_KEY) value PG_SECRET_KEY ;;
    BACKUP_OBJECTS_ACCESS_KEY_ID) value OBJECTS_ACCESS_KEY ;;
    BACKUP_OBJECTS_SECRET_ACCESS_KEY) value OBJECTS_SECRET_KEY ;;
    *) die "usage: standin.sh secret BACKUP_PG_ACCESS_KEY_ID | BACKUP_PG_SECRET_ACCESS_KEY | BACKUP_OBJECTS_ACCESS_KEY_ID | BACKUP_OBJECTS_SECRET_ACCESS_KEY" ;;
  esac
}

main() {
  local command="${1:-}"
  [ -n "$command" ] || {
    sed -n '2,20p' "${BASH_SOURCE[0]}"
    exit 1
  }
  shift
  case "$command" in
    up) up ;;
    down) compose stop ;;
    secret) secret "$@" ;;
    aws) aws "$@" ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
