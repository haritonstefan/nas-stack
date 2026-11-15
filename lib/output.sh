# shellcheck shell=bash
# Sourced by ./nas. Output and prompt helpers.

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1" >&2; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

DRY_RUN="${DRY_RUN:-0}"

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

is_tty() { [ -t 0 ] && [ -t 1 ]; }

# ui_confirm <prompt> [Y|N] — returns 0 for yes. Default is No unless Y given.
# Without a TTY it always answers no.
ui_confirm() {
  local prompt="$1" def="${2:-N}" hint ans
  is_tty || return 1
  [ "$def" = "Y" ] && hint="Y/n" || hint="y/N"
  while :; do
    printf '    %s [%s]: ' "$prompt" "$hint"
    IFS= read -r ans
    case "${ans:-$def}" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

ui_banner() {
  printf '\n'
  printf '  # %s\n' "$@"
  printf '\n'
}
