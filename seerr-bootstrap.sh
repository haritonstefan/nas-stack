#!/usr/bin/env bash
# Configures a fresh Seerr instance over the API: the Jellyfin sign-in that
# creates Seerr's admin (user 1), the media-server settings, the library
# selection, the Sonarr/Radarr wiring, and finally POST /settings/initialize.
# Idempotent — safe to re-run.
#
# Run AFTER `docker compose ... up -d` and AFTER ./arr-bootstrap.sh. The
# ordering matters: the Sonarr/Radarr wiring below binds requests to the TRaSH
# quality profiles Configarr creates, so running this first silently binds them
# to a stock profile instead.
#
# Nothing here is one-shot. Setup stays re-runnable until
# POST /api/v1/settings/initialize, which is therefore the last call, made only
# once everything before it has succeeded.
#
#   ./seerr-bootstrap.sh
#   ./seerr-bootstrap.sh --dry-run
#   ./seerr-bootstrap.sh --verbose
#   SEERR_URL=http://apollo.local:5055 ./seerr-bootstrap.sh
#
# Requires: curl, jq. Reads two env files, because Seerr straddles two tiers:
#   arr.env      — SEERR_API_KEY, SONARR_API_KEY, RADARR_API_KEY, root folders
#   jellyfin.env — JELLYFIN_ADMIN_USER / _PASSWORD, read in an isolating
#                  subshell so shared names (TZ, PUID, PGID) cannot leak in
#
# Exit codes: 0 success, or a deliberate skip via SEERR_CONFIGURE=0.
#             1 precondition failure (missing credentials, unreachable service).
#             22 an API call returned a non-2xx.
# A Sonarr/Radarr wiring failure does not abort — the other app is still tried
# and `initialize` still runs, since leaving setup half-open is worse than
# leaving it incomplete — but it does own the exit code, so an unwired Seerr
# never reports success.
# There is deliberately no restart channel (Jellyfin's exit 10) — nothing
# configured here needs a container restart to take effect.
#
# On failure this script prints the state it observed — the initialized flag,
# the decoded mediaServerType, whether user 1 exists, and the raw response body
# — and then names the action required. It does not assert a cause it has not
# verified.

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
       echo "Usage: ./seerr-bootstrap.sh [--dry-run] [--verbose]" >&2
       exit 1 ;;
  esac
done

