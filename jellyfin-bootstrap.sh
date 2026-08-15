#!/usr/bin/env bash
# Configures a fresh Jellyfin instance over the API: server name, admin user,
# libraries, Intel QSV hardware transcoding, and the /jellyfin base URL.
# Idempotent — safe to re-run.
#
# Run AFTER `docker compose ... up -d` on a fresh (never-configured) Jellyfin.
# The /Startup/* endpoints are only reachable while the wizard is incomplete,
# so this must run before anyone finishes the wizard in a browser.
#
#   ./jellyfin-bootstrap.sh
#   ./jellyfin-bootstrap.sh --dry-run
#   JELLYFIN_URL=http://apollo.local:8096 ./jellyfin-bootstrap.sh
#
# BaseUrl is applied LAST, deliberately: once it takes effect the API moves to
# ${JELLYFIN_URL}${JELLYFIN_BASE_URL}, so every call before it targets the bare
# root and no call may follow it. A container restart activates it.
#
# Requires: curl, jq. Reads jellyfin.env if present (for JELLYFIN_ADMIN_*).

set -euo pipefail

DRY_RUN=0
VERBOSE=0
SCAN_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    -v|--verbose)   VERBOSE=1 ;;
    # Authenticate and trigger a library scan, nothing else. Used by up.sh
    # after the post-BaseUrl restart, when the API has moved under the prefix.
    --scan-only)    SCAN_ONLY=1 ;;
    *) echo "Unknown argument: ${arg}" >&2
       echo "Usage: ./jellyfin-bootstrap.sh [--dry-run] [--verbose] [--scan-only]" >&2
       exit 1 ;;
  esac
done

ENV_FILE="${ENV_FILE:-jellyfin.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "./$ENV_FILE"
  set +a
fi

JELLYFIN_URL="${JELLYFIN_URL:-http://apollo.local:8096}"
JELLYFIN_SERVER_NAME="${JELLYFIN_SERVER_NAME:-Apollo}"
JELLYFIN_ADMIN_USER="${JELLYFIN_ADMIN_USER:-admin}"
JELLYFIN_BASE_URL="${JELLYFIN_BASE_URL:-/jellyfin}"
JELLYFIN_METADATA_LANGUAGE="${JELLYFIN_METADATA_LANGUAGE:-en}"
# Region for metadata providers: picks release dates and certification scheme
# (US -> PG-13/R). Not a content filter — providers fall back to other regions
# when a title has no data for this one. Overridable per-library in the UI.
JELLYFIN_METADATA_COUNTRY="${JELLYFIN_METADATA_COUNTRY:-US}"
JELLYFIN_UI_CULTURE="${JELLYFIN_UI_CULTURE:-en-US}"

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required." >&2; exit 1; }
done

