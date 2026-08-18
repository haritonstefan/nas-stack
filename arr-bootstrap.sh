#!/usr/bin/env bash
# Configures a fresh arr stack over the APIs: root folders, the qBittorrent
# download client, media-management settings, Prowlarr's app sync to Sonarr and
# Radarr, the Byparr indexer proxy (with its tag on every indexer), the public
# and private indexers, a one-shot Configarr sync, and Seerr's first-run setup
# (Jellyfin sign-in, library sync, Sonarr/Radarr wiring).
# Idempotent — safe to re-run.
#
# Private indexers are listed in ARR_INDEXERS_PRIVATE, with credentials read
# from ARR_INDEXER_<NAME>_USER / ARR_INDEXER_<NAME>_PASS (<NAME> is the
# definition name uppercased) — see arr.env.example. One missing credential
# skips that indexer with a warning; it never aborts the run.
#
# Run AFTER `docker compose ... up -d`. Unlike Jellyfin's, nothing here is
# one-shot: every step reads the current state first and skips what is already
# configured, so a partial run can simply be repeated.
#
# Every app's API key is pre-seeded via <APP>__AUTH__APIKEY from arr.env, so no
# key is ever read out of a config.xml and there is no ordering dependency
# between the services.
#
#   ./arr-bootstrap.sh
#   ./arr-bootstrap.sh --dry-run
#   ./arr-bootstrap.sh --verbose
#   SONARR_URL=http://apollo.local:8989 ./arr-bootstrap.sh
#
# Requires: curl, jq. Reads arr.env if present (for the API keys), and
# jellyfin.env for Seerr's Jellyfin sign-in (in a subshell — nothing leaks).
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

