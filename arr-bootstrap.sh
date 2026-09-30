#!/usr/bin/env bash
# Configures a fresh arr stack over the APIs: root folders, the qBittorrent
# download client, media-management settings, Prowlarr's app sync to Sonarr,
# Radarr and Lidarr, and a one-shot Configarr sync.
# Idempotent — safe to re-run.
#
# The trackers — the Byparr indexer proxy and the public/private indexers —
# live in ./arr-indexers.sh, run separately after install (nas indexers).
#
# Seerr's first-run setup lives in ./seerr-bootstrap.sh, which must run AFTER
# this script: it binds requests to the quality profiles Configarr creates here.
#
# Run AFTER `docker compose ... up -d`. Unlike Jellyfin's, nothing here is
# one-shot: every step reads the current state first and skips what is already
# configured, so a partial run can simply be repeated.
#
# Every app's API key is pre-seeded via <APP>__AUTH__APIKEY from its own
# .env file, so no key is ever read out of a config.xml and there is no
# ordering dependency between the services.
#
#   ./arr-bootstrap.sh
#   ./arr-bootstrap.sh --dry-run
#   ./arr-bootstrap.sh --verbose
#   SONARR_URL=http://apollo.local:8989 ./arr-bootstrap.sh
#
# Requires: curl, jq. Reads shared.env (ADMIN_USER/ADMIN_PASSWORD, the
# identity qBittorrent's WebUI uses) plus sonarr.env, radarr.env, lidarr.env,
# prowlarr.env, qbittorrent.env and configarr.env if present, each one
# scoped to the vars that service owns.
#
# Exit codes: 0 success. 1 precondition failure. 22 an API call returned a
# non-2xx. There is deliberately no restart channel (Jellyfin's exit 10) —
# nothing configured here needs a container restart to take effect.

set -euo pipefail

DRY_RUN=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    -v|--verbose)   VERBOSE=1 ;;
    -h|--help)
      # Print the header block: every comment line after the shebang, stopping
      # at the first non-comment. Self-adjusting, so editing the header above
      # cannot silently truncate --help.
      sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
      exit 0 ;;
    *) echo "Unknown argument: ${arg}" >&2
       echo "Usage: ./arr-bootstrap.sh [--dry-run] [--verbose]" >&2
       exit 1 ;;
  esac
done

# Bare `. file` reads, no isolating subshell: no two of these files share a
# variable name, so a later file cannot clobber an earlier one.
SHARED_ENV_FILE="${SHARED_ENV_FILE:-shared.env}"
SONARR_ENV_FILE="${SONARR_ENV_FILE:-sonarr.env}"
RADARR_ENV_FILE="${RADARR_ENV_FILE:-radarr.env}"
LIDARR_ENV_FILE="${LIDARR_ENV_FILE:-lidarr.env}"
PROWLARR_ENV_FILE="${PROWLARR_ENV_FILE:-prowlarr.env}"
QBITTORRENT_ENV_FILE="${QBITTORRENT_ENV_FILE:-qbittorrent.env}"
CONFIGARR_ENV_FILE="${CONFIGARR_ENV_FILE:-configarr.env}"

