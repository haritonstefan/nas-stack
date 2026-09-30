# shellcheck shell=bash
# nas recreate — destroy + install per named unit, one confirmation covering
# both. The operation this per-unit architecture was built for: tear down and
# recreate one unit while it stays wired into the rest of the stack.

cmd_recreate() {
  local args=() arg no_post_install=0
  for arg in "$@"; do
    case "$arg" in
      --yes|-y)           DESTROY_YES=1 ;;
      --dry-run)          DRY_RUN=1 ;;
      --wipe-qbittorrent) DESTROY_WIPE_QBT=1 ;;
      --no-post-install)  no_post_install=1 ;;
      --verbose|-v)       VERBOSE=1 ;;
      -h|--help)          recreate_usage; return 0 ;;
      -*)                 die "unknown flag '${arg}' for nas recreate" ;;
      *)                  args+=("$arg") ;;
    esac
  done
  [ "${#args[@]}" -gt 0 ] || die "nas recreate needs explicit unit names (there is no 'all' default here)"
  select_units recreate 0 "${args[@]}"

  if [ "$DRY_RUN" -eq 0 ] && [ "$IS_ROOT" -eq 0 ]; then
    die "nas recreate needs root — run: sudo ./nas recreate $*"
  fi

  destroy_plan
  destroy_show_plan
  [ "$DRY_RUN" -eq 1 ] && exit 0
  say "After the teardown above, the same units are reinstalled."
  destroy_confirm || { echo "Refused — nothing was changed."; exit 2; }
  destroy_offer_save_logs
  destroy_execute

  install_preflight
  install_run
  . lib/cmd_post_install.sh
  [ "$no_post_install" -eq 1 ] || post_install_run

  if [ -n "$FAILED_UNITS" ]; then
    ui_banner "Recreate incomplete — failed:${FAILED_UNITS}" \
      "These units are DOWN, not restored. Resume with:" \
      "  sudo ./nas install $(selected_units | sed 's/^ *//')"
    exit 1
  fi
  say "Summary"
  local unit
  for unit in $(selected_units); do
    info "${unit}: recreated"
  done
  exit 0
}

recreate_usage() {
  cat <<EOF
nas recreate <unit...> [--yes] [--dry-run] [--wipe-qbittorrent] [--no-post-install]

Destroys and reinstalls the named units, one confirmation up front covering
both. The unit stays wired into the rest of the stack: same nas-net, same
shared identity, same API keys (each unit's own .env survives).
EOF
}
