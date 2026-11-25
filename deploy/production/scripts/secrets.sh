#!/usr/bin/env bash
# The secrets of each environment of Faclab (S8.1), encrypted with sops and age outside the
# repository: one file per environment, $FACLAB_SECRETS_DIR/<environment>.sops.yaml, with the
# recipients of $FACLAB_SECRETS_DIR/.sops.yaml (copy deploy/production/sops.yaml.example there).
# Runs on the operator's machine; the server never needs sops nor the age key.
#
#   secrets.sh init <environment>               generate every secret, encrypted (fails if it exists)
#   secrets.sh edit <environment>               open it decrypted in $EDITOR (sops edit)
#   secrets.sh names <environment>              list the variables, without their values
#   secrets.sh set <environment> <name> [kind]  replace one secret, without an editor: a new value
#                                               of that kind (see generate) or, without a kind,
#                                               the value read from stdin. A variable of
#                                               secrets.env.example missing from an older file
#                                               is added
#   secrets.sh push <environment> <ssh target>  copy them decrypted to ~/.faclab-incoming on the
#                                               server, over SSH and without touching the local disk;
#                                               then: sudo stack.sh install-secrets <environment>
#   secrets.sh generate <kind>                  print a new value, to paste in `edit` when rotating:
#                                               hex, base64, fernet, ed25519, garage-key-id,
#                                               garage-secret
#
# Requirements: sops, age (its private key where sops looks for it, or SOPS_AGE_KEY_FILE) and an
# OpenSSL that generates Ed25519 keys (macOS: brew install sops age openssl@3). FACLAB_SSH changes
# the ssh command of push (for example "ssh -p 2222" or "ssh -F <config file>").
set -euo pipefail

# What the server receives: env goes to /etc/faclab/secrets.env, files to /etc/faclab/secrets
FILES=(postgres_password jwt_private_key.pem secret_encryption_keys)
# The variables of secrets.env.example: set adds one of these to a file created before it existed
ENV_NAMES=(CORE_DB_OWNER_PASSWORD CORE_DB_APP_PASSWORD CORE_DB_WORKER_PASSWORD DB_MONITOR_PASSWORD
  INVOICING_DB_PASSWORD CERTIFICATE_PASSWORD_KEY OBJECT_STORAGE_ACCESS_KEY_ID
  OBJECT_STORAGE_SECRET_ACCESS_KEY GARAGE_RPC_SECRET GARAGE_ADMIN_TOKEN SMTP_USER SMTP_PASSWORD
  BACKUP_PG_ACCESS_KEY_ID BACKUP_PG_SECRET_ACCESS_KEY BACKUP_PG_CIPHER_PASS
  BACKUP_OBJECTS_ACCESS_KEY_ID BACKUP_OBJECTS_SECRET_ACCESS_KEY BACKUP_OBJECTS_CRYPT_PASSWORD
  BACKUP_OBJECTS_CRYPT_SALT SIGNOZ_INGESTION_KEY SIGNOZ_OTLP_AUTHORIZATION HEARTBEAT_BASE_URL)

die() {
  echo "secrets.sh: $*" >&2
  exit 1
}

find_openssl() {
  local candidate
  for candidate in "${OPENSSL:-}" openssl /opt/homebrew/opt/openssl@3/bin/openssl \
    /usr/local/opt/openssl@3/bin/openssl; do
    [ -n "$candidate" ] || continue
    command -v "$candidate" > /dev/null 2>&1 || continue
    if "$candidate" genpkey -algorithm ed25519 > /dev/null 2>&1; then
      printf '%s' "$candidate"
      return
    fi
  done
  die "no OpenSSL that generates Ed25519 keys (macOS: brew install openssl@3, or set OPENSSL)"
}

secrets_dir() {
  local dir="${FACLAB_SECRETS_DIR:?set FACLAB_SECRETS_DIR to the folder of the encrypted secrets}"
  [ -d "$dir" ] || die "$dir doesn't exist"
  printf '%s' "$dir"
}

secrets_file() {
  local environment="${1:?the environment is missing}"
  printf '%s/%s.sops.yaml' "$(secrets_dir)" "$environment"
}

existing_file() {
  local file
  file="$(secrets_file "$1")"
  [ -f "$file" ] || die "$file doesn't exist: run secrets.sh init $1"
  printf '%s' "$file"
}

