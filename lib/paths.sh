# shellcheck shell=bash
# Sourced by ./nas. R1: nothing outside /volume2/docker can ever be deleted.
# Delete targets come from sourced .env files, so a mistyped or empty value
# must not be able to expand into something outside the root.

SAFE_ROOT="/volume2/docker"

# path_deletable <path> — a real subdirectory of SAFE_ROOT: rejects anything
# that escapes it, contains '..', or is the root itself.
path_deletable() {
  case "$1" in
    "${SAFE_ROOT}"/?*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *..*) return 1 ;;
  esac
  return 0
}
