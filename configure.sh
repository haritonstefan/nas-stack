#!/usr/bin/env bash
# Interactive wizard that fills in core.env / jellyfin.env / arr.env.
# Writes only the .env files; sudo ./up.sh does everything else.

set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Guided setup for the .env files, meant to run before `sudo ./up.sh`:
  ./configure.sh && sudo ./up.sh

Detects host facts (docker GID, render GID, LAN IP, timezone), asks once for
values shared between tiers (media dirs, PUID/PGID), prompts for the handful
of values that need a human (Jellyfin admin password, allowed hosts,
indexers + private-tracker credentials), and writes the .env files only after
showing a per-file summary you confirm.

Re-runnable: current .env values become the defaults. The generated secrets
(arr API keys, qBittorrent password) are managed by up.sh and never touched.
Optional: up.sh works without this script, from hand-edited .env files.

  ./configure.sh                # quick mode, all tiers
  ./configure.sh --advanced     # walk every variable, with help text
  ./configure.sh --dry-run      # full wizard, prints writes, changes nothing
  ./configure.sh jellyfin arr   # only these tiers
EOF
}

ADVANCED=0
DRY_RUN=0
STACKS=""

for arg in "$@"; do
  case "$arg" in
    --advanced)        ADVANCED=1 ;;
    --dry-run)         DRY_RUN=1 ;;
    core|jellyfin|arr)
      case " $STACKS " in
        *" $arg "*) ;;
        *) STACKS="${STACKS} ${arg}" ;;
      esac ;;
    -h|--help)         usage; exit 0 ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: ./configure.sh [--advanced] [--dry-run] [core] [jellyfin] [arr]" >&2
      exit 1 ;;
  esac
done
STACKS="${STACKS:- core jellyfin arr}"

want() { case " $STACKS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1" >&2; }

# A wizard is prompts; without a terminal there is nothing it can do.
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "ERROR: configure.sh is interactive and needs a terminal." >&2
  echo "       Edit the .env files by hand instead — up.sh runs headless." >&2
  exit 1
fi

# Files this script writes under sudo would otherwise end up root-owned inside
# a user-owned repo, leaving the invoking user unable to read their own .env.
IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1
repo_own() {
  [ "$IS_ROOT" -eq 1 ] && [ -n "${SUDO_UID:-}" ] || return 0
  chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$1"
}

# bash 4 gained read -i (pre-filled editable input); older bash (macOS 3.2)
# falls back to [default]-in-prompt, empty answer keeps the default.
READ_EDITABLE=0
[ "${BASH_VERSINFO[0]}" -ge 4 ] && READ_EDITABLE=1

# --- prompt helpers ------------------------------------------------------------

# ask <prompt> <default> [validator] — result in REPLY_VALUE
ask() {
  local prompt="$1" default="$2" validator="${3:-}" val
  while :; do
    if [ "$READ_EDITABLE" -eq 1 ]; then
      IFS= read -r -e -i "$default" -p "    ${prompt}: " val
    else
      IFS= read -r -e -p "    ${prompt} [${default}]: " val
      [ -n "$val" ] || val="$default"
    fi
    if [ -n "$validator" ] && ! "$validator" "$val"; then continue; fi
    REPLY_VALUE="$val"
    return 0
  done
}

# Masked, non-empty, confirmed twice — a typo in the Jellyfin password is only
# discovered after the one-shot wizard has closed around it.
ask_secret() { # ask_secret <prompt> — result in REPLY_VALUE
  local val confirm
  while :; do
    printf '    %s: ' "$1"
    IFS= read -rs val; printf '\n'
    if [ -z "$val" ]; then
      warn "cannot be empty"
      continue
    fi
    printf '    Confirm: '
    IFS= read -rs confirm; printf '\n'
    [ "$val" = "$confirm" ] && break
    warn "did not match, try again"
  done
  REPLY_VALUE="$val"
}

