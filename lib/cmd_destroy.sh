# shellcheck shell=bash
# nas destroy — tear units down: plan, confirm, execute (docs/cli-spec.md
# §nas destroy). The plan is validated against SAFE_ROOT before it is shown,
# so the plan is the truth (R1). .env files and the download tree always
# survive (R2, R3).

DESTROY_YES=0
DESTROY_CONTAINERS_ONLY=0
DESTROY_WIPE_QBT=0
DESTROY_SAVE_LOGS=0
KEEP_QBITTORRENT=0
DESTROY_PATHS=""

cmd_destroy() {
  local args=() arg
  for arg in "$@"; do
    case "$arg" in
      --yes|-y)           DESTROY_YES=1 ;;
      --dry-run)          DRY_RUN=1 ;;
      --containers)       DESTROY_CONTAINERS_ONLY=1 ;;
      --wipe-qbittorrent) DESTROY_WIPE_QBT=1 ;;
      --save-logs)        DESTROY_SAVE_LOGS=1 ;;
      -h|--help)          destroy_usage; return 0 ;;
      -*)                 die "unknown flag '${arg}' for nas destroy" ;;
      *)                  args+=("$arg") ;;
    esac
  done
  select_units destroy 0 ${args[@]+"${args[@]}"}

  if [ "$DRY_RUN" -eq 0 ] && [ "$IS_ROOT" -eq 0 ]; then
    die "nas destroy needs root — run: sudo ./nas destroy $*"
  fi
  command -v docker >/dev/null 2>&1 || die "docker is required"

  destroy_plan
  destroy_show_plan
  [ "$DRY_RUN" -eq 1 ] && exit 0
  destroy_confirm || { echo "Refused — nothing was changed."; exit 2; }
  destroy_offer_save_logs
  destroy_execute
  say "Done"
  info "Bring it back with: sudo ./nas install $(selected_units | sed 's/^ *//')"
  exit 0
}

destroy_usage() {
  cat <<EOF
nas destroy [--yes] [--dry-run] [--containers] [--wipe-qbittorrent] [--save-logs] [unit...|all]

Shows the full teardown plan (containers, on-disk paths), asks for
confirmation (typed 'delete' when data is involved), then executes.
DESTRUCTIVE: the selected units' config under ${SAFE_ROOT} is deleted.

Always survives: .env files (the only copy of the API keys and the admin
password) and the download tree (a still-seeding torrent is not reproducible
from this repo). qBittorrent is spared entirely when in scope only via 'arr'
or the no-args default — name it or pass --wipe-qbittorrent to include it.

  --dry-run     print the plan, change nothing
  --yes         skip confirmation (required without a TTY)
  --containers  stop/remove containers only, delete no data
  --save-logs   copy each unit's logs to ${SAFE_ROOT}/_saved-logs/ first
EOF
}

destroy_plan() {
  # qBittorrent sparing: only when in scope via the arr alias or the no-args
  # default — never when named explicitly, never with --wipe-qbittorrent.
  if want qbittorrent && [ "$DESTROY_WIPE_QBT" -eq 0 ] && [ "$EXPLICIT_QBITTORRENT" -eq 0 ]; then
    KEEP_QBITTORRENT=1
    local u new_units=""
    for u in $UNITS; do [ "$u" = "qbittorrent" ] || new_units="${new_units} $u"; done
    UNITS="$new_units"
  fi

  local unit target p
  for unit in $(selected_units); do
    unit_load "$unit"
    unit_env_load
    local candidates=""
    target=$(unit_config_dir 2>/dev/null) || target=""
    [ -n "$target" ] && candidates="$(dirname "$target")"
    if unit_has_hook unit_destroy_plan; then
      candidates="${candidates} $(unit_destroy_plan | tr '\n' ' ')"
    fi
    for p in $candidates; do
      if ! path_deletable "$p"; then
        warn "refusing to delete '${p}' — outside ${SAFE_ROOT} or contains '..'"
        continue
      fi
      case " $DESTROY_PATHS " in *" $p "*) continue ;; esac
      DESTROY_PATHS="${DESTROY_PATHS} ${p}"
    done
  done
}

