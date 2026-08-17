#!/usr/bin/env bash
# Brings the whole NAS stack up from a fresh clone. Idempotent.

set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Brings the whole NAS stack up from a fresh clone:
  git clone ... && cd nas-stack && sudo ./up.sh

Creates .env files from the examples, creates host directories with the right
ownership, starts core (Homepage on :80, which creates nas-net), starts
Jellyfin (host networking), then configures it over its API via
jellyfin-bootstrap.sh. Starts the arr stack (Sonarr/Radarr/Prowlarr/qBittorrent)
and configures it via arr-bootstrap.sh.

Generates the arr API keys and the qBittorrent password into arr.env on first
run, and never regenerates them.

Idempotent — existing .env files are never overwritten, already-running stacks
are reconciled rather than recreated, and the bootstraps skip what is already
configured.

  sudo ./up.sh                  # everything
  ./up.sh --dry-run             # print what would happen, change nothing
  sudo ./up.sh core             # only the core stack
  sudo ./up.sh jellyfin         # only the jellyfin stack (+ bootstrap)
  sudo ./up.sh arr              # only the arr stack (+ bootstrap)
  sudo ./up.sh --no-bootstrap   # bring stacks up, skip all API config
  sudo ./up.sh --verbose        # log every API request and response
EOF
}

DRY_RUN=0
RUN_BOOTSTRAP=1
VERBOSE=0
STACKS=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --no-bootstrap) RUN_BOOTSTRAP=0 ;;
    -v|--verbose)   VERBOSE=1 ;;
    core|jellyfin|arr) STACKS="${STACKS} ${arg}" ;;
    -h|--help)      usage; exit 0 ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: ./up.sh [--dry-run] [--verbose] [--no-bootstrap] [core] [jellyfin] [arr]" >&2
      exit 1 ;;
  esac
done
STACKS="${STACKS:- core jellyfin arr}"

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
for tier in core jellyfin arr; do
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
if want arr && [ -f arr.env ]; then
  # shellcheck disable=SC1091
  set -a; . ./arr.env; set +a
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
  # docker.yaml: tiles render from labels without it, but container stats and
  # status only resolve once it declares the socket.
  # services.yaml: seeds tiles for things that are not containers here (UGOS)
  # and so cannot be auto-discovered.
  # bookmarks.yaml: empty on purpose — Homepage writes sample Developer/Social/
  # Entertainment bookmarks when the file is missing.
  # All are copied only when absent, so edits made on the NAS survive re-runs.
  HP_CONFIG="${HOMEPAGE_CONFIG_DIR:-/volume2/docker/homepage/config}"
  for hp_file in docker.yaml services.yaml bookmarks.yaml; do
    if [ -f "${HP_CONFIG}/${hp_file}" ]; then
      info "${hp_file} exists, leaving untouched"
    else
      run cp "homepage-config/${hp_file}" "${HP_CONFIG}/${hp_file}"
      [ "$IS_ROOT" -eq 1 ] && run chown "${PUID}:${PGID}" "${HP_CONFIG}/${hp_file}"
      info "${hp_file} $([ "$DRY_RUN" -eq 1 ] && echo 'would be installed' || echo installed)"
    fi
  done
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

