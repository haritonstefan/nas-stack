# shellcheck shell=bash
# nas install — bring units up (docs/cli-spec.md §nas install).

cmd_install() {
  local args=() arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run)         DRY_RUN=1 ;;
      -h|--help)         install_usage; return 0 ;;
      -*)                die "unknown flag '${arg}' for nas install (see: nas install --help)" ;;
      *)                 args+=("$arg") ;;
    esac
  done
  select_units install 0 ${args[@]+"${args[@]}"}

  if [ "$DRY_RUN" -eq 0 ] && [ "$IS_ROOT" -eq 0 ]; then
    die "nas install needs root — run: sudo ./nas install $*"
  fi

  install_preflight
  install_run
  install_summary
}

install_usage() {
  cat <<EOF
nas install [--dry-run] [unit...|all]

Brings the selected units (default: all) from a fresh clone to running:
nas-net, .env files (created from the examples, never overwritten), host
directories with the right ownership, generated per-unit API keys, Homepage
config templates (installed only when absent), compose up per unit.
Idempotent. Configuring the services themselves is done by hand in each UI.

Units: ${UNITS_ALL} (aliases: core, arr, all)
EOF
}

install_preflight() {
  say "Checking prerequisites"
  command -v docker >/dev/null 2>&1 || die "docker is required"
  docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) is required"
  info "docker and docker compose present"
  if ! docker info >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "cannot talk to the Docker daemon — continuing anyway since this is a dry run"
    else
      die "cannot talk to the Docker daemon — is it running, and does this user have permission?"
    fi
  fi
  say "Ensuring nas-net exists"
  ensure_nas_net
}

install_run() {
  local unit

  say "Preparing .env files"
  env_file_create shared.env
  for unit in $(selected_units); do
    unit_load "$unit"
    env_file_create "$UNIT_ENV_FILE"
  done
  for unit in $(selected_units); do
    unit_load "$unit"
    unit_env_load
  done

  say "Per-unit secrets"
  local var
  for unit in $(selected_units); do
    unit_load "$unit"
    for var in $UNIT_GENERATED; do
      gen_secret_into "$UNIT_ENV_FILE" "$var"
    done
  done

  install_check_required

  say "Creating host directories"
  local spec path done_dirs=""
  for unit in $(selected_units); do
    unit_load "$unit"
    for spec in $UNIT_DIRS; do
      path=$(resolve_dir_spec "$spec") || { warn "${unit}: ${spec%%/*} resolves to nothing — skipped"; continue; }
      case " $done_dirs " in *" $path "*) continue ;; esac
      done_dirs="${done_dirs} ${path}"
      make_dir "$path"
    done
    install_check_dirs
  done

  say "Installing config templates (only when absent)"
  for unit in $(selected_units); do
    unit_load "$unit"
    if unit_has_hook unit_templates; then
      unit_templates || mark_failed "$unit" 1
    else
      install_templates_default
    fi
  done

  for unit in $(selected_units); do
    unit_load "$unit"
    say "Starting ${unit}"
    compose_up_unit || mark_failed "$unit" $?
  done
}

# Required values that are still empty stop the run before anything starts:
# compose would refuse them anyway (${VAR:?}), one unit at a time.
install_check_required() {
  local unit var val missing=""
  for unit in $(selected_units); do
    unit_load "$unit"
    unit_env_load
    for var in $UNIT_REQUIRED; do
      eval "val=\${${var}:-}"
      [ -n "$val" ] || missing="${missing} ${unit}:${var}"
    done
  done
  [ -z "$missing" ] && return 0
  warn "missing required values:${missing}"
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "continuing — this is a dry run"
    return 0
  fi
  die "fill them in (shared.env or the unit's own .env), then re-run: sudo ./nas install $(selected_units | sed 's/^ *//')"
}

make_dir() {
  local path="$1"
  if [ -d "$path" ]; then
    info "${path} exists"
    # Only the directory itself — a recursive chown would walk all of
    # Jellyfin's metadata and transcodes on every single run.
    [ "$IS_ROOT" -eq 1 ] && run chown "${PUID:-1000}:${PGID:-10}" "$path"
  else
    run mkdir -p "$path"
    [ "$IS_ROOT" -eq 1 ] && run chown -R "${PUID:-1000}:${PGID:-10}" "$path"
    info "${path} $([ "$DRY_RUN" -eq 1 ] && echo 'would be created' || echo created)"
  fi
  return 0
}

# Media libraries are pre-existing — never created or chowned (a chown across
# a live 14 TB library is not something a bring-up should ever do).
install_check_dirs() {
  local spec var mode d
  for spec in $UNIT_CHECK_DIRS; do
    var="${spec%%:*}"
    mode=""
    [ "$spec" != "$var" ] && mode="${spec#*:}"
    eval "d=\${${var}:-}"
    [ -n "$d" ] || continue
    if [ ! -d "$d" ]; then
      warn "${d} does not exist — ${UNIT_NAME} will start but that library will be empty or fail to add"
    elif [ "$mode" = "w" ] && [ ! -w "$d" ]; then
      warn "${d} is not writable — imports will fail (expected owner ${PUID:-1000}:${PGID:-10}; check: ls -ldn ${d})"
    else
      info "${d} present$([ "$mode" = "w" ] && echo ' and writable')"
    fi
  done
}

install_templates_default() {
  local pair src dest_var dest_dir dest
  for pair in $UNIT_TEMPLATES; do
    src="${pair%%:*}"
    dest_var="${pair#*:}"
    eval "dest_dir=\${${dest_var}:-}"
    [ -n "$dest_dir" ] || { warn "${UNIT_NAME}: ${dest_var} resolves to nothing — ${src} not installed"; continue; }
    dest="${dest_dir}/$(basename "$src")"
    if [ -f "$dest" ]; then
      info "$(basename "$src") exists, leaving untouched"
    else
      run cp "$src" "$dest"
      [ "$IS_ROOT" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && chown "${PUID:-1000}:${PGID:-10}" "$dest"
      info "$(basename "$src") $([ "$DRY_RUN" -eq 1 ] && echo 'would be installed' || echo installed)"
    fi
  done
}

install_summary() {
  say "Summary"
  local unit
  for unit in $(selected_units); do
    case " ${FAILED_UNITS} " in
      *" ${unit}:"*)
        local rc="${FAILED_UNITS##*"${unit}":}"; rc="${rc%% *}"
        info "${unit}: FAILED (exit ${rc})" ;;
      *)
        info "${unit}: ok" ;;
    esac
  done
  if want homepage;    then info "Homepage:    http://apollo.local/"; fi
  if want jellyfin;    then info "Jellyfin:    http://apollo.local:8096"; fi
  if want sonarr;      then info "Sonarr:      http://apollo.local:$(unit_load sonarr; unit_env_load; unit_port)"; fi
  if [ -n "$FAILED_UNITS" ]; then
    ui_banner "Some units FAILED:${FAILED_UNITS}" \
      "The stack that did come up stays up. Fix the cause above, then" \
      "re-run: sudo ./nas install <unit>"
    exit 1
  fi
  exit 0
}