if [ "$DRY_RUN" -eq 0 ] && [ -z "${JELLYFIN_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: JELLYFIN_ADMIN_PASSWORD is not set (put it in $ENV_FILE)." >&2
  exit 1
fi
: "${JELLYFIN_ADMIN_PASSWORD:=<unset>}"

TOKEN=""

urlencode() { printf '%s' "$1" | jq -sRr @uri; }

api() {
  # api <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  # No -f: it discards the response body on HTTP errors, which is exactly where
  # Jellyfin explains itself. Status is captured separately instead.
  local -a args=(-sS -X "$method" "${JELLYFIN_URL}${path}" -H 'Content-Type: application/json')

  # Jellyfin wants the token inside the MediaBrowser authorization scheme.
  local auth='MediaBrowser Client="nas-stack", Device="bootstrap", DeviceId="nas-stack-bootstrap", Version="1.0.0"'
  [ -n "$TOKEN" ] && auth="${auth}, Token=\"${TOKEN}\""
  args+=(-H "Authorization: ${auth}")
  [ -n "$body" ] && args+=(-d "$body")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [dry-run] ${method} ${path}" >&2
    [ -n "$body" ] && printf '%s\n' "$body" | jq -c . | sed 's/^/              /' >&2
    echo '{}'
    return 0
  fi

  if [ "$VERBOSE" -eq 1 ]; then
    echo "    --> ${method} ${JELLYFIN_URL}${path}" >&2
    [ -n "$body" ] && printf '        body: %s\n' \
      "$(printf '%s' "$body" | jq -c '(.Password? // empty) |= "***"' 2>/dev/null || echo '<unprintable>')" >&2
  fi

  # Append the status as a trailing line so body and code come back together.
  local raw rc=0 status out
  raw=$(curl "${args[@]}" -w $'\n%{http_code}') || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: ${method} ${JELLYFIN_URL}${path} — curl failed (exit ${rc})" >&2
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
  echo "ERROR: ${method} ${JELLYFIN_URL}${path} returned HTTP ${status}" >&2
  if [ -n "$body" ]; then
    printf '       sent: %s\n' \
      "$(printf '%s' "$body" | jq -c '(.Password? // empty) |= "***"' 2>/dev/null || printf '%s' "$body")" >&2
  fi
  if [ -n "$out" ]; then
    printf '       said: %s\n' "$(printf '%s' "$out" | head -c 500)" >&2
  else
    printf '       said: <empty body>\n' >&2
  fi
  return 22
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> DRY RUN — no requests will be sent"
fi

echo "==> Waiting for Jellyfin at ${JELLYFIN_URL}"
if [ "$DRY_RUN" -eq 0 ]; then
  # An instance that already has BaseUrl set serves its whole API under that
  # prefix, so probe both roots and adopt whichever actually answers. Without
  # this, a re-run against a configured server 503s on the first wizard call.
  BASE_STRIPPED="${JELLYFIN_URL%/}"
  BASE_STRIPPED="${BASE_STRIPPED%"${JELLYFIN_BASE_URL}"}"
  PROBE_INFO=""
  for i in $(seq 1 90); do
    for candidate in "$BASE_STRIPPED" "${BASE_STRIPPED}${JELLYFIN_BASE_URL}"; do
      # /System/Info/Public is unauthenticated and only 200s once the server is
      # genuinely serving requests — a plain TCP connect is not enough, since
      # Jellyfin accepts connections well before it finishes starting.
      if PROBE_INFO=$(curl -fsS --max-time 5 "${candidate}/System/Info/Public" 2>/dev/null) \
         && printf '%s' "$PROBE_INFO" | jq -e '.Version' >/dev/null 2>&1; then
        JELLYFIN_URL="$candidate"
        break 2
      fi
    done
    if [ "$i" -eq 90 ]; then
      echo "ERROR: Jellyfin did not answer at ${BASE_STRIPPED} or" >&2
      echo "       ${BASE_STRIPPED}${JELLYFIN_BASE_URL} after 180s." >&2
      echo "       Check: docker logs jellyfin" >&2
      exit 1
    fi
    sleep 2
  done
  info_line=$(printf '%s' "$PROBE_INFO" | jq -r '"\(.ServerName // "?") \(.Version // "?")"')
  echo "    reachable at ${JELLYFIN_URL} (${info_line})"
  WIZARD_DONE=$(printf '%s' "$PROBE_INFO" | jq -r '.StartupWizardCompleted // false')
  # StartupWizardCompleted gates the whole /Startup/* surface: once true, those
  # routes stop being mapped and return 404 rather than 403.
  [ "$VERBOSE" -eq 1 ] && printf '    StartupWizardCompleted=%s\n%s\n' "$WIZARD_DONE" \
    "$(printf '%s' "$PROBE_INFO" | jq -c . | sed 's/^/    /')" >&2
else
  WIZARD_DONE=false
fi

# Only meaningful when we actually probed — in a dry run WIZARD_DONE is a
# placeholder, not an observation.
if [ "$SCAN_ONLY" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && [ "$WIZARD_DONE" = "false" ]; then
  echo "ERROR: --scan-only needs a configured server, but the startup wizard is" >&2
  echo "       still open. Run the full bootstrap first." >&2
  exit 1
fi

if [ "$SCAN_ONLY" -eq 0 ] && [ "$WIZARD_DONE" = "false" ]; then
  echo "==> Running startup wizard"

  api POST /Startup/Configuration "$(jq -n \
    --arg name "$JELLYFIN_SERVER_NAME" \
    --arg culture "$JELLYFIN_UI_CULTURE" \
    --arg lang "$JELLYFIN_METADATA_LANGUAGE" \
    --arg country "$JELLYFIN_METADATA_COUNTRY" \
    '{ServerName: $name, UICulture: $culture,
      PreferredMetadataLanguage: $lang, MetadataCountryCode: $country}')" >/dev/null
  echo "    server name: ${JELLYFIN_SERVER_NAME}"

  # REQUIRED before the POST below, not just a read: GetFirstUser() calls
  # _userManager.InitializeAsync(), which lazily creates the default user.
  # UpdateStartupUser() only *updates* an existing one — it returns 404 outright
  # if GetFirstUser() comes back null. On a fresh config nothing else creates
  # that user, so skipping this GET makes the next call fail on a clean install
  # while working on any server where the wizard UI was ever opened.
  api GET /Startup/User >/dev/null

  # Renames the now-initialized first user and sets its password.
  api POST /Startup/User "$(jq -n \
    --arg name "$JELLYFIN_ADMIN_USER" \
    --arg pass "$JELLYFIN_ADMIN_PASSWORD" \
    '{Name: $name, Password: $pass}')" >/dev/null
  echo "    admin user: ${JELLYFIN_ADMIN_USER}"

  # LAN-only server; no UPnP port mapping.
  api POST /Startup/RemoteAccess \
    '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null

  api POST /Startup/Complete >/dev/null
  echo "    wizard completed"
else
  echo "==> Wizard already completed, skipping"
fi

# Everything above ran unauthenticated: /Startup/* is gated by the
# FirstTimeSetupOrElevated policy, whose first branch succeeds outright while
# IsStartupWizardCompleted is false — no user, no token required. POST
# /Startup/Complete closes that window, so from here on a real token is needed.
echo "==> Authenticating as ${JELLYFIN_ADMIN_USER}"
if [ "$DRY_RUN" -eq 0 ]; then
  # Not `api`: a 401 here is an expected outcome to diagnose, not a hard abort.
  AUTH_JSON=$(curl -sS -X POST "${JELLYFIN_URL}/Users/AuthenticateByName" \
    -H 'Content-Type: application/json' \
    -H 'Authorization: MediaBrowser Client="nas-stack", Device="bootstrap", DeviceId="nas-stack-bootstrap", Version="1.0.0"' \
    -d "$(jq -n --arg u "$JELLYFIN_ADMIN_USER" --arg p "$JELLYFIN_ADMIN_PASSWORD" \
          '{Username: $u, Pw: $p}')" 2>/dev/null || true)
  TOKEN=$(printf '%s' "$AUTH_JSON" | jq -r '.AccessToken // empty' 2>/dev/null || true)
  if [ -z "$TOKEN" ]; then
    cat >&2 <<EOF
ERROR: could not authenticate as "${JELLYFIN_ADMIN_USER}".

  The wizard steps above are unauthenticated and may well have succeeded; this
  step is where a wrong assumption would first surface. Likely causes:

  1. The wizard was already completed by hand with different credentials.
     Check JELLYFIN_ADMIN_USER / JELLYFIN_ADMIN_PASSWORD in ${ENV_FILE}.
  2. POST /Startup/User did not set the credentials as expected on this
     Jellyfin version. Reset and retry:
       docker compose -p nas-jellyfin --env-file ${ENV_FILE} -f docker-compose.jellyfin.yml down
       rm -rf ${JELLYFIN_CONFIG_DIR:-/volume2/docker/jellyfin/config}/*
       sudo ./up.sh jellyfin

  Server said: $(printf '%s' "$AUTH_JSON" | head -c 200)
EOF
    exit 1
  fi
else
  echo "    [dry-run] POST /Users/AuthenticateByName" >&2
  TOKEN="dry-run-token"
fi

if [ "$SCAN_ONLY" -eq 1 ]; then
  echo "==> Triggering library scan"
  # 204 comes back immediately; the scan itself runs in the background.
  api POST /Library/Refresh >/dev/null
  echo "    started (runs in the background; watch Dashboard -> Scheduled Tasks)"
  exit 0
fi

echo "==> Creating libraries"
if [ "$DRY_RUN" -eq 0 ]; then
  EXISTING=$(api GET /Library/VirtualFolders | jq -r '.[].Name')
else
  EXISTING=""
fi

add_library() {
  # add_library <name> <collectionType> <container-path>
  local name="$1" type="$2" path="$3"

  if printf '%s\n' "$EXISTING" | grep -Fxq "$name"; then
    echo "    ${name}: exists, skipping"
    return 0
  fi

  # Paths travel as a query param AND inside LibraryOptions.PathInfos — these
  # are CONTAINER paths, not host paths. EnableRealtimeMonitor stays off so
  # inotify on the media HDD can't keep it spinning; metadata/images are written
  # under /config (SSD), never beside the media.
  local opts
  opts=$(jq -n \
    --arg path "$path" \
    --arg lang "$JELLYFIN_METADATA_LANGUAGE" \
    --arg country "$JELLYFIN_METADATA_COUNTRY" \
    '{LibraryOptions: {
        Enabled: true,
        EnableRealtimeMonitor: false,
        EnableChapterImageExtraction: false,
        SaveLocalMetadata: false,
        PreferredMetadataLanguage: $lang,
        MetadataCountryCode: $country,
        PathInfos: [{Path: $path}]
      }}')

  api POST "/Library/VirtualFolders?name=$(urlencode "$name")&collectionType=${type}&paths=$(urlencode "$path")&refreshLibrary=false" \
    "$opts" >/dev/null
  echo "    ${name}: created (${type} -> ${path})"
}

# collectionType values are lowercase enum names — "tvshows", not "series".
add_library "Movies" movies  /media/movies
add_library "Series" tvshows /media/series
add_library "Music"  music   /media/music

echo "==> Enabling Intel QSV hardware transcoding"
# GET-modify-POST: the endpoint takes the whole EncodingOptions object, so the
# untouched fields must be preserved rather than sent as a bare patch.
ENC=$(api GET /System/Configuration/encoding)
[ "$DRY_RUN" -eq 1 ] && ENC='{}'
api POST /System/Configuration/encoding "$(printf '%s' "$ENC" | jq \
  '.HardwareAccelerationType = "qsv"
   | .VaapiDevice = "/dev/dri/renderD128"
   | .QsvDevice = "/dev/dri/renderD128"
   | .EnableHardwareEncoding = true
   | .EnableIntelLowPowerH264HwEncoder = true
   | .EnableIntelLowPowerHevcHwEncoder = true
   | .HardwareDecodingCodecs = ["h264","vc1","vp8","hevc","mpeg2video","vp9"]')" >/dev/null
echo "    QSV on /dev/dri/renderD128"

echo "==> Setting base URL to ${JELLYFIN_BASE_URL}"
NET=$(api GET /System/Configuration/network)
[ "$DRY_RUN" -eq 1 ] && NET='{}'
CURRENT_BASE=$(printf '%s' "$NET" | jq -r '.BaseUrl // ""')
if [ "$CURRENT_BASE" = "$JELLYFIN_BASE_URL" ]; then
  echo "    already set, skipping"
  RESTART_NEEDED=0
else
  # LAST call against the bare root — the API moves under the prefix after this.
  api POST /System/Configuration/network "$(printf '%s' "$NET" \
    | jq --arg b "$JELLYFIN_BASE_URL" '.BaseUrl = $b')" >/dev/null
  echo "    set"
  RESTART_NEEDED=1
fi

# JELLYFIN_URL may already carry the prefix (detected above), so strip before
# re-appending rather than doubling it up.
DIRECT_URL="${JELLYFIN_URL%/}"
DIRECT_URL="${DIRECT_URL%"${JELLYFIN_BASE_URL}"}${JELLYFIN_BASE_URL}"

cat <<EOF

==> Done.
EOF
if [ "${RESTART_NEEDED}" -eq 1 ]; then
  cat <<EOF
    Restart for the base URL to take effect:
      docker restart jellyfin
EOF
fi
cat <<EOF
    Traefik: http://apollo.local${JELLYFIN_BASE_URL}
    Direct:  ${DIRECT_URL}

    Still manual: Dashboard -> Plugins -> Catalog -> DLNA (if you want Jellyfin
    to serve DLNA in place of UGOS's disabled responder).
EOF

# Exit 10 = success, and a restart is required. Lets up.sh restart only when
# something actually changed, instead of bouncing the container on every re-run.
[ "${RESTART_NEEDED}" -eq 1 ] && exit 10
exit 0
