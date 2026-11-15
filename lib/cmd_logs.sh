# shellcheck shell=bash
# nas logs — docker logs with the unit's container resolved.

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

  docker logs ${passthrough[@]+"${passthrough[@]}"} "$UNIT_CONTAINER"
}

logs_usage() {
  cat <<EOF
nas logs <unit> [--follow] [--since ...] [--tail ...]

docker logs on the unit's container, flags passed through.
EOF
}