generate() {
  local openssl
  openssl="$(find_openssl)"
  case "${1:?usage: secrets.sh generate <kind>}" in
    # Database passwords: hex goes into connection URLs without escaping
    hex) "$openssl" rand -hex 24 ;;
    # CERTIFICATE_PASSWORD_KEY (32 bytes), GARAGE_ADMIN_TOKEN
    base64) "$openssl" rand -base64 32 ;;
    # A key of SECRET_ENCRYPTION_KEYS: 32 bytes, URL-safe base64
    fernet) "$openssl" rand 32 | "$openssl" base64 -A | tr '+/' '-_' && echo ;;
    # JWT_PRIVATE_KEY of faclab-core: Ed25519 in PEM (PKCS#8)
    ed25519) "$openssl" genpkey -algorithm ed25519 ;;
    # Garage's access key: GK and 12 bytes in hex; its secret and the RPC secret: 32 bytes in hex
    garage-key-id) printf 'GK%s\n' "$("$openssl" rand -hex 12)" ;;
    garage-secret) "$openssl" rand -hex 32 ;;
    *) die "unknown kind: $1" ;;
  esac
}

init() {
  local environment="${1:?usage: secrets.sh init <environment>}"
  local dir file pem yaml
  dir="$(secrets_dir)"
  file="$(secrets_file "$environment")"
  [ ! -e "$file" ] || die "$file already exists: change it with secrets.sh edit $environment"
  [ -f "$dir/.sops.yaml" ] || die "$dir/.sops.yaml is missing: copy sops.yaml.example with your age recipients"

  pem="$(generate ed25519 | sed 's/^/    /')"
  # Only in memory: sops reads it from stdin and writes the encrypted file
  yaml="$(
    cat << YAML
# Secrets of $environment (deploy/production/secrets.env.example says what each one is)
env:
  CORE_DB_OWNER_PASSWORD: '$(generate hex)'
  CORE_DB_APP_PASSWORD: '$(generate hex)'
  CORE_DB_WORKER_PASSWORD: '$(generate hex)'
  DB_MONITOR_PASSWORD: '$(generate hex)'
  INVOICING_DB_PASSWORD: '$(generate hex)'
  CERTIFICATE_PASSWORD_KEY: '$(generate base64)'
  OBJECT_STORAGE_ACCESS_KEY_ID: '$(generate garage-key-id)'
  OBJECT_STORAGE_SECRET_ACCESS_KEY: '$(generate garage-secret)'
  GARAGE_RPC_SECRET: '$(generate garage-secret)'
  GARAGE_ADMIN_TOKEN: '$(generate base64)'
  SMTP_USER: ''
  SMTP_PASSWORD: ''
  BACKUP_PG_ACCESS_KEY_ID: ''
  BACKUP_PG_SECRET_ACCESS_KEY: ''
  BACKUP_PG_CIPHER_PASS: '$(generate base64)'
  BACKUP_OBJECTS_ACCESS_KEY_ID: ''
  BACKUP_OBJECTS_SECRET_ACCESS_KEY: ''
  BACKUP_OBJECTS_CRYPT_PASSWORD: '$(generate hex)'
  BACKUP_OBJECTS_CRYPT_SALT: '$(generate hex)'
  SIGNOZ_INGESTION_KEY: ''
  SIGNOZ_OTLP_AUTHORIZATION: ''
  HEARTBEAT_BASE_URL: ''
files:
  postgres_password: '$(generate hex)'
  jwt_private_key.pem: |
$pem
  secret_encryption_keys: '$(generate fernet)'
YAML
  )"
  # sops looks for .sops.yaml from the working directory up
  (cd "$dir" && printf '%s\n' "$yaml" | sops encrypt --filename-override "$file" \
    --input-type yaml --output-type yaml /dev/stdin > "$file.tmp")
  mv "$file.tmp" "$file"
  echo "Created $file. Empty, to fill with secrets.sh set $environment <name> (the value from stdin):"
  echo "  SMTP_USER, SMTP_PASSWORD (the mail provider) and BACKUP_PG_* and BACKUP_OBJECTS_* keys (the"
  echo "  storage outside the server, RESPALDOS.md); HEARTBEAT_BASE_URL (the ping URL of the heartbeat"
  echo "  service, scripts/heartbeats.sh) and, when there is a telemetry backend, SIGNOZ_INGESTION_KEY or"
  echo "  SIGNOZ_OTLP_AUTHORIZATION"
}

