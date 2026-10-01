#!/usr/bin/env bash
# Configures Unmanic over its API: installs the two pinned community plugins,
# sets the worker count, and writes the Movies and Series libraries with both
# plugins enabled and configured. Idempotent — safe to re-run, and a re-run
# rewrites everything below, so on-UI edits to these settings do not survive it.
#
#   ./unmanic-bootstrap.sh
#   ./unmanic-bootstrap.sh --dry-run
#   ./unmanic-bootstrap.sh --verbose
#   UNMANIC_URL=http://apollo.local:8888 ./unmanic-bootstrap.sh
#
# Requires: curl, jq, sha256sum (or shasum). Reads three env files:
#   unmanic.env  — UNMANIC_URL, UNMANIC_SUBTITLE_LANGS, UNMANIC_CONFIGURE
#   sonarr.env   — SONARR_API_KEY
#   radarr.env   — RADARR_API_KEY
# None of these share a variable name, so they are sourced directly.
#
# The plugins come from community repos, which always serve their latest
# build. Each is pinned instead to a zip at a fixed commit, checked against a
# sha256 before upload — a repo that moves on cannot change what runs here.
#
# Unmanic has no API auth (LAN-only box). The Radarr/Sonarr keys are written
# into the audio plugin's per-library settings, which live in Unmanic's config
# dir: a copy, re-synced from sonarr.env/radarr.env on every run.
#
# Exit codes: 0 success, or a deliberate skip via UNMANIC_CONFIGURE=0.
#             1 precondition failure (missing key, unreachable service, bad
#               plugin download or checksum).
#             22 an API call returned a non-2xx, or a read-back did not match
#               what was written.

set -euo pipefail

DRY_RUN=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    -v|--verbose)   VERBOSE=1 ;;
    -h|--help)
      # Print the header block: every comment line after the shebang, stopping
      # at the first non-comment.
      sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
      exit 0 ;;
    *) echo "Unknown argument: ${arg}" >&2
       echo "Usage: ./unmanic-bootstrap.sh [--dry-run] [--verbose]" >&2
       exit 1 ;;
  esac
done

