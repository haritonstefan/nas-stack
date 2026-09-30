# shellcheck shell=bash
# nas indexers — Prowlarr tracker wiring. Deliberately not part of install:
# Prowlarr fetches its Cardigann definitions shortly after start, so a
# definition missing on the first run often appears on a later one; the script
# is idempotent and re-runnable.

cmd_indexers() {
  local arg passthrough=()
  for arg in "$@"; do
    case "$arg" in
      -h|--help) indexers_usage; return 0 ;;
      --dry-run|--verbose|-v|--non-interactive) passthrough+=("$arg") ;;
      *) die "unknown argument '${arg}' for nas indexers" ;;
    esac
  done
  exec ./arr-indexers.sh ${passthrough[@]+"${passthrough[@]}"}
}

indexers_usage() {
  cat <<EOF
nas indexers [--dry-run] [--verbose] [--non-interactive]

Adds the trackers to Prowlarr: the byparr tag, the Byparr proxy, the public
and private indexers (arr-indexers.sh). Prompts per failing indexer;
--non-interactive saves untested with a warning instead.
EOF
}
