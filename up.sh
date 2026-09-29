#!/usr/bin/env bash
# Brings the whole NAS stack up from a fresh clone. Idempotent.

set -euo pipefail
cd "$(dirname "$0")"

# UNITS_ALL, ARR_UNITS, is_unit(), add_unit(), want() — shared with down.sh
# and configure.sh so the unit list has one source of truth.
. ./lib-units.sh

usage() {
  cat <<EOF
Brings the whole NAS stack up from a fresh clone:
  git clone ... && cd nas-stack && sudo ./up.sh

Every service is its own compose project (docker-compose.<unit>.yml), joined
by nas-net (created here, before anything else) and a shared identity/host-
facts file (shared.env). Creates .env files from the examples, creates host
directories with the right ownership, starts homepage, then jellyfin (host
networking) and configures it over its API via jellyfin-bootstrap.sh, then
the arr units (sonarr/radarr/prowlarr/qbittorrent/seerr/byparr/configarr/
ofelia) and configures them via arr-bootstrap.sh then seerr-bootstrap.sh. The
trackers (the Byparr proxy and the Prowlarr indexers) are not added here —
run ./arr-indexers.sh afterwards.

Generates each arr unit's own API key and seeds qBittorrent's WebUI password
hash on first run, and never regenerates them.

Idempotent — existing .env files are never overwritten, already-running units
are reconciled rather than recreated, and the bootstraps skip what is already
configured.

Optional: run ./configure.sh first for a guided setup of the .env files.

  sudo ./up.sh                  # everything
  ./up.sh --dry-run             # print what would happen, change nothing
  sudo ./up.sh core             # alias for: homepage
  sudo ./up.sh jellyfin         # only jellyfin (+ bootstrap)
  sudo ./up.sh arr              # alias for: ${ARR_UNITS}
  sudo ./up.sh radarr           # just one unit, e.g. to recreate it alone
  sudo ./up.sh --no-bootstrap   # bring units up, skip all API config
  sudo ./up.sh --verbose        # log every API request and response

Addressable units: ${UNITS_ALL}
EOF
}

DRY_RUN=0
RUN_BOOTSTRAP=1
VERBOSE=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --no-bootstrap) RUN_BOOTSTRAP=0 ;;
    -v|--verbose)   VERBOSE=1 ;;
    -h|--help)      usage; exit 0 ;;
    core)           add_unit homepage ;;
    arr)            for u in $ARR_UNITS; do add_unit "$u"; done ;;
    *)
      if is_unit "$arg"; then
        add_unit "$arg"
      else
        echo "Unknown argument: ${arg}" >&2
        echo "Usage: ./up.sh [--dry-run] [--verbose] [--no-bootstrap] [core|arr|<unit>...]" >&2
        echo "Units: ${UNITS_ALL}" >&2
        exit 1
      fi ;;
  esac
done
UNITS="${UNITS:-$UNITS_ALL}"

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
for cmd in docker curl jq openssl; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING="${MISSING} ${cmd}"
done
if [ -n "$MISSING" ]; then
  echo "ERROR: missing required command(s):${MISSING}" >&2
  exit 1
fi
docker compose version >/dev/null 2>&1 || {
  echo "ERROR: 'docker compose' (v2) is required." >&2; exit 1; }
info "docker, docker compose, curl, jq, openssl present"

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

# --- nas-net -------------------------------------------------------------------

# Owned by no compose file — every unit's compose file declares it as
# external: true. Created here, unconditionally, before anything else: every
# unit needs it. Idempotent via `network inspect` first.
say "Ensuring nas-net exists"
if docker network inspect nas-net >/dev/null 2>&1; then
  info "nas-net exists"
else
  run docker network create nas-net >/dev/null
  info "nas-net $([ "$DRY_RUN" -eq 1 ] && echo 'would be created' || echo created)"
fi

# --- env files ---------------------------------------------------------------

say "Preparing .env files"
# shared.env always, regardless of which units are selected — every unit's
# compose invocation passes it first via --env-file.
if [ -f shared.env ]; then
  info "shared.env exists, leaving untouched"
else
  run cp shared.env.example shared.env
  repo_own shared.env
  info "shared.env created from example — run ./configure.sh to customize, or edit by hand"