# Both env files are resolved the same way: ./ prefixed only for a bare
# filename, so a relative name is read from here rather than $PATH, without
# mangling an absolute override.
source_env() {
  # shellcheck disable=SC1090
  case "$1" in
    /*|./*|../*) . "$1" ;;
    *)           . "./$1" ;;
  esac
}

ENV_FILE="${ENV_FILE:-arr.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  source_env "$ENV_FILE"
  set +a
fi

# Not sourced into this shell at all: arr.env and jellyfin.env share names
# (TZ, PUID, PGID), and up.sh sources every selected tier into one shell where
# the last one wins. Read in subshells instead, one variable at a time.
JELLYFIN_ENV_FILE="${JELLYFIN_ENV_FILE:-jellyfin.env}"
jellyfin_env_get() {
  # jellyfin_env_get <var-name> — empty if the file or the variable is absent.
  local var="$1"
  [ -f "$JELLYFIN_ENV_FILE" ] || return 0
  (
    set +u
    source_env "$JELLYFIN_ENV_FILE" >/dev/null 2>&1
    eval "printf '%s' \"\${${var}:-}\""
  ) || true
}

SEERR_URL="${SEERR_URL:-http://127.0.0.1:5055}"
SONARR_ROOT_FOLDER="${SONARR_ROOT_FOLDER:-/media/series}"
RADARR_ROOT_FOLDER="${RADARR_ROOT_FOLDER:-/media/movies}"

# Renamed from ARR_CONFIGURE_SEERR when this moved out of arr-bootstrap.sh; the
# old name is still honoured so an existing arr.env keeps working.
SEERR_CONFIGURE="${SEERR_CONFIGURE:-${ARR_CONFIGURE_SEERR:-1}}"

# Jellyfin as Seerr must reach it: the host LAN address, because Jellyfin is
# host-networked and not on nas-net — a container name will not resolve, and
# .local usually does not resolve inside containers either.
SEERR_JELLYFIN_HOST="${SEERR_JELLYFIN_HOST:-192.168.0.231}"
SEERR_JELLYFIN_PORT="${SEERR_JELLYFIN_PORT:-8096}"

# Addresses the containers use for each other over nas-net. Not SEERR_URL,
# which is how this script (running on the host) reaches Seerr.
SONARR_INTERNAL_HOST="sonarr"
SONARR_INTERNAL_PORT=8989
RADARR_INTERNAL_HOST="radarr"
RADARR_INTERNAL_PORT=7878

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required." >&2; exit 1; }
done

say()  { echo "==> $1"; }
info() { echo "    $1"; }
warn() { echo "    WARNING: $1" >&2; }
fail() { echo "    ERROR: $1" >&2; }

# In the arr apps' bodies secrets travel inside `fields` arrays; in Seerr's they
# are top-level (`apiKey` on the Sonarr/Radarr settings, `password` on the
# sign-in), so both shapes are covered. Verbose and dry-run output is the thing
# most likely to be pasted into a chat or an issue, so it must carry no secrets.
mask() {
  printf '%s' "$1" | jq -c '
    if type == "object" then
      (if has("fields") then
         .fields |= map(if (.name // "" | test("password|apiKey"; "i")) then .value = "***" else . end)
       else . end)
      | (if has("password") then .password = "***" else . end)
      | (if has("apiKey") then .apiKey = "***" else . end)
    else . end' 2>/dev/null || echo '<unprintable>'
}

api() {
  # api <method> <path> [json-body]
  # stdout is the response body only; all logging goes to stderr, so
  #   X=$(api ...) works and `api ... >/dev/null` stays quiet.
  local method="$1" path="$2" body="${3:-}"
  local base="$SEERR_URL"
  # No -f: it discards the response body on HTTP errors, which is exactly where
  # Seerr puts its error messages. Status is captured separately.
  local -a args=(-sS -X "$method" "${base}${path}"
                 -H 'Content-Type: application/json' -H "X-Api-Key: ${SEERR_API_KEY}")
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

if [ "$SEERR_CONFIGURE" != "1" ]; then
  say "Skipping Seerr (SEERR_CONFIGURE=0)"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  say "DRY RUN — no requests will be sent"
fi

if [ "$DRY_RUN" -eq 0 ] && [ -z "${SEERR_API_KEY:-}" ]; then
  fail "SEERR_API_KEY is not set (put it in ${ENV_FILE}, or run up.sh which"
  fail "generates it). Seerr cannot be configured without it."
  exit 1
fi
: "${SEERR_API_KEY:=<unset>}"

# --- state -------------------------------------------------------------------

# MediaServerType, from the pinned image's own source:
#   github.com/seerr-team/seerr/blob/v3.4.1/server/constants/server.ts
#   PLEX = 1, JELLYFIN = 2, EMBY = 3, NOT_CONFIGURED = 4
# Worth decoding rather than printing the bare number: 4 means "fresh install,
# nothing ever stored", which is the difference between a wedged Seerr and one
# that was simply never set up.
decode_server_type() {
  case "${1:-}" in
    1) echo "1 (PLEX)" ;;
    2) echo "2 (JELLYFIN)" ;;
    3) echo "3 (EMBY)" ;;
    4) echo "4 (NOT_CONFIGURED — fresh, nothing ever stored)" ;;
    ""|null) echo "<absent>" ;;
    *) echo "$1 (unknown)" ;;
  esac
}

SEERR_INITIALIZED=""
SEERR_SERVER_TYPE=""

read_public_settings() {
  local pub
  pub=$(curl -sS --max-time 5 "${SEERR_URL}/api/v1/settings/public" 2>/dev/null) || pub=""
  # Not `// empty`: that maps a legitimate `false` to "", losing the difference
  # between "not initialized" and "could not be read".
  SEERR_INITIALIZED=$(printf '%s' "$pub" | jq -r 'if has("initialized") then .initialized else empty end' 2>/dev/null) || SEERR_INITIALIZED=""
  SEERR_SERVER_TYPE=$(printf '%s' "$pub" | jq -r 'if has("mediaServerType") then .mediaServerType else empty end' 2>/dev/null) || SEERR_SERVER_TYPE=""
}

# Distinguishes "no user 1 yet" from "a user exists": before the first user
# exists there is nobody for the API key to authenticate as, so this route 403s.
# That 403 is a state signal, not an error.
user_state() {
  local status
  status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "X-Api-Key: ${SEERR_API_KEY}" "${SEERR_URL}/api/v1/user" 2>/dev/null) || status="000"
  case "$status" in
    2*)  echo "present" ;;
    403) echo "absent" ;;
    *)   echo "unknown (HTTP ${status})" ;;
  esac
}

# Printed on every failure path. The whole point of this script's existence:
# the old code asserted "not a Jellyfin administrator" for any 403, which on a
# fresh install is flatly false and sends the reader after the wrong cause.
report_state() {
  read_public_settings
  warn "Seerr state at the time of failure:"
  warn "  initialized:     ${SEERR_INITIALIZED:-<unknown>}"
  warn "  mediaServerType: $(decode_server_type "$SEERR_SERVER_TYPE")"
  warn "  user 1:          $(user_state)"
  warn "  Seerr URL:       ${SEERR_URL}"
  warn "  Jellyfin:        ${SEERR_JELLYFIN_HOST}:${SEERR_JELLYFIN_PORT}"
}

# --- readiness ---------------------------------------------------------------

wait_for_seerr() {
  local probe
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would wait for seerr at ${SEERR_URL}"
    return 0
  fi
  # No /ping here; /api/v1/status is Seerr's unauthenticated equivalent, and the
  # JSON shape is checked because a wrong port can 200 with something else.
  for _ in $(seq 1 90); do
    if probe=$(curl -fsS --max-time 5 "${SEERR_URL}/api/v1/status" 2>/dev/null) \
       && printf '%s' "$probe" | jq -e '.version' >/dev/null 2>&1; then
      info "seerr ready at ${SEERR_URL}"
      return 0
    fi
    sleep 2
  done
  fail "seerr did not answer at ${SEERR_URL}/api/v1/status after 180s"
  fail "check: docker logs seerr — then re-run ./seerr-bootstrap.sh"
  return 1
}

# Retried rather than probed once: up.sh restarts Jellyfin on its deferred
# exit-10 path, and a single-shot probe can lose that race and report a
# perfectly healthy Jellyfin as unreachable.
wait_for_jellyfin() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would wait for jellyfin at ${SEERR_JELLYFIN_HOST}:${SEERR_JELLYFIN_PORT}"
    return 0
  fi
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 5 \
         "http://${SEERR_JELLYFIN_HOST}:${SEERR_JELLYFIN_PORT}/System/Info/Public" \
         >/dev/null 2>&1; then
      info "jellyfin reachable at ${SEERR_JELLYFIN_HOST}:${SEERR_JELLYFIN_PORT}"
      return 0
    fi
    sleep 2
  done
  fail "Jellyfin not answering at ${SEERR_JELLYFIN_HOST}:${SEERR_JELLYFIN_PORT} after 60s"
  fail "Seerr stores this address and reaches Jellyfin itself, so it must be the"
  fail "host LAN IP — not a container name, not apollo.local."
  return 1
}

# --- sign-in -----------------------------------------------------------------

say "Configuring Seerr"

wait_for_seerr || exit 1
read_public_settings

if [ "$SEERR_INITIALIZED" != "true" ]; then
  jf_user=$(jellyfin_env_get JELLYFIN_ADMIN_USER)
  jf_pass=$(jellyfin_env_get JELLYFIN_ADMIN_PASSWORD)

  if [ "$DRY_RUN" -eq 0 ] && { [ -z "$jf_user" ] || [ -z "$jf_pass" ]; }; then
    fail "no Jellyfin admin credentials in ${JELLYFIN_ENV_FILE}"
    if [ ! -f "$JELLYFIN_ENV_FILE" ]; then
      fail "the file does not exist (looked from $(pwd))"
    else
      [ -z "$jf_user" ] && fail "JELLYFIN_ADMIN_USER is empty or unset"
      [ -z "$jf_pass" ] && fail "JELLYFIN_ADMIN_PASSWORD is empty or unset"
    fi
    fail "Seerr's admin is created FROM the Jellyfin account, so setup cannot"
    fail "proceed without it. up.sh prompts for the password only when the"
    fail "jellyfin tier is selected — 'sudo ./up.sh arr' skips that prompt."
    report_state
    exit 1
  fi

  wait_for_jellyfin || { report_state; exit 1; }

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] POST /api/v1/auth/jellyfin — Jellyfin at ${SEERR_JELLYFIN_HOST}:${SEERR_JELLYFIN_PORT}, creds from ${JELLYFIN_ENV_FILE}"
    info "[dry-run] would sync and enable the Movies/Series libraries"
  else
    # First-ever call creates Seerr's admin (user 1) from this account and stores
    # the media-server settings; on later runs it is a plain sign-in.
    # serverType 2 = MediaServerType.JELLYFIN (see decode_server_type above).
    # Deliberately not api(): this route takes no X-Api-Key — before the first
    # user exists there is nobody for the key to authenticate as.
    body=$(jq -n --arg u "$jf_user" --arg p "$jf_pass" \
             --arg h "$SEERR_JELLYFIN_HOST" --argjson port "$SEERR_JELLYFIN_PORT" \
             '{username: $u, password: $p, hostname: $h, port: $port,
               useSsl: false, serverType: 2}') \
      || { fail "could not build the sign-in body"; exit 1; }
    if [ "$VERBOSE" -eq 1 ]; then
      echo "    --> POST ${SEERR_URL}/api/v1/auth/jellyfin" >&2
      printf '        body: %s\n' "$(mask "$body")" >&2
    fi
    rc=0
    raw=$(curl -sS -X POST "${SEERR_URL}/api/v1/auth/jellyfin" \
            -H 'Content-Type: application/json' -d "$body" -w $'\n%{http_code}') || rc=$?
    if [ "$rc" -ne 0 ]; then
      fail "POST /api/v1/auth/jellyfin — curl failed (exit ${rc})"
      report_state
      exit 1
    fi
    status="${raw##*$'\n'}"
    out="${raw%$'\n'*}"
    [ "$VERBOSE" -eq 1 ] && echo "    <-- ${status}" >&2

    case "$status" in
      2*) info "signed in to Seerr as ${jf_user}" ;;
      403)
        # Per the API spec, the first-user path creates the account with full
        # admin privileges unconditionally — so it cannot 403 on admin grounds.
        # Only the path where a user already exists can. Which one this is
        # decides the fix, so report the evidence instead of picking one.
        fail "Seerr refused the sign-in (403)"
        fail "said: $(printf '%s' "$out" | head -c 500)"
        case "$(user_state)" in
          absent)
            fail "Seerr has no user 1, and the first-user path grants admin"
            fail "unconditionally — a 403 here is unexpected. The response body"
            fail "above is the evidence; check docker logs seerr for the"
            fail "upstream Jellyfin error behind it." ;;
          present)
            fail "Seerr already has a user, so this took the existing-user path,"
            fail "which requires '${jf_user}' to be a Jellyfin administrator and"
            fail "to match the stored media server. If first-time setup needs to"
            fail "run again, Seerr's config must be reset:"
            fail "  docker stop seerr"
            fail "  mv \${SEERR_CONFIG_DIR}/settings.json{,.bak}   # keep the evidence"
            fail "  docker start seerr && ./seerr-bootstrap.sh" ;;
          *)
            fail "could not determine whether Seerr has a user — see the state below." ;;
        esac
        report_state
        exit 1 ;;
      *)
        fail "Seerr sign-in failed (HTTP ${status})"
        fail "said: $(printf '%s' "$out" | head -c 500)"
        report_state
        exit 1 ;;
    esac

    # sync pulls the library list from Jellyfin; enable REPLACES the enabled set
    # (anything not passed is disabled), which is why this only runs before
    # initialize, where the state is known to be fresh.
    libs=$(api GET '/api/v1/settings/jellyfin/library?sync=true') || {
      fail "library sync failed"; report_state; exit 22; }
    ids=$(printf '%s' "$libs" | jq -r \
      '[.[] | select(.name == "Movies" or .name == "Series") | .id] | join(",")')
    if [ -z "$ids" ]; then
      ids=$(printf '%s' "$libs" | jq -r '[.[].id] | join(",")')
      [ -n "$ids" ] && warn "no libraries named Movies/Series — enabling all of them instead"
    fi
    if [ -z "$ids" ]; then
      fail "Jellyfin reported no libraries — run ./jellyfin-bootstrap.sh first,"
      fail "then re-run this script."
      report_state
      exit 1
    fi
    api GET "/api/v1/settings/jellyfin/library?enable=${ids}" >/dev/null || {
      fail "library enable failed"; report_state; exit 22; }
    info "libraries enabled"
  fi
fi

# --- sonarr / radarr ---------------------------------------------------------

# Idempotent by name, GET-list-then-skip. Hostnames are container names: this
# traffic stays on nas-net, unlike SEERR_URL which is a host-side address.
#
# A failure here does not abort — the other app is still worth attempting, and
# initialize still needs to run so the setup is not left half-open — but it does
# have to reach the exit code. A Seerr with no download apps wired cannot fulfil
# a single request, which is not something to report as a successful bring-up.
WIRING_RC=0
add_seerr_app() {
  # add_seerr_app <Name> <path> <host> <port> <api-key> <root> <preferred-profile> <extra-jq>
  local name="$1" path="$2" host="$3" port="$4" app_key="$5" root="$6" preferred="$7" extra="$8"
  local existing test_out profile_id profile_name body

  if [ -z "$app_key" ]; then
    fail "${name}: no API key in ${ENV_FILE} — run up.sh to generate it"
    WIRING_RC=1
    return 0
  fi

  # `arrays` guards the dry-run stub, where api() returns {} rather than a list.
  existing=$(api GET "/api/v1/settings/${path}" | jq -r 'arrays[].name') || {
    fail "${name}: could not list existing instances"; WIRING_RC=22; return 0; }
  if printf '%s\n' "$existing" | grep -Fxq "$name"; then
    info "${name}: exists, skipping"
    return 0
  fi

  # Seerr's own connection test doubles as profile discovery.
  body=$(jq -n --arg h "$host" --argjson p "$port" --arg k "$app_key" \
           '{hostname: $h, port: $p, apiKey: $k, useSsl: false, baseUrl: ""}')
  test_out=$(api POST "/api/v1/settings/${path}/test" "$body") || {
    fail "${name}: connection test failed — Seerr could not reach ${host}:${port}."
    fail "${name}: check the container is up and its key in ${ENV_FILE} is current."
    WIRING_RC=22; return 0; }

  # Prefer the TRaSH profile configarr installs; fall back to the first.
  # `arrays` again for the dry-run stub, which carries no .profiles at all.
  profile_id=$(printf '%s' "$test_out" | jq -r --arg n "$preferred" \
    '(.profiles | arrays | .[] | select(.name == $n) | .id) // (.profiles | arrays | .[0].id) // empty')
  profile_name=$(printf '%s' "$test_out" | jq -r --arg n "$preferred" \
    '(.profiles | arrays | .[] | select(.name == $n) | .name) // (.profiles | arrays | .[0].name) // empty')
  if [ -z "$profile_id" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      # The real run reads these off the connection test; a dry run has no
      # response to read, so stand in the intended profile to show the shape.
      profile_id=0
      profile_name="$preferred"
    else
      fail "${name}: no quality profiles returned — cannot bind requests"
      WIRING_RC=22
      return 0
    fi
  fi
  [ "$profile_name" != "$preferred" ] \
    && warn "${name}: profile '${preferred}' not found (configarr not synced yet? run ./arr-bootstrap.sh first) — using '${profile_name}'"

  body=$(jq -n --arg name "$name" --arg h "$host" --argjson p "$port" \
           --arg k "$app_key" --argjson pid "$profile_id" --arg pname "$profile_name" \
           --arg dir "$root" \
           '{name: $name, hostname: $h, port: $p, apiKey: $k, useSsl: false,
             baseUrl: "", activeProfileId: $pid, activeProfileName: $pname,
             activeDirectory: $dir, is4k: false, isDefault: true,
             syncEnabled: true, preventSearch: false}')
  [ -n "$extra" ] && body=$(printf '%s' "$body" | jq "$extra")
  api POST "/api/v1/settings/${path}" "$body" >/dev/null || {
    fail "${name}: create failed — see the response above"; WIRING_RC=22; return 0; }
  info "${name}: wired (profile '${profile_name}', root ${root})"
}

# The extra-jq carries each schema's own required field: enableSeasonFolders is
# required by SonarrSettings, minimumAvailability by RadarrSettings.
add_seerr_app Sonarr sonarr "$SONARR_INTERNAL_HOST" "$SONARR_INTERNAL_PORT" \
  "${SONARR_API_KEY:-}" "$SONARR_ROOT_FOLDER" "WEB-1080p" '.enableSeasonFolders = true'
add_seerr_app Radarr radarr "$RADARR_INTERNAL_HOST" "$RADARR_INTERNAL_PORT" \
  "${RADARR_API_KEY:-}" "$RADARR_ROOT_FOLDER" "HD Bluray + WEB" '.minimumAvailability = "released"'

# --- initialize --------------------------------------------------------------

# Last, and only now: everything above must have succeeded, because this is the
# one call that ends the re-runnable window.
if [ "$SEERR_INITIALIZED" != "true" ]; then
  if api POST /api/v1/settings/initialize >/dev/null; then
    info "Seerr initialized — sign in with the Jellyfin account"
  else
    fail "initialize failed — setup stays re-runnable, so fix the cause above"
    fail "and run ./seerr-bootstrap.sh again."
    report_state
    exit 22
  fi
else
  info "already initialized"
fi

# initialize deliberately ran even if the wiring failed — leaving setup open is
# worse than leaving it incomplete, and the wiring is fixable in place by a
# re-run. But the failure still owns the exit code.
if [ "$WIRING_RC" -ne 0 ]; then
  say "Done, with errors"
  fail "Seerr is initialized but not fully wired — it cannot fulfil requests"
  fail "until Sonarr/Radarr are connected. Fix the cause above and re-run:"
  fail "  ./seerr-bootstrap.sh --verbose"
  info "Seerr: ${SEERR_URL}"
  exit "$WIRING_RC"
fi

say "Done"
info "Seerr: ${SEERR_URL}"
exit 0