source_env() {
  # ./ prefixed only for a bare filename, so a relative name is read from here
  # rather than $PATH, without mangling an absolute override.
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

ENV_FILE="${ENV_FILE:-unmanic.env}"
source_env "$ENV_FILE"

SONARR_ENV_FILE="${SONARR_ENV_FILE:-sonarr.env}"
source_env "$SONARR_ENV_FILE"

RADARR_ENV_FILE="${RADARR_ENV_FILE:-radarr.env}"
source_env "$RADARR_ENV_FILE"

UNMANIC_URL="${UNMANIC_URL:-http://127.0.0.1:8888}"
UNMANIC_CONFIGURE="${UNMANIC_CONFIGURE:-1}"
# Empty must mean "keep every subtitle": keep_stream_by_language treats an
# empty subtitle list as "keep none" and strips them all, so it never gets one.
SUBTITLE_LANGS="${UNMANIC_SUBTITLE_LANGS:-}"
[ -n "$SUBTITLE_LANGS" ] || SUBTITLE_LANGS='*'

API="${UNMANIC_URL}/unmanic/api/v2"

# What the plugin, inside the unmanic container, uses to reach the arr apps
# over nas-net. Not RADARR_URL/SONARR_URL from their env files: those are the
# host-side addresses the bootstraps use.
RADARR_INTERNAL_URL="http://radarr:7878"
SONARR_INTERNAL_URL="http://sonarr:8989"

# Container paths, identical to radarr's/sonarr's: the audio plugin matches a
# file to its movie/series by path prefix, with no path mapping configured.
MOVIES_PATH=/media/movies
SERIES_PATH=/media/series

# One worker: each job rewrites a whole file on the HDD, and two in parallel
# only make the disk seek between them. A fresh Unmanic ships with zero, so
# nothing processes until this is set.
WORKERS=1

AUDIO_ID=unmanic_plugin_keep_original_language_audio
AUDIO_VERSION=1.0.0
AUDIO_URL="https://raw.githubusercontent.com/MatthijsSmets/unmanic-plugins/73b23dbc0dddb1ccb3c5ade19baf7791c4c76b92/${AUDIO_ID}/${AUDIO_ID}-${AUDIO_VERSION}.zip"
AUDIO_SHA256=beb6ca4fab8e281308eaa6e5721d5bb613c218fcbabe82014edd1667752ac751

SUBS_ID=keep_stream_by_language
SUBS_VERSION=0.3.3
SUBS_URL="https://raw.githubusercontent.com/yajrendrag/unmanic-plugins/36367744fae5696e2141ba5ab9f3fdc30d676766/${SUBS_ID}/${SUBS_ID}-${SUBS_VERSION}.zip"
SUBS_SHA256=07d223b8d7585e189ab416f6c292234442f23dd93a0213c8a42f93746099613d

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required." >&2; exit 1; }
done
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "ERROR: sha256sum or shasum is required." >&2; exit 1
fi

say()  { echo "==> $1"; }
info() { echo "    $1"; }
fail() { echo "    ERROR: $1" >&2; }

# Masks the arr keys wherever they sit in a library write: inside each enabled
# plugin's flat `settings` object, keyed by the plugin's own label.
mask() {
  printf '%s' "$1" | jq -c '
    (.. | objects | select(has("settings")) | .settings | objects)
      |= with_entries(if (.key | test("api key"; "i")) then .value = "***" else . end)' \
    2>/dev/null || echo '<unprintable>'
}

api() {
  # api <method> <path> [json-body]
  # stdout is the response body only; all logging goes to stderr.
  local method="$1" path="$2" body="${3:-}"
  # No -f: it discards the error body, which is where Unmanic puts its
  # `error` and `messages` fields.
  local -a args=(-sS -X "$method" "${API}${path}" -H 'Content-Type: application/json')
  [ -n "$body" ] && args+=(-d "$body")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [dry-run] ${method} ${API}${path}" >&2
    [ -n "$body" ] && printf '%s\n' "$(mask "$body")" | sed 's/^/              /' >&2
    echo '{}'
    return 0
  fi

  if [ "$VERBOSE" -eq 1 ]; then
    echo "    --> ${method} ${API}${path}" >&2
    [ -n "$body" ] && printf '        body: %s\n' "$(mask "$body")" >&2
  fi

  local raw rc=0 status out
  raw=$(curl "${args[@]}" -w $'\n%{http_code}') || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: ${method} ${API}${path} — curl failed (exit ${rc})" >&2
    return "$rc"
  fi
  status="${raw##*$'\n'}"
  out="${raw%$'\n'*}"

  [ "$VERBOSE" -eq 1 ] && echo "    <-- ${status} ($(printf '%s' "$out" | wc -c | tr -d ' ') bytes)" >&2

  case "$status" in
    2*) printf '%s' "$out"; return 0 ;;
  esac

  echo "ERROR: ${method} ${API}${path} returned HTTP ${status}" >&2
  [ -n "$body" ] && printf '       sent: %s\n' "$(mask "$body")" >&2
  if [ -n "$out" ]; then
    printf '       said: %s\n' "$(printf '%s' "$out" | head -c 500)" >&2
  else
    printf '       said: <empty body>\n' >&2
  fi
  return 22
}

if [ "$UNMANIC_CONFIGURE" != "1" ]; then
  say "Skipping Unmanic (UNMANIC_CONFIGURE=0)"
  exit 0
fi

[ "$DRY_RUN" -eq 1 ] && say "DRY RUN — no requests will be sent to Unmanic"

# Without both keys the audio plugin cannot look up a single original
# language, so every file would be skipped — fail now rather than configure
# a no-op.
if [ "$DRY_RUN" -eq 0 ]; then
  missing=0
  [ -n "${RADARR_API_KEY:-}" ] || { fail "RADARR_API_KEY is not set (looked in ${RADARR_ENV_FILE})"; missing=1; }
  [ -n "${SONARR_API_KEY:-}" ] || { fail "SONARR_API_KEY is not set (looked in ${SONARR_ENV_FILE})"; missing=1; }
  if [ "$missing" -eq 1 ]; then
    fail "The audio plugin looks up each file's original language in Radarr/Sonarr."
    fail "Run: sudo ./nas install radarr sonarr — it generates both keys."
    exit 1
  fi
fi
: "${RADARR_API_KEY:=<unset>}" "${SONARR_API_KEY:=<unset>}"

# --- readiness ---------------------------------------------------------------

wait_for_unmanic() {
  local probe
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would wait for unmanic at ${UNMANIC_URL}"
    return 0
  fi
  # The JSON shape is checked because a wrong port can 200 with something else.
  for _ in $(seq 1 90); do
    if probe=$(curl -fsS --max-time 5 "${API}/version/read" 2>/dev/null) \
       && printf '%s' "$probe" | jq -e '.version' >/dev/null 2>&1; then
      info "unmanic $(printf '%s' "$probe" | jq -r '.version') ready at ${UNMANIC_URL}"
      return 0
    fi
    sleep 2
  done
  fail "unmanic did not answer at ${API}/version/read after 180s"
  fail "check: docker logs unmanic — then re-run ./unmanic-bootstrap.sh"
  return 1
}

say "Configuring Unmanic"
wait_for_unmanic || exit 1

