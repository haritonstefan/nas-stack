#!/usr/bin/env bash
# Adds the torrent trackers to Prowlarr: the 'byparr' tag, the Byparr indexer
# proxy (registered under the FlareSolverr implementation — it speaks that
# API), the public indexers from ARR_INDEXERS, and the private ones from
# ARR_INDEXERS_PRIVATE with credentials from ARR_INDEXER_<NAME>_USER / _PASS
# (<NAME> is the definition name uppercased) — see arr.env.example.
# Idempotent — safe to re-run.
#
# Run AFTER `sudo ./up.sh`: it only talks to Prowlarr and skips anything
# already configured. Split out of arr-bootstrap.sh so tracker wiring can be
# run — and re-run when a tracker was down or a definition missing — without
# repeating the whole stack bring-up.
#
# Each indexer is added one at a time and tested on create: the POST without
# forceSave makes Prowlarr run its connection test, which for private trackers
# includes the login. When a test fails you are asked to retry, update the
# credentials (private only), save it untested, or skip it. With
# --non-interactive — or no terminal at all (cron) — a failing indexer is
# saved untested with a warning instead, so unattended runs never hang.
#
# A definition missing from Prowlarr's schema is warned about and skipped:
# Prowlarr fetches the Cardigann definitions from its update service shortly
# after start, so on a fresh stack a re-run a few minutes later often finds
# them.
#
#   ./arr-indexers.sh
#   ./arr-indexers.sh --dry-run
#   ./arr-indexers.sh --verbose
#   ./arr-indexers.sh --non-interactive   # never prompt; save failures untested
#   PROWLARR_URL=http://apollo.local:9696 ./arr-indexers.sh
#
# Requires: curl, jq. Reads arr.env if present (for PROWLARR_API_KEY and the
# indexer lists).
#
# Exit codes: 0 success — but individual trackers may still have warned and
# been skipped, so read the output. 1 precondition failure. A per-indexer API
# failure never aborts the run.

set -euo pipefail

DRY_RUN=0
VERBOSE=0
NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)         DRY_RUN=1 ;;
    -v|--verbose)      VERBOSE=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    -h|--help)
      # Print the header block: every comment line after the shebang, stopping
      # at the first non-comment. Self-adjusting, so editing the header above
      # cannot silently truncate --help.
      sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
      exit 0 ;;
    *) echo "Unknown argument: ${arg}" >&2
       echo "Usage: ./arr-indexers.sh [--dry-run] [--verbose] [--non-interactive]" >&2
       exit 1 ;;
  esac
done

# Prompting needs a controlling terminal, read via /dev/tty because stdin is
# busy carrying the indexer lists into the while-read loops below. Without one
# (cron, CI) fall back to the automatic path rather than hang on a read.
INTERACTIVE=0
if [ "$NON_INTERACTIVE" -eq 0 ] && { : </dev/tty; } 2>/dev/null; then
  INTERACTIVE=1
fi

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

PROWLARR_URL="${PROWLARR_URL:-http://127.0.0.1:9696}"

# Still honored here (configure.sh stages it): 0 skips the indexers section,
# leaving Prowlarr empty for hand-adding. The Byparr proxy is set up regardless.
ARR_INSTALL_INDEXERS="${ARR_INSTALL_INDEXERS:-1}"
ARR_INDEXERS="${ARR_INDEXERS:-1337x,thepiratebay,yts,eztv,limetorrents,torlock,therarbg,knaben,glodls,magnetdl}"
# No default: the credentials are secrets, so the list is opt-in via arr.env.
ARR_INDEXERS_PRIVATE="${ARR_INDEXERS_PRIVATE:-}"

# The address Prowlarr uses for Byparr over nas-net — not how this script
# (running on the host) reaches anything.
BYPARR_INTERNAL_URL="http://byparr:8191"

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required." >&2; exit 1; }
done

if [ "$DRY_RUN" -eq 0 ] && [ -z "${PROWLARR_API_KEY:-}" ]; then
  echo "ERROR: PROWLARR_API_KEY is not set (put it in ${ENV_FILE}, or run up.sh" >&2
  echo "       which generates it). Prowlarr cannot be configured without it." >&2
  exit 1
fi
: "${PROWLARR_API_KEY:=<unset>}"

say()  { echo "==> $1"; }
info() { echo "    $1"; }
warn() { echo "    WARNING: $1" >&2; }