fi
for unit in $UNITS_ALL; do
  want "$unit" || continue
  [ -f "${unit}.env.example" ] || continue
  if [ -f "${unit}.env" ]; then
    info "${unit}.env exists, leaving untouched"
  else
    run cp "${unit}.env.example" "${unit}.env"
    repo_own "${unit}.env"
    info "${unit}.env created from example — run ./configure.sh to customize, or edit by hand"
  fi
done

# Load values so directory paths below match what compose will use. shared.env
# first, then each selected unit's own file, so a unit-specific name always
# wins over a same-named shared default (there should be none, but sourcing
# order matters if there ever is).
if [ -f shared.env ]; then
  # shellcheck disable=SC1091
  set -a; . ./shared.env; set +a
fi
for unit in $UNITS_ALL; do
  want "$unit" || continue
  # shellcheck disable=SC1090,SC1091
  [ -f "${unit}.env" ] && { set -a; . "./${unit}.env"; set +a; }
done

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

if want homepage; then
  make_dir "${HOMEPAGE_CONFIG_DIR:-/volume2/docker/homepage/config}"
  # docker.yaml: tiles render from labels without it, but container stats and
  # status only resolve once it declares the socket.
  # services.yaml: seeds tiles for things that are not containers here (UGOS)
  # and so cannot be auto-discovered.
  # bookmarks.yaml: empty on purpose — Homepage writes sample Developer/Social/
  # Entertainment bookmarks when the file is missing.
  # settings.yaml: title, theme, group layout/order, statusStyle, quicklaunch.
  # widgets.yaml: header row — search, resources (disk paths are the container-
  # side /volume1 + /volume2 :ro mounts), open-meteo weather, clock.
  # All are copied only when absent, so edits made on the NAS survive re-runs.
  HP_CONFIG="${HOMEPAGE_CONFIG_DIR:-/volume2/docker/homepage/config}"
  for hp_file in docker.yaml services.yaml bookmarks.yaml settings.yaml widgets.yaml; do
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

if want sonarr; then
  make_dir "${SONARR_CONFIG_DIR:-/volume2/docker/sonarr/config}"
  # Media dir is a pre-existing library — never created or chowned here, only
  # checked. A chown across a live 14 TB library is not something a bring-up
  # script should ever do. Read-write, unlike Jellyfin's read-only mounts, so
  # writability is what matters.
  d="${ARR_SERIES_DIR:-/volume1/Media/Series}"
  if [ ! -d "$d" ]; then
    warn "${d} does not exist — the Sonarr root folder for it will fail to add"
  elif [ ! -w "$d" ]; then
    warn "${d} is not writable — imports will fail"
    warn "expected owner ${PUID}:${PGID}; check: ls -ldn ${d}"
  else
    info "${d} present and writable"
  fi
fi

if want radarr; then
  make_dir "${RADARR_CONFIG_DIR:-/volume2/docker/radarr/config}"
  d="${ARR_MOVIES_DIR:-/volume1/Media/Movies}"
  if [ ! -d "$d" ]; then
    warn "${d} does not exist — the Radarr root folder for it will fail to add"
  elif [ ! -w "$d" ]; then
    warn "${d} is not writable — imports will fail"
    warn "expected owner ${PUID}:${PGID}; check: ls -ldn ${d}"
  else
    info "${d} present and writable"
  fi
fi

if want prowlarr; then
  make_dir "${PROWLARR_CONFIG_DIR:-/volume2/docker/prowlarr/config}"
fi

if want qbittorrent; then
  make_dir "${QBITTORRENT_CONFIG_DIR:-/volume2/docker/qbittorrent/config}"
fi

if want seerr; then
  # Seerr runs as `user: PUID:PGID` (not an LSIO image), so this chown is what
  # makes /app/config writable for it.
  make_dir "${SEERR_CONFIG_DIR:-/volume2/docker/seerr/config}"
fi

if want configarr; then
  make_dir "${CONFIGARR_CONFIG_DIR:-/volume2/docker/configarr/config}"
  # Cached clones of the TRaSH and Recyclarr template repos, a few hundred MB.
  make_dir "${CONFIGARR_REPOS_DIR:-/volume2/docker/configarr/repos}"
  # config.yml: the quality profiles and custom formats to apply. Needs no
  # token substitution — the API keys reach configarr as environment variables
  # and !env resolves them at run time. Installed only when absent, so edits
  # made on the NAS survive re-runs.
  CFGARR_CONFIG="${CONFIGARR_CONFIG_DIR:-/volume2/docker/configarr/config}"
  if [ -f "${CFGARR_CONFIG}/config.yml" ]; then
    info "config.yml exists, leaving untouched"
  else
    run cp "configarr-config/config.yml" "${CFGARR_CONFIG}/config.yml"
    [ "$IS_ROOT" -eq 1 ] && run chown "${PUID}:${PGID}" "${CFGARR_CONFIG}/config.yml"
    info "config.yml $([ "$DRY_RUN" -eq 1 ] && echo 'would be installed' || echo installed)"
  fi
