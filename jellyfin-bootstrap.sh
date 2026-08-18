#!/usr/bin/env bash
# Configures a fresh Jellyfin instance over the API: server name, admin user,
# libraries, Intel QSV hardware transcoding, the DLNA plugin, and the network
# settings (LAN subnets, no known proxies, empty base URL). Idempotent — safe
# to re-run.
#
# Run AFTER `docker compose ... up -d` on a fresh (never-configured) Jellyfin.
# The /Startup/* endpoints are only reachable while the wizard is incomplete,
# so this must run before anyone finishes the wizard in a browser.
#
#   ./jellyfin-bootstrap.sh
#   ./jellyfin-bootstrap.sh --dry-run
#   JELLYFIN_URL=http://apollo.local:8096 ./jellyfin-bootstrap.sh
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
    # after the restart, when a base URL had to be cleared.
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
  JELLYFIN_URL="${JELLYFIN_URL%/}"
  PROBE_INFO=""
  for i in $(seq 1 90); do
    # /System/Info/Public is unauthenticated and only 200s once the server is
    # genuinely serving requests — a plain TCP connect is not enough, since
    # Jellyfin accepts connections well before it finishes starting.
    if PROBE_INFO=$(curl -fsS --max-time 5 "${JELLYFIN_URL}/System/Info/Public" 2>/dev/null) \
       && printf '%s' "$PROBE_INFO" | jq -e '.Version' >/dev/null 2>&1; then
      break
    fi
    if [ "$i" -eq 90 ]; then
      echo "ERROR: Jellyfin did not answer at ${JELLYFIN_URL} after 180s." >&2
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

# Homepage's Jellyfin widget authenticates with a server-minted API key
# (Dashboard -> API Keys), and its scan-status widget polls the "Scan media
# library" scheduled task by id. Neither value can be seeded via the
# environment — the key lives in Jellyfin's database, the id is derived from
# the task's type name — so both are read here, post-auth, and written back to
# jellyfin.env for docker compose to inject as container labels. up.sh
# recreates the container when the labels lag the file (a plain restart keeps
# the old ones). Idempotent: the key is matched by AppName on re-runs.
persist_env() { # persist_env <VAR> <value> — write back to $ENV_FILE
  local var="$1" value="$2"
  if [ ! -f "$ENV_FILE" ]; then
    echo "    WARNING: ${ENV_FILE} not found — set ${var}=${value} in it yourself" >&2
    return 0
  fi
  grep -Fqx "${var}=${value}" "$ENV_FILE" && return 0
  grep -v "^${var}=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
  printf '%s=%s\n' "$var" "$value" >> "${ENV_FILE}.tmp"
  cat "${ENV_FILE}.tmp" > "$ENV_FILE"   # keeps the original owner and mode
  rm -f "${ENV_FILE}.tmp"
  echo "    ${var} saved to ${ENV_FILE}"
}

echo "==> Homepage widget credentials"
if [ "$DRY_RUN" -eq 0 ]; then
  API_KEY=$(api GET /Auth/Keys \
    | jq -r '[.Items[]? | select(.AppName == "Homepage")][0].AccessToken // empty')
  if [ -n "$API_KEY" ]; then
    echo "    API key exists, reusing"
  else
    # POST answers 204 with no body; the token is only readable via the GET.
    api POST '/Auth/Keys?app=Homepage' >/dev/null
    API_KEY=$(api GET /Auth/Keys \
      | jq -r '[.Items[]? | select(.AppName == "Homepage")][0].AccessToken // empty')
    if [ -z "$API_KEY" ]; then
      echo "ERROR: key created but absent from GET /Auth/Keys — check the Jellyfin log." >&2
      exit 1
    fi
    echo "    API key created (AppName: Homepage)"
  fi
  persist_env JELLYFIN_API_KEY "$API_KEY"

  SCAN_TASK_ID=$(api GET /ScheduledTasks \
    | jq -r '[.[] | select(.Key == "RefreshLibrary")][0].Id // empty')
  if [ -n "$SCAN_TASK_ID" ]; then
    persist_env JELLYFIN_SCAN_TASK_ID "$SCAN_TASK_ID"
  else
    echo "    WARNING: no Key=RefreshLibrary task in /ScheduledTasks —" >&2
    echo "             the dashboard's scan-status widget will stay empty." >&2
  fi
else
  echo "    [dry-run] GET /Auth/Keys (POST if missing), GET /ScheduledTasks" >&2
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

RESTART_NEEDED=0

