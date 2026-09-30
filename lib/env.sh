# shellcheck shell=bash
# Sourced by ./nas. Everything that reads or writes a .env file.
#
# These files are dual-parsed — shell-sourced by the CLI and the bootstraps,
# dotenv-parsed by docker compose — and both read single quotes literally, so
# there is exactly one quoting rule, shared by the wizard and the secret
# generator: bare when the value is entirely safe characters, single-quoted
# with close-escape-reopen otherwise.

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

# Files created under sudo would otherwise end up root-owned inside a
# user-owned repo, leaving the invoking user unable to read their own .env.
repo_own() {
  [ "$IS_ROOT" -eq 1 ] && [ -n "${SUDO_UID:-}" ] || return 0
  chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$1"
}

# env_file_create <path> — from <path>.example, never overwriting (R5).
env_file_create() {
  local file="$1"
  if [ -f "$file" ]; then
    info "${file} exists, leaving untouched"
    return 0
  fi
  [ -f "${file}.example" ] || return 0
  run cp "${file}.example" "$file"
  [ "$DRY_RUN" -eq 1 ] || repo_own "$file"
  info "${file} $([ "$DRY_RUN" -eq 1 ] && echo 'would be created' || echo created) from ${file}.example"
}

# env_quote <value> — a ready-to-write RHS. Single quotes are literal in both
# parsers but neither allows one inside; the shell's close-escape-reopen idiom
# is a compose dotenv parse ERROR that kills every compose call on the file.
# A value carrying a single quote is double-quoted with \\ \" \$ escaped —
# verified identical in both parsers — except backticks, where they disagree,
# so a value with both ' and ` is refused.
env_quote() {
  if printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9_./:@,+=-]*$'; then
    printf '%s' "$1"
    return 0
  fi
  case "$1" in
    *"'"*)
      case "$1" in
        *'`'*) die "cannot store a value containing both a single quote and a backtick — shell and compose dotenv cannot agree on it; pick another value" ;;
      esac
      printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g')" ;;
    *)
      printf "'%s'" "$1" ;;
  esac
}

# env_set <file> <name> <value> — replace the first ^name= line in place,
# preserving order and comments; append under a marker when absent. Later
# duplicate lines are dropped: shell-sourcing makes the LAST value win, so a
# surviving duplicate would silently override the one just written. Pure
# bash: a sed replacement side would corrupt on & or \ in a password.
env_set() {
  local file="$1" name="$2" value="$3" line new_line replaced=0
  new_line="${name}=$(env_quote "$value")"
  : > "${file}.tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${name}="*)
        if [ "$replaced" -eq 0 ]; then
          printf '%s\n' "$new_line" >> "${file}.tmp"
          replaced=1
        fi
        continue ;;
    esac
    printf '%s\n' "$line" >> "${file}.tmp"
  done < "$file"
  if [ "$replaced" -eq 0 ]; then
    grep -q '^# --- added by nas configure ---$' "${file}.tmp" \
      || printf '\n# --- added by nas configure ---\n' >> "${file}.tmp"
    printf '%s\n' "$new_line" >> "${file}.tmp"
  fi
  cat "${file}.tmp" > "$file"   # keeps the original owner and mode
  rm -f "${file}.tmp"
}

# env_get <env-file-path> <name> — the value exactly as every consumer will
# read it: example default first, real file over it.
env_get() {
  local file="$1" name="$2"
  ( set +eu
    # shellcheck disable=SC1090
    [ -f "${file}.example" ] && . "./${file}.example" >/dev/null 2>&1
    # shellcheck disable=SC1090
    [ -f "$file" ] && . "./$file" >/dev/null 2>&1
    eval "printf '%s' \"\${${name}-}\"" ) 2>/dev/null || true
}

env_get_example() {
  local file="$1" name="$2"
  ( set +eu
    # shellcheck disable=SC1090
    [ -f "${file}.example" ] && . "./${file}.example" >/dev/null 2>&1
    eval "printf '%s' \"\${${name}-}\"" ) 2>/dev/null || true
}

example_vars() { # variable names in <env-file-path>.example, file order
  grep -E '^[A-Z][A-Z0-9_]*=' "${1}.example" 2>/dev/null | cut -d= -f1
}

# The contiguous # block above VAR= in the example — the wizard's help text,
# so it tracks example edits for free.
env_help_for() {
  awk -v var="$2" '
    /^#/ { buf = buf $0 "\n"; next }
    index($0, var "=") == 1 { printf "%s", buf; exit }
    { buf = "" }
  ' "${1}.example" 2>/dev/null
}

# --- generated secrets ----------------------------------------------------------

# 32 lowercase hex chars, matching what the arr apps mint themselves.
gen_api_key() { od -vAn -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# gen_secret_into <env-file-path> <name> — exactly once; a non-empty value is
# never regenerated (R2: rotating a key silently breaks Prowlarr sync,
# Configarr and that unit's Homepage widget at once). Generated even under
# --dry-run: the compose files declare these ${VAR:?}, so nothing — not even
# `docker compose config` — interpolates while they are empty, and writing a
# gitignored .env is not the kind of change a dry run withholds.
gen_secret_into() {
  local file="$1" name="$2" current new_value
  [ -f "$file" ] || return 0
  eval "current=\${${name}:-}"
  if [ -n "$current" ]; then
    info "${name} already set, keeping it"
    return 0
  fi
  new_value="$(gen_api_key)"
  env_set "$file" "$name" "$new_value"
  eval "export ${name}=\"\$new_value\""
  repo_own "$file"
  chmod 600 "$file"
  info "${name} generated (${file})"
}
