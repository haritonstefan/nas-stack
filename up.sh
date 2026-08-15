#!/usr/bin/env bash
# Brings the whole NAS stack up from a fresh clone:
#   git clone ... && cd nas-stack && ./up.sh
#
# Creates .env files from the examples, creates host directories with the right
# ownership, starts core (Traefik + Homepage, which creates nas-net), starts
# Jellyfin, then configures Jellyfin over its API via jellyfin-bootstrap.sh.
#
# Idempotent — safe to re-run. Existing .env files are never overwritten,
# already-running stacks are reconciled rather than recreated, and the Jellyfin
# bootstrap skips whatever is already configured.
#
#   ./up.sh                  # everything
#   ./up.sh --dry-run        # print what would happen, change nothing
#   ./up.sh core             # only the core stack
#   ./up.sh jellyfin         # only the jellyfin stack (+ bootstrap)
#   ./up.sh --no-bootstrap   # bring stacks up, skip Jellyfin API config

set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=0
RUN_BOOTSTRAP=1
STACKS=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    --no-bootstrap) RUN_BOOTSTRAP=0 ;;
    core|jellyfin) STACKS="${STACKS} ${arg}" ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: ./up.sh [--dry-run] [--no-bootstrap] [core] [jellyfin]" >&2
      exit 1 ;;
  esac
done
STACKS="${STACKS:- core jellyfin}"

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

# --- env files ---------------------------------------------------------------

say "Preparing .env files"
for tier in core jellyfin; do
  case " $STACKS " in *" $tier "*) ;; *) continue ;; esac
  if [ -f "${tier}.env" ]; then
    info "${tier}.env exists, leaving untouched"
  else
    run cp "${tier}.env.example" "${tier}.env"
    info "${tier}.env created from example — review before relying on it"
  fi
done

# Load values so directory paths below match what compose will use.
# shellcheck disable=SC1091
[ -f core.env ] && { set -a; . ./core.env; set +a; }
# shellcheck disable=SC1091
[ -f jellyfin.env ] && { set -a; . ./jellyfin.env; set +a; }

PUID="${PUID:-1000}"
PGID="${PGID:-10}"

# --- host directories --------------------------------------------------------

say "Creating host directories"
make_dir() {
  local path="$1"
  if [ -d "$path" ]; then
    info "${path} exists"
  else
    run mkdir -p "$path"
    info "${path} created"
  fi
  if [ "$IS_ROOT" -eq 1 ]; then
    run chown -R "${PUID}:${PGID}" "$path"
  fi
}

case " $STACKS " in
  *" core "*)
    make_dir "${HOMEPAGE_CONFIG_DIR:-/volume2/docker/homepage/config}"
    # Homepage renders tiles from labels without this, but container stats and
    # status only resolve once docker.yaml declares the socket.
    HP_DOCKER="${HOMEPAGE_CONFIG_DIR:-/volume2/docker/homepage/config}/docker.yaml"
    if [ -f "$HP_DOCKER" ]; then
      info "docker.yaml exists, leaving untouched"
    else
      run cp homepage-config/docker.yaml "$HP_DOCKER"
      [ "$IS_ROOT" -eq 1 ] && run chown "${PUID}:${PGID}" "$HP_DOCKER"
      info "docker.yaml installed"
    fi
    ;;
esac

case " $STACKS " in
  *" jellyfin "*)
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

    # Hardware transcoding needs the render node; without it the container
    # fails to start because the device bind has no source.
    if [ -e /dev/dri/renderD128 ]; then
      info "/dev/dri/renderD128 present"
      if [ "$DRY_RUN" -eq 0 ] && command -v getent >/dev/null 2>&1; then
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
    ;;
esac

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
case " $STACKS " in *" core "*) compose_up core ;; esac
case " $STACKS " in *" jellyfin "*) compose_up jellyfin ;; esac

# --- jellyfin bootstrap ------------------------------------------------------

case " $STACKS " in
  *" jellyfin "*)
    if [ "$RUN_BOOTSTRAP" -eq 0 ]; then
      say "Skipping Jellyfin bootstrap (--no-bootstrap)"
    else
      say "Configuring Jellyfin"

      # The only genuinely interactive step: the admin password has no default
      # by design, so a missing one must fail loudly rather than invent a secret.
      if [ -z "${JELLYFIN_ADMIN_PASSWORD:-}" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
          info "[dry-run] would prompt for JELLYFIN_ADMIN_PASSWORD"
        elif [ -t 0 ]; then
          printf '    Jellyfin admin password for user "%s": ' "${JELLYFIN_ADMIN_USER:-admin}"
          read -rs JELLYFIN_ADMIN_PASSWORD
          printf '\n'
          if [ -z "$JELLYFIN_ADMIN_PASSWORD" ]; then
            echo "ERROR: password cannot be empty." >&2
            exit 1
          fi
          # Persist so re-runs and the bootstrap script itself pick it up.
          if grep -q '^JELLYFIN_ADMIN_PASSWORD=' jellyfin.env; then
            tmp=$(mktemp)
            grep -v '^JELLYFIN_ADMIN_PASSWORD=' jellyfin.env > "$tmp"
            printf 'JELLYFIN_ADMIN_PASSWORD=%s\n' "$JELLYFIN_ADMIN_PASSWORD" >> "$tmp"
            mv "$tmp" jellyfin.env
          else
            printf 'JELLYFIN_ADMIN_PASSWORD=%s\n' "$JELLYFIN_ADMIN_PASSWORD" >> jellyfin.env
          fi
          chmod 600 jellyfin.env
          info "saved to jellyfin.env (chmod 600)"
        else
          echo "ERROR: JELLYFIN_ADMIN_PASSWORD is unset and there is no TTY to" >&2
          echo "       prompt on. Set it in jellyfin.env and re-run." >&2
          exit 1
        fi
      fi

      export JELLYFIN_ADMIN_PASSWORD
      if [ "$DRY_RUN" -eq 1 ]; then
        ./jellyfin-bootstrap.sh --dry-run 2>&1 | sed 's/^/    /' || true
      else
        # Exit 10 means it changed BaseUrl and a restart is needed; 0 means
        # nothing to activate. Anything else is a real failure.
        BOOTSTRAP_RC=0
        ./jellyfin-bootstrap.sh || BOOTSTRAP_RC=$?
        case "$BOOTSTRAP_RC" in
          0)
            info "no restart needed"
            ;;
          10)
            say "Restarting Jellyfin to apply the base URL"
            run docker restart jellyfin >/dev/null
            info "restarted"
            ;;
          *)
            echo "ERROR: jellyfin-bootstrap.sh failed (exit ${BOOTSTRAP_RC})." >&2
            exit "$BOOTSTRAP_RC"
            ;;
        esac
      fi
    fi
    ;;
esac

# --- summary -----------------------------------------------------------------

say "Done"
cat <<EOF
    Homepage:          http://apollo.local/
    Traefik dashboard: http://apollo.local:${TRAEFIK_DASHBOARD_PORT:-8082}/dashboard/
    Jellyfin:          http://apollo.local/jellyfin

    Still manual: Jellyfin Dashboard -> Plugins -> Catalog -> DLNA, if you want
    Jellyfin to serve DLNA in place of UGOS's disabled responder.
EOF
