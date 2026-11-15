# shellcheck shell=bash
# Sourced by ./nas. Creating .env files and generating the per-unit API keys.

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

# Files created under sudo would otherwise end up root-owned inside a
# user-owned repo, leaving the invoking user unable to read their own .env.
repo_own() {
  [ "$IS_ROOT" -eq 1 ] && [ -n "${SUDO_UID:-}" ] || return 0
  chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$1"
}

# env_file_create <path> — from <path>.example, never overwriting.
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

# env_set <file> <name> <value> — replace the first ^name= line in place,
# append when absent. Later duplicates are dropped: shell-sourcing makes the
# LAST value win, so a surviving duplicate would override the one just
# written. Only ever called with hex keys, so the value needs no quoting.
env_set() {
  local file="$1" name="$2" value="$3" line replaced=0
  : > "${file}.tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${name}="*)
        [ "$replaced" -eq 0 ] && printf '%s=%s\n' "$name" "$value" >> "${file}.tmp"
        replaced=1
        continue ;;
    esac
    printf '%s\n' "$line" >> "${file}.tmp"
  done < "$file"
  [ "$replaced" -eq 1 ] || printf '%s=%s\n' "$name" "$value" >> "${file}.tmp"
  cat "${file}.tmp" > "$file"   # keeps the original owner and mode
  rm -f "${file}.tmp"
}

# 32 lowercase hex chars, matching what the arr apps mint themselves.
gen_api_key() { od -vAn -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# gen_secret_into <env-file-path> <name> — exactly once; a non-empty value is
# never regenerated: the apps read the key from the environment at every start
# and never persist it, so rotating it silently breaks Prowlarr sync and the
# Homepage widgets at once. Generated even under --dry-run: the compose files
# declare these ${VAR:?}, so not even `docker compose config` interpolates
# while they are empty.
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