source_env_file() {
  # Prefixed with ./ only for a bare filename, so that a relative name is read
  # from here rather than $PATH, without mangling an absolute override.
  local f="$1"
  [ -f "$f" ] || return 0
  set -a
  # shellcheck disable=SC1090
  case "$f" in
    /*|./*|../*) . "$f" ;;
    *)           . "./$f" ;;
  esac
  set +a
}
source_env_file "$SHARED_ENV_FILE"
source_env_file "$SONARR_ENV_FILE"
source_env_file "$RADARR_ENV_FILE"
source_env_file "$LIDARR_ENV_FILE"
source_env_file "$PROWLARR_ENV_FILE"
source_env_file "$QBITTORRENT_ENV_FILE"
source_env_file "$CONFIGARR_ENV_FILE"

# nas install only creates <unit>.env for a unit it was asked to bring up, so file
# presence is the selection signal — every step below is gated on these flags.
have_sonarr=0;   [ -f "$SONARR_ENV_FILE" ]      && have_sonarr=1
have_radarr=0;   [ -f "$RADARR_ENV_FILE" ]      && have_radarr=1
have_lidarr=0;   [ -f "$LIDARR_ENV_FILE" ]      && have_lidarr=1
have_prowlarr=0; [ -f "$PROWLARR_ENV_FILE" ]    && have_prowlarr=1
have_qbt=0;      [ -f "$QBITTORRENT_ENV_FILE" ] && have_qbt=1
have_configarr=0;[ -f "$CONFIGARR_ENV_FILE" ]   && have_configarr=1

if [ "$have_sonarr" -eq 0 ] && [ "$have_radarr" -eq 0 ] && [ "$have_lidarr" -eq 0 ] && \
   [ "$have_prowlarr" -eq 0 ] && [ "$have_qbt" -eq 0 ]; then
  echo "Nothing to configure — none of sonarr.env/radarr.env/lidarr.env/prowlarr.env/qbittorrent.env is present." >&2
  echo "Run nas install with at least one of those units first." >&2
  exit 0
fi

SONARR_URL="${SONARR_URL:-http://127.0.0.1:8989}"
RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
LIDARR_URL="${LIDARR_URL:-http://127.0.0.1:8686}"
PROWLARR_URL="${PROWLARR_URL:-http://127.0.0.1:9696}"

SONARR_ROOT_FOLDER="${SONARR_ROOT_FOLDER:-/media/series}"
RADARR_ROOT_FOLDER="${RADARR_ROOT_FOLDER:-/media/movies}"
LIDARR_ROOT_FOLDER="${LIDARR_ROOT_FOLDER:-/media/music}"

# The shared identity (shared.env), not a qBittorrent-only credential — the
# same account backs the Jellyfin admin login and Seerr's sign-in.
ADMIN_USER="${ADMIN_USER:-admin}"
QBITTORRENT_PORT="${QBITTORRENT_PORT:-8080}"

ARR_RUN_CONFIGARR="${ARR_RUN_CONFIGARR:-1}"

# Addresses the containers use for each other over nas-net. Not the *_URL vars
# above, which are how this script (running on the host) reaches them.
SONARR_INTERNAL_URL="http://sonarr:8989"
RADARR_INTERNAL_URL="http://radarr:7878"
LIDARR_INTERNAL_URL="http://lidarr:8686"
PROWLARR_INTERNAL_URL="http://prowlarr:9696"
QBITTORRENT_HOST="qbittorrent"

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required." >&2; exit 1; }
done

if [ "$DRY_RUN" -eq 0 ]; then
  # Only required for units actually present this run — ADMIN_PASSWORD only
  # matters when qbittorrent is, since it's solely used to wire qBittorrent's
  # WebUI credentials into the arr apps' download clients (see have_qbt below).
  require_var() {
    local var="$1" val
    eval "val=\${${var}:-}"
    if [ -z "$val" ]; then
      echo "ERROR: ${var} is not set (run nas install, which generates the API keys" >&2
      echo "       and prompts for ADMIN_PASSWORD). The stack cannot be" >&2
      echo "       configured without it." >&2
      exit 1
    fi
  }
  [ "$have_sonarr" -eq 1 ]   && require_var SONARR_API_KEY
  [ "$have_radarr" -eq 1 ]   && require_var RADARR_API_KEY
  [ "$have_lidarr" -eq 1 ]   && require_var LIDARR_API_KEY
  [ "$have_prowlarr" -eq 1 ] && require_var PROWLARR_API_KEY
  [ "$have_qbt" -eq 1 ]      && require_var ADMIN_PASSWORD
fi
: "${SONARR_API_KEY:=<unset>}"
: "${RADARR_API_KEY:=<unset>}"
: "${LIDARR_API_KEY:=<unset>}"
: "${PROWLARR_API_KEY:=<unset>}"
: "${ADMIN_PASSWORD:=<unset>}"

say()  { echo "==> $1"; }
info() { echo "    $1"; }
warn() { echo "    WARNING: $1" >&2; }

api() {
  # api <base-url> <api-key> <method> <path> [json-body]
  # Talks to several services, so the target is an argument rather than a global.
  # stdout is the response body only; all logging goes to stderr, so
  #   X=$(api ...) works and `api ... >/dev/null` stays quiet.
  local base="$1" key="$2" method="$3" path="$4" body="${5:-}"
  # No -f: it discards the response body on HTTP errors, which is exactly where
  # these apps put their validation messages. Status is captured separately.
  local -a args=(-sS -X "$method" "${base}${path}"
                 -H 'Content-Type: application/json' -H "X-Api-Key: ${key}")
  [ -n "$body" ] && args+=(-d "$body")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [dry-run] ${method} ${base}${path}" >&2
    # Masked like the verbose and error paths: a dry run is the thing most likely
    # to be pasted into a chat or an issue, so it must not carry the API keys.
    [ -n "$body" ] && printf '%s\n' "$(mask "$body")" | sed 's/^/              /' >&2
    echo '{}'
    return 0
  fi

  if [ "$VERBOSE" -eq 1 ]; then
    echo "    --> ${method} ${base}${path}" >&2
    [ -n "$body" ] && printf '        body: %s\n' "$(mask "$body")" >&2
  fi

  # Append the status as a trailing line so body and code come back together.
  local raw rc=0 status out
  raw=$(curl "${args[@]}" -w $'\n%{http_code}') || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: ${method} ${base}${path} — curl failed (exit ${rc})" >&2
    return "$rc"
  fi
  status="${raw##*$'\n'}"
  out="${raw%$'\n'*}"

  [ "$VERBOSE" -eq 1 ] && echo "    <-- ${status} ($(printf '%s' "$out" | wc -c | tr -d ' ') bytes)" >&2

  case "$status" in
    2*) printf '%s' "$out"; return 0 ;;
  esac

  # A failing status is the whole point of the exercise — print what the server
  # actually said, not just the number.
  echo "ERROR: ${method} ${base}${path} returned HTTP ${status}" >&2
  [ -n "$body" ] && printf '       sent: %s\n' "$(mask "$body")" >&2
  if [ -n "$out" ]; then
    printf '       said: %s\n' "$(printf '%s' "$out" | head -c 500)" >&2
  else
    printf '       said: <empty body>\n' >&2
  fi
  return 22
}

# mask() and wait_for() — shared with seerr-bootstrap.sh and arr-indexers.sh.
. ./lib/http.sh

if [ "$DRY_RUN" -eq 1 ]; then
  say "DRY RUN — no requests will be sent"
fi

# --- readiness ---------------------------------------------------------------

say "Waiting for the arr services"
[ "$have_sonarr" -eq 1 ]   && wait_for sonarr   "$SONARR_URL"
[ "$have_radarr" -eq 1 ]   && wait_for radarr   "$RADARR_URL"
[ "$have_lidarr" -eq 1 ]   && wait_for lidarr   "$LIDARR_URL"
[ "$have_prowlarr" -eq 1 ] && wait_for prowlarr "$PROWLARR_URL"

# qBittorrent too, and not just for tidiness: POST /downloadclient runs
# Test(definition) whenever the client is enabled, so adding it while qBittorrent
# is still starting fails the test and aborts the run under set -e. It has no
# /ping, and /api/v2/app/version needs a session — but a 401/403 still proves the
# WebUI is answering, which is all this needs to know.
wait_for_qbittorrent() {
  local url="http://127.0.0.1:${QBITTORRENT_PORT}" i status
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would wait for qbittorrent at ${url}"
    return 0
  fi
  for i in $(seq 1 90); do
    status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      "${url}/api/v2/app/version" 2>/dev/null || echo 000)
    case "$status" in
      2*|401|403) info "qbittorrent ready at ${url} (HTTP ${status})"; return 0 ;;
    esac
    if [ "$i" -eq 90 ]; then
      echo "ERROR: qBittorrent did not answer at ${url} after 180s (last: ${status})." >&2
      echo "       Check: docker logs qbittorrent" >&2
      exit 1
    fi
    sleep 2
  done
}
[ "$have_qbt" -eq 1 ] && wait_for_qbittorrent

# A 401 here means the pre-seeded key never reached the app — almost always a
# stale container from before its .env file existed. Worth its own message,
# because every later call would fail the same way with a less obvious cause.
if [ "$DRY_RUN" -eq 0 ]; then
  check_key() {
    # check_key <name> <base-url> <api-key> <api-version> <env-file>
    # Prowlarr and Lidarr are on API v1, Sonarr and Radarr on v3 — the wrong
    # one 404s, which would read as a bad key rather than a bad path.
    local name="$1" base="$2" key="$3" ver="$4" env_file="$5" status
    status=$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "X-Api-Key: ${key}" "${base}/api/${ver}/system/status" 2>/dev/null || echo 000)
    case "$status" in
      2*) return 0 ;;
      401|403)
        echo "ERROR: ${name} rejected the API key from ${env_file} (HTTP ${status})." >&2
        echo "       The key is injected at container start, so a container that" >&2
        echo "       predates the current ${env_file} still has the old one:" >&2
        echo "         docker compose -p nas-${name} --env-file shared.env --env-file ${env_file} -f docker-compose.${name}.yml up -d --force-recreate ${name}" >&2
        exit 1 ;;
      *)
        warn "${name}: unexpected HTTP ${status} from its status endpoint" ;;
    esac
  }
  [ "$have_sonarr" -eq 1 ]   && check_key sonarr   "$SONARR_URL"   "$SONARR_API_KEY"   v3 "$SONARR_ENV_FILE"
  [ "$have_radarr" -eq 1 ]   && check_key radarr   "$RADARR_URL"   "$RADARR_API_KEY"   v3 "$RADARR_ENV_FILE"
  [ "$have_lidarr" -eq 1 ]   && check_key lidarr   "$LIDARR_URL"   "$LIDARR_API_KEY"   v1 "$LIDARR_ENV_FILE"
  [ "$have_prowlarr" -eq 1 ] && check_key prowlarr "$PROWLARR_URL" "$PROWLARR_API_KEY" v1 "$PROWLARR_ENV_FILE"
fi

# --- root folders ------------------------------------------------------------

say "Adding root folders"
add_root_folder() {
  # add_root_folder <name> <base-url> <api-key> <container-path>
  local name="$1" base="$2" key="$3" path="$4" existing
  if [ "$DRY_RUN" -eq 0 ]; then
    existing=$(api "$base" "$key" GET /api/v3/rootfolder | jq -r '.[].path')
    if printf '%s\n' "$existing" | grep -Fxq "$path"; then
      info "${name}: ${path} exists, skipping"
      return 0
    fi
  fi
  # A container path, not a host path. The app rejects one it cannot write to,
  # which is the useful error — it means the bind mount is wrong or read-only.
  api "$base" "$key" POST /api/v3/rootfolder \
    "$(jq -n --arg p "$path" '{path: $p}')" >/dev/null
  info "${name}: ${path} added"
}

[ "$have_sonarr" -eq 1 ] && add_root_folder sonarr "$SONARR_URL" "$SONARR_API_KEY" "$SONARR_ROOT_FOLDER"
[ "$have_radarr" -eq 1 ] && add_root_folder radarr "$RADARR_URL" "$RADARR_API_KEY" "$RADARR_ROOT_FOLDER"

# Lidarr's root folder is not Sonarr/Radarr's: POST /api/v1/rootfolder also
# validates name and defaultQualityProfileId/defaultMetadataProfileId (> 0 and
# existing), so the bare {path} body above would 400. Resolve real ids first —
# same trap class as Prowlarr's placeholder appProfileId.
add_lidarr_root_folder() {
  local path="$1" existing qp mp body
  if [ "$DRY_RUN" -eq 1 ]; then
    qp=1; mp=1
  else
    existing=$(api "$LIDARR_URL" "$LIDARR_API_KEY" GET /api/v1/rootfolder | jq -r '.[].path')
    if printf '%s\n' "$existing" | grep -Fxq "$path"; then
      info "lidarr: ${path} exists, skipping"
      return 0
    fi
    qp=$(api "$LIDARR_URL" "$LIDARR_API_KEY" GET /api/v1/qualityprofile | jq -r '.[0].id // empty')
    mp=$(api "$LIDARR_URL" "$LIDARR_API_KEY" GET /api/v1/metadataprofile | jq -r '.[0].id // empty')
    if [ -z "$qp" ] || [ -z "$mp" ]; then
      echo "ERROR: lidarr has no quality or metadata profile to default the root folder to." >&2
      exit 1
    fi
  fi
  body=$(jq -n --arg p "$path" --argjson qp "$qp" --argjson mp "$mp" \
    '{name: "Music", path: $p,
      defaultQualityProfileId: $qp, defaultMetadataProfileId: $mp,
      defaultMonitorOption: "all", defaultNewItemMonitorOption: "all",
      defaultTags: []}')
  api "$LIDARR_URL" "$LIDARR_API_KEY" POST /api/v1/rootfolder "$body" >/dev/null
  info "lidarr: ${path} added"
}
[ "$have_lidarr" -eq 1 ] && add_lidarr_root_folder "$LIDARR_ROOT_FOLDER"

# --- download client ---------------------------------------------------------

say "Adding the qBittorrent download client"
add_download_client() {
  # add_download_client <name> <base-url> <api-key> <api-version> <category-field> <category>
  local name="$1" base="$2" key="$3" ver="$4" cat_field="$5" cat="$6" current desired body

  # Seeding hand-off: qBittorrent.conf stops (not removes) the torrent at the
  # ratio/time cap, and removeCompletedDownloads=true makes the arr app delete
  # the torrent AND its files once qBittorrent reports it stopped at the cap —
  # the app never removes a torrent that is still seeding, so the limits are
  # honoured. The reverse split (qBittorrent RemoveWithContent) can delete a
  # download before it has been imported. POST and PUT both test the client and
  # reject a qBittorrent still configured to remove-at-limit — that rejection
  # guards this pairing, so no forceSave here.
  if [ "$DRY_RUN" -eq 0 ]; then
    current=$(api "$base" "$key" GET "/api/${ver}/downloadclient" \
      | jq -c '[.[] | select(.name == "qBittorrent")] | first // empty')
    if [ -n "$current" ]; then
      if printf '%s' "$current" | jq -e '.removeCompletedDownloads == true' >/dev/null; then
        info "${name}: qBittorrent exists, skipping"
      else
        # GET-modify-PUT over the whole object, never a partial body.
        desired=$(printf '%s' "$current" | jq '.removeCompletedDownloads = true')
        api "$base" "$key" PUT "/api/${ver}/downloadclient/$(printf '%s' "$current" | jq -r '.id')" \
          "$desired" >/dev/null
        info "${name}: qBittorrent updated (removal after seeding is now ${name}'s job)"
      fi
      return 0
    fi
  fi

  body=$(jq -n \
    --arg host "$QBITTORRENT_HOST" \
    --argjson port "$QBITTORRENT_PORT" \
    --arg user "$ADMIN_USER" \
    --arg pass "$ADMIN_PASSWORD" \
    --arg catfield "$cat_field" \
    --arg cat "$cat" \
    '{
      enable: true,
      protocol: "torrent",
      priority: 1,
      removeCompletedDownloads: true,
      removeFailedDownloads: true,
      name: "qBittorrent",
      implementation: "QBittorrent",
      implementationName: "qBittorrent",
      configContract: "QBittorrentSettings",
      tags: [],
      fields: [
        {name: "host",     value: $host},
        {name: "port",     value: $port},
        {name: "useSsl",   value: false},
        {name: "urlBase",  value: ""},
        {name: "username", value: $user},
        {name: "password", value: $pass},
        {name: $catfield,  value: $cat},
        {name: "initialState",    value: 0},
        {name: "sequentialOrder", value: false},
        {name: "firstAndLast",    value: false},
        {name: "contentLayout",   value: 0}
      ]
    }')

  api "$base" "$key" POST "/api/${ver}/downloadclient" "$body" >/dev/null
  info "${name}: qBittorrent added (category ${cat}; removes torrent+data after the seed cap)"
}

if [ "$have_qbt" -eq 1 ]; then
  [ "$have_sonarr" -eq 1 ] && add_download_client sonarr "$SONARR_URL" "$SONARR_API_KEY" v3 tvCategory    tv-sonarr
  [ "$have_radarr" -eq 1 ] && add_download_client radarr "$RADARR_URL" "$RADARR_API_KEY" v3 movieCategory radarr
  [ "$have_lidarr" -eq 1 ] && add_download_client lidarr "$LIDARR_URL" "$LIDARR_API_KEY" v1 musicCategory lidarr
else
  info "qbittorrent not present — skipping download client wiring"
fi

# --- media management --------------------------------------------------------

say "Checking media management"
set_media_management() {
  # set_media_management <name> <base-url> <api-key> <api-version> <extra-file-extensions>
  # An empty extensions arg leaves the app's own default alone — the subtitle
  # list makes sense for video, not for Lidarr's lyrics/cover-art extras.
  local name="$1" base="$2" key="$3" ver="$4" exts="$5" current desired
  # GET-modify-PUT: this endpoint deserialises over the whole object, so a
  # partial body would reset every field it omits.
  current=$(api "$base" "$key" GET "/api/${ver}/config/mediamanagement")
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] ${name}: would assert hardlinks + import settings"
    return 0
  fi

  # copyUsingHardlinks is asserted rather than assumed. It has no effect in this
  # layout — downloads are on the SSD and the library on the HDD, so an import
  # is always a cross-filesystem copy — but leaving it on costs nothing and
  # keeps the setting correct if the download tree ever moves to /volume1.
  desired=$(printf '%s' "$current" | jq --arg exts "$exts" \
    '.copyUsingHardlinks = true
     | .importExtraFiles = true
     | (if $exts != "" then .extraFileExtensions = $exts else . end)')

  if [ "$(printf '%s' "$current" | jq -cS .)" = "$(printf '%s' "$desired" | jq -cS .)" ]; then
    info "${name}: already correct, skipping"
    return 0
  fi
  api "$base" "$key" PUT "/api/${ver}/config/mediamanagement" "$desired" >/dev/null
  info "${name}: hardlinks asserted, extra-file import on"
}

[ "$have_sonarr" -eq 1 ] && set_media_management sonarr "$SONARR_URL" "$SONARR_API_KEY" v3 "srt,sub,idx,ass"
[ "$have_radarr" -eq 1 ] && set_media_management radarr "$RADARR_URL" "$RADARR_API_KEY" v3 "srt,sub,idx,ass"
[ "$have_lidarr" -eq 1 ] && set_media_management lidarr "$LIDARR_URL" "$LIDARR_API_KEY" v1 ""

# --- prowlarr app sync -------------------------------------------------------

if [ "$have_prowlarr" -eq 1 ]; then
  say "Connecting Prowlarr to the arr apps"
  add_application() {
    # add_application <name> <implementation> <target-internal-url> <target-key> <extra-jq>
    local name="$1" impl="$2" target="$3" target_key="$4" extra="$5" existing body
    if [ "$DRY_RUN" -eq 0 ]; then
      existing=$(api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/applications \
        | jq -r '.[].name')
      if printf '%s\n' "$existing" | grep -Fxq "$name"; then
        info "${name}: exists, skipping"
        return 0
      fi
    fi

    # Two different addresses, easy to swap and confusing when swapped:
    #   prowlarrUrl — where the target app should reach Prowlarr
    #   baseUrl     — where Prowlarr should reach the target app
    # Both are container names, since this traffic stays on nas-net.
    body=$(jq -n \
      --arg name "$name" \
      --arg impl "$impl" \
      --arg contract "${impl}Settings" \
      --arg prowlarr "$PROWLARR_INTERNAL_URL" \
      --arg base "$target" \
      --arg key "$target_key" \
      '{
        name: $name,
        implementation: $impl,
        implementationName: $impl,
        configContract: $contract,
        syncLevel: "fullSync",
        tags: [],
        fields: [
          {name: "prowlarrUrl", value: $prowlarr},
          {name: "baseUrl",     value: $base},
          {name: "apiKey",      value: $key}
        ]
      }')
    [ -n "$extra" ] && body=$(printf '%s' "$body" | jq "$extra")

    api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST /api/v1/applications "$body" >/dev/null
    info "${name}: connected (fullSync)"
  }

  if [ "$have_sonarr" -eq 1 ]; then
    add_application Sonarr Sonarr "$SONARR_INTERNAL_URL" "$SONARR_API_KEY" \
      '.fields += [{name: "syncCategories", value: [5000,5010,5020,5030,5040,5045,5050,5090]},
                   {name: "animeSyncCategories", value: [5070]}]'
  fi
  if [ "$have_radarr" -eq 1 ]; then
    add_application Radarr Radarr "$RADARR_INTERNAL_URL" "$RADARR_API_KEY" \
      '.fields += [{name: "syncCategories", value: [2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]}]'
  fi
  if [ "$have_lidarr" -eq 1 ]; then
    add_application Lidarr Lidarr "$LIDARR_INTERNAL_URL" "$LIDARR_API_KEY" \
      '.fields += [{name: "syncCategories", value: [3000,3010,3030,3040,3050,3060]}]'
  fi
else
  info "prowlarr not present — skipping Prowlarr app sync"
fi

# --- configarr ----------------------------------------------------------------

if [ "$ARR_RUN_CONFIGARR" = "1" ] && [ "$have_sonarr" -eq 1 ] && [ "$have_radarr" -eq 1 ] && [ "$have_configarr" -eq 1 ]; then
  say "Applying TRaSH quality profiles with Configarr"

  # A throwaway container with its own --name, so this never collides with the
  # persistent `configarr` container that nas install creates for the scheduler.
  # Four --env-file flags, no copied keys — reasoning in configarr.env.example.
  configarr_run() {
    # configarr_run <name> [extra docker args...]
    local name="$1"; shift
    docker compose -p nas-configarr --env-file "$SHARED_ENV_FILE" \
      --env-file "$SONARR_ENV_FILE" --env-file "$RADARR_ENV_FILE" \
      --env-file "$CONFIGARR_ENV_FILE" -f docker-compose.configarr.yml \
      run --rm --name "$name" "$@" configarr
  }

  run_configarr() {
    local rc=0

    # A real read-only run: configarr prints the same diff it would apply, which
    # is a far better preflight than echoing the command back.
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] configarr (DRY_RUN=true — reports the diff, changes nothing)"
      configarr_run configarr-dryrun -e DRY_RUN=true 2>&1 | sed 's/^/    /' || true
      return 0
    fi

    # Non-fatal: this clones the TRaSH and Recyclarr template repos from
    # GitHub, and a network hiccup must not fail the whole bring-up. Ofelia
    # retries on its own schedule, so a miss here is temporary rather than a
    # permanent gap.
    #
    # STOP_ON_ERROR + enforced validation (set in the compose file) make a
    # non-zero rc meaningful rather than best-effort.
    configarr_run configarr-sync 2>&1 | sed 's/^/    /' || rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "configarr failed (exit ${rc}) — profiles are unchanged"
      warn "re-run by hand once reachable:"
      warn "  docker compose -p nas-configarr --env-file ${SHARED_ENV_FILE} --env-file ${SONARR_ENV_FILE} --env-file ${RADARR_ENV_FILE} --env-file ${CONFIGARR_ENV_FILE} -f docker-compose.configarr.yml run --rm configarr"
      return 0
    fi
    info "profiles and custom formats applied"
    return 0
  }
  run_configarr
elif [ "$ARR_RUN_CONFIGARR" = "1" ]; then
  warn "skipping configarr sync — sonarr.env/radarr.env/configarr.env not all present yet"
else
  say "Skipping Configarr (ARR_RUN_CONFIGARR=0) — ofelia still syncs on schedule"
fi

# --- summary -----------------------------------------------------------------

say "Done"
[ "$have_sonarr" -eq 1 ]   && info "Sonarr:      ${SONARR_URL}   (root ${SONARR_ROOT_FOLDER})"
[ "$have_radarr" -eq 1 ]   && info "Radarr:      ${RADARR_URL}   (root ${RADARR_ROOT_FOLDER})"
[ "$have_lidarr" -eq 1 ]   && info "Lidarr:      ${LIDARR_URL}   (root ${LIDARR_ROOT_FOLDER})"
[ "$have_prowlarr" -eq 1 ] && info "Prowlarr:    ${PROWLARR_URL}"
cat <<'EOF'

    Next: run ./seerr-bootstrap.sh to configure Seerr (it must run after this
    script, so it can bind to the quality profiles Configarr just created), and
    ./arr-indexers.sh to add the trackers (Byparr proxy + indexers) to Prowlarr.
    Still manual: import the existing library — Sonarr -> Series -> Import,
    Radarr -> Movies -> Import, Lidarr -> Library Import — which reads what is
    already on the HDD.
EOF
