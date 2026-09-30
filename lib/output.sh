# shellcheck shell=bash
# Sourced by ./nas. Plain output helpers plus the gum presentation layer.
# gum is presentation only: every ui_* helper degrades to read/printf when
# there is no TTY or the vendored binary is missing or fails its checksum,
# so a gum upgrade can never change what the CLI does (R6).

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1" >&2; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

is_tty() { [ -t 0 ] && [ -t 1 ]; }

GUM_BIN=""
GUM_CHECKED=0

gum_ok() {
  if [ "$GUM_CHECKED" -eq 0 ]; then
    GUM_CHECKED=1
    local dir bin
    for dir in vendor/gum/*/; do
      [ -d "$dir" ] || continue
      bin="${dir}gum-linux-amd64"
      [ -f "$bin" ] && [ -f "${bin}.sha256" ] || continue
      if ! (cd "$dir" && { sha256sum -c gum-linux-amd64.sha256 \
          || shasum -a 256 -c gum-linux-amd64.sha256; } >/dev/null 2>&1); then
        warn "vendored gum failed its checksum — falling back to plain prompts"
        continue
      fi
      if [ -x "$bin" ] && "$bin" --version >/dev/null 2>&1; then
        GUM_BIN="$bin"
      fi
    done
  fi
  [ -n "$GUM_BIN" ]
}

ui_available() { is_tty && gum_ok; }

# ui_confirm <prompt> [Y|N] — returns 0 for yes. Default is No unless Y given.
ui_confirm() {
  local prompt="$1" def="${2:-N}" hint ans
  if ui_available; then
    local defflag=--default=false
    [ "$def" = "Y" ] && defflag=--default=true
    "$GUM_BIN" confirm "$defflag" "$prompt"
    return $?
  fi
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

# ui_input <prompt> <default> — result in REPLY_VALUE.
ui_input() {
  local prompt="$1" default="$2"
  if ui_available; then
    REPLY_VALUE=$("$GUM_BIN" input --prompt "    ${prompt}: " --value "$default") || return 1
    return 0
  fi
  IFS= read -r -e -i "$default" -p "    ${prompt}: " REPLY_VALUE
}

# ui_input_secret <prompt> — masked, result in REPLY_VALUE.
ui_input_secret() {
  local prompt="$1"
  if ui_available; then
    REPLY_VALUE=$("$GUM_BIN" input --password --prompt "    ${prompt}: ") || return 1
    return 0
  fi
  printf '    %s: ' "$prompt"
  IFS= read -rs REPLY_VALUE
  printf '\n'
}

# ui_choose_multi <item...> — pre-selects everything, result in REPLY_VALUE
# (space-separated). Falls back to "all" without gum: the argv path is the
# non-interactive selection mechanism.
ui_choose_multi() {
  if ui_available; then
    REPLY_VALUE=$(printf '%s\n' "$@" | "$GUM_BIN" choose --no-limit \
      --selected "$(IFS=,; printf '%s' "$*")" | tr '\n' ' ')
    return 0
  fi
  REPLY_VALUE="$*"
}

ui_banner() {
  if ui_available; then
    "$GUM_BIN" style --border rounded --padding "0 2" --margin "1 0" "$@"
  else
    printf '\n'
    printf '  # %s\n' "$@"
    printf '\n'
  fi
}