ENV_FILE="${ENV_FILE:-arr.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # Prefixed with ./ only for a bare filename, so that a relative name is read
  # from here rather than $PATH, without mangling an absolute override.
  # shellcheck disable=SC1090
  case "$ENV_FILE" in
    /*|./*|../*) . "$ENV_FILE" ;;
    *)           . "./$ENV_FILE" ;;
  esac
  set +a
fi

SONARR_URL="${SONARR_URL:-http://127.0.0.1:8989}"
RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
PROWLARR_URL="${PROWLARR_URL:-http://127.0.0.1:9696}"
SEERR_URL="${SEERR_URL:-http://127.0.0.1:5055}"

SONARR_ROOT_FOLDER="${SONARR_ROOT_FOLDER:-/media/series}"
RADARR_ROOT_FOLDER="${RADARR_ROOT_FOLDER:-/media/movies}"

QBITTORRENT_USER="${QBITTORRENT_USER:-admin}"
QBITTORRENT_PORT="${QBITTORRENT_PORT:-8080}"

ARR_INSTALL_INDEXERS="${ARR_INSTALL_INDEXERS:-1}"
ARR_INDEXERS="${ARR_INDEXERS:-1337x,thepiratebay,yts,eztv,limetorrents,torlock,therarbg,knaben,glodls,magnetdl}"
# No default: the credentials are secrets, so the list is opt-in via arr.env.
ARR_INDEXERS_PRIVATE="${ARR_INDEXERS_PRIVATE:-}"
ARR_RUN_CONFIGARR="${ARR_RUN_CONFIGARR:-1}"
ARR_CONFIGURE_SEERR="${ARR_CONFIGURE_SEERR:-1}"
# Jellyfin as Seerr must reach it: the host LAN address, because Jellyfin is
# host-networked and not on nas-net — a container name will not resolve, and
# .local usually does not resolve inside containers either.
SEERR_JELLYFIN_HOST="${SEERR_JELLYFIN_HOST:-192.168.0.231}"
SEERR_JELLYFIN_PORT="${SEERR_JELLYFIN_PORT:-8096}"

# Addresses the containers use for each other over nas-net. Not the *_URL vars
# above, which are how this script (running on the host) reaches them.
SONARR_INTERNAL_URL="http://sonarr:8989"
RADARR_INTERNAL_URL="http://radarr:7878"
PROWLARR_INTERNAL_URL="http://prowlarr:9696"
BYPARR_INTERNAL_URL="http://byparr:8191"
QBITTORRENT_HOST="qbittorrent"

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required." >&2; exit 1; }
done

if [ "$DRY_RUN" -eq 0 ]; then
  for var in SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY QBITTORRENT_PASSWORD; do
    eval "val=\${${var}:-}"
    if [ -z "$val" ]; then
      echo "ERROR: ${var} is not set (put it in ${ENV_FILE}, or run up.sh which" >&2
      echo "       generates it). The stack cannot be configured without it." >&2
      exit 1
    fi
  done
fi
: "${SONARR_API_KEY:=<unset>}"
: "${RADARR_API_KEY:=<unset>}"
: "${PROWLARR_API_KEY:=<unset>}"
: "${QBITTORRENT_PASSWORD:=<unset>}"

say()  { echo "==> $1"; }
info() { echo "    $1"; }
warn() { echo "    WARNING: $1" >&2; }

api() {
  # api <base-url> <api-key> <method> <path> [json-body]
  # Talks to four services, so the target is an argument rather than a global.
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

# Passwords and API keys travel inside `fields` arrays, so masking has to reach
# into them by name rather than looking at top-level keys.
mask() {
  printf '%s' "$1" | jq -c '
    if type == "object" then
      (if has("fields") then
         .fields |= map(if (.name // "" | test("password|apiKey"; "i")) then .value = "***" else . end)
       else . end)
      | (if has("password") then .password = "***" else . end)
    else . end' 2>/dev/null || echo '<unprintable>'
}

if [ "$DRY_RUN" -eq 1 ]; then
  say "DRY RUN — no requests will be sent"
fi

# --- readiness ---------------------------------------------------------------

wait_for() {
  # wait_for <name> <base-url>
  local name="$1" base="$2" i probe
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would wait for ${name} at ${base}"
    return 0
  fi
  for i in $(seq 1 90); do
    # /ping is unauthenticated and only 200s once the app is genuinely serving.
    # A TCP connect is not enough: these apps accept connections well before
    # they finish migrating their database. The JSON shape is checked too, since
    # a reverse proxy or a wrong port can 200 with something else entirely.
    if probe=$(curl -fsS --max-time 5 "${base}/ping" 2>/dev/null) \
       && printf '%s' "$probe" | jq -e '.status == "OK"' >/dev/null 2>&1; then
      info "${name} ready at ${base}"
      return 0
    fi
    if [ "$i" -eq 90 ]; then
      echo "ERROR: ${name} did not answer at ${base}/ping after 180s." >&2
      echo "       Check: docker logs ${name}" >&2
      exit 1
    fi
    sleep 2
  done
}

say "Waiting for the arr services"
wait_for sonarr   "$SONARR_URL"
wait_for radarr   "$RADARR_URL"
wait_for prowlarr "$PROWLARR_URL"

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
wait_for_qbittorrent

# A 401 here means the pre-seeded key never reached the app — almost always a
# stale container from before arr.env existed. Worth its own message, because
# every later call would fail the same way with a less obvious cause.
if [ "$DRY_RUN" -eq 0 ]; then
  check_key() {
    # check_key <name> <base-url> <api-key> <api-version>
    # Prowlarr is on API v1, Sonarr and Radarr on v3 — the wrong one 404s, which
    # would read as a bad key rather than a bad path.
    local name="$1" base="$2" key="$3" ver="$4" status
    status=$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "X-Api-Key: ${key}" "${base}/api/${ver}/system/status" 2>/dev/null || echo 000)
    case "$status" in
      2*) return 0 ;;
      401|403)
        echo "ERROR: ${name} rejected the API key from ${ENV_FILE} (HTTP ${status})." >&2
        echo "       The key is injected at container start, so a container that" >&2
        echo "       predates the current ${ENV_FILE} still has the old one:" >&2
        echo "         docker compose -p nas-arr --env-file ${ENV_FILE} -f docker-compose.arr.yml up -d --force-recreate ${name}" >&2
        exit 1 ;;
      *)
        warn "${name}: unexpected HTTP ${status} from its status endpoint" ;;
    esac
  }
  check_key sonarr   "$SONARR_URL"   "$SONARR_API_KEY"   v3
  check_key radarr   "$RADARR_URL"   "$RADARR_API_KEY"   v3
  check_key prowlarr "$PROWLARR_URL" "$PROWLARR_API_KEY" v1
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

add_root_folder sonarr "$SONARR_URL" "$SONARR_API_KEY" "$SONARR_ROOT_FOLDER"
add_root_folder radarr "$RADARR_URL" "$RADARR_API_KEY" "$RADARR_ROOT_FOLDER"

# --- download client ---------------------------------------------------------

say "Adding the qBittorrent download client"
add_download_client() {
  # add_download_client <name> <base-url> <api-key> <category-field> <category>
  local name="$1" base="$2" key="$3" cat_field="$4" cat="$5" current desired body

  # Seeding hand-off: qBittorrent.conf stops (not removes) the torrent at the
  # ratio/time cap, and removeCompletedDownloads=true makes the arr app delete
  # the torrent AND its files once qBittorrent reports it stopped at the cap —
  # the app never removes a torrent that is still seeding, so the limits are
  # honoured. The reverse split (qBittorrent RemoveWithContent) can delete a
  # download before it has been imported. POST and PUT both test the client and
  # reject a qBittorrent still configured to remove-at-limit — that rejection
  # guards this pairing, so no forceSave here.
  if [ "$DRY_RUN" -eq 0 ]; then
    current=$(api "$base" "$key" GET /api/v3/downloadclient \
      | jq -c '[.[] | select(.name == "qBittorrent")] | first // empty')
    if [ -n "$current" ]; then
      if printf '%s' "$current" | jq -e '.removeCompletedDownloads == true' >/dev/null; then
        info "${name}: qBittorrent exists, skipping"
      else
        # GET-modify-PUT over the whole object, never a partial body.
        desired=$(printf '%s' "$current" | jq '.removeCompletedDownloads = true')
        api "$base" "$key" PUT "/api/v3/downloadclient/$(printf '%s' "$current" | jq -r '.id')" \
          "$desired" >/dev/null
        info "${name}: qBittorrent updated (removal after seeding is now ${name}'s job)"
      fi
      return 0
    fi
  fi

  body=$(jq -n \
    --arg host "$QBITTORRENT_HOST" \
    --argjson port "$QBITTORRENT_PORT" \
    --arg user "$QBITTORRENT_USER" \
    --arg pass "$QBITTORRENT_PASSWORD" \
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

  api "$base" "$key" POST /api/v3/downloadclient "$body" >/dev/null
  info "${name}: qBittorrent added (category ${cat}; removes torrent+data after the seed cap)"
}

add_download_client sonarr "$SONARR_URL" "$SONARR_API_KEY" tvCategory    tv-sonarr
add_download_client radarr "$RADARR_URL" "$RADARR_API_KEY" movieCategory radarr

# --- media management --------------------------------------------------------

say "Checking media management"
set_media_management() {
  # set_media_management <name> <base-url> <api-key>
  local name="$1" base="$2" key="$3" current desired
  # GET-modify-PUT: this endpoint deserialises over the whole object, so a
  # partial body would reset every field it omits.
  current=$(api "$base" "$key" GET /api/v3/config/mediamanagement)
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] ${name}: would assert hardlinks + import settings"
    return 0
  fi

  # copyUsingHardlinks is asserted rather than assumed. It has no effect in this
  # layout — downloads are on the SSD and the library on the HDD, so an import
  # is always a cross-filesystem copy — but leaving it on costs nothing and
  # keeps the setting correct if the download tree ever moves to /volume1.
  desired=$(printf '%s' "$current" | jq \
    '.copyUsingHardlinks = true
     | .importExtraFiles = true
     | .extraFileExtensions = "srt,sub,idx,ass"')

  if [ "$(printf '%s' "$current" | jq -cS .)" = "$(printf '%s' "$desired" | jq -cS .)" ]; then
    info "${name}: already correct, skipping"
    return 0
  fi
  api "$base" "$key" PUT /api/v3/config/mediamanagement "$desired" >/dev/null
  info "${name}: hardlinks asserted, subtitle extras imported"
}

set_media_management sonarr "$SONARR_URL" "$SONARR_API_KEY"
set_media_management radarr "$RADARR_URL" "$RADARR_API_KEY"

# --- prowlarr app sync -------------------------------------------------------

say "Connecting Prowlarr to Sonarr and Radarr"
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

add_application Sonarr Sonarr "$SONARR_INTERNAL_URL" "$SONARR_API_KEY" \
  '.fields += [{name: "syncCategories", value: [5000,5010,5020,5030,5040,5045,5050,5090]},
               {name: "animeSyncCategories", value: [5070]}]'
add_application Radarr Radarr "$RADARR_INTERNAL_URL" "$RADARR_API_KEY" \
  '.fields += [{name: "syncCategories", value: [2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]}]'

# --- byparr indexer proxy ------------------------------------------------------

say "Registering Byparr as Prowlarr's indexer proxy"
# Prowlarr routes a request through the proxy only when it detects a Cloudflare
# challenge AND the indexer shares a tag with the proxy — so tagging every
# indexer costs nothing on unprotected trackers and future-proofs any that add
# Cloudflare later. Byparr is registered under the FlareSolverr implementation:
# it speaks that API. It is GET-only — Prowlarr's request.post degrades to a
# GET — acceptable because the Cloudflare-protected trackers here search via GET.
#
# Non-fatal throughout, like the indexers: a solver that cannot be registered
# must not abort the run before Configarr gets its turn.
BYPARR_TAG_ID=""
setup_byparr_proxy() {
  local tags entry existing indexers id name rc=0

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] ensure tag 'byparr'; GET /api/v1/indexerproxy/schema, then POST the"
    info "[dry-run] FlareSolverr implementation with host ${BYPARR_INTERNAL_URL}; tag every indexer"
    return 0
  fi

  # Tag first: a proxy with no matching tagged indexer is dead weight and a
  # Prowlarr health warning, so without the tag the whole section is skipped.
  tags=$(api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/tag) || {
    warn "could not list Prowlarr's tags — skipping the Byparr proxy"
    return 0
  }
  # Prowlarr lowercases tag labels on create, so match the stored form.
  BYPARR_TAG_ID=$(printf '%s' "$tags" \
    | jq -r 'map(select(.label == "byparr")) | first | .id // empty')
  if [ -n "$BYPARR_TAG_ID" ]; then
    info "tag 'byparr': exists (id ${BYPARR_TAG_ID})"
  else
    BYPARR_TAG_ID=$(api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST /api/v1/tag \
      '{"label":"byparr"}' | jq -r '.id // empty') || BYPARR_TAG_ID=""
    if [ -z "$BYPARR_TAG_ID" ]; then
      warn "could not create the 'byparr' tag — skipping the Byparr proxy"
      return 0
    fi
    info "tag 'byparr': created (id ${BYPARR_TAG_ID})"
  fi

  existing=$(api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexerproxy \
    | jq -r '.[].name // empty') || existing=""
  if printf '%s\n' "$existing" | grep -Fxq "Byparr"; then
    info "proxy: exists, skipping"
  else
    # GET-schema-modify-POST, the same mandatory pattern as the indexers: the
    # resource mapper rejects hand-written bodies.
    entry=$(api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexerproxy/schema \
      | jq -c 'map(select(.implementation == "FlareSolverr")) | first // empty') || entry=""
    if [ -z "$entry" ]; then
      warn "no FlareSolverr implementation in the indexerproxy schema — skipping the proxy"
    else
      entry=$(printf '%s' "$entry" \
        | jq -c --arg host "$BYPARR_INTERNAL_URL" --argjson tag "$BYPARR_TAG_ID" '
            .name = "Byparr" | .tags = [$tag]
            | .fields |= map(if .name == "host" then .value = $host else . end)')
      # No forceSave on the first try: the create-path test is the only automatic
      # reachability check the proxy gets. Only when it fails (byparr still
      # starting, most likely) is it saved untested, retestable from the UI.
      rc=0
      api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST /api/v1/indexerproxy \
        "$entry" >/dev/null || rc=$?
      if [ "$rc" -ne 0 ]; then
        warn "proxy connection test failed (details above) — saving untested"
        rc=0
        api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST '/api/v1/indexerproxy?forceSave=true' \
          "$entry" >/dev/null || rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        info "proxy: registered (host ${BYPARR_INTERNAL_URL}, tag 'byparr')"
      else
        warn "proxy could not be registered (exit ${rc})"
      fi
    fi
  fi

  # Retro-tag indexers from earlier runs (or added by hand), which predate the
  # tag. New ones are born tagged in add_one below. GET-modify-PUT over the
  # whole object — never a partial body — and forceSave because a tracker being
  # down right now is not a reason to leave it untagged.
  indexers=$(api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexer) || {
    warn "could not list indexers to retro-tag — new ones are still tagged on create"
    return 0
  }
  printf '%s' "$indexers" \
    | jq -c --argjson tag "$BYPARR_TAG_ID" '.[] | select((.tags // []) | index($tag) | not)' \
    | while read -r entry; do
        id=$(printf '%s' "$entry" | jq -r '.id')
        name=$(printf '%s' "$entry" | jq -r '.name')
        entry=$(printf '%s' "$entry" | jq -c --argjson tag "$BYPARR_TAG_ID" '.tags += [$tag]')
        rc=0
        api "$PROWLARR_URL" "$PROWLARR_API_KEY" PUT "/api/v1/indexer/${id}?forceSave=true" \
          "$entry" >/dev/null || rc=$?
        if [ "$rc" -eq 0 ]; then
          info "${name}: tagged 'byparr'"
        else
          warn "${name}: could not be tagged (exit ${rc})"
        fi
      done
  return 0
}
setup_byparr_proxy

# --- indexers ----------------------------------------------------------------

if [ "$ARR_INSTALL_INDEXERS" = "1" ]; then
  say "Adding indexers to Prowlarr"
  # Every call below is non-fatal on purpose: `api` returns 22 under `set -e`,
  # and a tracker that is merely down or renamed must not abort the run before
  # Configarr gets its turn. Each step captures its own rc and warns instead.
  add_indexers() {
    local schema existing def key user pass

    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] GET /api/v1/indexer/schema, then POST each of: ${ARR_INDEXERS}"
      [ -n "$ARR_INDEXERS_PRIVATE" ] && info "[dry-run] plus, with credentials: ${ARR_INDEXERS_PRIVATE}"
      return 0
    fi

    # GET-schema-modify-POST is mandatory here, not stylistic. Prowlarr's
    # IndexerResource.ToModel() looks every non-standard field up in the cached
    # Cardigann definition and throws ArgumentOutOfRangeException on anything it
    # does not recognise, so a hand-written body is rejected outright.
    schema=$(api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexer/schema) || {
      warn "could not fetch the indexer schema — skipping indexers"
      return 0
    }
    existing=$(api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexer \
      | jq -r '.[].definitionName // empty') || existing=""

    # add_one <definitionName> [<username> <password>]
    add_one() {
      local def="$1" user="${2:-}" pass="${3:-}" entry rc=0

      if printf '%s\n' "$existing" | grep -Fxq "$def"; then
        info "${def}: exists, skipping"
        return 0
      fi

      entry=$(printf '%s' "$schema" \
        | jq -c --arg d "$def" 'map(select(.definitionName == $d)) | first // empty')
      if [ -z "$entry" ]; then
        warn "${def}: not in Prowlarr's bundled definitions — skipping"
        return 0
      fi

      # Born tagged for the Byparr proxy (see setup_byparr_proxy above). Empty
      # when the proxy section was skipped, in which case the tag is left alone.
      if [ -n "$BYPARR_TAG_ID" ]; then
        entry=$(printf '%s' "$entry" | jq -c --argjson tag "$BYPARR_TAG_ID" '.tags = [$tag]')
      fi

      if [ -n "$user" ]; then
        # A definition that authenticates some other way (cookie, passkey, 2FA)
        # has no username/password fields; injecting into it would drop the
        # credentials silently and save a dead indexer that looks configured.
        if ! printf '%s' "$entry" | jq -e \
            '[.fields[].name] | (index("username") != null and index("password") != null)' >/dev/null; then
          warn "${def}: definition has no username/password fields — skipping."
          warn "${def}: its fields are: $(printf '%s' "$entry" | jq -r '[.fields[].name] | join(", ")')"
          return 0
        fi
        # Priority 10 vs the public 25: on otherwise-equal releases the apps
        # break the tie toward the private copy.
        entry=$(printf '%s' "$entry" | jq -c --arg u "$user" --arg p "$pass" '
          .enable = true | .priority = 10
          | .fields |= map(if   .name == "username" then .value = $u
                           elif .name == "password" then .value = $p
                           else . end)')

        # No forceSave on the first try: the create-path test is the only
        # automatic check these credentials will ever get. Only when it fails
        # (site down, captcha, wrong password — the error above says which) is
        # the indexer saved untested, so it can be retested from the UI.
        rc=0
        api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST /api/v1/indexer \
          "$entry" >/dev/null || rc=$?
        if [ "$rc" -eq 0 ]; then
          info "${def}: added (credentials verified)"
          return 0
        fi
        warn "${def}: connection test failed (details above) — saving untested"
      else
        entry=$(printf '%s' "$entry" | jq -c '.enable = true | .priority = 25')
      fi

      # forceSave: CreateProvider tests the indexer before saving and aborts on
      # failure. A public tracker being unreachable right now is not a reason to
      # leave it unconfigured — it can be tested from the UI later.
      rc=0
      api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST '/api/v1/indexer?forceSave=true' \
        "$entry" >/dev/null || rc=$?
      if [ "$rc" -ne 0 ]; then
        warn "${def}: could not be added (exit ${rc})"
        return 0
      fi
      info "${def}: added"
      return 0
    }

    # %s\n, not %s: read consumes up to a newline and fails on EOF, so without a
    # trailing one the last indexer in the list is assigned but never processed.
    printf '%s\n' "$ARR_INDEXERS" | tr ',' '\n' | while read -r def; do
      def="$(printf '%s' "$def" | tr -d '[:space:]')"
      [ -z "$def" ] && continue
      add_one "$def"
    done

    printf '%s\n' "$ARR_INDEXERS_PRIVATE" | tr ',' '\n' | while read -r def; do
      def="$(printf '%s' "$def" | tr -d '[:space:]')"
      [ -z "$def" ] && continue
      # kinozal -> ARR_INDEXER_KINOZAL_USER / _PASS. tr -c leaves only A-Z0-9,
      # so the eval'd name cannot carry anything but a variable name.
      key=$(printf '%s' "$def" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')
      user=$(eval "printf '%s' \"\${ARR_INDEXER_${key}_USER:-}\"")
      pass=$(eval "printf '%s' \"\${ARR_INDEXER_${key}_PASS:-}\"")
      if [ -z "$user" ] || [ -z "$pass" ]; then
        warn "${def}: ARR_INDEXER_${key}_USER/_PASS not set in ${ENV_FILE} — skipping"
        continue
      fi
      add_one "$def" "$user" "$pass"
    done
    return 0
  }
  add_indexers
else
  say "Skipping indexers (ARR_INSTALL_INDEXERS=0)"
fi

# --- configarr ----------------------------------------------------------------

if [ "$ARR_RUN_CONFIGARR" = "1" ]; then
  say "Applying TRaSH quality profiles with Configarr"

  # No config is generated or rewritten here: configarr-config/config.yml is
  # installed by up.sh and reads the API keys straight from the environment via
  # !env, so there are no placeholder credentials to patch.
  #
  # A throwaway container with its own --name, so this never collides with the
  # persistent `configarr` container that up.sh creates for the scheduler.
  configarr_run() {
    # configarr_run <name> [extra docker args...]
    local name="$1"; shift
    docker compose -p nas-arr --env-file "$ENV_FILE" -f docker-compose.arr.yml \
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

    # Non-fatal for the same reason as the indexers: this clones the TRaSH and
    # Recyclarr template repos from GitHub, and a network hiccup must not fail
    # the whole bring-up. Ofelia retries on its own schedule, so a miss here is
    # temporary rather than a permanent gap.
    #
    # The container sets STOP_ON_ERROR and CONFIGARR_ENFORCE_CONFIG_VALIDATION,
    # because configarr otherwise exits 0 even when an instance fails — so a
    # non-zero rc here is meaningful rather than best-effort.
    configarr_run configarr-sync 2>&1 | sed 's/^/    /' || rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "configarr failed (exit ${rc}) — profiles are unchanged"
      warn "re-run by hand once reachable:"
      warn "  docker compose -p nas-arr --env-file ${ENV_FILE} -f docker-compose.arr.yml run --rm configarr"
      return 0
    fi
    info "profiles and custom formats applied"
    return 0
  }
  run_configarr
else
  say "Skipping Configarr (ARR_RUN_CONFIGARR=0) — ofelia still syncs on schedule"
fi

# --- seerr ---------------------------------------------------------------------

# Deliberately after configarr: the Sonarr/Radarr wiring below picks the TRaSH
# quality profiles configarr creates; run first it would bind requests to a
# stock profile. Non-fatal throughout, like the indexers — a dead or not-yet-
# built Jellyfin must not abort the arr bring-up. Nothing here is one-shot:
# setup stays re-runnable until POST /settings/initialize, which is therefore
# the last call, made only once everything before it succeeded.
if [ "$ARR_CONFIGURE_SEERR" = "1" ]; then
  say "Configuring Seerr"

  configure_seerr() {
    local i probe initialized

    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] would wait for seerr at ${SEERR_URL}"
      info "[dry-run] POST /api/v1/auth/jellyfin — Jellyfin at ${SEERR_JELLYFIN_HOST}:${SEERR_JELLYFIN_PORT}, creds from jellyfin.env"
      info "[dry-run] enable Movies/Series libraries; POST /api/v1/settings/{sonarr,radarr}; POST /api/v1/settings/initialize"
      return 0
    fi

    if [ -z "${SEERR_API_KEY:-}" ]; then
      warn "SEERR_API_KEY is unset in ${ENV_FILE} — run up.sh to generate it; skipping Seerr"
      return 0
    fi

    # No /ping here; /api/v1/status is Seerr's unauthenticated equivalent, and
    # the JSON shape is checked for the same reason wait_for checks it.
    for i in $(seq 1 90); do
      if probe=$(curl -fsS --max-time 5 "${SEERR_URL}/api/v1/status" 2>/dev/null) \
         && printf '%s' "$probe" | jq -e '.version' >/dev/null 2>&1; then
        info "seerr ready at ${SEERR_URL}"
        break
      fi
      if [ "$i" -eq 90 ]; then
        warn "seerr did not answer at ${SEERR_URL}/api/v1/status after 180s — skipping"
        warn "check: docker logs seerr — then re-run ./arr-bootstrap.sh"
        return 0
      fi
      sleep 2
    done

    initialized=$(curl -sS --max-time 5 "${SEERR_URL}/api/v1/settings/public" 2>/dev/null \
      | jq -r '.initialized' 2>/dev/null) || initialized=""

    if [ "$initialized" != "true" ]; then
      # The Jellyfin admin credentials live in jellyfin.env — another tier's
      # env file. Extracted in subshells so nothing else in that file can
      # shadow this shell's variables (the shared-name rule in arr.env.example).
      local jf_user="" jf_pass=""
      if [ -f jellyfin.env ]; then
        jf_user=$( ( set +u; . ./jellyfin.env >/dev/null 2>&1; printf '%s' "${JELLYFIN_ADMIN_USER:-}" ) ) || jf_user=""
        jf_pass=$( ( set +u; . ./jellyfin.env >/dev/null 2>&1; printf '%s' "${JELLYFIN_ADMIN_PASSWORD:-}" ) ) || jf_pass=""
      fi
      if [ -z "$jf_user" ] || [ -z "$jf_pass" ]; then
        warn "jellyfin.env is missing or has no admin credentials — skipping Seerr setup"
        warn "re-run ./arr-bootstrap.sh once the jellyfin tier is up"
        return 0
      fi

      # Probed from the host, which proves Jellyfin answers at the address Seerr
      # will store; Seerr re-checks it from inside nas-net during sign-in.
      if ! curl -fsS --max-time 5 "http://${SEERR_JELLYFIN_HOST}:${SEERR_JELLYFIN_PORT}/System/Info/Public" >/dev/null 2>&1; then
        warn "Jellyfin not answering at ${SEERR_JELLYFIN_HOST}:${SEERR_JELLYFIN_PORT} — skipping Seerr setup"
        return 0
      fi

      # First-ever call creates Seerr's admin (user 1) from this account and
      # stores the media-server settings; on later runs it is a plain sign-in.
      # The account must be a Jellyfin administrator — a plain user gets 403.
      # serverType 2 = MediaServerType.JELLYFIN (numeric enum, see the spec).
      # Deliberately not api(): this route takes no X-Api-Key — before the
      # first user exists there is nobody for the key to authenticate as.
      local body raw rc status out
      body=$(jq -n --arg u "$jf_user" --arg p "$jf_pass" \
               --arg h "$SEERR_JELLYFIN_HOST" --argjson port "$SEERR_JELLYFIN_PORT" \
               '{username: $u, password: $p, hostname: $h, port: $port,
                 useSsl: false, serverType: 2}') \
        || { warn "could not build the sign-in body — skipping Seerr setup"; return 0; }
      if [ "$VERBOSE" -eq 1 ]; then
        echo "    --> POST ${SEERR_URL}/api/v1/auth/jellyfin" >&2
        printf '        body: %s\n' "$(mask "$body")" >&2
      fi
      rc=0
      raw=$(curl -sS -X POST "${SEERR_URL}/api/v1/auth/jellyfin" \
              -H 'Content-Type: application/json' -d "$body" -w $'\n%{http_code}') || rc=$?
      if [ "$rc" -ne 0 ]; then
        warn "POST /api/v1/auth/jellyfin — curl failed (exit ${rc}); skipping Seerr setup"
        return 0
      fi
      status="${raw##*$'\n'}"
      out="${raw%$'\n'*}"
      case "$status" in
        2*) info "signed in to Seerr as ${jf_user}" ;;
        403)
          warn "Seerr sign-in refused (403): '${jf_user}' is not a Jellyfin administrator"
          warn "said: $(printf '%s' "$out" | head -c 300)"
          return 0 ;;
        *)
          warn "Seerr sign-in failed (HTTP ${status}) — skipping Seerr setup"
          warn "said: $(printf '%s' "$out" | head -c 300)"
          return 0 ;;
      esac

      # sync pulls the library list from Jellyfin; enable REPLACES the enabled
      # set (anything not passed is disabled), which is why this only runs
      # before initialize, where the state is known to be fresh.
      local libs ids
      libs=$(api "$SEERR_URL" "$SEERR_API_KEY" GET '/api/v1/settings/jellyfin/library?sync=true') \
        || { warn "library sync failed — finish Seerr setup in its UI"; return 0; }
      ids=$(printf '%s' "$libs" | jq -r \
        '[.[] | select(.name == "Movies" or .name == "Series") | .id] | join(",")')
      if [ -z "$ids" ]; then
        ids=$(printf '%s' "$libs" | jq -r '[.[].id] | join(",")')
        [ -n "$ids" ] && warn "no libraries named Movies/Series — enabling all of them instead"
      fi
      if [ -z "$ids" ]; then
        warn "Jellyfin reported no libraries — run jellyfin-bootstrap.sh first, then re-run this"
        return 0
      fi
      api "$SEERR_URL" "$SEERR_API_KEY" GET "/api/v1/settings/jellyfin/library?enable=${ids}" >/dev/null \
        || { warn "library enable failed — finish Seerr setup in its UI"; return 0; }
      info "libraries enabled"
    fi

    # Idempotent by name, GET-list-then-skip — the same shape as Prowlarr's
    # add_application. Hostnames are container names: this traffic stays on
    # nas-net (matches SONARR_INTERNAL_URL / RADARR_INTERNAL_URL above).
    add_seerr_app() {
      # add_seerr_app <Name> <path> <host> <port> <api-key> <root> <preferred-profile> <extra-jq>
      local name="$1" path="$2" host="$3" port="$4" app_key="$5" root="$6" preferred="$7" extra="$8"
      local existing test_out profile_id profile_name body

      existing=$(api "$SEERR_URL" "$SEERR_API_KEY" GET "/api/v1/settings/${path}" | jq -r '.[].name') \
        || { warn "${name}: could not list existing instances — skipping"; return 0; }
      if printf '%s\n' "$existing" | grep -Fxq "$name"; then
        info "${name}: exists, skipping"
        return 0
      fi

      # Seerr's own connection test doubles as profile discovery.
      body=$(jq -n --arg h "$host" --argjson p "$port" --arg k "$app_key" \
               '{hostname: $h, port: $p, apiKey: $k, useSsl: false, baseUrl: ""}')
      test_out=$(api "$SEERR_URL" "$SEERR_API_KEY" POST "/api/v1/settings/${path}/test" "$body") \
        || { warn "${name}: connection test failed — add it in the Seerr UI"; return 0; }

      # Prefer the TRaSH profile configarr installs; fall back to the first.
      profile_id=$(printf '%s' "$test_out" | jq -r --arg n "$preferred" \
        '(.profiles[] | select(.name == $n) | .id) // .profiles[0].id // empty')
      profile_name=$(printf '%s' "$test_out" | jq -r --arg n "$preferred" \
        '(.profiles[] | select(.name == $n) | .name) // .profiles[0].name // empty')
      if [ -z "$profile_id" ]; then
        warn "${name}: no quality profiles returned — skipping"
        return 0
      fi
      [ "$profile_name" != "$preferred" ] \
        && warn "${name}: profile '${preferred}' not found (configarr not synced yet?) — using '${profile_name}'"

      body=$(jq -n --arg name "$name" --arg h "$host" --argjson p "$port" \
               --arg k "$app_key" --argjson pid "$profile_id" --arg pname "$profile_name" \
               --arg dir "$root" \
               '{name: $name, hostname: $h, port: $p, apiKey: $k, useSsl: false,
                 baseUrl: "", activeProfileId: $pid, activeProfileName: $pname,
                 activeDirectory: $dir, is4k: false, isDefault: true,
                 syncEnabled: true, preventSearch: false}')
      [ -n "$extra" ] && body=$(printf '%s' "$body" | jq "$extra")
      api "$SEERR_URL" "$SEERR_API_KEY" POST "/api/v1/settings/${path}" "$body" >/dev/null \
        || { warn "${name}: create failed — add it in the Seerr UI"; return 0; }
      info "${name}: wired (profile '${profile_name}', root ${root})"
    }

    # The extra-jq carries each schema's own required field: enableSeasonFolders
    # is required by SonarrSettings, minimumAvailability by RadarrSettings.
    add_seerr_app Sonarr sonarr sonarr 8989 "$SONARR_API_KEY" "$SONARR_ROOT_FOLDER" \
      "WEB-1080p" '.enableSeasonFolders = true'
    add_seerr_app Radarr radarr radarr 7878 "$RADARR_API_KEY" "$RADARR_ROOT_FOLDER" \
      "HD Bluray + WEB" '.minimumAvailability = "released"'

    if [ "$initialized" != "true" ]; then
      if api "$SEERR_URL" "$SEERR_API_KEY" POST /api/v1/settings/initialize >/dev/null; then
        info "Seerr initialized — sign in with the Jellyfin account"
      else
        warn "initialize failed — setup stays re-runnable; finish in the Seerr UI"
      fi
    else
      info "already initialized"
    fi
    return 0
  }
  configure_seerr
else
  say "Skipping Seerr (ARR_CONFIGURE_SEERR=0)"
fi

# --- summary -----------------------------------------------------------------

say "Done"
info "Sonarr:      ${SONARR_URL}   (root ${SONARR_ROOT_FOLDER})"
info "Radarr:      ${RADARR_URL}   (root ${RADARR_ROOT_FOLDER})"
info "Prowlarr:    ${PROWLARR_URL}"
info "Seerr:       ${SEERR_URL}"
cat <<'EOF'

    Still manual: any private indexer not covered by ARR_INDEXERS_PRIVATE
    (cookie/captcha/2FA logins cannot be scripted), and import the existing
    library — Sonarr -> Series -> Import, Radarr -> Movies -> Import — which
    reads what is already on the HDD.
EOF