if [ "${JELLYFIN_INSTALL_DLNA:-1}" = "1" ]; then
  echo "==> Installing the DLNA plugin"
  # DLNA is a plugin as of 10.10, not core. Jellyfin does not hot-load plugins:
  # a freshly installed one sits at status "Restart" until the process comes
  # back. So nothing here restarts mid-run — the work is folded into the same
  # deferred restart the base URL already uses (exit 10), which up.sh performs
  # before the library scan.
  #
  # Every call below is non-fatal on purpose: `api` returns 22 under `set -e`,
  # and a plugin that fails to install must not abort the run before the base
  # URL is asserted. Each step captures its own rc and warns instead.
  dlna_warn() { echo "    WARNING: $1" >&2; }

  install_dlna() {
    local rc=0 pkgs pkg name guid plugins entry status version

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "    [dry-run] GET /Packages, then POST /Packages/Installed/<DLNA>" >&2
      echo "    [dry-run] poll GET /Plugins until it appears" >&2
      return 0
    fi

    plugins=$(api GET /Plugins) || return 0

    # PluginInfo is PascalCase (Id/Name/Status/Version); PackageInfo below is
    # camelCase (name/guid/versions). Same feature, two casings — matching the
    # wrong one fails silently as "never appeared", not as an error.
    entry=$(printf '%s' "$plugins" \
      | jq -c 'map(select(.Name | test("dlna"; "i"))) | first // empty')

    if [ -n "$entry" ]; then
      status=$(printf '%s' "$entry" | jq -r '.Status // "?"')
      name=$(printf '%s' "$entry" | jq -r '.Name')
      case "$status" in
        Active)
          echo "    ${name}: already active, skipping"
          return 0 ;;
        Restart)
          # Only "Restart" justifies asking for another bounce. If the plugin is
          # still saying this *after* a restart it will never load, and silently
          # re-requesting would bounce Jellyfin on every up.sh run forever.
          echo "    ${name}: installed, awaiting restart"
          dlna_warn "if ${name} still reports \"Restart\" after a restart, it is"
          dlna_warn "failing to load — check docker logs jellyfin."
          RESTART_NEEDED=1
          return 0 ;;
        Superseded|Superceded)
          # A newer version is present. Not evidence that a restart changes
          # anything, so this must not set RESTART_NEEDED.
          echo "    ${name}: superseded by a newer version, leaving as-is"
          return 0 ;;
        Disabled)
          guid=$(printf '%s' "$entry" | jq -r '.Id')
          version=$(printf '%s' "$entry" | jq -r '.Version')
          api POST "/Plugins/${guid}/${version}/Enable" >/dev/null || rc=$?
          if [ "$rc" -ne 0 ]; then
            dlna_warn "${name} is disabled and could not be enabled."
            return 0
          fi
          echo "    ${name}: re-enabled"
          RESTART_NEEDED=1
          return 0 ;;
        *)
          # Malfunctioned / NotSupported / Deleted. Installed but not working —
          # must not read as success.
          dlna_warn "${name} is installed but its status is \"${status}\"."
          dlna_warn "Check Dashboard -> Plugins, and docker logs jellyfin."
          return 0 ;;
      esac
    fi

    # Not installed. Resolve the catalog entry rather than hardcoding a display
    # name — it is the {name} path segment of the install call and an exact
    # match is required.
    pkgs=$(api GET /Packages) || return 0
    pkg=$(printf '%s' "$pkgs" \
      | jq -c 'map(select(.name | test("dlna"; "i")))')

    local count
    count=$(printf '%s' "$pkg" | jq 'length')
    if [ "$count" -eq 0 ]; then
      if [ "$(printf '%s' "$pkgs" | jq 'length')" -eq 0 ]; then
        # An empty catalog is a different failure from a catalog without DLNA:
        # no repository configured, or the NAS cannot reach repo.jellyfin.org.
        dlna_warn "the plugin catalog is empty — Jellyfin could not reach its"
        dlna_warn "repository. Check egress and Dashboard -> Plugins -> Repositories."
      else
        dlna_warn "no DLNA plugin in the catalog. Available:"
        printf '%s' "$pkgs" | jq -r '.[].name' | sed 's/^/             /' >&2
      fi
      return 0
    fi
    if [ "$count" -gt 1 ]; then
      dlna_warn "${count} catalog entries match \"dlna\" — not guessing:"
      printf '%s' "$pkg" | jq -r '.[].name' | sed 's/^/             /' >&2
      return 0
    fi

    name=$(printf '%s' "$pkg" | jq -r '.[0].name')
    guid=$(printf '%s' "$pkg" | jq -r '.[0].guid')

    # No version pinned: Jellyfin picks the build matching this server's ABI,
    # which is a better judge of compatibility than a string compare here.
    api POST "/Packages/Installed/$(urlencode "$name")" >/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
      dlna_warn "could not start the install of \"${name}\"."
      return 0
    fi

    # 204 only means the download was QUEUED. The install completes
    # asynchronously, and a failure past this point surfaces only in the
    # Jellyfin log — so poll /Plugins for the package guid rather than trusting
    # the status code.
    echo "    ${name}: install queued, waiting for it to land"
    local i
    for i in $(seq 1 30); do
      sleep 2
      plugins=$(api GET /Plugins) || continue
      entry=$(printf '%s' "$plugins" \
        | jq -c --arg id "$guid" 'map(select((.Id // "") | ascii_downcase == ($id | ascii_downcase))) | first // empty')
      if [ -n "$entry" ]; then
        status=$(printf '%s' "$entry" | jq -r '.Status // "?"')
        version=$(printf '%s' "$entry" | jq -r '.Version // "?"')
        case "$status" in
          Active|Restart|Superseded|Superceded)
            echo "    ${name} ${version}: installed (status ${status})"
            RESTART_NEEDED=1 ;;
          *)
            dlna_warn "${name} installed but its status is \"${status}\"."
            dlna_warn "Check docker logs jellyfin." ;;
        esac
        return 0
      fi
    done

    dlna_warn "\"${name}\" did not appear in /Plugins after 60s."
    dlna_warn "The download may still be running. Check docker logs jellyfin,"
    dlna_warn "then re-run this script — it will pick up where this left off."
  }

  install_dlna
