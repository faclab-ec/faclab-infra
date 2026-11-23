#!/usr/bin/env bash
# The server's entry for deploy.sh (S8.2). It runs as the deploy user, either as the forced command
# of the CI's SSH key (stack.sh authorize-ci: that key can run nothing else) or by hand:
#
#   remote.sh deploy <infra> <core> <invoicing> <web>   check out faclab-infra v<infra> and run its
#                                                      stack.sh deploy with those versions
#   remote.sh rollback                                 stack.sh rollback
#   remote.sh status                                   stack.sh status
#   remote.sh deployments                              stack.sh deployments
#
# With a forced command, sshd passes what the client asked for in SSH_ORIGINAL_COMMAND: only those
# four commands get through, each version checked against a strict pattern, never run by a shell.
set -euo pipefail

SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

die() {
  echo "remote.sh: $*" >&2
  exit 1
}

main() {
  local here repo stack arguments=() version
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo="$(cd "$here/../../.." && pwd)"
  stack="$here/stack.sh"

  if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    read -r -a arguments <<< "$SSH_ORIGINAL_COMMAND"
    # deploy.sh sends this script's path first, so the same line works without a forced command
    case "${arguments[0]:-}" in
      */remote.sh) arguments=("${arguments[@]:1}") ;;
    esac
  else
    arguments=("$@")
  fi
  [ "${#arguments[@]}" -gt 0 ] || die "usage: remote.sh deploy <infra> <core> <invoicing> <web> | rollback | status | deployments"

  case "${arguments[0]}" in
    deploy)
      [ "${#arguments[@]}" = 5 ] || die "usage: remote.sh deploy <infra> <core> <invoicing> <web>"
      for version in "${arguments[@]:1}"; do
        [[ "$version" =~ $SEMVER ]] || die "'$version' isn't a version"
      done
      # The stack of that faclab-infra version: its compose.yaml, its scripts. Tags may be recreated
      # (a pre-release published again), hence --force
      git -C "$repo" fetch --quiet --tags --force origin
      git -C "$repo" -c advice.detachedHead=false checkout --quiet --detach "refs/tags/v${arguments[1]}"
      echo "faclab-infra at v${arguments[1]} ($(git -C "$repo" rev-parse --short HEAD))"
      exec sudo "$stack" deploy "${arguments[@]:1}"
      ;;
    rollback | status | deployments)
      [ "${#arguments[@]}" = 1 ] || die "${arguments[0]} takes no arguments"
      exec sudo "$stack" "${arguments[0]}"
      ;;
    *) die "unknown command '${arguments[0]}': deploy, rollback, status or deployments" ;;
  esac
}

# On one line: the checkout replaces this file while it runs, and bash reads a script as it goes
main "$@"; exit $?