fi

if want ofelia; then
  make_dir "${OFELIA_CONFIG_DIR:-/volume2/docker/ofelia/config}"
  # ofelia.ini: the sync schedule, in its own directory so it cannot be
  # mistaken for a configarr config file. Installed only when absent.
  OFELIA_CONFIG="${OFELIA_CONFIG_DIR:-/volume2/docker/ofelia/config}"
  if [ -f "${OFELIA_CONFIG}/ofelia.ini" ]; then
    info "ofelia.ini exists, leaving untouched"
  else
    run cp "configarr-config/ofelia.ini" "${OFELIA_CONFIG}/ofelia.ini"
    [ "$IS_ROOT" -eq 1 ] && run chown "${PUID}:${PGID}" "${OFELIA_CONFIG}/ofelia.ini"
    info "ofelia.ini $([ "$DRY_RUN" -eq 1 ] && echo 'would be installed' || echo installed)"
  fi
fi

# Downloads live on the SSD and seed from there, so this tree is created and
# owned here. qBittorrent writes the subdirectories itself; these exist so the
# bind mount has a source with the right ownership from the start. One value
# (DOWNLOADS_DIR, shared.env) shared by sonarr, radarr and qbittorrent, so
# this runs once if any of the three is selected — make_dir is idempotent.
if want sonarr || want radarr || want qbittorrent; then
  ARR_DOWNLOADS="${DOWNLOADS_DIR:-/volume2/docker/downloads}"
  make_dir "$ARR_DOWNLOADS"
  make_dir "${ARR_DOWNLOADS}/incomplete"
  make_dir "${ARR_DOWNLOADS}/complete"
fi

# --- shared admin identity ----------------------------------------------------

# Resolved BEFORE anything starts. Jellyfin's setup wizard is one-shot:
# aborting after the container is up would leave a reachable server with an
# open wizard and no admin user, which is exactly the state that cannot be
# retried without wiping /config. qBittorrent needs the same password to seed
# its WebUI hash before first start, so this is shared between both, not a
# Jellyfin-only prompt.
NEED_PASSWORD_PROMPT=0
if { want jellyfin && [ "$RUN_BOOTSTRAP" -eq 1 ]; } || want qbittorrent; then
  [ -z "${ADMIN_PASSWORD:-}" ] && NEED_PASSWORD_PROMPT=1
fi

if [ "$NEED_PASSWORD_PROMPT" -eq 1 ]; then
  say "Admin password (Jellyfin + qBittorrent WebUI)"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would prompt for ADMIN_PASSWORD"
  elif [ -t 0 ]; then
    while :; do
      printf '    Password for user "%s": ' "${ADMIN_USER:-admin}"
      read -rs ADMIN_PASSWORD; printf '\n'
      if [ -z "$ADMIN_PASSWORD" ]; then
        warn "password cannot be empty"
        continue
      fi
      # Confirmed twice: a typo here is only discovered after Jellyfin's
      # one-shot wizard has already closed around it, and recovering means
      # wiping /config.
      printf '    Confirm: '
      read -rs CONFIRM_PASSWORD; printf '\n'
      [ "$ADMIN_PASSWORD" = "$CONFIRM_PASSWORD" ] && break
      warn "passwords did not match, try again"
    done
    unset CONFIRM_PASSWORD

    # Single-quoted on write: shared.env is shell-sourced by this script and by
    # every bootstrap, and dotenv-parsed by docker compose (docker-compose.
    # qbittorrent.yml reads it directly), so a space, # or $ in the password
    # must not be interpreted. Embedded single quotes close-escape-reopen.
    ESCAPED_PASSWORD=$(printf "%s" "$ADMIN_PASSWORD" | sed "s/'/'\\\\''/g")
    grep -v '^ADMIN_PASSWORD=' shared.env > shared.env.tmp
    printf "ADMIN_PASSWORD='%s'\n" "$ESCAPED_PASSWORD" >> shared.env.tmp
    cat shared.env.tmp > shared.env   # keeps the original owner and mode
    rm -f shared.env.tmp
    chmod 600 shared.env
    repo_own shared.env
    export ADMIN_PASSWORD
    info "saved to shared.env (chmod 600)"
  else
    echo "ERROR: ADMIN_PASSWORD is unset and there is no TTY to prompt on." >&2
    echo "       Set it in shared.env (or run ./configure.sh on a terminal" >&2
    echo "       first) and re-run." >&2
    exit 1
  fi