ask_yn() { # ask_yn <prompt> <Y|N> — returns 0 for yes
  local prompt="$1" def="$2" hint ans
  [ "$def" = "Y" ] && hint="Y/n" || hint="y/N"
  while :; do
    printf '    %s [%s]: ' "$prompt" "$hint"
    IFS= read -r ans
    case "${ans:-$def}" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

# --- validators (each warns and returns 1 on bad input) -------------------------

is_port() {
  case "$1" in
    ''|*[!0-9]*) ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] && return 0 ;;
  esac
  warn "must be a port number 1-65535"; return 1
}
is_gid() {
  case "$1" in
    ''|*[!0-9]*) warn "must be numeric"; return 1 ;;
  esac
  return 0
}
is_abs_dir() {
  case "$1" in
    /*) case "/${1}/" in *"/../"*) ;; *) return 0 ;; esac ;;
  esac
  warn "must be an absolute path without .."; return 1
}
is_nonempty() {
  [ -n "$1" ] && return 0
  warn "cannot be empty"; return 1
}
is_01() {
  case "$1" in 0|1) return 0 ;; esac
  warn "must be 0 or 1"; return 1
}
# A real CIDR check, not just shape — 999.9.9.9/99 must not pass.
is_subnet() {
  local ip mask o n=0 ok=0
  case "$1" in
    *[!0-9./]*|''|*/*/*|/*|*/) ;;
    */*)
      ip="${1%/*}" mask="${1#*/}"
      ok=1
      case "$mask" in
        *[!0-9]*) ok=0 ;;
        *) { [ "${#mask}" -le 2 ] && [ "$mask" -le 32 ]; } || ok=0 ;;
      esac
      local IFS=.
      for o in $ip; do
        n=$((n + 1))
        { [ -n "$o" ] && [ "${#o}" -le 3 ] && [ "$o" -le 255 ]; } || ok=0
      done
      [ "$n" -eq 4 ] || ok=0 ;;
  esac
  [ "$ok" -eq 1 ] && return 0
  warn "must be IPv4 CIDR notation, e.g. 192.168.0.0/24"; return 1
}
# Both land in Session\GlobalMaxRatio / GlobalMaxSeedingMinutes, where -1
# means no cap.
is_seed_ratio() {
  case "$1" in
    -1) return 0 ;;
    ''|*[!0-9.]*|*.*.*|.*|*.) ;;
    *) return 0 ;;
  esac
  warn "must be a ratio like 2 or 1.5, or -1 for no cap"; return 1
}
is_seed_minutes() {
  case "$1" in
    -1) return 0 ;;
    ''|*[!0-9]*) ;;
    *) return 0 ;;
  esac
  warn "must be a whole number of minutes, or -1 for no cap"; return 1
}
is_csv() {
  case "$1" in
    ''|*' '*) warn "comma-separated, no spaces"; return 1 ;;
    *[!A-Za-z0-9,._-]*) warn "definition names are letters/digits/._- only"; return 1 ;;
  esac
  return 0
}
is_defname() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) warn "must be a single Prowlarr definition name"; return 1 ;;
  esac
  return 0
}
# No wildcards or CIDR — Homepage matches each entry literally, so 192.168.0.*
# or a /24 rejects everything; a bare * disables the check entirely (spec 7).
is_hosts_list() {
  local v="$1" t
  if [ "$v" = "*" ]; then
    warn "'*' disables the Host check entirely — accepted, but listing hosts is safer"
    return 0
  fi
  if [ -z "$v" ]; then warn "cannot be empty"; return 1; fi
  local IFS=','
  for t in $v; do
    case "$t" in
      ''|*'*'*|*/*)
        warn "no wildcards or CIDR — each name/IP listed in full (got '${t}')"; return 1 ;;
      *[!A-Za-z0-9.-]*)
        warn "invalid host '${t}'"; return 1 ;;
    esac
  done
  return 0
}

validator_for() {
  case "$1" in
    *_PORT)                          printf 'is_port' ;;
    PUID|PGID|UMASK|*_GID)           printf 'is_gid' ;;
    *_DIR|*_ROOT_FOLDER)             printf 'is_abs_dir' ;;
    JELLYFIN_LOCAL_SUBNET)           printf 'is_subnet' ;;
    HOMEPAGE_ALLOWED_HOSTS)          printf 'is_hosts_list' ;;
    ARR_INDEXERS|ARR_INDEXERS_PRIVATE) printf 'is_csv' ;;
    QBITTORRENT_SEED_RATIO)          printf 'is_seed_ratio' ;;
    QBITTORRENT_SEED_MINUTES)        printf 'is_seed_minutes' ;;
    JELLYFIN_SCAN_ON_BOOTSTRAP|JELLYFIN_INSTALL_DLNA) printf 'is_01' ;;
    # ARR_CONFIGURE_SEERR is SEERR_CONFIGURE's pre-rename name, still honoured.
    ARR_INSTALL_INDEXERS|ARR_RUN_CONFIGARR|SEERR_CONFIGURE|ARR_CONFIGURE_SEERR) printf 'is_01' ;;
    *)                               printf '' ;;
  esac
}

# --- env file read/write --------------------------------------------------------

# Generated once by up.sh (or, for the Jellyfin widget values, minted by
# jellyfin-bootstrap.sh) and load-bearing forever — never written, cleared,
# or displayed here.
is_secret() {
  case "$1" in
    SONARR_API_KEY|RADARR_API_KEY|PROWLARR_API_KEY|SEERR_API_KEY|QBITTORRENT_PASSWORD)
      return 0 ;;
    JELLYFIN_API_KEY|JELLYFIN_SCAN_TASK_ID)
      return 0 ;;
  esac
  return 1
}

# Reads the value exactly as every consumer will (shell-sourcing un-escapes
# whatever quoting the file uses). Example first, file over it — so a variable
# missing from the .env falls back to the example's default.
env_get() { # env_get <tier> <name>
  local tier="$1" name="$2"
  ( set +eu
    # shellcheck disable=SC1090
    [ -f "${tier}.env.example" ] && . "./${tier}.env.example" >/dev/null 2>&1
    # shellcheck disable=SC1090
    [ -f "${tier}.env" ] && . "./${tier}.env" >/dev/null 2>&1
    eval "printf '%s' \"\${${name}-}\"" ) 2>/dev/null || true
}

env_get_example() { # env_get_example <tier> <name>
  local tier="$1" name="$2"
  ( set +eu
    # shellcheck disable=SC1090
    [ -f "${tier}.env.example" ] && . "./${tier}.env.example" >/dev/null 2>&1
    eval "printf '%s' \"\${${name}-}\"" ) 2>/dev/null || true
}

# Replace the first ^name= line in place, preserving file order and comments
# (up.sh's set_env_var is grep-v-append, which would scramble them); append
# under a marker if the name is not present. Pure bash on purpose: a sed
# replacement side would corrupt on & or \ in a password.
# Quoting: bare when the value has only safe chars (keeps diffs vs the example
# clean); otherwise single-quoted with close-escape-reopen — must stay
# equivalent to up.sh set_env_var's escaping, since these files are dual-parsed
# (shell-sourced and compose dotenv) and both read single quotes literally.
env_set() { # env_set <file> <name> <value>
  local file="$1" name="$2" value="$3" line new_line escaped replaced=0
  if printf '%s' "$value" | LC_ALL=C grep -Eq '^[A-Za-z0-9_./:@,+=-]*$'; then
    new_line="${name}=${value}"
  else
    escaped=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
    new_line="${name}='${escaped}'"
  fi
  : > "${file}.tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$replaced" -eq 0 ]; then
      case "$line" in
        "${name}="*) printf '%s\n' "$new_line" >> "${file}.tmp"; replaced=1; continue ;;
      esac
    fi
    printf '%s\n' "$line" >> "${file}.tmp"
  done < "$file"
  if [ "$replaced" -eq 0 ]; then
    grep -q '^# --- added by configure.sh ---$' "${file}.tmp" \
      || printf '\n# --- added by configure.sh ---\n' >> "${file}.tmp"
    printf '%s\n' "$new_line" >> "${file}.tmp"
  fi
  cat "${file}.tmp" > "$file"   # keeps the original owner and mode
  rm -f "${file}.tmp"
}

example_vars() { # variable names in <tier>.env.example, file order
  grep -E '^[A-Z][A-Z0-9_]*=' "${1}.env.example" | cut -d= -f1
}

# The contiguous # comment block immediately above VAR= in the example — used
# as advanced-mode help text, so it tracks example edits for free.
help_for() { # help_for <tier> <var>
  awk -v var="$2" '
    /^#/ { buf = buf $0 "\n"; next }
    index($0, var "=") == 1 { printf "%s", buf; exit }
    { buf = "" }
  ' "${1}.env.example"
}

# --- detection (each degrades to empty — nothing here may be fatal) --------------

detect_tz() {
  if [ -r /etc/timezone ]; then
    tr -d '[:space:]' < /etc/timezone
    return 0
  fi
  if [ -L /etc/localtime ]; then
    readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||'
  fi
  return 0
}
detect_docker_gid() {
  command -v getent >/dev/null 2>&1 || return 0
  getent group docker 2>/dev/null | cut -d: -f3 || true
  return 0
}
detect_render_gid() {
  if [ -e /dev/dri/renderD128 ]; then
    stat -c %g /dev/dri/renderD128 2>/dev/null && return 0
  fi
  command -v getent >/dev/null 2>&1 || return 0
  getent group render 2>/dev/null | cut -d: -f3 || true
  return 0
}
detect_lan_ip() {
  local out=""
  if command -v ip >/dev/null 2>&1; then
    out=$(ip route get 1.1.1.1 2>/dev/null \
      | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}') || out=""
  fi
  if [ -z "$out" ]; then
    out=$(hostname -I 2>/dev/null | awk '{print $1}') || out=""
  fi
  if [ -z "$out" ] && command -v ipconfig >/dev/null 2>&1; then
    out=$(ipconfig getifaddr en0 2>/dev/null) || out=""
  fi
  printf '%s' "$out"
  return 0
}
detect_hostname() {
  local h
  h=$(hostname -s 2>/dev/null) || h=""
  [ -n "$h" ] && printf '%s.local' "$h"
  return 0
}

# Detection wins only while the .env still holds the example's default — a
# value the user changed by hand is never overridden by a probe.
pick_default() { # pick_default <current> <example> <detected>
  if [ -n "$3" ] && [ "$1" = "$2" ]; then
    printf '%s' "$3"
  else
    printf '%s' "$1"
  fi
}

# --- staging --------------------------------------------------------------------
# Nothing is written until a tier's summary is accepted, so Ctrl-C loses at
# most the current tier. Indexed arrays only (portable to old bash).

# shellcheck disable=SC2034  # read via eval indirection in sget/stage_count
CORE_KEYS=()     CORE_VALS=()     CORE_OLD=()
# shellcheck disable=SC2034
JELLYFIN_KEYS=() JELLYFIN_VALS=() JELLYFIN_OLD=()
# shellcheck disable=SC2034
ARR_KEYS=()      ARR_VALS=()      ARR_OLD=()

prefix_for() {
  case "$1" in
    core) printf 'CORE' ;;
    jellyfin) printf 'JELLYFIN' ;;
    arr) printf 'ARR' ;;
  esac
}

sget() { eval "printf '%s' \"\${${1}[${2}]-}\""; }
stage_count() { eval "printf '%s' \"\${#${1}_KEYS[@]}\""; }

stage() { # stage <tier> <name> <value>
  local tier="$1" name="$2" value="$3" P n i old
  want "$tier" || return 0
  if is_secret "$name"; then
    warn "refusing to stage ${name} — managed by up.sh"
    return 0
  fi
  P=$(prefix_for "$tier")
  n=$(stage_count "$P")
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$(sget "${P}_KEYS" "$i")" = "$name" ]; then
      eval "${P}_VALS[${i}]=\$value"
      return 0
    fi
    i=$((i + 1))
  done
  old=$(env_get "$tier" "$name")
  eval "${P}_KEYS[${n}]=\$name; ${P}_VALS[${n}]=\$value; ${P}_OLD[${n}]=\$old"
}

# Stage a shared value into every wanted tier whose example defines it.
stage_where_defined() { # stage_where_defined <name> <value>
  local t
  for t in core jellyfin arr; do
    want "$t" || continue
    grep -q "^${1}=" "${t}.env.example" && stage "$t" "$1" "$2"
  done
  return 0
}

disp() { # disp <name> <value> — passwords masked
  local shown="$2"
  case "$1" in
    *PASSWORD*|*_PASS) [ -n "$2" ] && shown='********' ;;
  esac
  [ -n "$shown" ] && printf '%s' "$shown" || printf '(empty)'
}

print_stage() { # print_stage <tier>
  local tier="$1" P n i name val old
  P=$(prefix_for "$tier")
  n=$(stage_count "$P")
  printf '\n'
  i=0
  while [ "$i" -lt "$n" ]; do
    name=$(sget "${P}_KEYS" "$i")
    val=$(sget "${P}_VALS" "$i")
    old=$(sget "${P}_OLD" "$i")
    if [ "$val" != "$old" ]; then
      printf '    %2d) %-28s = %s  \033[33m(was: %s)\033[0m\n' \
        $((i + 1)) "$name" "$(disp "$name" "$val")" "$(disp "$name" "$old")"
    else
      printf '    %2d) %-28s = %s\n' $((i + 1)) "$name" "$(disp "$name" "$val")"
    fi
    i=$((i + 1))
  done
  if [ "$tier" = "arr" ]; then
    info "(the arr API keys and qBittorrent password are generated by up.sh, never here)"
  fi
}

WRITTEN_TIERS=""
trap 'printf "\n"; rm -f core.env.tmp jellyfin.env.tmp arr.env.tmp; warn "interrupted — written:${WRITTEN_TIERS:- nothing}; everything else untouched"; exit 130' INT

write_tier() { # write_tier <tier>
  local tier="$1" P n i name val
  P=$(prefix_for "$tier")
  n=$(stage_count "$P")
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ ! -f "${tier}.env" ]; then
      cp "${tier}.env.example" "${tier}.env"
      repo_own "${tier}.env"
      info "${tier}.env created from ${tier}.env.example"
    fi
    # jellyfin.env carries the admin password, arr.env the tracker credentials
    # (and, once up.sh has run, the API keys) — restrict before writing them.
    case "$tier" in jellyfin|arr) chmod 600 "${tier}.env" ;; esac
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    name=$(sget "${P}_KEYS" "$i")
    val=$(sget "${P}_VALS" "$i")
    if [ "$DRY_RUN" -eq 1 ]; then
      # Not disp: an empty value must print as NAME= (what would be written),
      # not as the review table's "(empty)" placeholder.
      local shown="$val"
      case "$name" in *PASSWORD*|*_PASS) [ -n "$val" ] && shown='********' ;; esac
      printf '    [dry-run] %s.env: %s=%s\n' "$tier" "$name" "$shown"
    else
      env_set "${tier}.env" "$name" "$val"
    fi
    i=$((i + 1))
  done
  if [ "$DRY_RUN" -eq 0 ]; then
    repo_own "${tier}.env"
    info "${n} value(s) written to ${tier}.env"
    WRITTEN_TIERS="${WRITTEN_TIERS} ${tier}"
  fi
}

review_and_write() { # review_and_write <tier>
  local tier="$1" P n i name val ans idx vfun
  want "$tier" || return 0
  P=$(prefix_for "$tier")
  n=$(stage_count "$P")
  [ "$n" -eq 0 ] && return 0
  say "Review — ${tier}.env"
  print_stage "$tier"
  while :; do
    printf '\n    [Enter] write   e <n> edit item   s skip this file   q quit: '
    IFS= read -r ans
    case "$ans" in
      '') write_tier "$tier"; return 0 ;;
      s)  warn "skipped — nothing written to ${tier}.env"; return 0 ;;
      q)  warn "quit — written so far:${WRITTEN_TIERS:- nothing}"; exit 1 ;;
      e*)
        idx="${ans#e}"
        idx="${idx//[[:space:]]/}"
        case "$idx" in ''|*[!0-9]*) warn "usage: e <item number>"; continue ;; esac
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "$n" ]; then
          warn "no item ${idx}"
          continue
        fi
        i=$((idx - 1))
        name=$(sget "${P}_KEYS" "$i")
        case "$name" in
          *PASSWORD*|*_PASS) ask_secret "New value for ${name}" ;;
          *)
            vfun=$(validator_for "$name")
            val=$(sget "${P}_VALS" "$i")
            ask "$name" "$val" "$vfun" ;;
        esac
        eval "${P}_VALS[${i}]=\$REPLY_VALUE"
        print_stage "$tier" ;;
      *) warn "unrecognized: ${ans}" ;;
    esac
  done
}

# --- drift against the examples --------------------------------------------------

# A variable added to the example since the .env was written gets staged with
# the example's default (advanced mode will still prompt it in the walk).
# Variables the example no longer has are warned about, never deleted.
drift_sync() { # drift_sync <tier>
  local tier="$1" var
  [ -f "${tier}.env" ] || return 0
  for var in $(example_vars "$tier"); do
    is_secret "$var" && continue
    grep -q "^${var}=" "${tier}.env" && continue
    info "${tier}.env is missing ${var} (new in the example) — staging the default"
    stage "$tier" "$var" "$(env_get_example "$tier" "$var")"
  done
  # shellcheck disable=SC2013  # names match ^[A-Z][A-Z0-9_]*= — single words
  for var in $(grep -E '^[A-Z][A-Z0-9_]*=' "${tier}.env" | cut -d= -f1); do
    grep -q "^${var}=" "${tier}.env.example" && continue
    case "$var" in ARR_INDEXER_*) continue ;; esac   # custom tracker credentials
    warn "${tier}.env has ${var}, which is not in ${tier}.env.example — kept as-is"
  done
  return 0
}

# --- advanced walk ----------------------------------------------------------------

# Variables owned by a dedicated prompt (or by up.sh) — the walk skips them.
skip_in_walk() { # skip_in_walk <tier> <var>
  is_secret "$2" && return 0
  case "$2" in TZ|PUID|PGID|DOCKER_GID) return 0 ;; esac
  case "${1}:${2}" in
    core:HOMEPAGE_ALLOWED_HOSTS) return 0 ;;
    jellyfin:MEDIA_*_DIR) return 0 ;;
    jellyfin:JELLYFIN_SERVER_NAME|jellyfin:JELLYFIN_ADMIN_USER|jellyfin:JELLYFIN_ADMIN_PASSWORD) return 0 ;;
    jellyfin:RENDER_GID|jellyfin:JELLYFIN_LOCAL_SUBNET|jellyfin:JELLYFIN_LAN_HOST) return 0 ;;
    arr:ARR_MOVIES_DIR|arr:ARR_SERIES_DIR|arr:SEERR_JELLYFIN_HOST) return 0 ;;
    arr:ARR_INSTALL_INDEXERS|arr:ARR_INDEXERS|arr:ARR_INDEXERS_PRIVATE|arr:ARR_INDEXER_*) return 0 ;;
  esac
  return 1
}

walk_tier() { # walk_tier <tier> — advanced mode: every remaining example var
  local tier="$1" var help cur
  for var in $(example_vars "$tier"); do
    skip_in_walk "$tier" "$var" && continue
    help=$(help_for "$tier" "$var")
    if [ -n "$help" ]; then
      printf '\n'
      printf '%s\n' "$help" | sed 's/^#/    /'
    fi
    cur=$(env_get "$tier" "$var")
    ask "$var" "$cur" "$(validator_for "$var")"
    stage "$tier" "$var" "$REPLY_VALUE"
    case "$var" in
      *_CONFIG_DIR|DOWNLOADS_DIR)
        case "$REPLY_VALUE" in
          /volume2/docker/*) ;;
          *) warn "outside /volume2/docker — down.sh's safety root will refuse to clean it" ;;
        esac ;;
      QBITTORRENT_USER)
        [ "$REPLY_VALUE" = "$cur" ] \
          || warn "seeded into qBittorrent.conf at first boot only — after that, changing it here breaks the login Sonarr/Radarr use" ;;
      QBITTORRENT_SEED_RATIO|QBITTORRENT_SEED_MINUTES)
        [ "$REPLY_VALUE" = "$cur" ] \
          || warn "applied via qBittorrent.conf at first start only — a change here does not reach a running qBittorrent" ;;
    esac
  done
}

# --- sections ---------------------------------------------------------------------

first_tier() {
  local t
  for t in core jellyfin arr; do
    want "$t" && { printf '%s' "$t"; return 0; }
  done
}

shared_section() {
  say "Shared settings"
  local ft cur ex def
  ft=$(first_tier)

  cur=$(env_get "$ft" TZ); ex=$(env_get_example "$ft" TZ)
  def=$(pick_default "$cur" "$ex" "$DET_TZ")
  if [ "$ADVANCED" -eq 1 ]; then
    ask "TZ" "$def" is_nonempty
    def="$REPLY_VALUE"
  fi
  stage_where_defined TZ "$def"

  cur=$(env_get "$ft" PUID)
  if [ "$ADVANCED" -eq 1 ]; then
    info "PUID/PGID: the user and group every service runs as."
    ask "PUID" "$cur" is_gid; stage_where_defined PUID "$REPLY_VALUE"
    ask "PGID" "$(env_get "$ft" PGID)" is_gid; stage_where_defined PGID "$REPLY_VALUE"
  else
    stage_where_defined PUID "$cur"
    stage_where_defined PGID "$(env_get "$ft" PGID)"
  fi

  if want core || want arr; then
    local dgid_tier=core
    want core || dgid_tier=arr
    cur=$(env_get "$dgid_tier" DOCKER_GID); ex=$(env_get_example "$dgid_tier" DOCKER_GID)
    def=$(pick_default "$cur" "$ex" "$DET_DOCKER_GID")
    if [ -z "$DET_DOCKER_GID" ]; then
      info "docker group GID not detectable here — confirm with: getent group docker"
    fi
    if [ "$ADVANCED" -eq 1 ]; then
      ask "DOCKER_GID" "$def" is_gid
      def="$REPLY_VALUE"
    fi
    stage_where_defined DOCKER_GID "$def"
  fi

  # Media dirs: asked once, staged under both names — MEDIA_*_DIR (jellyfin)
  # and ARR_*_DIR (arr) must hold identical values (see arr.env.example).
  if want jellyfin || want arr; then
    local mt=jellyfin
    want jellyfin || mt=arr
    local movies_var=MEDIA_MOVIES_DIR series_var=MEDIA_SERIES_DIR
    [ "$mt" = "arr" ] && { movies_var=ARR_MOVIES_DIR; series_var=ARR_SERIES_DIR; }

    info "Media libraries (pre-existing — never created or chowned by up.sh):"
    ask "Movies directory" "$(env_get "$mt" "$movies_var")" is_abs_dir
    [ -d "$REPLY_VALUE" ] || warn "does not exist yet — that library will start empty"
    stage jellyfin MEDIA_MOVIES_DIR "$REPLY_VALUE"
    stage arr ARR_MOVIES_DIR "$REPLY_VALUE"

    ask "Series directory" "$(env_get "$mt" "$series_var")" is_abs_dir
    [ -d "$REPLY_VALUE" ] || warn "does not exist yet — that library will start empty"
    stage jellyfin MEDIA_SERIES_DIR "$REPLY_VALUE"
    stage arr ARR_SERIES_DIR "$REPLY_VALUE"

    if want jellyfin; then
      ask "Music directory" "$(env_get jellyfin MEDIA_MUSIC_DIR)" is_abs_dir
      [ -d "$REPLY_VALUE" ] || warn "does not exist yet — that library will start empty"
      stage jellyfin MEDIA_MUSIC_DIR "$REPLY_VALUE"
    fi
  fi
}

core_section() {
  want core || return 0
  say "Core (Homepage)"
  local cur def t val
  cur=$(env_get core HOMEPAGE_ALLOWED_HOSTS)
  def="$cur"
  for t in $DET_HOSTNAME $DET_LAN_IP; do
    [ -n "$t" ] || continue
    case ",${def}," in
      *",${t},"*) ;;
      *) def="${def:+${def},}${t}" ;;
    esac
  done
  info "Every name and address Homepage is reached AT — the NAS's own, not clients'."
  info "Comma-separated, no wildcards or CIDR (each entry is matched literally)."
  while :; do
    ask "HOMEPAGE_ALLOWED_HOSTS" "$def"
    val="${REPLY_VALUE// /}"
    is_hosts_list "$val" && break
  done
  stage core HOMEPAGE_ALLOWED_HOSTS "$val"

  [ "$ADVANCED" -eq 1 ] && walk_tier core
  return 0
}

jellyfin_section() {
  want jellyfin || return 0
  say "Jellyfin"
  local cur ex def

  ask "Server name (JELLYFIN_SERVER_NAME)" "$(env_get jellyfin JELLYFIN_SERVER_NAME)" is_nonempty
  stage jellyfin JELLYFIN_SERVER_NAME "$REPLY_VALUE"

  ask "Admin username (JELLYFIN_ADMIN_USER)" "$(env_get jellyfin JELLYFIN_ADMIN_USER)" is_nonempty
  stage jellyfin JELLYFIN_ADMIN_USER "$REPLY_VALUE"

  cur=$(env_get jellyfin JELLYFIN_ADMIN_PASSWORD)
  if [ -n "$cur" ]; then
    if ! ask_yn "JELLYFIN_ADMIN_PASSWORD is already set — keep it?" Y; then
      ask_secret "New Jellyfin admin password"
      stage jellyfin JELLYFIN_ADMIN_PASSWORD "$REPLY_VALUE"
    fi
  else
    info "Jellyfin's setup wizard is one-shot — a password typo is only discovered"
    info "after the wizard has closed around it, so this is confirmed twice."
    ask_secret "Jellyfin admin password"
    stage jellyfin JELLYFIN_ADMIN_PASSWORD "$REPLY_VALUE"
  fi

  cur=$(env_get jellyfin RENDER_GID); ex=$(env_get_example jellyfin RENDER_GID)
  def=$(pick_default "$cur" "$ex" "$DET_RENDER_GID")
  if [ -z "$DET_RENDER_GID" ]; then
    info "render GID not detectable here — confirm with: stat -c '%g' /dev/dri/renderD128"
  fi
  if [ "$ADVANCED" -eq 1 ]; then
    ask "RENDER_GID" "$def" is_gid
    def="$REPLY_VALUE"
  fi
  stage jellyfin RENDER_GID "$def"

  cur=$(env_get jellyfin JELLYFIN_LAN_HOST); ex=$(env_get_example jellyfin JELLYFIN_LAN_HOST)
  def=$(pick_default "$cur" "$ex" "$DET_LAN_IP")
  if [ "$ADVANCED" -eq 1 ]; then
    info "How Homepage (a container on nas-net) reaches Jellyfin (host-networked)"
    info "for its dashboard widgets: must be the LAN IP."
    ask "JELLYFIN_LAN_HOST" "$def" is_nonempty
    def="$REPLY_VALUE"
  fi
  stage jellyfin JELLYFIN_LAN_HOST "$def"

  cur=$(env_get jellyfin JELLYFIN_LOCAL_SUBNET); ex=$(env_get_example jellyfin JELLYFIN_LOCAL_SUBNET)
  local det_subnet=""
  [ -n "$DET_LAN_IP" ] && det_subnet="${DET_LAN_IP%.*}.0/24"
  def=$(pick_default "$cur" "$ex" "$det_subnet")
  if [ "$ADVANCED" -eq 1 ]; then
    ask "JELLYFIN_LOCAL_SUBNET" "$def" is_subnet
    def="$REPLY_VALUE"
  fi
  stage jellyfin JELLYFIN_LOCAL_SUBNET "$def"

  [ "$ADVANCED" -eq 1 ] && walk_tier jellyfin
  return 0
}

configure_indexers() {
  say "Prowlarr indexers"
  local cur enabled="" def key user pass have defyn seen=""

  if ask_yn "Install the public indexers at bootstrap?" Y; then
    stage arr ARR_INSTALL_INDEXERS 1
    ask "Public indexers (Prowlarr definition names)" "$(env_get arr ARR_INDEXERS)" is_csv
    stage arr ARR_INDEXERS "$REPLY_VALUE"
  else
    stage arr ARR_INSTALL_INDEXERS 0
    info "Prowlarr will be left empty for hand-adding"
  fi

  info "Private indexers need a username + password login; anything cookie/passkey/"
  info "2FA-based is skipped at bootstrap and must be added in the Prowlarr UI."
  cur=$(env_get arr ARR_INDEXERS_PRIVATE)
  for def in $(printf '%s,%s' "$cur" "$(env_get_example arr ARR_INDEXERS_PRIVATE)" | tr ',' ' '); do
    [ -n "$def" ] || continue
    case " $seen " in *" $def "*) continue ;; esac
    seen="${seen} ${def}"
    # kinozal -> ARR_INDEXER_KINOZAL_USER / _PASS — must derive exactly as
    # arr-bootstrap.sh does.
    key=$(printf '%s' "$def" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')
    user=$(env_get arr "ARR_INDEXER_${key}_USER")
    pass=$(env_get arr "ARR_INDEXER_${key}_PASS")
    have="no credentials stored"
    if [ -n "$user" ]; then
      have="user ${user}"
      [ -n "$pass" ] && have="${have}, password stored"
    fi
    defyn=N
    case ",${cur}," in
      *",${def},"*) [ -n "$user" ] && [ -n "$pass" ] && defyn=Y ;;
    esac
    if ask_yn "Enable ${def}? (${have})" "$defyn"; then
      ask "${def} username" "$user" is_nonempty
      user="$REPLY_VALUE"
      if [ -z "$pass" ] || ! ask_yn "Keep the stored password for ${def}?" Y; then
        ask_secret "${def} password"
        pass="$REPLY_VALUE"
      fi
      stage arr "ARR_INDEXER_${key}_USER" "$user"
      stage arr "ARR_INDEXER_${key}_PASS" "$pass"
      enabled="${enabled:+${enabled},}${def}"
    elif [ -n "$user" ] || [ -n "$pass" ]; then
      if ask_yn "Clear the stored credentials for ${def}?" N; then
        stage arr "ARR_INDEXER_${key}_USER" ""
        stage arr "ARR_INDEXER_${key}_PASS" ""
      fi
    fi
  done

  while ask_yn "Add another private indexer?" N; do
    ask "Prowlarr definition name" "" is_defname
    def="$REPLY_VALUE"
    key=$(printf '%s' "$def" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')
    ask "${def} username" "$(env_get arr "ARR_INDEXER_${key}_USER")" is_nonempty
    user="$REPLY_VALUE"
    ask_secret "${def} password"
    stage arr "ARR_INDEXER_${key}_USER" "$user"
    stage arr "ARR_INDEXER_${key}_PASS" "$REPLY_VALUE"
    enabled="${enabled:+${enabled},}${def}"
  done

  # Rebuilt from the enabled set only — a name listed without both credentials
  # would just be warn-and-skipped by arr-bootstrap.sh.
  stage arr ARR_INDEXERS_PRIVATE "$enabled"
}

arr_section() {
  want arr || return 0
  say "Arr stack"
  local cur ex def

  cur=$(env_get arr SEERR_JELLYFIN_HOST); ex=$(env_get_example arr SEERR_JELLYFIN_HOST)
  def=$(pick_default "$cur" "$ex" "$DET_LAN_IP")
  info "How Seerr (a container on nas-net) reaches Jellyfin (host-networked):"
  info "must be the LAN IP — container names and .local don't resolve in containers."
  ask "SEERR_JELLYFIN_HOST" "$def" is_nonempty
  case "$REPLY_VALUE" in
    *[!0-9.]*) warn "'${REPLY_VALUE}' is not an IPv4 address — mDNS/.local usually fails inside containers" ;;
  esac
  stage arr SEERR_JELLYFIN_HOST "$REPLY_VALUE"

  configure_indexers

  [ "$ADVANCED" -eq 1 ] && walk_tier arr
  return 0
}

# --- main -------------------------------------------------------------------------

say "nas-stack configuration wizard"
MODE_DESC="quick (detect + confirm; --advanced walks every variable)"
[ "$ADVANCED" -eq 1 ] && MODE_DESC="advanced (every variable, with help text)"
info "mode: ${MODE_DESC}"
[ "$DRY_RUN" -eq 1 ] && info "dry run: full wizard, nothing will be written"
info "tiers:${STACKS}"
info "Ctrl-C is safe — each file is written only after you confirm its summary."
if [ "$IS_ROOT" -eq 1 ]; then
  if [ -n "${SUDO_UID:-}" ]; then
    info "(sudo is not needed for configure.sh — written files will be chowned back)"
  else
    warn "running as plain root — written .env files will be root-owned"
  fi
fi

DET_TZ=$(detect_tz)
DET_DOCKER_GID=$(detect_docker_gid)
DET_RENDER_GID=$(detect_render_gid)
DET_LAN_IP=$(detect_lan_ip)
DET_HOSTNAME=$(detect_hostname)

say "Detected host facts"
show_det() { info "$1: ${2:-"(not detected — keeping current values)"}"; }
show_det "timezone   " "$DET_TZ"
show_det "docker GID " "$DET_DOCKER_GID"
show_det "render GID " "$DET_RENDER_GID"
show_det "LAN IP     " "$DET_LAN_IP"
show_det "hostname   " "$DET_HOSTNAME"

say "Preparing .env files"
for tier in core jellyfin arr; do
  want "$tier" || continue
  if [ -f "${tier}.env" ]; then
    info "${tier}.env exists — its values are the defaults below"
    # shellcheck disable=SC1090
    if ! ( set +eu; . "./${tier}.env" ) >/dev/null 2>&1; then
      warn "${tier}.env failed to parse as shell — showing example defaults;"
      warn "only the lines prompted here will be replaced"
    fi
  elif [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] ${tier}.env would be created from ${tier}.env.example"
  else
    # Created by write_tier only once the summary is confirmed — quitting or
    # Ctrl-C before then really does leave the tier untouched.
    info "${tier}.env will be created from ${tier}.env.example when confirmed"
  fi
  drift_sync "$tier"
done

shared_section
core_section
review_and_write core
jellyfin_section
review_and_write jellyfin
arr_section
review_and_write arr

say "Done"
if [ "$DRY_RUN" -eq 1 ]; then
  info "dry run — nothing was written"
else
  info "written:${WRITTEN_TIERS:- nothing}"
fi
info "Next: sudo ./up.sh   (starts the stacks and runs both bootstraps;"
info "generates the arr API keys and qBittorrent password on first run)"