edit() {
  local file
  file="$(existing_file "${1:?usage: secrets.sh edit <environment>}")"
  (cd "$(secrets_dir)" && sops edit "$file")
}

set_value() {
  local environment="${1:?usage: secrets.sh set <environment> <name> [kind]}"
  local name="${2:?usage: secrets.sh set <environment> <name> [kind]}"
  local kind="${3:-}" file index value
  file="$(existing_file "$environment")"
  case "$name" in
    postgres_password | jwt_private_key.pem | secret_encryption_keys) index="[\"files\"][\"$name\"]" ;;
    *) index="[\"env\"][\"$name\"]" ;;
  esac
  # Only names that exist, or that secrets.env.example added since: a typo would add a secret
  # nobody reads
  if ! sops decrypt --extract "$index" "$file" > /dev/null 2>&1 &&
    ! printf '%s\n' "${ENV_NAMES[@]}" | grep -qxF "$name"; then
    die "$name isn't a secret of $environment (secrets.sh names $environment)"
  fi
  if [ -n "$kind" ]; then
    value="$(generate "$kind")"
  else
    value="$(cat)"
  fi
  # Optional ones may be empty: the mail provider's login, the telemetry backend's credentials
  case "$name" in
    SMTP_USER | SMTP_PASSWORD | SIGNOZ_INGESTION_KEY | SIGNOZ_OTLP_AUTHORIZATION) ;;
    *) [ -n "$value" ] || die "empty value for $name" ;;
  esac
  # The PEM keeps its final line break, as init writes it
  [ "$name" != jwt_private_key.pem ] || value+=$'\n'
  # sops reads it from stdin as JSON: never in a command line
  printf '%s' "$value" | python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read()))' |
    (cd "$(secrets_dir)" && sops set --value-stdin "$file" "$index")
  echo "$name of $environment saved. Next: secrets.sh push, then stack.sh install-secrets on the server."
}

names() {
  local file
  file="$(existing_file "${1:?usage: secrets.sh names <environment>}")"
  sops decrypt --extract '["env"]' --output-type dotenv "$file" | cut -d= -f1
  printf 'files: %s\n' "${FILES[*]}"
}

push() {
  local environment="${1:?usage: secrets.sh push <environment> <ssh target>}"
  local target="${2:?usage: secrets.sh push <environment> <ssh target>}"
  local file name ssh_command
  read -r -a ssh_command <<< "${FACLAB_SSH:-ssh}"
  file="$(existing_file "$environment")"
  # Decrypt first: a wrong key fails here, before touching the server
  sops decrypt "$file" > /dev/null

  # shellcheck disable=SC2016  # $HOME expands on the server
  "${ssh_command[@]}" "$target" \
    'umask 077 && rm -rf "$HOME/.faclab-incoming" && mkdir -p "$HOME/.faclab-incoming/secrets"'
  # shellcheck disable=SC2016
  sops decrypt --extract '["env"]' --output-type dotenv "$file" |
    "${ssh_command[@]}" "$target" 'umask 077 && cat > "$HOME/.faclab-incoming/secrets.env"'
  for name in "${FILES[@]}"; do
    # The files are written as stored: the PEM keeps its line breaks. $name expands here, $HOME there
    # shellcheck disable=SC2029
    sops decrypt --extract "[\"files\"][\"$name\"]" "$file" |
      "${ssh_command[@]}" "$target" "umask 077 && cat > \"\$HOME/.faclab-incoming/secrets/$name\""
  done
  echo "Copied to $target:~/.faclab-incoming. On the server, from the faclab-infra checkout:"
  echo "  sudo deploy/production/scripts/stack.sh install-secrets $environment"
}

main() {
  local command="${1:-}"
  [ -n "$command" ] || {
    sed -n '2,24p' "${BASH_SOURCE[0]}"
    exit 1
  }
  shift
  case "$command" in
    init) init "$@" ;;
    edit) edit "$@" ;;
    names) names "$@" ;;
    set) set_value "$@" ;;
    push) push "$@" ;;
    generate) generate "$@" ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