fi

# --- per-unit secrets ---------------------------------------------------------

# set_env_var <file> <name> <value> — replace-or-append, single-quoted.
# These files are shell-sourced by this script and the bootstraps, and
# dotenv-parsed by docker compose, so a generated value containing a shell
# metacharacter must not be interpreted. Embedded single quotes close-escape-
# reopen.
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

# Written BEFORE each unit's stack starts, because the apps read their API key
# from the environment at every start and never persist it. Generated once
# per unit and never regenerated: rotating a key silently breaks Prowlarr's
# sync, Configarr and the Homepage widget for that unit at once.
gen_secret_into() { # gen_secret_into <unit> <var-name>
  local unit="$1" name="$2" current new_value
  want "$unit" || return 0
  [ -f "${unit}.env" ] || return 0
  eval "current=\${${name}:-}"
  if [ -n "$current" ]; then
    info "${name} already set, keeping it"
    return 0
  fi
  # Generated even under --dry-run, unlike everything else here. Each compose
  # file declares its key as ${VAR:?} so that a missing secret fails loudly,
  # which means `docker compose config` — and therefore the dry run's own
  # compose invocation — cannot even interpolate the file while it is empty.
  # Writing a gitignored .env is not the kind of change --dry-run withholds.
  new_value="$(gen_api_key)"
  set_env_var "${unit}.env" "$name" "$new_value"
  eval "export ${name}=\"\$new_value\""
  repo_own "${unit}.env"
  chmod 600 "${unit}.env"
  info "${name} generated (${unit}.env)"
}

say "Per-unit secrets"
gen_secret_into sonarr   SONARR_API_KEY
gen_secret_into radarr   RADARR_API_KEY
gen_secret_into prowlarr PROWLARR_API_KEY
gen_secret_into seerr    SEERR_API_KEY