destroy_show_plan() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "DRY RUN — nothing will be changed"
  fi
  say "Containers to stop and remove"
  local unit p size
  for unit in $(selected_units); do
    info "project nas-${unit} (docker-compose.${unit}.yml)"
  done
  if [ "$KEEP_QBITTORRENT" -eq 1 ]; then
    info "qbittorrent excluded, stays running (pass --wipe-qbittorrent to include it)"
  fi

  if [ "$DESTROY_CONTAINERS_ONLY" -eq 1 ]; then
    say "Data to delete"
    info "none — --containers given, all config is kept"
    return 0
  fi

  say "Data to DELETE (irreversible)"
  if [ -z "$DESTROY_PATHS" ]; then
    info "none resolved"
  else
    for p in $DESTROY_PATHS; do
      if [ -d "$p" ]; then
        size=$(du -sh "$p" 2>/dev/null | cut -f1 || echo '?')
        info "${p}  (${size})"
      else
        info "${p}  (does not exist, skipping)"
      fi
    done
  fi
  say "NOT touched"
  info "anything outside ${SAFE_ROOT}"
  info "shared.env / <unit>.env files — the only copy of the API keys and the"
  info "  admin password; losing them means every integration must be redone"
  info "${DOWNLOADS_DIR:-${SAFE_ROOT}/downloads} (downloads keep seeding; remove by hand)"
  if [ "$KEEP_QBITTORRENT" -eq 1 ]; then
    info "${QBITTORRENT_CONFIG_DIR:-${SAFE_ROOT}/qbittorrent/config} (kept running)"
  fi
}

destroy_confirm() {
  [ "$DESTROY_YES" -eq 1 ] && return 0
  if ! is_tty; then
    warn "no TTY to confirm on — pass --yes if you really mean it"
    return 1
  fi
  if [ "$DESTROY_CONTAINERS_ONLY" -eq 1 ]; then
    ui_confirm "Stop and remove the containers above?" N
    return $?
  fi
  # Typed word, not y/N: a reflex Enter must not wipe config.
  printf '\n\033[1mType "delete" to confirm removal of the paths above: \033[0m'
  local reply
  IFS= read -r reply
  [ "$reply" = "delete" ]
}

destroy_offer_save_logs() {
  [ "$DESTROY_CONTAINERS_ONLY" -eq 1 ] && return 0
  [ -z "$DESTROY_PATHS" ] && return 0
  if [ "$DESTROY_SAVE_LOGS" -eq 0 ] && is_tty && [ "$DESTROY_YES" -eq 0 ]; then
    ui_confirm "Save each unit's logs first? (Jellyfin's only live inside the dir being deleted)" Y \
      && DESTROY_SAVE_LOGS=1
  fi
  [ "$DESTROY_SAVE_LOGS" -eq 1 ] || return 0

  local ts unit dest spec src
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  say "Saving logs to ${SAFE_ROOT}/_saved-logs/${ts}/"
  for unit in $(selected_units); do
    unit_load "$unit"
    unit_env_load
    dest="${SAFE_ROOT}/_saved-logs/${ts}/${unit}"
    mkdir -p "$dest"
    if docker ps -aq -f "name=^${UNIT_CONTAINER}$" | grep -q .; then
      docker logs "$UNIT_CONTAINER" > "${dest}/docker.log" 2>&1 || true
    fi
    for spec in $UNIT_LOG_PATHS; do
      src=$(resolve_dir_spec "$spec") || continue
      [ -e "$src" ] && cp -a "$src" "$dest/" 2>/dev/null || true
    done
    info "${unit} saved"
  done
}

destroy_execute() {
  local unit c
  for unit in $(selected_units); do
    unit_load "$unit"
    say "Stopping ${unit}"
    compose_down_unit || warn "compose down failed for ${unit} — continuing"
  done

  # A container started outside the -p convention lives under a different
  # project name and is missed above; clean up by name as a backstop.
  say "Removing any stray containers by name"
  for unit in $(selected_units); do
    unit_load "$unit"
    c="$UNIT_CONTAINER"
    if docker ps -aq -f "name=^${c}$" | grep -q .; then
      docker rm -f "$c" >/dev/null
      info "removed ${c}"
    else
      info "${c} not present"
    fi
  done

  if docker network ls -q -f "name=^nas-net$" | grep -q .; then
    if [ "$KEEP_QBITTORRENT" -eq 1 ]; then
      say "Keeping nas-net"
      info "qbittorrent is still attached"
    else
      say "Removing nas-net"
      docker network rm nas-net >/dev/null 2>&1 || \
        warn "could not remove nas-net (still in use by another container?)"
    fi
  fi

  if [ "$DESTROY_CONTAINERS_ONLY" -eq 0 ] && [ -n "$DESTROY_PATHS" ]; then
    say "Deleting data"
    local p
    for p in $DESTROY_PATHS; do
      if [ -d "$p" ]; then
        rm -rf "$p"
        info "removed ${p}"
      else
        info "${p} absent, nothing to do"
      fi
    done
  fi
}