else
  echo "==> DLNA plugin install skipped (JELLYFIN_INSTALL_DLNA=0)"
fi

echo "==> Network settings (LAN subnets, proxies, base URL)"
# All three live on NetworkConfiguration, which deserializes over the whole
# object — hence one GET-modify-POST, and BaseUrl settled here, last.
NET=$(api GET /System/Configuration/network)
[ "$DRY_RUN" -eq 1 ] && NET='{}'

CURRENT_BASE=$(printf '%s' "$NET" | jq -r '.BaseUrl // ""')
CURRENT_SUBNETS=$(printf '%s' "$NET" | jq -c '.LocalNetworkSubnets // []')
CURRENT_PROXIES=$(printf '%s' "$NET" | jq -c '.KnownProxies // []')

# KnownProxies stays empty: a stray entry makes Jellyfin trust X-Forwarded-For
# from anyone.
DESIRED_SUBNETS=$(jq -cn --arg s "${JELLYFIN_LOCAL_SUBNET:-192.168.0.0/24}" '[$s]')

NEW_NET=$(printf '%s' "$NET" | jq \
  --argjson subnets "$DESIRED_SUBNETS" \
  '.LocalNetworkSubnets = $subnets | .KnownProxies = [] | .BaseUrl = ""')

# UNVERIFIED: if Jellyfin normalizes LocalNetworkSubnets on write this never
# matches, and every up.sh run then restarts and rescans the HDD. Confirm by
# running up.sh twice — the second must say "already correct, skipping".
if [ "$CURRENT_BASE" = "" ] \
   && [ "$CURRENT_SUBNETS" = "$DESIRED_SUBNETS" ] \
   && [ "$CURRENT_PROXIES" = "[]" ]; then
  # Not `RESTART_NEEDED=0`: the DLNA step above may already have set it, and
  # this branch is only evidence about the network config.
  echo "    already correct, skipping"
else
  api POST /System/Configuration/network "$NEW_NET" >/dev/null
  [ "$CURRENT_SUBNETS" = "$DESIRED_SUBNETS" ] \
    || echo "    LAN subnets: $(printf '%s' "$DESIRED_SUBNETS" | jq -r 'join(", ")')"
  [ "$CURRENT_PROXIES" = "[]" ] || echo "    known proxies: cleared"
  [ -z "$CURRENT_BASE" ] || echo "    base URL: cleared"
  RESTART_NEEDED=1
fi

cat <<EOF

==> Done.
EOF
if [ "${RESTART_NEEDED}" -eq 1 ]; then
  cat <<EOF
    A restart is needed to apply the changes above:
      docker restart jellyfin
    (up.sh does this for you, then triggers the library scan.)
EOF
fi
cat <<EOF
    Jellyfin: ${JELLYFIN_URL%/}
      (also on the LAN as http://apollo.local:8096)
EOF

# Exit 10 = success, and a restart is required. Lets up.sh restart only when
# something actually changed, instead of bouncing the container on every re-run.
[ "${RESTART_NEEDED}" -eq 1 ] && exit 10
exit 0