if want arr; then
  make_dir "${SONARR_CONFIG_DIR:-/volume2/docker/sonarr/config}"
  make_dir "${RADARR_CONFIG_DIR:-/volume2/docker/radarr/config}"
  make_dir "${PROWLARR_CONFIG_DIR:-/volume2/docker/prowlarr/config}"
  make_dir "${QBITTORRENT_CONFIG_DIR:-/volume2/docker/qbittorrent/config}"
  make_dir "${CONFIGARR_CONFIG_DIR:-/volume2/docker/configarr/config}"
  # Cached clones of the TRaSH and Recyclarr template repos, a few hundred MB.
  make_dir "${CONFIGARR_REPOS_DIR:-/volume2/docker/configarr/repos}"
  make_dir "${OFELIA_CONFIG_DIR:-/volume2/docker/ofelia/config}"

  # config.yml: the quality profiles and custom formats to apply. Needs no
  # token substitution — the API keys reach configarr as environment variables
  # and !env resolves them at run time.
  # ofelia.ini: the sync schedule, in its own directory so it cannot be mistaken
  # for a configarr config file.
  # Both copied only when absent, so edits made on the NAS survive re-runs.
  CFGARR_CONFIG="${CONFIGARR_CONFIG_DIR:-/volume2/docker/configarr/config}"
  OFELIA_CONFIG="${OFELIA_CONFIG_DIR:-/volume2/docker/ofelia/config}"
  for spec in "config.yml:${CFGARR_CONFIG}" "ofelia.ini:${OFELIA_CONFIG}"; do
    ca_file="${spec%%:*}"
    ca_dest="${spec#*:}"
    if [ -f "${ca_dest}/${ca_file}" ]; then
      info "${ca_file} exists, leaving untouched"
    else
      run cp "configarr-config/${ca_file}" "${ca_dest}/${ca_file}"
      [ "$IS_ROOT" -eq 1 ] && run chown "${PUID}:${PGID}" "${ca_dest}/${ca_file}"
      info "${ca_file} $([ "$DRY_RUN" -eq 1 ] && echo 'would be installed' || echo installed)"
    fi
  done

  # Downloads live on the SSD and seed from there, so this tree is created and
  # owned here. qBittorrent writes the subdirectories itself; these exist so the
  # bind mount has a source with the right ownership from the start.
  ARR_DOWNLOADS="${DOWNLOADS_DIR:-/volume2/docker/downloads}"
  make_dir "$ARR_DOWNLOADS"
  make_dir "${ARR_DOWNLOADS}/incomplete"
  make_dir "${ARR_DOWNLOADS}/complete"

  # Media dirs are pre-existing libraries — never created or chowned here, only
  # checked. make_dir chowns, and a chown across a live 14 TB library is not
  # something a bring-up script should ever do. Unlike Jellyfin's read-only
  # mounts these are read-write, so writability is what matters.
  for d in "${ARR_MOVIES_DIR:-/volume1/Media/Movies}" \
           "${ARR_SERIES_DIR:-/volume1/Media/Series}"; do
    if [ ! -d "$d" ]; then
      warn "${d} does not exist — the arr root folder for it will fail to add"
    elif [ ! -w "$d" ]; then
      warn "${d} is not writable — imports will fail"
      warn "expected owner ${PUID}:${PGID}; check: ls -ldn ${d}"
    else
      info "${d} present and writable"
    fi
  done
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

# --- arr secrets -------------------------------------------------------------

