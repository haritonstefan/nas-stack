# shellcheck shell=bash
# nas logs — docker logs with the unit's container resolved, plus the one
# piece of knowledge the raw command lacks: configarr's scheduled-run history
# lives in ofelia's logs.

cmd_logs() {
  local unit="" passthrough=() arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) logs_usage; return 0 ;;
      --follow|-f|--since|--since=*|--tail|--tail=*|--timestamps|-t) passthrough+=("$arg") ;;
      -*)  passthrough+=("$arg") ;;
      *)
        if [ -n "$unit" ]; then
          # --since and --tail take a value argument
          passthrough+=("$arg")
        else
          unit="$arg"
        fi ;;
    esac
  done
  [ -n "$unit" ] || die "usage: nas logs <unit> [--follow] [--since ...]"
  is_unit "$unit" || is_standalone "$unit" || die "unknown unit '${unit}'"
  unit_load "$unit"

  local rc=0
  docker logs ${passthrough[@]+"${passthrough[@]}"} "$UNIT_CONTAINER" || rc=$?
  if [ "$unit" = "configarr" ]; then
    info "(configarr is run-to-completion; scheduled-run history: docker logs ofelia)"
  fi
  return "$rc"
}

logs_usage() {
  cat <<EOF
nas logs <unit> [--follow] [--since ...] [--tail ...]

docker logs on the unit's container, flags passed through. For configarr —
run-to-completion, so 'docker logs' works on the exited container — it also
points at ofelia for the scheduled-run history.
EOF
}