if want qbittorrent; then
  # PBKDF2 in qBittorrent's stored format: SHA-512, 100000 iterations, 16-byte
  # salt, 64-byte key, base64(salt):base64(key). `openssl kdf` needs
  # OpenSSL >= 3.0 (the NAS ships 3.0.20; openssl is checked in the preflight).
  # hexpass/hexsalt sidestep kdfopt value parsing, and the password appearing
  # on openssl's argv for this one call is the same exposure already accepted
  # by keeping it in plain text in shared.env.
  gen_qbt_hash() {
    local pw="$1" pw_hex salt_b64 salt_hex key_b64
    salt_b64=$(openssl rand -base64 16 2>/dev/null) || salt_b64=""
    salt_hex=$(printf '%s' "$salt_b64" | openssl base64 -d -A 2>/dev/null \
      | od -vAn -tx1 | tr -d ' \n') || salt_hex=""
    pw_hex=$(printf '%s' "$pw" | od -vAn -tx1 | tr -d ' \n')
    key_b64=$(openssl kdf -binary -keylen 64 \
        -kdfopt digest:SHA512 -kdfopt "hexpass:${pw_hex}" \
        -kdfopt "hexsalt:${salt_hex}" -kdfopt iter:100000 PBKDF2 \
        2>/dev/null | openssl base64 -A) || key_b64=""
    [ -n "$salt_b64" ] && [ -n "$key_b64" ] || return 1
    printf '%s:%s\n' "$salt_b64" "$key_b64"
  }

  QBT_CONFIG="${QBITTORRENT_CONFIG_DIR:-/volume2/docker/qbittorrent/config}"
  if [ -f "${QBT_CONFIG}/qBittorrent.conf" ]; then
    info "qBittorrent.conf exists, leaving untouched"
  elif [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would install qBittorrent.conf with a PBKDF2 password hash"
  else
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
      echo "ERROR: ADMIN_PASSWORD is unset — cannot seed qBittorrent.conf." >&2
      echo "       Set it in shared.env (or run ./configure.sh) and re-run." >&2
      exit 1
    fi
    QBT_HASH="$(gen_qbt_hash "$ADMIN_PASSWORD")" || QBT_HASH=""
    if [ -z "$QBT_HASH" ]; then
      echo "ERROR: could not generate the qBittorrent password hash." >&2
      echo "       'openssl kdf' failed — OpenSSL >= 3.0 is required (openssl version)." >&2
      exit 1
    fi

    # The template ships placeholders rather than values so it stays readable in
    # git and carries no secret. Substituted here, at install time.
    QBT_TMP="${QBT_CONFIG}/qBittorrent.conf.tmp"
    sed -e "s|__PASSWORD_PBKDF2__|${QBT_HASH}|" \
        -e "s|__WEBUI_PORT__|${QBITTORRENT_PORT:-8080}|" \
        -e "s|__WEBUI_USER__|${ADMIN_USER:-admin}|" \
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

# --- units ---------------------------------------------------------------------

# ofelia's job-run only *starts* an existing container by name — it never
# creates one — so whenever ofelia is in scope the configarr container must
# exist first, created but not started, even if configarr itself was not
# explicitly selected. Requires sonarr.env/radarr.env to already carry real
# keys, so this is skipped (not failed) if they are not there yet — the same
# way a bring-up that never touched sonarr/radarr has nothing for configarr
# to sync anyway.
ensure_configarr_container() {
  if [ ! -f sonarr.env ] || [ ! -f radarr.env ] || [ ! -f configarr.env ]; then
    warn "skipping configarr container creation — sonarr.env/radarr.env/configarr.env not all present yet"
    warn "(run sudo ./up.sh sonarr radarr configarr at least once first)"
    return 0
  fi
  say "Ensuring the configarr container exists (scheduler target)"
  run docker compose -p nas-configarr --env-file shared.env --env-file sonarr.env \
    --env-file radarr.env --env-file configarr.env -f docker-compose.configarr.yml \
    up -d --no-start configarr
}

compose_up() {
  local unit="$1"
  say "Starting ${unit}"
  # configarr is never brought up by a plain `up -d`: it sits behind a compose
  # profile and must never race Sonarr/Radarr's own startup (see
  # docker-compose.configarr.yml). Naming it here only ensures the container
  # exists — the actual sync runs via `docker compose run --rm` (arr-
  # bootstrap.sh) or ofelia starting it on schedule.
  if [ "$unit" = "configarr" ]; then
    ensure_configarr_container
    return 0
  fi
  # -p per unit: without it every unit shares the directory-derived project
  # name, and each `up` reports the other units' containers as orphans.
  run docker compose -p "nas-${unit}" --env-file shared.env --env-file "${unit}.env" \
    -f "docker-compose.${unit}.yml" up -d
}

# homepage first: nas-net already exists (created above), but homepage is the
# dashboard everything else shows up on, so bring it up first for parity with
# the old core-first ordering.
for unit in $UNITS_ALL; do
  want "$unit" || continue
  compose_up "$unit"
done

if want ofelia && ! want configarr; then
  ensure_configarr_container
fi

# --- jellyfin bootstrap ------------------------------------------------------

if want jellyfin; then
  if [ "$RUN_BOOTSTRAP" -eq 0 ]; then
    say "Skipping Jellyfin bootstrap (--no-bootstrap)"
  else
    say "Configuring Jellyfin"
    export ADMIN_USER="${ADMIN_USER:-admin}"
    export ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
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
        0|10) ;;
        *)  echo "ERROR: jellyfin-bootstrap.sh failed (exit ${BOOTSTRAP_RC})." >&2
            exit "$BOOTSTRAP_RC" ;;
      esac

      # The bootstrap may have minted JELLYFIN_API_KEY/JELLYFIN_SCAN_TASK_ID
      # into jellyfin.env, but the Homepage widget labels were baked into the
      # container at create time and `docker restart` keeps the old ones — only
      # a recreate refreshes them. compose_up recreates exactly when the
      # rendered config changed, and that recreate also covers a pending
      # exit-10 restart. Re-sourced in a subshell: this shell still holds the
      # pre-bootstrap values.
      # shellcheck disable=SC1091
      NEW_WIDGET_KEY=$( . ./jellyfin.env && printf '%s' "${JELLYFIN_API_KEY:-}" )
      CUR_WIDGET_KEY=$(docker inspect jellyfin \
        --format '{{ index .Config.Labels "homepage.widgets[0].key" }}' 2>/dev/null || true)
      if [ -n "$NEW_WIDGET_KEY" ] && [ "$NEW_WIDGET_KEY" != "$CUR_WIDGET_KEY" ]; then
        say "Recreating Jellyfin to publish the Homepage widget labels"
        compose_up jellyfin
      elif [ "$BOOTSTRAP_RC" -eq 10 ]; then
        say "Restarting Jellyfin to apply pending changes"
        docker restart jellyfin >/dev/null
        info "restarted"
      else
        info "no restart needed"
      fi

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

