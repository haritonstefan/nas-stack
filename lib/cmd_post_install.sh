# shellcheck shell=bash
# nas post-install — per-unit API configuration over the running services,
# re-runnable at any time (docs/cli-spec.md §nas post-install). Fixed order
# jellyfin → arr → seerr (R8): seerr binds to the quality profiles configarr
# creates, so it must go last, and its failure is deferred, never fatal.

SEERR_DEFERRED_RC=0

cmd_post_install() {
  local args=() arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run)    DRY_RUN=1 ;;
      --verbose|-v) VERBOSE=1 ;;
      -h|--help)    post_install_usage; return 0 ;;
      -*)           die "unknown flag '${arg}' for nas post-install" ;;
      *)            args+=("$arg") ;;
    esac
  done
  select_units post-install 0 ${args[@]+"${args[@]}"}
  if [ "$DRY_RUN" -eq 0 ] && [ "$IS_ROOT" -eq 0 ]; then
    die "nas post-install needs root — run: sudo ./nas post-install $*"
  fi
  post_install_run
  say "Summary"
  local unit
  for unit in $(selected_units); do
    case " ${FAILED_UNITS} " in
      *" ${unit}:"*) info "${unit}: FAILED" ;;
      *)             info "${unit}: ok" ;;
    esac
  done
  [ -z "$FAILED_UNITS" ] || exit 1
  exit 0
}

post_install_usage() {
  cat <<EOF
nas post-install [--dry-run] [--verbose] [unit...|all]

Configures the selected units' running services over their APIs, in the fixed
order jellyfin -> arr -> seerr. Wraps the bootstrap scripts; idempotent and
re-runnable without touching containers. Units without a post-install step
are skipped silently.
EOF
}

bootstrap_args() {
  local a=""
  [ "$VERBOSE" -eq 1 ] && a="${a} --verbose"
  [ "$DRY_RUN" -eq 1 ] && a="${a} --dry-run"
  printf '%s' "$a"
}

post_install_run() {
  local unit arr_wanted=0
  for unit in $(selected_units); do
    unit_load "$unit"
    [ "$UNIT_POST_INSTALL" = "arr" ] && arr_wanted=1
  done

  if want jellyfin; then
    post_install_jellyfin || mark_failed jellyfin $?
  fi

  # One arr-bootstrap.sh run covers every arr-driver unit: the script scopes
  # itself by which env files exist, and the wiring is inherently group-shaped
  # (Prowlarr -> Sonarr), so `nas post-install sonarr` may legitimately touch
  # a sibling's wiring.
  if [ "$arr_wanted" -eq 1 ]; then
    say "Configuring the arr units"
    local arr_rc=0
    # shellcheck disable=SC2086
    ./arr-bootstrap.sh $(bootstrap_args) || arr_rc=$?
    if [ "$arr_rc" -ne 0 ]; then
      warn "arr-bootstrap.sh failed (exit ${arr_rc})"
      for unit in $(selected_units); do
        unit_load "$unit"
        [ "$UNIT_POST_INSTALL" = "arr" ] && mark_failed "$unit" "$arr_rc"
      done
    fi
  fi

  if want seerr; then
    say "Configuring Seerr"
    # shellcheck disable=SC2086
    ./seerr-bootstrap.sh $(bootstrap_args) || SEERR_DEFERRED_RC=$?
    if [ "$SEERR_DEFERRED_RC" -ne 0 ]; then
      mark_failed seerr "$SEERR_DEFERRED_RC"
      ui_banner "Seerr was NOT configured (seerr-bootstrap.sh exit ${SEERR_DEFERRED_RC})." \
        "The rest of the stack is up. Seerr will show its first-run wizard," \
        "and Homepage's Seerr widget returns 403 until setup completes." \
        "The cause is in the output above. Fix it, then: ./nas post-install seerr"
    fi
  fi
}

post_install_jellyfin() {
  say "Configuring Jellyfin"
  unit_load jellyfin
  unit_env_load
  export ADMIN_USER="${ADMIN_USER:-admin}"
  export ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

  local rc=0
  # shellcheck disable=SC2086
  ./jellyfin-bootstrap.sh $(bootstrap_args) || rc=$?
  case "$rc" in
    0|10) ;;
    *) warn "jellyfin-bootstrap.sh failed (exit ${rc})"; return "$rc" ;;
  esac

  if [ "$DRY_RUN" -eq 0 ]; then
    # The bootstrap may have minted JELLYFIN_API_KEY into jellyfin.env, but
    # the Homepage widget labels bake in at container create — `docker
    # restart` never refreshes them, only a recreate does. The recreate also
    # covers a pending exit-10 restart. Re-sourced in a subshell: this shell
    # still holds the pre-bootstrap values.
    local new_key cur_key
    # shellcheck disable=SC1091
    new_key=$( . ./jellyfin.env && printf '%s' "${JELLYFIN_API_KEY:-}" )
    cur_key=$(docker inspect jellyfin \
      --format '{{ index .Config.Labels "homepage.widgets[0].key" }}' 2>/dev/null || true)
    if [ -n "$new_key" ] && [ "$new_key" != "$cur_key" ]; then
      say "Recreating Jellyfin to publish the Homepage widget labels"
      compose_up_unit
    elif [ "$rc" -eq 10 ]; then
      say "Restarting Jellyfin to apply pending changes"
      docker restart jellyfin >/dev/null
      info "restarted"
    else
      info "no restart needed"
    fi
  fi

  # Scan last, after any restart: it walks the whole media HDD, and a restart
  # moments in would cut it short. A failed scan is not worth failing the
  # bring-up over — it is re-triggerable from the dashboard.
  if [ "${JELLYFIN_SCAN_ON_BOOTSTRAP:-1}" = "1" ]; then
    local scan_rc=0
    # shellcheck disable=SC2086
    ./jellyfin-bootstrap.sh --scan-only $(bootstrap_args) || scan_rc=$?
    [ "$scan_rc" -eq 0 ] || warn "library scan could not be started (exit ${scan_rc})"
  else
    info "library scan skipped (JELLYFIN_SCAN_ON_BOOTSTRAP=0)"
  fi
  return 0
}
