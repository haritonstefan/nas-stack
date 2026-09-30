# shellcheck shell=bash
# nas status — per-unit state, cheap by construction: filesystem and
# docker-socket checks plus one TCP connect per tile. Never a service API
# call (N4).

cmd_status() {
  local args=() arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) status_usage; return 0 ;;
      -*)        die "unknown flag '${arg}' for nas status" ;;
      *)         args+=("$arg") ;;
    esac
  done
  select_units status 1 ${args[@]+"${args[@]}"}

  local rows unit
  rows="unit\tstate\tenv\tconfig\ttile"
  for unit in $(selected_units); do
    rows="${rows}\n$(status_row "$unit")"
  done
  if ui_available; then
    printf '%b\n' "$rows" | "$GUM_BIN" table --print --separator "$(printf '\t')"
  else
    printf '%b\n' "$rows" | column -t -s "$(printf '\t')" 2>/dev/null \
      || printf '%b\n' "$rows"
  fi

  if [ "${#args[@]}" -eq 1 ] && { is_unit "${args[0]}" || is_standalone "${args[0]}"; }; then
    status_detail "${args[0]}"
  fi
}

status_usage() {
  cat <<EOF
nas status [unit...]

Per-unit state table: container state, .env presence + required values,
config dir + template drift, and whether the web port answers on 127.0.0.1.
A single unit argument adds detail (image, ports, mounts). Read-only, no
root needed, never calls a service API.
EOF
}

status_row() {
  local unit="$1" state env_col config_col tile_col
  unit_load "$unit"
  unit_env_load

  state=$(container_state "$UNIT_CONTAINER")
  [ -n "$state" ] || state="not-installed"

  if [ ! -f "$UNIT_ENV_FILE" ]; then
    env_col="missing"
  else
    env_col="ok"
    local var val
    for var in $UNIT_REQUIRED; do
      eval "val=\${${var}:-}"
      [ -n "$val" ] || { env_col="empty:${var}"; break; }
    done
  fi

  config_col=$(status_config_col)
  tile_col=$(status_tile_col)
  printf '%s\t%s\t%s\t%s\t%s' "$unit" "$state" "$env_col" "$config_col" "$tile_col"
}

status_config_col() {
  local dir drift=0 pair src dest_var dest_dir dest
  dir=$(unit_config_dir 2>/dev/null) || { printf '%s' "—"; return; }
  [ -d "$dir" ] || { printf '%s' "absent"; return; }
  for pair in $UNIT_TEMPLATES; do
    src="${pair%%:*}"
    dest_var="${pair#*:}"
    eval "dest_dir=\${${dest_var}:-}"
    dest="${dest_dir}/$(basename "$src")"
    [ -f "$dest" ] || continue
    cmp -s "$src" "$dest" || drift=$((drift + 1))
  done
  if [ "$drift" -gt 0 ]; then
    printf 'drift:%d' "$drift"
  else
    printf 'ok'
  fi
}

status_tile_col() {
  local port
  port=$(unit_port)
  if [ -z "$port" ] || [ "$UNIT_STANDALONE" -eq 1 ]; then
    printf '%s' "—"
    return
  fi
  if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
    printf 'up:%s' "$port"
  else
    printf 'down:%s' "$port"
  fi
}

status_detail() {
  local unit="$1"
  unit_load "$unit"
  docker inspect "$UNIT_CONTAINER" >/dev/null 2>&1 || return 0
  say "${unit} detail"
  docker inspect "$UNIT_CONTAINER" --format \
    'image:   {{.Config.Image}}
created: {{.Created}}
ports:   {{range $p, $b := .NetworkSettings.Ports}}{{$p}} {{end}}
mounts:  {{range .Mounts}}{{.Source}} -> {{.Destination}} ({{if .RW}}rw{{else}}ro{{end}})
         {{end}}' | sed 's/^/    /'
}
