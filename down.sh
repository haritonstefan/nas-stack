#!/usr/bin/env bash
# Tears the NAS stack down: stops and removes containers, removes the nas-net
# network, and DELETES the persistent config under /volume2/docker.
#
# DESTRUCTIVE. Everything Jellyfin knows — users, libraries, watch state,
# metadata — lives in /volume2/docker/jellyfin and does not survive this.
# Homepage's config goes too, including any tile edits made on the NAS. The
# arr units' config goes as well: indexers, quality profiles and download
# history, plus Seerr's users and request history — the wiring is
# reproducible from this repo, but who requested what is not.
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
#   ./down.sh --yes jellyfin  # scope to one unit
#   ./down.sh --yes radarr    # scope to a single arr unit — the point of the
#                              # per-service split: tear down just this one
#
# Every service is its own compose project (docker-compose.<unit>.yml).
# `core` and `arr` remain as convenience aliases: core -> homepage, arr -> the
# 8 arr-derived units. Whenever qBittorrent is in scope only because of the
# `arr` alias (explicitly typed or via the no-args default), it is kept by
# default — untouched, still running, still seeding — so this destroy/
# recreate cycle can be run freely without losing active torrents or the
# WebUI credentials Sonarr/Radarr rely on. Pass --wipe-qbittorrent to also
# reset it, the old behavior, or name `qbittorrent` directly to always
# include it regardless of --wipe-qbittorrent.
#
#   ./down.sh --yes --wipe-qbittorrent   # also reset qBittorrent (loses seeding state)
#   ./down.sh --yes qbittorrent          # qbittorrent specifically, always included
#
# Default is a dry run on purpose: this is the one script in the repo where a
# mistyped invocation costs real data.

set -euo pipefail
cd "$(dirname "$0")"

# UNITS_ALL, ARR_UNITS, is_unit(), add_unit(), want() — shared with up.sh and
# configure.sh so the unit list has one source of truth.
. ./lib-units.sh

APPLY=0
FORCE=0
CONTAINERS_ONLY=0
WIPE_QBITTORRENT=0
EXPLICIT_QBITTORRENT=0
RAW_TOKENS=""

for arg in "$@"; do
  case "$arg" in
    --yes|-y)             APPLY=1 ;;
    --force|-f)           FORCE=1 ;;
    --containers)         CONTAINERS_ONLY=1 ;;
    --wipe-qbittorrent)   WIPE_QBITTORRENT=1 ;;
    core|jellyfin|arr)    RAW_TOKENS="${RAW_TOKENS} ${arg}" ;;
    -h|--help)
      # Print the header block: every comment line after the shebang, stopping
      # at the first non-comment. Self-adjusting, so editing the header above
      # cannot silently truncate --help.
      sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
      exit 0 ;;
    *)
      if is_unit "$arg"; then
        RAW_TOKENS="${RAW_TOKENS} ${arg}"
        [ "$arg" = "qbittorrent" ] && EXPLICIT_QBITTORRENT=1
      else
        echo "Unknown argument: ${arg}" >&2
        echo "Usage: ./down.sh [--yes] [--force] [--containers] [--wipe-qbittorrent] [core|arr|<unit>...]" >&2
        echo "Units: ${UNITS_ALL}" >&2
        exit 1
      fi ;;
  esac
done
RAW_TOKENS="${RAW_TOKENS:- core jellyfin arr}"

for t in $RAW_TOKENS; do
  case "$t" in
    core) add_unit homepage ;;
    arr)  for u in $ARR_UNITS; do add_unit "$u"; done ;;
    *)    add_unit "$t" ;;
  esac
done

# qBittorrent is spared by default whenever it is only in scope because of the
# `arr` alias (explicit or default) — not when the caller named it directly,
# and not when --wipe-qbittorrent opts into the old full-reset behavior.
KEEP_QBITTORRENT=0
if [ "$WIPE_QBITTORRENT" -eq 0 ] && [ "$EXPLICIT_QBITTORRENT" -eq 0 ]; then
  case " $UNITS " in
    *" qbittorrent "*)
      KEEP_QBITTORRENT=1
      NEW_UNITS=""
      for u in $UNITS; do [ "$u" = "qbittorrent" ] || NEW_UNITS="${NEW_UNITS} $u"; done
      UNITS="$NEW_UNITS"
      ;;
  esac
fi

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

# Load env so the paths below match what the units actually used. Every
# file, not just the ones in scope this run — cheap, and paths are only
# acted on for units that are actually selected below.
# shellcheck disable=SC1091
[ -f shared.env ] && { set -a; . ./shared.env; set +a; }
for unit in $UNITS_ALL; do
  # shellcheck disable=SC1090,SC1091
  [ -f "${unit}.env" ] && { set -a; . "./${unit}.env"; set +a; }
done

# --- what would be deleted ---------------------------------------------------

# Only real subdirectories of this root may ever be removed. The paths below
# come from sourced .env files, so a mistyped or empty value must not be able
# to expand into something outside it.
SAFE_ROOT="/volume2/docker"