api() {
  # api <method> <path> [json-body] — Prowlarr only, unlike arr-bootstrap.sh's.
  # stdout is the response body only; all logging goes to stderr, so
  #   X=$(api ...) works and `api ... >/dev/null` stays quiet.
  local method="$1" path="$2" body="${3:-}"
  # No -f: it discards the response body on HTTP errors, which is exactly where
  # Prowlarr puts its validation messages. Status is captured separately.
  local -a args=(-sS -X "$method" "${PROWLARR_URL}${path}"
                 -H 'Content-Type: application/json' -H "X-Api-Key: ${PROWLARR_API_KEY}")
  [ -n "$body" ] && args+=(-d "$body")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [dry-run] ${method} ${PROWLARR_URL}${path}" >&2
    # Masked like the verbose and error paths: a dry run is the thing most likely
    # to be pasted into a chat or an issue, so it must not carry the credentials.
    [ -n "$body" ] && printf '%s\n' "$(mask "$body")" | sed 's/^/              /' >&2
    echo '{}'
    return 0
  fi

  if [ "$VERBOSE" -eq 1 ]; then
    echo "    --> ${method} ${PROWLARR_URL}${path}" >&2
    [ -n "$body" ] && printf '        body: %s\n' "$(mask "$body")" >&2
  fi

  # Append the status as a trailing line so body and code come back together.
  local raw rc=0 status out
  raw=$(curl "${args[@]}" -w $'\n%{http_code}') || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: ${method} ${PROWLARR_URL}${path} — curl failed (exit ${rc})" >&2
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
  echo "ERROR: ${method} ${PROWLARR_URL}${path} returned HTTP ${status}" >&2
  [ -n "$body" ] && printf '       sent: %s\n' "$(mask "$body")" >&2
  if [ -n "$out" ]; then
    printf '       said: %s\n' "$(printf '%s' "$out" | head -c 500)" >&2
  else
    printf '       said: <empty body>\n' >&2
  fi
  return 22
}

# Passwords travel inside `fields` arrays, so masking has to reach into them by
# name rather than looking at top-level keys.
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

say "Waiting for Prowlarr"
wait_for_prowlarr() {
  local i probe
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would wait for prowlarr at ${PROWLARR_URL}"
    return 0
  fi
  for i in $(seq 1 90); do
    # /ping is unauthenticated and only 200s once the app is genuinely serving.
    # A TCP connect is not enough: it accepts connections well before it
    # finishes migrating its database. The JSON shape is checked too, since a
    # reverse proxy or a wrong port can 200 with something else entirely.
    if probe=$(curl -fsS --max-time 5 "${PROWLARR_URL}/ping" 2>/dev/null) \
       && printf '%s' "$probe" | jq -e '.status == "OK"' >/dev/null 2>&1; then
      info "prowlarr ready at ${PROWLARR_URL}"
      return 0
    fi
    if [ "$i" -eq 90 ]; then
      echo "ERROR: prowlarr did not answer at ${PROWLARR_URL}/ping after 180s." >&2
      echo "       Check: docker logs prowlarr" >&2
      exit 1
    fi
    sleep 2
  done
}
wait_for_prowlarr

# A 401 here means the pre-seeded key never reached the app — almost always a
# stale container from before arr.env existed. Worth its own message, because
# every later call would fail the same way with a less obvious cause.
if [ "$DRY_RUN" -eq 0 ]; then
  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-Api-Key: ${PROWLARR_API_KEY}" "${PROWLARR_URL}/api/v1/system/status" 2>/dev/null || echo 000)
  case "$status" in
    2*) ;;
    401|403)
      echo "ERROR: prowlarr rejected the API key from ${ENV_FILE} (HTTP ${status})." >&2
      echo "       The key is injected at container start, so a container that" >&2
      echo "       predates the current ${ENV_FILE} still has the old one:" >&2
      echo "         docker compose -p nas-arr --env-file ${ENV_FILE} -f docker-compose.arr.yml up -d --force-recreate prowlarr" >&2
      exit 1 ;;
    *)
      warn "prowlarr: unexpected HTTP ${status} from its status endpoint" ;;
  esac
