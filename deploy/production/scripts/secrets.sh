#!/usr/bin/env bash
# The secrets of each environment of Faclab (S8.1), encrypted with sops and age outside the
# repository: one file per environment, $FACLAB_SECRETS_DIR/<environment>.sops.yaml, with the
# recipients of $FACLAB_SECRETS_DIR/.sops.yaml (copy deploy/production/sops.yaml.example there).
# Runs on the operator's machine; the server never needs sops nor the age key.
#
#   secrets.sh init <environment>               generate every secret, encrypted (fails if it exists)
#   secrets.sh edit <environment>               open it decrypted in $EDITOR (sops edit)
#   secrets.sh names <environment>              list the variables, without their values
#   secrets.sh push <environment> <ssh target>  copy them decrypted to ~/.faclab-incoming on the
#                                               server, over SSH and without touching the local disk;
#                                               then: sudo stack.sh install-secrets <environment>
#   secrets.sh generate <kind>                  print a new value, to paste in `edit` when rotating:
#                                               hex, base64, fernet, ed25519, garage-key-id,
#                                               garage-secret
#
# Requirements: sops, age (its private key where sops looks for it, or SOPS_AGE_KEY_FILE) and an
# OpenSSL that generates Ed25519 keys (macOS: brew install sops age openssl@3).
set -euo pipefail

# What the server receives: env goes to /etc/faclab/secrets.env, files to /etc/faclab/secrets
FILES=(postgres_password jwt_private_key.pem secret_encryption_keys)

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
  echo "Created $file. SMTP_USER and SMTP_PASSWORD are empty: fill them with secrets.sh edit $environment."
}

edit() {
  local file
  file="$(existing_file "${1:?usage: secrets.sh edit <environment>}")"
  (cd "$(secrets_dir)" && sops edit "$file")
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
  local file name
  file="$(existing_file "$environment")"
  # Decrypt first: a wrong key fails here, before touching the server
  sops decrypt "$file" > /dev/null

  # shellcheck disable=SC2016  # $HOME expands on the server
  ssh "$target" 'umask 077 && rm -rf "$HOME/.faclab-incoming" && mkdir -p "$HOME/.faclab-incoming/secrets"'
  # shellcheck disable=SC2016
  sops decrypt --extract '["env"]' --output-type dotenv "$file" |
    ssh "$target" 'umask 077 && cat > "$HOME/.faclab-incoming/secrets.env"'
  for name in "${FILES[@]}"; do
    # The files are written as stored: the PEM keeps its line breaks. $name expands here, $HOME there
    # shellcheck disable=SC2029
    sops decrypt --extract "[\"files\"][\"$name\"]" "$file" |
      ssh "$target" "umask 077 && cat > \"\$HOME/.faclab-incoming/secrets/$name\""
  done
  echo "Copied to $target:~/.faclab-incoming. On the server, from the faclab-infra checkout:"
  echo "  sudo deploy/production/scripts/stack.sh install-secrets $environment"
}

main() {
  local command="${1:-}"
  [ -n "$command" ] || {
    sed -n '2,20p' "${BASH_SOURCE[0]}"
    exit 1
  }
  shift
  case "$command" in
    init) init "$@" ;;
    edit) edit "$@" ;;
    names) names "$@" ;;
    push) push "$@" ;;
    generate) generate "$@" ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