# --- plugins -----------------------------------------------------------------

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

installed_version() {
  # The table endpoint filters by search text; the exact id is matched here.
  api POST /plugins/installed "$(jq -n --arg s "$1" '{start: 0, length: 100, search_value: $s}')" \
    | jq -r --arg id "$1" '(.results // [])[] | select(.plugin_id == $id) | .version'
}

install_plugin() {
  # install_plugin <id> <version> <url> <sha256>
  local id="$1" version="$2" url="$3" want_sha="$4"
  local zip="${WORKDIR}/${id}-${version}.zip" have got raw status

  have=$(installed_version "$id") || return 22
  if [ "$have" = "$version" ]; then
    info "${id} ${version}: installed"
    return 0
  fi

  # Fetched even on a dry run: it proves the pin still resolves and still
  # matches its checksum, and it touches nothing but a temp dir.
  if ! curl -fsSL --max-time 120 -o "$zip" "$url"; then
    fail "${id}: download failed — ${url}"
    return 1
  fi
  got=$(sha256 "$zip")
  if [ "$got" != "$want_sha" ]; then
    fail "${id}: checksum mismatch — refusing to install"
    fail "  expected ${want_sha}"
    fail "  got      ${got}"
    fail "  from     ${url}"
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] ${id}: checksum ok; would upload ${version} (installed: ${have:-none})"
    return 0
  fi

  # Unmanic parses this multipart body by hand: it expects the boundary line,
  # then Content-Disposition carrying the filename, then Content-Type — the
  # shape curl -F produces for a file part with an explicit type.
  [ "$VERBOSE" -eq 1 ] && echo "    --> POST ${API}/upload/plugin/file (${id}-${version}.zip)" >&2
  raw=$(curl -sS -X POST "${API}/upload/plugin/file" \
          -F "fileName=@${zip};type=application/zip" -w $'\n%{http_code}') || {
    fail "${id}: upload failed (curl)"; return 1; }
  status="${raw##*$'\n'}"
  case "$status" in
    2*) ;;
    *) fail "${id}: upload returned HTTP ${status}"
       fail "said: $(printf '%s' "${raw%$'\n'*}" | head -c 500)"
       fail "the cause is in: docker logs unmanic"
       return 22 ;;
  esac

  # The upload's 200 covers the unpack, not the database row — read it back.
  have=$(installed_version "$id") || return 22
  if [ "$have" != "$version" ]; then
    fail "${id}: uploaded, but Unmanic reports version '${have:-none}', not ${version}"
    fail "the cause is in: docker logs unmanic"
    return 22
  fi
  info "${id} ${version}: installed (was: ${have:-none})"
}

install_plugin "$AUDIO_ID" "$AUDIO_VERSION" "$AUDIO_URL" "$AUDIO_SHA256" || exit $?
install_plugin "$SUBS_ID"  "$SUBS_VERSION"  "$SUBS_URL"  "$SUBS_SHA256"  || exit $?

# --- workers -----------------------------------------------------------------

