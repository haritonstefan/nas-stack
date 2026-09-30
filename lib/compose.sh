# shellcheck shell=bash
# Sourced by ./nas. Compose invocation for the loaded unit.
#
# Compose does not read .env files on its own, and every unit shares one
# directory — so --env-file (shared.env first, then the unit's own) and
# -p nas-<unit> are required on every call, or the units collapse into one
# project and report each other as orphans.

compose_env_flags() { # only files that exist: configarr's down still needs
  local f flags=""     # sonarr.env/radarr.env to interpolate, when present
  for f in $UNIT_ENV_FILES; do
    [ -f "$f" ] && flags="${flags} --env-file ${f}"
  done
  printf '%s' "$flags"
}

compose_unit() { # compose_unit <args...>
  # shellcheck disable=SC2046
  run docker compose -p "$UNIT_PROJECT" $(compose_env_flags) -f "$UNIT_COMPOSE_FILE" "$@"
}

compose_up_unit() {
  local f
  for f in $UNIT_ENV_FILES; do
    if [ ! -f "$f" ]; then
      warn "skipping ${UNIT_NAME} — ${f} is missing"
      return 0
    fi
  done
  # shellcheck disable=SC2086
  compose_unit up -d $UNIT_UP_ARGS
}

compose_down_unit() {
  # shellcheck disable=SC2086
  compose_unit $UNIT_DOWN_ARGS down --remove-orphans
}

ensure_nas_net() {
  if docker network inspect nas-net >/dev/null 2>&1; then
    info "nas-net exists"
  else
    run docker network create nas-net >/dev/null
    info "nas-net $([ "$DRY_RUN" -eq 1 ] && echo 'would be created' || echo created)"
  fi
}

container_state() { # running / exited / created / "" when absent
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true
}

# The read-only verbs run without root, but the socket is root:docker — an
# unreachable daemon must read as "unknown", never as "not installed" or as a
# foreign process on our port.
DOCKER_OK=""
docker_reachable() {
  if [ -z "$DOCKER_OK" ]; then
    if docker info >/dev/null 2>&1; then DOCKER_OK=1; else DOCKER_OK=0; fi
  fi
  [ "$DOCKER_OK" -eq 1 ]
}
