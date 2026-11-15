#!/usr/bin/env bash
# The single entrypoint for the stack (docs/cli-spec.md): every lifecycle
# operation on the units goes through here. Runs on the NAS, from anywhere —
# it resolves its own directory, so the caller's cwd never matters.

set -euo pipefail
cd "$(dirname "$0")"
NAS_SELF="./nas"

. lib/output.sh
. lib/units.sh
. lib/env.sh
. lib/paths.sh
. lib/compose.sh

FAILED_UNITS=""
mark_failed() {
  case " $FAILED_UNITS " in *" ${1}:"*) return 0 ;; esac
  FAILED_UNITS="${FAILED_UNITS} ${1}:${2}"
}

usage() {
  cat <<EOF
nas — manage the apollo NAS stack

  sudo ./nas install [unit...|all]    bring units up
  sudo ./nas destroy [unit...|all]    tear down (plan + confirm; --yes)
  sudo ./nas recreate <unit...>       destroy + install, one confirmation
  ./nas status       [unit...]        per-unit state table
  ./nas logs <unit> [--follow]        docker logs, unit-aware
  ./nas doctor       [unit...]        read-only checks of known failure modes

Units:   ${UNITS_ALL}
         ${UNITS_STANDALONE} (standalone: read-only verbs only)
Aliases: core -> homepage · arr -> ${ARR_UNITS} · all

'nas <verb> --help' has the details. Typical first run:
  sudo ./nas install, fill in the .env files it creates, sudo ./nas install again.
Service setup (libraries, download clients, indexers) is done by hand in each UI.
EOF
}

[ "$#" -ge 1 ] || { usage; exit 1; }
VERB="$1"
shift

case "$VERB" in
  install)       . lib/cmd_install.sh;      cmd_install "$@" ;;
  destroy)       . lib/cmd_destroy.sh;      cmd_destroy "$@" ;;
  recreate)      . lib/cmd_destroy.sh; . lib/cmd_install.sh; . lib/cmd_recreate.sh
                 cmd_recreate "$@" ;;
  status)        . lib/cmd_status.sh;       cmd_status "$@" ;;
  logs)          . lib/cmd_logs.sh;         cmd_logs "$@" ;;
  doctor)        . lib/cmd_doctor.sh;       cmd_doctor "$@" ;;
  update)        die "nas update is reserved but not designed yet — edit the image pin and run: sudo ./nas recreate <unit>" ;;
  help|-h|--help) usage ;;
  *)             echo "Unknown verb: ${VERB}" >&2; usage >&2; exit 1 ;;
esac