# GET-modify-POST: the write takes the whole group object, schedules and tags
# included, so it is posted back as read with only the count changed.
groups=$(api GET /settings/worker_groups) || exit 22
group=$(printf '%s' "$groups" | jq -c '(.worker_groups // []) | sort_by(.id) | .[0] // empty')
if [ -z "$group" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would set the default worker group to ${WORKERS} worker(s)"
  else
    fail "Unmanic reported no worker groups"; exit 22
  fi
elif [ "$(printf '%s' "$group" | jq -r '.number_of_workers')" = "$WORKERS" ]; then
  info "workers: ${WORKERS}"
else
  api POST /settings/worker_group/write \
    "$(printf '%s' "$group" | jq -c --argjson n "$WORKERS" '.number_of_workers = $n')" >/dev/null || exit 22
  info "workers: set to ${WORKERS}"
fi

# --- libraries ---------------------------------------------------------------

libraries=$(api GET /settings/libraries) || exit 22

library_id_for() {
  # Matched by path, so a rename in the UI still finds it. Movies falls back
  # to library 1: Unmanic creates it on first boot (pointing at /library,
  # which is not mounted) and refuses to delete it, so it is repurposed.
  # 0 makes the write create a new library.
  local path="$1" fallback="$2"
  printf '%s' "$libraries" | jq -r --arg p "$path" --argjson f "$fallback" \
    '(.libraries // []) | (map(select(.path == $p)) | .[0].id) // $f'
}

# Scanner off: a scheduled scan walks the whole library and wakes the HDD.
# inotify on: event-driven, it fires only when Radarr/Sonarr write a file —
# the disk is awake for the import anyway. Existing files are never queued
# by this; a one-off scan from the UI does that.
#
# Audio plugin: "Keep all" keeps every original-language track, commentary
# included; untagged/`und` tracks do not count as original and are removed
# when a tagged one exists. Any failure (API down, no match, no tagged
# original track) is a no-op.
#
# Subtitle plugin: audio `*` hands audio entirely to the plugin above, and
# keep_commentary stays on so it never removes an audio track on its own.
# reorder_kept is off for the same reason. TMDB lookup stays off.
library_body() {
  # library_body <id> <name> <path>
  jq -n --argjson id "$1" --arg name "$2" --arg path "$3" \
        --arg audio "$AUDIO_ID" --arg subs "$SUBS_ID" \
        --arg rurl "$RADARR_INTERNAL_URL" --arg rkey "$RADARR_API_KEY" \
        --arg surl "$SONARR_INTERNAL_URL" --arg skey "$SONARR_API_KEY" \
        --arg langs "$SUBTITLE_LANGS" '
    {
      library_config: {
        id: $id, name: $name, path: $path, locked: false,
        enable_remote_only: false, enable_scanner: false, enable_inotify: true,
        priority_score: 0, tags: []
      },
      plugins: {
        enabled_plugins: [
          { plugin_id: $audio, has_config: true, settings: {
              "Selection mode": "Keep all original-language audio",
              "Radarr URL": $rurl, "Radarr API key": $rkey,
              "Sonarr URL": $surl, "Sonarr API key": $skey,
              "Path mappings": ""
          } },
          { plugin_id: $subs, has_config: true, settings: {
              audio_languages: "*", subtitle_languages: $langs,
              keep_undefined: true, keep_commentary: true, fail_safe: true,
              reorder_kept: false, keep_original_audio: false
          } }
        ],
        plugin_flow: {
          "library_management.file_test": [$audio, $subs],
          "worker.process":               [$audio, $subs],
          "postprocessor.file_move":      [],
          "postprocessor.task_result":    [$subs]
        }
      }
    }'
}

# The library write saves plugin settings but discards whether that save
# worked, so a renamed setting key in a future plugin version would pass
# silently. Read back one value per plugin instead.
setting_value() {
  # setting_value <plugin-id> <library-id> <key>
  api POST /plugins/info "$(jq -n --arg p "$1" --argjson l "$2" \
      '{plugin_id: $p, library_id: $l, prefer_local: true}')" \
    | jq -r --arg k "$3" '(.settings // [])[] | select(.key == $k) | .value | tostring'
}

WRITE_RC=0
write_library() {
  # write_library <name> <path> <fallback-id>
  local name="$1" path="$2" fallback="$3" id got
  id=$(library_id_for "$path" "$fallback")
  api POST /settings/library/write "$(library_body "$id" "$name" "$path")" >/dev/null || {
    fail "${name}: library write failed"; WRITE_RC=22; return 0; }

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] ${name}: would write ${path} (library id ${id}, 0 = new)"
    return 0
  fi

  # A new library has no id until the write returns; find it again by path.
  libraries=$(api GET /settings/libraries) || { WRITE_RC=22; return 0; }
  id=$(library_id_for "$path" 0)
  if [ "$id" = "0" ]; then
    fail "${name}: written, but no library with path ${path} exists afterwards"
    WRITE_RC=22; return 0
  fi

  got=$(setting_value "$AUDIO_ID" "$id" "Radarr URL") || got=""
  if [ "$got" != "$RADARR_INTERNAL_URL" ]; then
    fail "${name}: ${AUDIO_ID} setting 'Radarr URL' reads back '${got}', expected ${RADARR_INTERNAL_URL}"
    WRITE_RC=22; return 0
  fi
  got=$(setting_value "$SUBS_ID" "$id" "subtitle_languages") || got=""
  if [ "$got" != "$SUBTITLE_LANGS" ]; then
    fail "${name}: ${SUBS_ID} setting 'subtitle_languages' reads back '${got}', expected ${SUBTITLE_LANGS}"
    WRITE_RC=22; return 0
  fi
  info "${name}: ${path} (library ${id}), inotify on, scanner off, subtitles kept: ${SUBTITLE_LANGS}"
}

write_library Movies "$MOVIES_PATH" 1
write_library Series "$SERIES_PATH" 0

if [ "$WRITE_RC" -ne 0 ]; then
  say "Done, with errors"
  fail "A library is not fully configured — fix the cause above and re-run:"
  fail "  ./unmanic-bootstrap.sh --verbose"
  exit "$WRITE_RC"
fi

say "Done"
info "Unmanic: ${UNMANIC_URL}"
info "Files already in the library are not queued; start a library scan from the UI once to clean them."
exit 0