# Written to arr.env BEFORE the stack starts, because the apps read their API key
# from the environment at every start and never persist it. Generated once and
# never regenerated: rotating a key silently breaks Prowlarr's app sync,
# Configarr and all three Homepage widgets at once.
if want arr && [ -f arr.env ]; then
  say "arr secrets"

  # set_env_var <file> <name> <value> — replace-or-append, single-quoted.
  # arr.env is shell-sourced by this script, by compose and by arr-bootstrap.sh,
  # so a generated value containing a shell metacharacter must not be
  # interpreted. Embedded single quotes close-escape-reopen.
  set_env_var() {
    local file="$1" name="$2" value="$3" escaped
    escaped=$(printf "%s" "$value" | sed "s/'/'\\\\''/g")
    grep -v "^${name}=" "$file" > "${file}.tmp"
    printf "%s='%s'\n" "$name" "$escaped" >> "${file}.tmp"
    cat "${file}.tmp" > "$file"   # keeps the original owner and mode
    rm -f "${file}.tmp"
  }

  # 32 lowercase hex chars, matching the format these apps generate themselves.
  gen_api_key() { od -vAn -N16 -tx1 /dev/urandom | tr -d ' \n'; }
  # No shell metacharacters, so it survives the .conf and the compose label too.
  gen_password() { od -vAn -N18 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-24; }

  ARR_SECRETS_WRITTEN=0
  for secret in SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY; do
    eval "current=\${${secret}:-}"
    if [ -n "$current" ]; then
      info "${secret} already set, keeping it"
      continue
    fi
    # Generated even under --dry-run, unlike everything else here. The compose
    # file declares these as ${VAR:?} so that a missing secret fails loudly, which
    # means `docker compose config` — and therefore the dry run's own compose
    # invocation — cannot even interpolate the file while they are empty. Writing
    # a gitignored .env is not the kind of change --dry-run exists to withhold.
    new_value="$(gen_api_key)"
    set_env_var arr.env "$secret" "$new_value"
    eval "export ${secret}=\"\$new_value\""
    ARR_SECRETS_WRITTEN=1
    info "${secret} generated"
  done

  if [ -n "${QBITTORRENT_PASSWORD:-}" ]; then
    info "QBITTORRENT_PASSWORD already set, keeping it"
  else
    # Generated in a dry run too, for the same reason as the keys above: the
    # compose file will not interpolate at all while it is empty.
    QBITTORRENT_PASSWORD="$(gen_password)"
    set_env_var arr.env QBITTORRENT_PASSWORD "$QBITTORRENT_PASSWORD"
    export QBITTORRENT_PASSWORD
    ARR_SECRETS_WRITTEN=1
    info "QBITTORRENT_PASSWORD generated"
  fi

  if [ "$ARR_SECRETS_WRITTEN" -eq 1 ]; then
    chmod 600 arr.env
    repo_own arr.env
    info "arr.env updated (chmod 600) — back this file up, the keys live only here"
  fi

  # qBittorrent mints a new random WebUI password on every start unless one is
  # already stored, which would invalidate the credentials Sonarr and Radarr hold
  # on every restart. So the config is seeded before first start, with a PBKDF2
  # hash of the password above. Copied only when absent, so on-NAS edits survive.
  QBT_CONFIG="${QBITTORRENT_CONFIG_DIR:-/volume2/docker/qbittorrent/config}"
  if [ -f "${QBT_CONFIG}/qBittorrent.conf" ]; then
    info "qBittorrent.conf exists, leaving untouched"
  elif [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would install qBittorrent.conf with a PBKDF2 password hash"
  else
    # SHA-512, 100000 iterations, 16-byte salt, 64-byte key, base64(salt):base64(key).
    QBT_HASH=""
    if command -v python3 >/dev/null 2>&1; then
      QBT_HASH=$(QBT_PW="$QBITTORRENT_PASSWORD" python3 -c '
import base64, hashlib, os
pw = os.environ["QBT_PW"].encode()
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac("sha512", pw, salt, 100000, dklen=64)
print(base64.b64encode(salt).decode() + ":" + base64.b64encode(key).decode())
') || QBT_HASH=""
    fi
    if [ -z "$QBT_HASH" ]; then
      echo "ERROR: could not generate the qBittorrent password hash." >&2
      echo "       python3 is required for this step (checked: python3)." >&2
      exit 1
    fi

    # The template ships placeholders rather than values so it stays readable in
    # git and carries no secret. Substituted here, at install time.
    QBT_TMP="${QBT_CONFIG}/qBittorrent.conf.tmp"
    sed -e "s|__PASSWORD_PBKDF2__|${QBT_HASH}|" \
        -e "s|__WEBUI_PORT__|${QBITTORRENT_PORT:-8080}|" \
        -e "s|__WEBUI_USER__|${QBITTORRENT_USER:-admin}|" \
        -e "s|__SAVE_PATH__|/downloads/complete|" \
        -e "s|__TEMP_PATH__|/downloads/incomplete|" \
        -e "s|__SEED_RATIO__|${QBITTORRENT_SEED_RATIO:-2}|" \
        -e "s|__SEED_MINUTES__|${QBITTORRENT_SEED_MINUTES:-20160}|" \
        qbittorrent-config/qBittorrent.conf > "$QBT_TMP"
    # [A-Z0-9_], not [A-Z_]: __PASSWORD_PBKDF2__ contains a digit, and missing it
    # here would let a literal placeholder through as the password hash — which
    # locks the WebUI with no error to explain why.
    if grep -q '__[A-Z0-9_]\{3,\}__' "$QBT_TMP"; then
      rm -f "$QBT_TMP"
      echo "ERROR: qBittorrent.conf still has unsubstituted placeholders." >&2
      exit 1
    fi
    mv "$QBT_TMP" "${QBT_CONFIG}/qBittorrent.conf"
    [ "$IS_ROOT" -eq 1 ] && chown "${PUID}:${PGID}" "${QBT_CONFIG}/qBittorrent.conf"
    chmod 600 "${QBT_CONFIG}/qBittorrent.conf"
    info "qBittorrent.conf installed (password hash seeded, seeding capped)"
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

# core first: it defines nas-net, which later bridged tiers join as external.
if want core;     then compose_up core;     fi
if want jellyfin; then compose_up jellyfin; fi
if want arr;      then compose_up arr;      fi

if want arr; then
  # configarr sits behind a compose profile, so the `up -d` above skips it. Ofelia
  # can only start a container that already exists — it never creates one — so
  # create it here, stopped. Naming the service enables its profile implicitly.
  #
  # Unconditional, and deliberately not gated on ARR_RUN_CONFIGARR: that flag
  # decides whether the *first sync* runs now, not whether the schedule exists.
  # The first sync happens in arr-bootstrap.sh, once Sonarr and Radarr answer.
  say "Creating the configarr container for the scheduler"
  run docker compose -p nas-arr --env-file arr.env \
    -f docker-compose.arr.yml up -d --no-start configarr
fi

# --- jellyfin bootstrap ------------------------------------------------------

if want jellyfin; then
  if [ "$RUN_BOOTSTRAP" -eq 0 ]; then
    say "Skipping Jellyfin bootstrap (--no-bootstrap)"
  else
    say "Configuring Jellyfin"
    export JELLYFIN_ADMIN_PASSWORD="${JELLYFIN_ADMIN_PASSWORD:-}"
    BOOTSTRAP_ARGS=""
    [ "$VERBOSE" -eq 1 ] && BOOTSTRAP_ARGS="--verbose"
    if [ "$DRY_RUN" -eq 1 ]; then
      # shellcheck disable=SC2086
      ./jellyfin-bootstrap.sh --dry-run $BOOTSTRAP_ARGS 2>&1 | sed 's/^/    /' || true
      if [ "${JELLYFIN_SCAN_ON_BOOTSTRAP:-1}" = "1" ]; then
        say "Triggering library scan (after any restart)"
        # shellcheck disable=SC2086
        ./jellyfin-bootstrap.sh --scan-only --dry-run $BOOTSTRAP_ARGS 2>&1 \
          | sed 's/^/    /' || true
      fi
    else
      # Not piped: keeps stdout/stderr separate and unbuffered, so a failure's
      # diagnostics arrive in the right order for debugging.
      # Exit 10 means something needs a restart to take effect (a cleared
      # BaseUrl, a newly installed DLNA plugin, or both); 0 means nothing to
      # activate. Anything else is a real failure.
      BOOTSTRAP_RC=0
      # shellcheck disable=SC2086
      ./jellyfin-bootstrap.sh $BOOTSTRAP_ARGS || BOOTSTRAP_RC=$?
      case "$BOOTSTRAP_RC" in
        0)  info "no restart needed" ;;
        10) say "Restarting Jellyfin to apply pending changes"
            docker restart jellyfin >/dev/null
            info "restarted" ;;
        *)  echo "ERROR: jellyfin-bootstrap.sh failed (exit ${BOOTSTRAP_RC})." >&2
            exit "$BOOTSTRAP_RC" ;;
      esac

      # Scan last, after any restart: it walks the whole media HDD, and a
      # restart moments in would cut it short.
      if [ "${JELLYFIN_SCAN_ON_BOOTSTRAP:-1}" = "1" ]; then
        SCAN_RC=0
        # shellcheck disable=SC2086
        ./jellyfin-bootstrap.sh --scan-only $BOOTSTRAP_ARGS || SCAN_RC=$?
        # A failed scan is not worth failing the whole bring-up over — the
        # stack is running and the scan is re-triggerable from the dashboard.
        if [ "$SCAN_RC" -ne 0 ]; then
          warn "library scan could not be started (exit ${SCAN_RC})"
        fi
      else
        info "library scan skipped (JELLYFIN_SCAN_ON_BOOTSTRAP=0)"
      fi
    fi
  fi
