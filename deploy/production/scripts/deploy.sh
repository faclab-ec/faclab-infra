#!/usr/bin/env bash
# Deploys an environment from the operator's machine or from CI (S8.2). It reads the versions of
# versions/<environment>.env, checks that the combination is in COMPATIBILITY.md and that each image
# is published in GHCR, and asks the server over SSH to run remote.sh, which checks faclab-infra out
# at that version and runs its stack.sh deploy. Nothing changes on the server before those checks.
#
#   deploy.sh <environment>              deploy versions/<environment>.env
#   deploy.sh <environment> rollback     go back to what ran before the last deployment
#   deploy.sh <environment> status       the server's containers and versions
#   deploy.sh <environment> deployments  what runs, what ran before and the history
#
# FACLAB_SSH (required): the ssh command to the server's deploy user, for example
#   "ssh deploy@203.0.113.10" or "ssh -i ~/.ssh/faclab_ci -o UserKnownHostsFile=<file> deploy@<host>"
# FACLAB_REMOTE_DIR: the faclab-infra checkout on the server (/opt/faclab/faclab-infra)
# IMAGE_REGISTRY: where the images are (ghcr.io/faclab-ec)
#
# Exits with stack.sh's code: 0 deployed, 3 the deployment failed and the previous versions run again,
# anything else failed (read its output).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

die() {
  echo "deploy.sh: $*" >&2
  exit 1
}

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" >&2
  exit 1
}

# version_of <file> <name>: the last value of a variable
version_of() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

main() {
  local environment="${1:-}" action="${2:-deploy}" file remote registry ssh_command=()
  local infra core invoicing web version image
  [ -n "$environment" ] || usage
  case "$action" in
    deploy | rollback | status | deployments) ;;
    *) usage ;;
  esac
  [ -n "${FACLAB_SSH:-}" ] || die "set FACLAB_SSH to the ssh command of the server, e.g. \"ssh deploy@<host>\""
  read -r -a ssh_command <<< "$FACLAB_SSH"
  remote="${FACLAB_REMOTE_DIR:-/opt/faclab/faclab-infra}/deploy/production/scripts/remote.sh"

  if [ "$action" != deploy ]; then
    exec "${ssh_command[@]}" "$remote" "$action"
  fi

  file="$HERE/versions/$environment.env"
  [ -f "$file" ] || die "$file doesn't exist"
  infra="$(version_of "$file" INFRA_VERSION)"
  core="$(version_of "$file" CORE_VERSION)"
  invoicing="$(version_of "$file" INVOICING_VERSION)"
  web="$(version_of "$file" WEB_VERSION)"
  for version in "$infra" "$core" "$invoicing" "$web"; do
    [[ "$version" =~ $SEMVER ]] || die "$file: '$version' isn't a version (X.Y.Z or X.Y.Z-rc.N)"
    if [ "$environment" = production ] && [[ "$version" == *-* ]]; then
      die "$file: production takes final versions, not $version"
    fi
  done
  echo "== $environment: infra $infra, core $core, invoicing $invoicing, web $web"

  echo "== Compatibility (COMPATIBILITY.md)"
  python3 "$HERE/scripts/compat.py" "$file"

  echo "== Images"
  registry="${IMAGE_REGISTRY:-ghcr.io/faclab-ec}"
  for image in "faclab-caddy:$infra" "faclab-api:$core" "faclab-invoicing:$invoicing" "faclab-web:$web"; do
    docker buildx imagetools inspect "$registry/$image" > /dev/null 2>&1 ||
      die "$registry/$image isn't published: pushing the tag runs its release workflow"
    echo "  ok: $registry/$image"
  done

  echo "== Deploying on the server"
  exec "${ssh_command[@]}" "$remote" deploy "$infra" "$core" "$invoicing" "$web"
}

main "$@"
