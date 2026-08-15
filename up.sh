#!/usr/bin/env bash
# Brings the whole NAS stack up from a fresh clone. Idempotent.

set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Brings the whole NAS stack up from a fresh clone:
  git clone ... && cd nas-stack && sudo ./up.sh

Creates .env files from the examples, creates host directories with the right
ownership, starts core (Traefik + Homepage, which creates nas-net), starts
Jellyfin, then configures Jellyfin over its API via jellyfin-bootstrap.sh.

Idempotent — existing .env files are never overwritten, already-running stacks
are reconciled rather than recreated, and the bootstrap skips what is already
configured.

  sudo ./up.sh                  # everything
  ./up.sh --dry-run             # print what would happen, change nothing
  sudo ./up.sh core             # only the core stack
  sudo ./up.sh jellyfin         # only the jellyfin stack (+ bootstrap)
  sudo ./up.sh --no-bootstrap   # bring stacks up, skip Jellyfin API config
EOF
}

DRY_RUN=0
RUN_BOOTSTRAP=1
STACKS=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --no-bootstrap) RUN_BOOTSTRAP=0 ;;
    core|jellyfin)  STACKS="${STACKS} ${arg}" ;;
    -h|--help)      usage; exit 0 ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: ./up.sh [--dry-run] [--no-bootstrap] [core] [jellyfin]" >&2
      exit 1 ;;
  esac
done
STACKS="${STACKS:- core jellyfin}"

