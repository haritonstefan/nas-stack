#!/usr/bin/env bash
# Configures a fresh arr stack over the APIs: root folders, the qBittorrent
# download client, media-management settings, Prowlarr's app sync to Sonarr and
# Radarr, and a one-shot Configarr sync.
# Idempotent — safe to re-run.
#
# The trackers — the Byparr indexer proxy and the public/private indexers —
# live in ./arr-indexers.sh, run separately after up.sh.
#
# Seerr's first-run setup lives in ./seerr-bootstrap.sh, which must run AFTER
# this script: it binds requests to the quality profiles Configarr creates here.
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
# Requires: curl, jq. Reads arr.env if present (for the API keys).
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

SONARR_ROOT_FOLDER="${SONARR_ROOT_FOLDER:-/media/series}"
RADARR_ROOT_FOLDER="${RADARR_ROOT_FOLDER:-/media/movies}"

QBITTORRENT_USER="${QBITTORRENT_USER:-admin}"
QBITTORRENT_PORT="${QBITTORRENT_PORT:-8080}"

ARR_RUN_CONFIGARR="${ARR_RUN_CONFIGARR:-1}"

# Addresses the containers use for each other over nas-net. Not the *_URL vars
# above, which are how this script (running on the host) reaches them.
SONARR_INTERNAL_URL="http://sonarr:8989"
RADARR_INTERNAL_URL="http://radarr:7878"
PROWLARR_INTERNAL_URL="http://prowlarr:9696"
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

    # Non-fatal: this clones the TRaSH and Recyclarr template repos from
    # GitHub, and a network hiccup must not fail the whole bring-up. Ofelia
    # retries on its own schedule, so a miss here is temporary rather than a
    # permanent gap.
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

# --- summary -----------------------------------------------------------------

say "Done"
info "Sonarr:      ${SONARR_URL}   (root ${SONARR_ROOT_FOLDER})"
info "Radarr:      ${RADARR_URL}   (root ${RADARR_ROOT_FOLDER})"
info "Prowlarr:    ${PROWLARR_URL}"
cat <<'EOF'

    Next: run ./seerr-bootstrap.sh to configure Seerr (it must run after this
    script, so it can bind to the quality profiles Configarr just created), and
    ./arr-indexers.sh to add the trackers (Byparr proxy + indexers) to Prowlarr.
    Still manual: import the existing library — Sonarr -> Series -> Import,
    Radarr -> Movies -> Import — which reads what is already on the HDD.
EOF
