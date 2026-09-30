# shellcheck shell=bash
# nas install — bring units up (docs/cli-spec.md §nas install).

cmd_install() {
  local no_post_install=0 args=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run)         DRY_RUN=1 ;;
      --verbose|-v)      VERBOSE=1 ;;
      --no-post-install) no_post_install=1 ;;
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
  . lib/cmd_post_install.sh
  if [ "$no_post_install" -eq 1 ]; then
    say "Skipping post-install (--no-post-install)"
  else
    post_install_run
  fi
  install_summary
}

install_usage() {
  cat <<EOF
nas install [--dry-run] [--verbose] [--no-post-install] [unit...|all]

Brings the selected units (default: all) from a fresh clone to running:
nas-net, .env files (created from the examples, never overwritten), host
directories with the right ownership, generated per-unit secrets, config
templates (installed only when absent), compose up per unit, then chains
\`nas post-install\` for the selected units. Idempotent.

Units: ${UNITS_ALL} (aliases: core, arr, all)
EOF
}

install_preflight() {
  say "Checking prerequisites"
  local cmd missing=""
  for cmd in docker curl jq openssl; do
    command -v "$cmd" >/dev/null 2>&1 || missing="${missing} ${cmd}"
  done
  [ -z "$missing" ] || die "missing required command(s):${missing}"
  docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) is required"
  info "docker, docker compose, curl, jq, openssl present"
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

  # ofelia's job-run only starts an existing container by name — it never
  # creates one — so whenever ofelia is in scope the configarr container must
  # exist, created but not started, even when configarr was not selected.
  if want ofelia && ! want configarr; then
    say "Ensuring the configarr container exists (scheduler target)"
    unit_load configarr
    compose_up_unit || warn "could not create the configarr container — ofelia's schedule will fail on inspect"
  fi
}

# Missing required values stop the run and point at the wizard; with a TTY the
# wizard is offered right there, then the check re-runs once. A missing value
# that is another unit's generated key (configarr's cross-unit case) is not the
# wizard's to fill — its owner's install generates it.
generated_key_owner() { # generated_key_owner <var> — unit that generates it
  local u
  for u in $UNITS_ALL; do
    ( unit_load "$u"
      case " $UNIT_GENERATED " in *" $1 "*) exit 0 ;; esac
      exit 1 ) && { printf '%s' "$u"; return 0; }
  done
  return 1
}

install_check_required() {
  local attempt
  for attempt in 1 2; do
    local unit var val owner missing="" foreign=""
    for unit in $(selected_units); do
      unit_load "$unit"
      unit_env_load
      for var in $UNIT_REQUIRED; do
        eval "val=\${${var}:-}"
        [ -n "$val" ] && continue
        if owner=$(generated_key_owner "$var") && ! want "$owner"; then
          foreign="${foreign} ${unit} needs ${var} (owned by ${owner})"
        else
          missing="${missing} ${unit}:${var}"
        fi
      done
    done
    if [ -n "$foreign" ]; then
      warn "missing generated keys:${foreign}"
      [ "$DRY_RUN" -eq 1 ] || die "bring the owning unit(s) up first — e.g. sudo ./nas install sonarr radarr $(selected_units | sed 's/^ *//')"
    fi
    [ -z "$missing" ] && return 0
    warn "missing required values:${missing}"
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "continuing — this is a dry run"
      return 0
    fi
    if [ "$attempt" -eq 1 ] && is_tty && ui_confirm "Run 'nas configure' for the selected units now?" Y; then
      # shellcheck disable=SC2086
      "$NAS_SELF" configure $(selected_units) || true
      continue
    fi
    die "fill them in with: ./nas configure $(selected_units | sed 's/^ *//')"
  done
  die "required values still missing after configure — see above"
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
  if want prowlarr;    then info "Next: run ./nas indexers to add the trackers to Prowlarr"; fi
  if [ -n "$FAILED_UNITS" ]; then
    ui_banner "Some units FAILED:${FAILED_UNITS}" \
      "The stack that did come up stays up. Fix the cause above, then" \
      "re-run: sudo ./nas install <unit>  (or ./nas post-install <unit>)"
    exit 1
  fi
  exit 0
}