fi

# --- arr bootstrap -----------------------------------------------------------

if want arr; then
  if [ "$RUN_BOOTSTRAP" -eq 0 ]; then
    say "Skipping arr bootstrap (--no-bootstrap)"
  else
    say "Configuring the arr stack"
    ARR_BOOTSTRAP_ARGS=""
    [ "$VERBOSE" -eq 1 ] && ARR_BOOTSTRAP_ARGS="--verbose"
    if [ "$DRY_RUN" -eq 1 ]; then
      # shellcheck disable=SC2086
      ./arr-bootstrap.sh --dry-run $ARR_BOOTSTRAP_ARGS 2>&1 | sed 's/^/    /' || true
    else
      # Not piped: keeps stdout/stderr separate and unbuffered, so a failure's
      # diagnostics arrive in the right order for debugging. No restart channel
      # here — unlike Jellyfin, nothing the arr bootstrap sets needs one.
      ARR_RC=0
      # shellcheck disable=SC2086
      ./arr-bootstrap.sh $ARR_BOOTSTRAP_ARGS || ARR_RC=$?
      if [ "$ARR_RC" -ne 0 ]; then
        echo "ERROR: arr-bootstrap.sh failed (exit ${ARR_RC})." >&2
        exit "$ARR_RC"
      fi
    fi
  fi
fi

# --- summary -----------------------------------------------------------------

say "Done"
if want core; then
  info "Homepage:          http://apollo.local/"
fi
if want jellyfin; then
  info "Jellyfin:          http://apollo.local:8096"
fi
if want arr; then
  info "Sonarr:            http://apollo.local:${SONARR_PORT:-8989}"
  info "Radarr:            http://apollo.local:${RADARR_PORT:-7878}"
  info "Prowlarr:          http://apollo.local:${PROWLARR_PORT:-9696}"
  info "qBittorrent:       http://apollo.local:${QBITTORRENT_PORT:-8080}"
  info "qBittorrent login: ${QBITTORRENT_USER:-admin} / see QBITTORRENT_PASSWORD in arr.env"
fi
