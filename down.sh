#!/usr/bin/env bash
# Tears the NAS stack down: stops and removes containers, removes the nas-net
# network, and DELETES the persistent config under /volume2/docker.
#
# DESTRUCTIVE. Everything Jellyfin knows — users, libraries, watch state,
# metadata — lives in /volume2/docker/jellyfin and does not survive this.
# Homepage's config goes too, including any tile edits made on the NAS. The arr
# stack's config goes as well: indexers, quality profiles and download history.
# Media under /volume1 is never touched; nothing outside /volume2/docker is.
#
# Downloads are NOT deleted. Config is reproducible from this repo; a part-done
# or still-seeding torrent is not, so the download tree survives teardown and
# must be removed by hand if you want it gone.
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
    core|jellyfin|arr) STACKS="${STACKS} ${arg}" ;;
    -h|--help)
      # Print the header block: every comment line after the shebang, stopping
      # at the first non-comment. Self-adjusting, so editing the header above
      # cannot silently truncate --help.
      sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
      exit 0 ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: ./down.sh [--yes] [--force] [--containers] [core] [jellyfin] [arr]" >&2
      exit 1 ;;
  esac
done
STACKS="${STACKS:- core jellyfin arr}"

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
# shellcheck disable=SC1091
[ -f arr.env ] && { set -a; . ./arr.env; set +a; }

# --- what would be deleted ---------------------------------------------------

# Only real subdirectories of this root may ever be removed. The paths below
# come from a sourced .env, so a mistyped or empty value must not be able to
# expand into something outside it.
SAFE_ROOT="/volume2/docker"

DELETE_PATHS=""
case " $STACKS " in
  *" core "*)
    DELETE_PATHS="${DELETE_PATHS} $(dirname "${HOMEPAGE_CONFIG_DIR:-${SAFE_ROOT}/homepage/config}")"
    ;;
esac
case " $STACKS " in
  *" jellyfin "*)
    DELETE_PATHS="${DELETE_PATHS} $(dirname "${JELLYFIN_CONFIG_DIR:-${SAFE_ROOT}/jellyfin/config}")"
    ;;
esac
case " $STACKS " in
  *" arr "*)
    # One entry per service, since each owns its own /volume2/docker/<service>.
    # DOWNLOADS_DIR is deliberately absent: it is under SAFE_ROOT and so would be
    # accepted, but deleting a seeding torrent tree is not a config reset. It is
    # reported under "NOT touched" instead.
    DELETE_PATHS="${DELETE_PATHS} $(dirname "${SONARR_CONFIG_DIR:-${SAFE_ROOT}/sonarr/config}")"
    DELETE_PATHS="${DELETE_PATHS} $(dirname "${RADARR_CONFIG_DIR:-${SAFE_ROOT}/radarr/config}")"
    DELETE_PATHS="${DELETE_PATHS} $(dirname "${PROWLARR_CONFIG_DIR:-${SAFE_ROOT}/prowlarr/config}")"
    DELETE_PATHS="${DELETE_PATHS} $(dirname "${QBITTORRENT_CONFIG_DIR:-${SAFE_ROOT}/qbittorrent/config}")"
    # dirname covers both config/ and repos/ under /volume2/docker/configarr.
    DELETE_PATHS="${DELETE_PATHS} $(dirname "${CONFIGARR_CONFIG_DIR:-${SAFE_ROOT}/configarr/config}")"
    DELETE_PATHS="${DELETE_PATHS} $(dirname "${OFELIA_CONFIG_DIR:-${SAFE_ROOT}/ofelia/config}")"
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
for tier in core jellyfin arr; do
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
  info "core.env / jellyfin.env / arr.env (delete by hand for a truly clean slate)"
  info "  — but arr.env holds the only copy of the arr API keys; losing it means"
  info "    the rebuilt stack gets new ones and every integration must be redone"
  case " $STACKS " in
    *" arr "*)
      # Under SAFE_ROOT and therefore deletable, but excluded on purpose: config
      # comes back from this repo, a part-done download does not.
      info "${DOWNLOADS_DIR:-${SAFE_ROOT}/downloads} (downloads keep seeding; remove by hand)"
      ;;
  esac
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

# arr first, core last: core owns nas-net and arr joins it as external, so arr
# must release its reference before the network can go. Jellyfin is
# host-networked and on no Docker network, so it is order-independent.
for tier in arr jellyfin core; do
  case " $STACKS " in *" $tier "*) ;; *) continue ;; esac
  say "Stopping ${tier} stack"
  # `down` ignores services behind a compose profile unless that profile is
  # enabled, so the arr tier names its own or the configarr container survives.
  TIER_PROFILES=""
  [ "$tier" = "arr" ] && TIER_PROFILES="--profile configarr"
  if [ -f "${tier}.env" ]; then
    # shellcheck disable=SC2086
    run docker compose -p "nas-${tier}" --env-file "${tier}.env" \
      -f "docker-compose.${tier}.yml" $TIER_PROFILES down --remove-orphans
  else
    # shellcheck disable=SC2086
    run docker compose -p "nas-${tier}" \
      -f "docker-compose.${tier}.yml" $TIER_PROFILES down --remove-orphans
  fi
done

# A container started outside the -p convention lives under a different project
# name and is missed by the calls above; clean up by name as a backstop.
say "Removing any stray containers by name"
for c in homepage jellyfin sonarr radarr prowlarr qbittorrent byparr configarr ofelia; do
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
