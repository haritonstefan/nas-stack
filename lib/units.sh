# shellcheck shell=bash
# Sourced by ./nas. The unit list, the aliases, and the unit-file contract.
#
# Everything a unit declares is plain strings and space-delimited word lists
# (docs/cli-spec.md §Code layout). Core loads one unit file at a time and
# resets every declaration between loads, so unit files share one vocabulary
# with no per-unit prefixes. Cross-unit knowledge (ordering, aliases, the
# ofelia→configarr coupling, the jellyfin widget-key recreate) lives in the
# verb implementations, never in a unit file (R7).

UNITS_ALL="homepage jellyfin sonarr radarr lidarr prowlarr qbittorrent seerr byparr configarr ofelia"
UNITS_STANDALONE="pihole"
ARR_UNITS="sonarr radarr lidarr prowlarr qbittorrent seerr byparr configarr ofelia"

UNITS=""
EXPLICIT_QBITTORRENT=0
QBITTORRENT_VIA_ALIAS=0

is_unit()       { case " $UNITS_ALL " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
is_standalone() { case " $UNITS_STANDALONE " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
add_unit()      { case " $UNITS " in *" $1 "*) ;; *) UNITS="${UNITS} ${1}" ;; esac; }
want()          { case " $UNITS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# select_units <verb> <allow-standalone 0|1> [token...]
# Fills UNITS. No tokens means everything the verb may touch. Unknown names
# fail before anything runs; a standalone unit is only refused when named
# explicitly — `all` and the aliases never expand to one.
select_units() {
  local verb="$1" allow_standalone="$2" t u
  shift 2
  UNITS=""
  EXPLICIT_QBITTORRENT=0
  QBITTORRENT_VIA_ALIAS=0
  for t in "$@"; do
    case "$t" in
      all)  for u in $UNITS_ALL; do add_unit "$u"; done; QBITTORRENT_VIA_ALIAS=1 ;;
      core) add_unit homepage ;;
      arr)  for u in $ARR_UNITS; do add_unit "$u"; done; QBITTORRENT_VIA_ALIAS=1 ;;
      *)
        if is_unit "$t"; then
          add_unit "$t"
          [ "$t" = "qbittorrent" ] && EXPLICIT_QBITTORRENT=1
        elif is_standalone "$t"; then
          if [ "$allow_standalone" -eq 1 ]; then
            add_unit "$t"
          else
            die "nas ${verb} does not manage '${t}' — it is standalone. Bring it up with: cd pi-hole && sudo docker compose up -d (see docs/pihole-spec.md)"
          fi
        else
          die "unknown unit '${t}' — valid: ${UNITS_ALL} ${UNITS_STANDALONE} (aliases: core, arr, all)"
        fi ;;
    esac
  done
  if [ -z "$UNITS" ]; then
    for u in $UNITS_ALL; do add_unit "$u"; done
    QBITTORRENT_VIA_ALIAS=1
    if [ "$allow_standalone" -eq 1 ]; then
      for u in $UNITS_STANDALONE; do add_unit "$u"; done
    fi
  fi
}

# Iteration always follows UNITS_ALL order regardless of argv order; the
# standalone units come last.
selected_units() {
  local u out=""
  for u in $UNITS_ALL $UNITS_STANDALONE; do
    want "$u" && out="${out} ${u}"
  done
  printf '%s' "$out"
}

# --- unit-file contract --------------------------------------------------------

unit_load() {
  local unit="$1"
  UNIT_NAME="$unit"
  UNIT_PROJECT="nas-${unit}"
  UNIT_CONTAINER="$unit"
  UNIT_COMPOSE_FILE="docker-compose.${unit}.yml"
  UNIT_ENV_FILE="${unit}.env"
  UNIT_ENV_FILES="shared.env ${unit}.env"
  UNIT_UP_ARGS=""
  UNIT_DOWN_ARGS=""
  UNIT_DIRS=""
  UNIT_CHECK_DIRS=""
  UNIT_TEMPLATES=""
  UNIT_GENERATED=""
  UNIT_MINTED=""
  UNIT_REQUIRED=""
  UNIT_PORT=""
  UNIT_PORT_VAR=""
  UNIT_LOG_PATHS=""
  UNIT_POST_INSTALL=""
  UNIT_STANDALONE=0
  unset -f unit_configure unit_templates unit_post_install unit_destroy_plan unit_doctor 2>/dev/null || true
  # shellcheck disable=SC1090
  . "units/${unit}.sh"
}

unit_has_hook() { declare -F "$1" >/dev/null 2>&1; }

# Loads the unit's env values the way compose will see them: each env file's
# example first (so a missing file still resolves to the documented default),
# then the real file over it.
unit_env_load() {
  local f files="$UNIT_ENV_FILES"
  [ -z "$files" ] && files="$UNIT_ENV_FILE"
  set -a
  for f in $files; do
    # shellcheck disable=SC1090
    [ -f "${f}.example" ] && . "./${f}.example"
    # shellcheck disable=SC1090
    [ -f "$f" ] && . "./$f"
  done
  set +a
}

# resolve_dir_spec <VAR or VAR/sub> — the declared env var's value, with the
# literal subpath appended for the VAR/sub form (the downloads trio).
resolve_dir_spec() {
  local spec="$1" var="${1%%/*}" sub="" val
  [ "$spec" = "$var" ] || sub="${spec#*/}"
  eval "val=\${${var}:-}"
  [ -n "$val" ] || return 1
  if [ -n "$sub" ]; then printf '%s/%s' "$val" "$sub"; else printf '%s' "$val"; fi
}

# The unit's config dir is the first UNIT_DIRS entry; the default destroy
# target is its parent (one path covers configarr's config/ + repos/).
unit_config_dir() {
  local first="${UNIT_DIRS%% *}"
  [ -n "$first" ] || return 1
  resolve_dir_spec "$first"
}

unit_port() {
  local port="$UNIT_PORT" val
  if [ -n "$UNIT_PORT_VAR" ]; then
    eval "val=\${${UNIT_PORT_VAR}:-}"
    [ -n "$val" ] && port="$val"
  fi
  printf '%s' "$port"
}