DELETE_PATHS=""
want homepage    && DELETE_PATHS="${DELETE_PATHS} $(dirname "${HOMEPAGE_CONFIG_DIR:-${SAFE_ROOT}/homepage/config}")"
want jellyfin     && DELETE_PATHS="${DELETE_PATHS} $(dirname "${JELLYFIN_CONFIG_DIR:-${SAFE_ROOT}/jellyfin/config}")"
want sonarr       && DELETE_PATHS="${DELETE_PATHS} $(dirname "${SONARR_CONFIG_DIR:-${SAFE_ROOT}/sonarr/config}")"
want radarr       && DELETE_PATHS="${DELETE_PATHS} $(dirname "${RADARR_CONFIG_DIR:-${SAFE_ROOT}/radarr/config}")"
want prowlarr     && DELETE_PATHS="${DELETE_PATHS} $(dirname "${PROWLARR_CONFIG_DIR:-${SAFE_ROOT}/prowlarr/config}")"
# Kept by default (see KEEP_QBITTORRENT) — a still-seeding torrent's state is
# not a config reset. --wipe-qbittorrent (or naming it directly) opts back in.
want qbittorrent  && DELETE_PATHS="${DELETE_PATHS} $(dirname "${QBITTORRENT_CONFIG_DIR:-${SAFE_ROOT}/qbittorrent/config}")"
want seerr        && DELETE_PATHS="${DELETE_PATHS} $(dirname "${SEERR_CONFIG_DIR:-${SAFE_ROOT}/seerr/config}")"
# byparr is stateless — no config volume, nothing to delete.
# dirname covers both config/ and repos/ under /volume2/docker/configarr.
want configarr    && DELETE_PATHS="${DELETE_PATHS} $(dirname "${CONFIGARR_CONFIG_DIR:-${SAFE_ROOT}/configarr/config}")"
want ofelia       && DELETE_PATHS="${DELETE_PATHS} $(dirname "${OFELIA_CONFIG_DIR:-${SAFE_ROOT}/ofelia/config}")"

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
for unit in $UNITS_ALL; do
  want "$unit" || continue
  info "project nas-${unit} (docker-compose.${unit}.yml)"
done
if [ "$KEEP_QBITTORRENT" -eq 1 ]; then
  info "qbittorrent excluded, stays running (pass --wipe-qbittorrent to include it)"
fi

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
  info "shared.env / <unit>.env files (delete by hand for a truly clean slate)"
  info "  — but they hold the only copy of the arr API keys and the shared"
  info "    admin password; losing them means the rebuilt stack gets new ones"
  info "    and every integration must be redone"
  # Under SAFE_ROOT and therefore deletable, but excluded on purpose: config
  # comes back from this repo, a part-done download does not.
  if want sonarr || want radarr || want qbittorrent || [ "$KEEP_QBITTORRENT" -eq 1 ]; then
    info "${DOWNLOADS_DIR:-${SAFE_ROOT}/downloads} (downloads keep seeding; remove by hand)"
  fi
  if [ "$KEEP_QBITTORRENT" -eq 1 ]; then
    info "${QBITTORRENT_CONFIG_DIR:-${SAFE_ROOT}/qbittorrent/config} (kept running — pass --wipe-qbittorrent to reset it)"
  fi
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

for unit in $UNITS_ALL; do
  want "$unit" || continue
  say "Stopping ${unit}"
  TIER_PROFILES=""
  ENV_FLAGS="--env-file shared.env"
  [ -f "${unit}.env" ] && ENV_FLAGS="${ENV_FLAGS} --env-file ${unit}.env"
  if [ "$unit" = "configarr" ]; then
    # profiles: [configarr] means `down` ignores it unless the profile is
    # enabled; naming it here enables it implicitly, same as `up`. Its compose
    # file also requires SONARR_API_KEY/RADARR_API_KEY to interpolate at all
    # (even for `down`, which still renders the whole file), so sonarr.env and
    # radarr.env are passed the same way ensure_configarr_container in up.sh
    # does.
    TIER_PROFILES="--profile configarr"
    [ -f sonarr.env ] && ENV_FLAGS="${ENV_FLAGS} --env-file sonarr.env"
    [ -f radarr.env ] && ENV_FLAGS="${ENV_FLAGS} --env-file radarr.env"
  fi
  # shellcheck disable=SC2086
  run docker compose -p "nas-${unit}" $ENV_FLAGS \
    -f "docker-compose.${unit}.yml" $TIER_PROFILES down --remove-orphans
done

# A container started outside the -p convention lives under a different project
# name and is missed by the calls above; clean up by name as a backstop. Scoped
# to $UNITS like everything else here — otherwise this "backstop" removes every
# other running unit's container on any scoped teardown.
say "Removing any stray containers by name"
for c in homepage jellyfin sonarr radarr prowlarr qbittorrent seerr byparr configarr ofelia; do
  want "$c" || { info "${c} out of scope, left running"; continue; }
  if [ "$c" = "qbittorrent" ] && [ "$KEEP_QBITTORRENT" -eq 1 ]; then
    info "qbittorrent kept (pass --wipe-qbittorrent to remove)"
    continue
  fi
  if docker ps -aq -f "name=^${c}$" | grep -q .; then
    run docker rm -f "$c" >/dev/null
    info "removed ${c}"
  else
    info "${c} not present"
  fi
done

if docker network ls -q -f "name=^nas-net$" | grep -q .; then
  if [ "$KEEP_QBITTORRENT" -eq 1 ]; then
    say "Keeping nas-net"
    info "qbittorrent is still attached — pass --wipe-qbittorrent for a full reset"
  else
    say "Removing nas-net"
    run docker network rm nas-net >/dev/null 2>&1 || \
      warn "could not remove nas-net (still in use by another container?)"
  fi
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