if want sonarr || want radarr || want prowlarr || want qbittorrent; then
  if [ "$RUN_BOOTSTRAP" -eq 0 ]; then
    say "Skipping arr bootstrap (--no-bootstrap)"
  else
    say "Configuring the arr units"
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

# --- seerr bootstrap ---------------------------------------------------------

# After arr-bootstrap.sh, not merged into it: Seerr binds requests to the TRaSH
# quality profiles Configarr creates there, so running it earlier would silently
# bind them to a stock profile.
#
# Its failure is deferred rather than immediate. Seerr is the last thing
# configured and nothing else depends on it, so a bring-up that got this far has
# a working stack worth keeping — but the failure must not vanish either, which
# is what used to happen when this was a warn-and-continue block inside
# arr-bootstrap.sh. So: carry on, report it loudly in the summary, exit non-zero.
SEERR_RC=0
if want seerr; then
  if [ "$RUN_BOOTSTRAP" -eq 0 ]; then
    say "Skipping Seerr bootstrap (--no-bootstrap)"
  else
    say "Configuring Seerr"
    SEERR_BOOTSTRAP_ARGS=""
    [ "$VERBOSE" -eq 1 ] && SEERR_BOOTSTRAP_ARGS="--verbose"
    if [ "$DRY_RUN" -eq 1 ]; then
      # shellcheck disable=SC2086
      ./seerr-bootstrap.sh --dry-run $SEERR_BOOTSTRAP_ARGS 2>&1 | sed 's/^/    /' || true
    else
      # Not piped, for the same reason as the arr bootstrap above: a failure's
      # diagnostics must arrive in order, and this script's whole point is that
      # its failure output is the diagnosis.
      # shellcheck disable=SC2086
      ./seerr-bootstrap.sh $SEERR_BOOTSTRAP_ARGS || SEERR_RC=$?
    fi
  fi
fi

# --- summary -----------------------------------------------------------------

say "Done"
if want homepage; then
  info "Homepage:          http://apollo.local/"
fi
if want jellyfin; then
  info "Jellyfin:          http://apollo.local:8096"
fi
if want sonarr; then
  info "Sonarr:            http://apollo.local:${SONARR_PORT:-8989}"
fi
if want radarr; then
  info "Radarr:            http://apollo.local:${RADARR_PORT:-7878}"
fi
if want prowlarr; then
  info "Prowlarr:          http://apollo.local:${PROWLARR_PORT:-9696}"
fi
if want qbittorrent; then
  info "qBittorrent:       http://apollo.local:${QBITTORRENT_PORT:-8080}"
  info "qBittorrent login: ${ADMIN_USER:-admin} / see ADMIN_PASSWORD in shared.env"
fi
if want seerr; then
  info "Seerr:             http://apollo.local:${SEERR_PORT:-5055}"
fi
if want prowlarr; then
  info "Next: run ./arr-indexers.sh to add the trackers to Prowlarr"
fi

# The stack is up either way; this is the one thing that got left unconfigured,
# and it is reported here rather than mid-run so it cannot scroll past unnoticed.
if [ "$SEERR_RC" -ne 0 ]; then
  echo >&2
  echo "  ############################################################" >&2
  echo "  # Seerr was NOT configured (seerr-bootstrap.sh exit ${SEERR_RC})." >&2
  echo "  #" >&2
  echo "  # The rest of the stack is up. Seerr is reachable but will show" >&2
  echo "  # its first-run wizard, and Homepage's Seerr widget will return" >&2
  echo "  # 403 until setup completes — its API key only carries admin" >&2
  echo "  # rights once Seerr has a user." >&2
  echo "  #" >&2
  echo "  # The cause is in the output above. Fix it, then:" >&2
  echo "  #   ./seerr-bootstrap.sh --verbose" >&2
  echo "  ############################################################" >&2
  echo >&2
fi

exit "$SEERR_RC"