fi

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
# must not abort the run.
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
  tags=$(api GET /api/v1/tag) || {
    warn "could not list Prowlarr's tags — skipping the Byparr proxy"
    return 0
  }
  # Prowlarr lowercases tag labels on create, so match the stored form.
  BYPARR_TAG_ID=$(printf '%s' "$tags" \
    | jq -r 'map(select(.label == "byparr")) | first | .id // empty')
  if [ -n "$BYPARR_TAG_ID" ]; then
    info "tag 'byparr': exists (id ${BYPARR_TAG_ID})"
  else
    BYPARR_TAG_ID=$(api POST /api/v1/tag '{"label":"byparr"}' \
      | jq -r '.id // empty') || BYPARR_TAG_ID=""
    if [ -z "$BYPARR_TAG_ID" ]; then
      warn "could not create the 'byparr' tag — skipping the Byparr proxy"
      return 0
    fi
    info "tag 'byparr': created (id ${BYPARR_TAG_ID})"
  fi

  existing=$(api GET /api/v1/indexerproxy | jq -r '.[].name // empty') || existing=""
  if printf '%s\n' "$existing" | grep -Fxq "Byparr"; then
    info "proxy: exists, skipping"
  else
    # GET-schema-modify-POST, the same mandatory pattern as the indexers: the
    # resource mapper rejects hand-written bodies.
    entry=$(api GET /api/v1/indexerproxy/schema \
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
      api POST /api/v1/indexerproxy "$entry" >/dev/null || rc=$?
      if [ "$rc" -ne 0 ]; then
        warn "proxy connection test failed (details above) — saving untested"
        rc=0
        api POST '/api/v1/indexerproxy?forceSave=true' "$entry" >/dev/null || rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        info "proxy: registered (host ${BYPARR_INTERNAL_URL}, tag 'byparr')"
      else
        warn "proxy could not be registered (exit ${rc})"
      fi
    fi
  fi

  # Retro-tag indexers added by hand in the UI (or by runs that predate the
  # tag). New ones are born tagged in add_one below. GET-modify-PUT over the
  # whole object — never a partial body — and forceSave because a tracker being
  # down right now is not a reason to leave it untagged.
  indexers=$(api GET /api/v1/indexer) || {
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
        api PUT "/api/v1/indexer/${id}?forceSave=true" "$entry" >/dev/null || rc=$?
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

# Every call below is non-fatal on purpose: `api` returns 22 under `set -e`,
# and a tracker that is merely down or renamed must not abort the run.
add_indexers() {
  local schema existing app_profile_id def key user pass

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] GET /api/v1/appprofile for the sync-profile id"
    info "[dry-run] GET /api/v1/indexer/schema, then POST each of: ${ARR_INDEXERS}"
    [ -n "$ARR_INDEXERS_PRIVATE" ] && info "[dry-run] plus, with credentials: ${ARR_INDEXERS_PRIVATE}"
    info "[dry-run] each is tested on create; a failure prompts retry/update/force-save/skip"
    return 0
  fi

  # The schema's appProfileId is a placeholder 0, and validation rejects it —
  # 'App Profile Id' must be greater than 0 — on tested and forceSaved bodies
  # alike. Every indexer must reference a real sync profile, so resolve the id
  # of the first one (Prowlarr ships with 'Standard') and patch it in below.
  app_profile_id=$(api GET /api/v1/appprofile \
    | jq -r 'sort_by(.id) | first | .id // empty') || app_profile_id=""
  if [ -z "$app_profile_id" ]; then
    warn "could not resolve a sync profile from /api/v1/appprofile — skipping indexers"
    return 0
  fi
  info "using sync profile id ${app_profile_id}"

  # GET-schema-modify-POST is mandatory here, not stylistic. Prowlarr's
  # IndexerResource.ToModel() looks every non-standard field up in the cached
  # Cardigann definition and throws ArgumentOutOfRangeException on anything it
  # does not recognise, so a hand-written body is rejected outright.
  schema=$(api GET /api/v1/indexer/schema) || {
    warn "could not fetch the indexer schema — skipping indexers"
    return 0
  }
  existing=$(api GET /api/v1/indexer \
    | jq -r '.[].definitionName // empty') || existing=""

  # add_one <definitionName> [<username> <password>]
  add_one() {
    local def="$1" user="${2:-}" pass="${3:-}" entry rc=0 is_private=0 choice ans creds_changed=0

    if printf '%s\n' "$existing" | grep -Fxq "$def"; then
      info "${def}: exists, skipping"
      return 0
    fi

    entry=$(printf '%s' "$schema" \
      | jq -c --arg d "$def" 'map(select(.definitionName == $d)) | first // empty')
    if [ -z "$entry" ]; then
      warn "${def}: not in Prowlarr's definitions — skipping (Prowlarr fetches"
      warn "${def}: Cardigann definitions shortly after start; a later re-run may find it)"
      return 0
    fi

    entry=$(printf '%s' "$entry" \
      | jq -c --argjson ap "$app_profile_id" '.appProfileId = $ap')

    # Born tagged for the Byparr proxy (see setup_byparr_proxy above). Empty
    # when the proxy section was skipped, in which case the tag is left alone.
    if [ -n "$BYPARR_TAG_ID" ]; then
      entry=$(printf '%s' "$entry" | jq -c --argjson tag "$BYPARR_TAG_ID" '.tags = [$tag]')
    fi

    if [ -n "$user" ]; then
      is_private=1
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
    else
      entry=$(printf '%s' "$entry" | jq -c '.enable = true | .priority = 25')
    fi

    # No forceSave: CreateProvider tests the indexer before saving, so every
    # indexer — public and private — gets a real connection test on create,
    # and for private trackers that test is the login check. On failure the
    # operator decides; forceSave is only used when they choose it (or there
    # is no terminal to ask).
    while :; do
      rc=0
      api POST /api/v1/indexer "$entry" >/dev/null || rc=$?
      if [ "$rc" -eq 0 ]; then
        info "${def}: added (connection test passed)"
        if [ "$creds_changed" -eq 1 ]; then
          # Prowlarr now holds the working credentials, but a re-run after a
          # config wipe would reuse the stale ones from the env file.
          warn "${def}: the working credentials differ from ${ENV_FILE} — update"
          warn "${def}: ARR_INDEXER_$(printf '%s' "$def" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')_USER/_PASS there"
        fi
        return 0
      fi

      if [ "$INTERACTIVE" -eq 0 ]; then
        warn "${def}: connection test failed (details above) — saving untested"
        rc=0
        api POST '/api/v1/indexer?forceSave=true' "$entry" >/dev/null || rc=$?
        if [ "$rc" -ne 0 ]; then
          warn "${def}: could not be added (exit ${rc})"
        else
          info "${def}: added untested — retest it from the Prowlarr UI"
        fi
        return 0
      fi

      # The failure details were printed by api() just above the prompt.
      choice=""
      while [ -z "$choice" ]; do
        if [ "$is_private" -eq 1 ]; then
          printf '    %s failed its test. [r]etry / [u]pdate credentials / [f]orce-save untested / [s]kip (default r): ' \
            "$def" >/dev/tty
        else
          printf '    %s failed its test. [r]etry / [f]orce-save untested / [s]kip (default r): ' \
            "$def" >/dev/tty
        fi
        # EOF on /dev/tty (^D) means nobody is answering — skip, don't loop.
        IFS= read -r ans </dev/tty || ans="s"
        case "$ans" in
          r|R|"") choice=r ;;
          u|U)    [ "$is_private" -eq 1 ] && choice=u ;;
          f|F)    choice=f ;;
          s|S)    choice=s ;;
        esac
      done

      case "$choice" in
        r) continue ;;
        u)
          printf '    %s username [%s]: ' "$def" "$user" >/dev/tty
          IFS= read -r ans </dev/tty || ans=""
          [ -n "$ans" ] && user="$ans"
          printf '    %s password (hidden; empty keeps current): ' "$def" >/dev/tty
          IFS= read -rs ans </dev/tty || ans=""
          printf '\n' >/dev/tty
          [ -n "$ans" ] && pass="$ans"
          creds_changed=1
          entry=$(printf '%s' "$entry" | jq -c --arg u "$user" --arg p "$pass" '
            .fields |= map(if   .name == "username" then .value = $u
                           elif .name == "password" then .value = $p
                           else . end)')
          continue ;;
        f)
          rc=0
          api POST '/api/v1/indexer?forceSave=true' "$entry" >/dev/null || rc=$?
          if [ "$rc" -ne 0 ]; then
            warn "${def}: could not be added even untested (exit ${rc})"
          else
            info "${def}: added untested — retest it from the Prowlarr UI"
          fi
          return 0 ;;
        s)
          info "${def}: skipped"
          return 0 ;;
      esac
    done
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

if [ "$ARR_INSTALL_INDEXERS" = "1" ]; then
  say "Adding indexers to Prowlarr"
  add_indexers
else
  say "Skipping indexers (ARR_INSTALL_INDEXERS=0)"
fi

# --- summary -----------------------------------------------------------------

say "Done"
info "Prowlarr: ${PROWLARR_URL} — indexers sync to Sonarr/Radarr automatically"
cat <<'EOF'

    Still manual: any private indexer not covered by ARR_INDEXERS_PRIVATE
    (cookie/captcha/2FA logins cannot be scripted) — add those in the
    Prowlarr UI.
EOF
