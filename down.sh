#!/usr/bin/env bash
# Tears the NAS stack down: stops and removes containers, removes the nas-net
# network, and DELETES the persistent config under /volume2/docker.
#
# DESTRUCTIVE. Everything Jellyfin knows — users, libraries, watch state,
# metadata — lives in /volume2/docker/jellyfin and does not survive this.
# Nothing outside /volume2/docker is ever deleted.
#
#   ./down.sh                 # dry run: shows exactly what would be removed
#   ./down.sh --yes           # actually do it (prompts once for confirmation)
#   ./down.sh --yes --force   # no prompt, for scripted use
#   ./down.sh --containers    # stop/remove containers only, keep all data
#   ./down.sh --yes jellyfin  # scope to one stack
#
# Default is a dry run on purpose: this is the one script in the repo where a
# mistyped invocation costs real data.

set -euo pipefail
cd "$(dirname "$0")"

APPLY=0
FORCE=0
CONTAINERS_ONLY=0
STACKS=""

for arg in "$@"; do
  case "$arg" in
    --yes|-y)       APPLY=1 ;;
    --force|-f)     FORCE=1 ;;
    --containers)   CONTAINERS_ONLY=1 ;;
    core|jellyfin)  STACKS="${STACKS} ${arg}" ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: ./down.sh [--yes] [--force] [--containers] [core] [jellyfin]" >&2
      exit 1 ;;
  esac
done
STACKS="${STACKS:- core jellyfin}"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1" >&2; }

run() {
  if [ "$APPLY" -eq 0 ]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required." >&2; exit 1; }

# Load env so the paths below match what the stacks actually used.
# shellcheck disable=SC1091
[ -f core.env ] && { set -a; . ./core.env; set +a; }
# shellcheck disable=SC1091
[ -f jellyfin.env ] && { set -a; . ./jellyfin.env; set +a; }

# --- what would be deleted ---------------------------------------------------

# Only real subdirectories of this root may ever be removed. The paths below
# come from a sourced .env, so a mistyped or empty value must not be able to
# expand into something outside it.
SAFE_ROOT="/volume2/docker"

DELETE_PATHS=""
case " $STACKS " in
  *" core "*)
    # Traefik keeps no host config (docker.sock only), but a logs/acme dir may
    # exist from earlier iterations — remove it if so.
    DELETE_PATHS="${DELETE_PATHS} ${SAFE_ROOT}/traefik"
    DELETE_PATHS="${DELETE_PATHS} $(dirname "${HOMEPAGE_CONFIG_DIR:-${SAFE_ROOT}/homepage/config}")"
    ;;
esac
case " $STACKS " in
  *" jellyfin "*)
    DELETE_PATHS="${DELETE_PATHS} $(dirname "${JELLYFIN_CONFIG_DIR:-${SAFE_ROOT}/jellyfin/config}")"
    ;;
esac

# Deduplicate and validate every path before showing or touching anything.
CHECKED_PATHS=""
for p in $DELETE_PATHS; do
  # Refuse anything that isn't a real subdirectory of SAFE_ROOT: catches an
  # empty var expanding to "/", a stray "..", and SAFE_ROOT itself.
  case "$p" in
    "${SAFE_ROOT}"/?*) ;;
    *)
      warn "refusing to delete '${p}' — outside ${SAFE_ROOT}"
      continue ;;
  esac
  case "$p" in
    *..*)
      warn "refusing to delete '${p}' — contains '..'"
      continue ;;
  esac
  case " $CHECKED_PATHS " in *" $p "*) continue ;; esac
  CHECKED_PATHS="${CHECKED_PATHS} $p"
done

# --- plan --------------------------------------------------------------------

if [ "$APPLY" -eq 0 ]; then
  say "DRY RUN — nothing will be changed. Re-run with --yes to apply."
fi

say "Containers to stop and remove"
for tier in core jellyfin; do
  case " $STACKS " in *" $tier "*) ;; *) continue ;; esac
  info "project nas-${tier} (docker-compose.${tier}.yml)"
done

if [ "$CONTAINERS_ONLY" -eq 1 ]; then
  say "Data to delete"
  info "none — --containers given, all config is kept"
else
  say "Data to DELETE (irreversible)"
  if [ -z "$CHECKED_PATHS" ]; then
    info "none resolved"
  else
    for p in $CHECKED_PATHS; do
      if [ -d "$p" ]; then
        size=$(du -sh "$p" 2>/dev/null | cut -f1 || echo '?')
        info "${p}  (${size})"
      else
        info "${p}  (does not exist, skipping)"
      fi
    done
  fi
  say "NOT touched"
  info "anything outside ${SAFE_ROOT}"
  info "core.env / jellyfin.env (delete by hand if you want a truly clean slate)"
fi

if [ "$APPLY" -eq 0 ]; then
  printf '\n    Re-run with --yes to apply.\n'
  exit 0
fi

# --- confirm -----------------------------------------------------------------

if [ "$FORCE" -eq 0 ] && [ "$CONTAINERS_ONLY" -eq 0 ]; then
  if [ ! -t 0 ]; then
    echo "ERROR: refusing to delete data without a TTY to confirm on." >&2
    echo "       Pass --force if you really mean it." >&2
    exit 1
  fi
  printf '\n\033[1mType "delete" to confirm removal of the paths above: \033[0m'
  read -r REPLY
  if [ "$REPLY" != "delete" ]; then
    echo "Aborted — nothing was changed."
    exit 1
  fi
fi

# --- tear down ---------------------------------------------------------------

# Jellyfin first: it joins nas-net as an external network, and core owns that
# network, so removing core last avoids "network in use" errors.
for tier in jellyfin core; do
  case " $STACKS " in *" $tier "*) ;; *) continue ;; esac
  say "Stopping ${tier} stack"
  if [ -f "${tier}.env" ]; then
    run docker compose -p "nas-${tier}" --env-file "${tier}.env" \
      -f "docker-compose.${tier}.yml" down --remove-orphans
  else
    run docker compose -p "nas-${tier}" \
      -f "docker-compose.${tier}.yml" down --remove-orphans
  fi
done

# Containers predating the -p convention live under the directory-derived
# project name and are missed by the calls above; clean them up by name.
say "Removing any stray containers by name"
for c in traefik homepage jellyfin; do
  if docker ps -aq -f "name=^${c}$" | grep -q .; then
    run docker rm -f "$c" >/dev/null
    info "removed ${c}"
  else
    info "${c} not present"
  fi
done

if docker network ls -q -f "name=^nas-net$" | grep -q .; then
  say "Removing nas-net"
  run docker network rm nas-net >/dev/null 2>&1 || \
    warn "could not remove nas-net (still in use by another container?)"
fi

# --- delete data -------------------------------------------------------------

if [ "$CONTAINERS_ONLY" -eq 0 ] && [ -n "$CHECKED_PATHS" ]; then
  say "Deleting data"
  for p in $CHECKED_PATHS; do
    if [ -d "$p" ]; then
      run rm -rf "$p"
      info "removed ${p}"
    else
      info "${p} absent, nothing to do"
    fi
  done
fi

say "Done"
cat <<EOF
    Bring it all back with:
      sudo ./up.sh
EOF