want() { case " $STACKS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1" >&2; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# --- preflight ---------------------------------------------------------------

say "Checking prerequisites"
MISSING=""
for cmd in docker curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING="${MISSING} ${cmd}"
done
if [ -n "$MISSING" ]; then
  echo "ERROR: missing required command(s):${MISSING}" >&2
  exit 1
fi
docker compose version >/dev/null 2>&1 || {
  echo "ERROR: 'docker compose' (v2) is required." >&2; exit 1; }
info "docker, docker compose, curl, jq present"

if ! docker info >/dev/null 2>&1; then
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "cannot talk to the Docker daemon — continuing anyway since this is a dry run"
  else
    echo "ERROR: cannot talk to the Docker daemon. Is it running, and does this" >&2
    echo "       user have permission (try: sudo ./up.sh)?" >&2
    exit 1
  fi
fi

# Ownership only applies when we can actually chown — i.e. running as root.
IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

# Files this script creates under sudo would otherwise end up root-owned inside
# a user-owned repo, leaving the invoking user unable to read their own .env.
repo_own() {
  [ "$IS_ROOT" -eq 1 ] && [ -n "${SUDO_UID:-}" ] || return 0
  run chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$1"
}

# --- env files ---------------------------------------------------------------

say "Preparing .env files"
for tier in core jellyfin; do
  want "$tier" || continue
  if [ -f "${tier}.env" ]; then
    info "${tier}.env exists, leaving untouched"
  else
    run cp "${tier}.env.example" "${tier}.env"
    repo_own "${tier}.env"
    info "${tier}.env created from example — review before relying on it"
  fi
done

# Load values so directory paths below match what compose will use. Scoped to
# the selected stacks: jellyfin.env also carries PUID/PGID, which would
# otherwise override core.env's on a core-only run.
if want core && [ -f core.env ]; then
  # shellcheck disable=SC1091
  set -a; . ./core.env; set +a
fi
if want jellyfin && [ -f jellyfin.env ]; then
  # shellcheck disable=SC1091
  set -a; . ./jellyfin.env; set +a
fi

PUID="${PUID:-1000}"
PGID="${PGID:-10}"

# --- host directories --------------------------------------------------------

say "Creating host directories"
make_dir() {
  local path="$1"
  if [ -d "$path" ]; then
    info "${path} exists"
    # Only the directory itself — a recursive chown here would walk all of
    # Jellyfin's metadata and transcodes on every single run.
    [ "$IS_ROOT" -eq 1 ] && run chown "${PUID}:${PGID}" "$path"
  else
    run mkdir -p "$path"
    [ "$IS_ROOT" -eq 1 ] && run chown -R "${PUID}:${PGID}" "$path"
    info "${path} $([ "$DRY_RUN" -eq 1 ] && echo 'would be created' || echo created)"
  fi
  return 0
}

if want core; then
  make_dir "${HOMEPAGE_CONFIG_DIR:-/volume2/docker/homepage/config}"
  # Homepage renders tiles from labels without this, but container stats and
  # status only resolve once docker.yaml declares the socket.
  HP_DOCKER="${HOMEPAGE_CONFIG_DIR:-/volume2/docker/homepage/config}/docker.yaml"
  if [ -f "$HP_DOCKER" ]; then
    info "docker.yaml exists, leaving untouched"
  else
    run cp homepage-config/docker.yaml "$HP_DOCKER"
    [ "$IS_ROOT" -eq 1 ] && run chown "${PUID}:${PGID}" "$HP_DOCKER"
    info "docker.yaml $([ "$DRY_RUN" -eq 1 ] && echo 'would be installed' || echo installed)"
  fi
fi

if want jellyfin; then
  make_dir "${JELLYFIN_CONFIG_DIR:-/volume2/docker/jellyfin/config}"
  make_dir "${JELLYFIN_CACHE_DIR:-/volume2/docker/jellyfin/cache}"

  # Media dirs are pre-existing libraries — never created or chowned here,
  # only checked, since Jellyfin mounts them read-only.
  for d in "${MEDIA_MOVIES_DIR:-/volume1/Media/Movies}" \
           "${MEDIA_SERIES_DIR:-/volume1/Media/Series}" \
           "${MEDIA_MUSIC_DIR:-/volume1/Media/Music}"; do
    if [ -d "$d" ]; then
      info "${d} present"
    else
      warn "${d} does not exist — Jellyfin will start but that library will be empty"
    fi
  done

  # Hardware transcoding needs the render node; without it the container fails
  # to start because the device bind has no source.
  if [ -e /dev/dri/renderD128 ]; then
    info "/dev/dri/renderD128 present"
    if command -v getent >/dev/null 2>&1; then
      ACTUAL_GID="$(getent group render 2>/dev/null | cut -d: -f3 || true)"
      if [ -n "$ACTUAL_GID" ] && [ "$ACTUAL_GID" != "${RENDER_GID:-105}" ]; then
        warn "RENDER_GID is ${RENDER_GID:-105} but this host's render group is ${ACTUAL_GID}"
        warn "update RENDER_GID in jellyfin.env or transcoding will fail"
      fi
    fi
  else
    warn "/dev/dri/renderD128 missing — remove the devices: block from"
    warn "docker-compose.jellyfin.yml or the container will not start"
  fi
fi

# --- jellyfin admin password -------------------------------------------------

# Resolved BEFORE anything starts. Jellyfin's setup wizard is one-shot: aborting
# here after the container is up would leave a reachable server with an open
# wizard and no admin user, which is exactly the state that cannot be retried
# without wiping /config.
NEED_PASSWORD_PROMPT=0
if want jellyfin && [ "$RUN_BOOTSTRAP" -eq 1 ] && [ -z "${JELLYFIN_ADMIN_PASSWORD:-}" ]; then
  NEED_PASSWORD_PROMPT=1
fi

if [ "$NEED_PASSWORD_PROMPT" -eq 1 ]; then
  say "Jellyfin admin password"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would prompt for JELLYFIN_ADMIN_PASSWORD"
  elif [ -t 0 ]; then
    while :; do
      printf '    Password for user "%s": ' "${JELLYFIN_ADMIN_USER:-admin}"
      read -rs JELLYFIN_ADMIN_PASSWORD; printf '\n'
      if [ -z "$JELLYFIN_ADMIN_PASSWORD" ]; then
        warn "password cannot be empty"
        continue
      fi
      # Confirmed twice: a typo here is only discovered after the wizard has
      # already closed around it, and recovering means wiping /config.
      printf '    Confirm: '
      read -rs CONFIRM_PASSWORD; printf '\n'
      [ "$JELLYFIN_ADMIN_PASSWORD" = "$CONFIRM_PASSWORD" ] && break
      warn "passwords did not match, try again"
    done
    unset CONFIRM_PASSWORD

    # Single-quoted on write: jellyfin.env is shell-sourced by this script and
    # by jellyfin-bootstrap.sh, so a space, # or $ in the password must not be
    # interpreted. Embedded single quotes close-escape-reopen.
    ESCAPED_PASSWORD=$(printf "%s" "$JELLYFIN_ADMIN_PASSWORD" | sed "s/'/'\\\\''/g")
    grep -v '^JELLYFIN_ADMIN_PASSWORD=' jellyfin.env > jellyfin.env.tmp
    printf "JELLYFIN_ADMIN_PASSWORD='%s'\n" "$ESCAPED_PASSWORD" >> jellyfin.env.tmp
    cat jellyfin.env.tmp > jellyfin.env   # keeps the original owner and mode
    rm -f jellyfin.env.tmp
    chmod 600 jellyfin.env
    repo_own jellyfin.env
    info "saved to jellyfin.env (chmod 600)"
  else
    echo "ERROR: JELLYFIN_ADMIN_PASSWORD is unset and there is no TTY to" >&2
    echo "       prompt on. Set it in jellyfin.env and re-run." >&2
    exit 1
  fi
fi

# --- stacks ------------------------------------------------------------------

compose_up() {
  local tier="$1"
  say "Starting ${tier} stack"
  # -p per tier: without it every stack shares the directory-derived project
  # name, and each `up` reports the other stack's containers as orphans.
  run docker compose -p "nas-${tier}" --env-file "${tier}.env" \
    -f "docker-compose.${tier}.yml" up -d
}

# core first: it defines nas-net, which every other stack joins as external.
if want core;     then compose_up core;     fi
if want jellyfin; then compose_up jellyfin; fi

# --- jellyfin bootstrap ------------------------------------------------------

if want jellyfin; then
  if [ "$RUN_BOOTSTRAP" -eq 0 ]; then
    say "Skipping Jellyfin bootstrap (--no-bootstrap)"
  else
    say "Configuring Jellyfin"
    export JELLYFIN_ADMIN_PASSWORD="${JELLYFIN_ADMIN_PASSWORD:-}"
    if [ "$DRY_RUN" -eq 1 ]; then
      ./jellyfin-bootstrap.sh --dry-run 2>&1 | sed 's/^/    /' || true
    else
      # Exit 10 means it changed BaseUrl and a restart is needed; 0 means
      # nothing to activate. Anything else is a real failure.
      BOOTSTRAP_RC=0
      ./jellyfin-bootstrap.sh || BOOTSTRAP_RC=$?
      case "$BOOTSTRAP_RC" in
        0)  info "no restart needed" ;;
        10) say "Restarting Jellyfin to apply the base URL"
            docker restart jellyfin >/dev/null
            info "restarted" ;;
        *)  echo "ERROR: jellyfin-bootstrap.sh failed (exit ${BOOTSTRAP_RC})." >&2
            exit "$BOOTSTRAP_RC" ;;
      esac
    fi
  fi
fi

# --- summary -----------------------------------------------------------------

say "Done"
if want core; then
  info "Homepage:          http://apollo.local/"
  info "Traefik dashboard: http://apollo.local:${TRAEFIK_DASHBOARD_PORT:-8082}/dashboard/"
fi
if want jellyfin; then
  info "Jellyfin:          http://apollo.local${JELLYFIN_BASE_URL:-/jellyfin}"
  printf '\n'
  info "Still manual: Jellyfin Dashboard -> Plugins -> Catalog -> DLNA, if you"
  info "want Jellyfin to serve DLNA in place of UGOS's disabled responder."
fi
