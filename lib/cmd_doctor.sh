# shellcheck shell=bash
# nas doctor — read-only diagnosis of the known failure modes, so debugging
# starts from mechanism instead of guesswork. Each failure states the
# mechanism and the fix; exit non-zero if any check fails.

DOCTOR_FAILURES=0

doctor_pass() { info "ok: $1"; }
doctor_fail() {
  DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
  warn "FAIL: $1"
  [ -n "${2:-}" ] && warn "  fix: $2"
}

cmd_doctor() {
  local args=() arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) doctor_usage; return 0 ;;
      -*)        die "unknown flag '${arg}' for nas doctor" ;;
      *)         args+=("$arg") ;;
    esac
  done
  select_units doctor 1 ${args[@]+"${args[@]}"}
  command -v docker >/dev/null 2>&1 || die "docker is required"
  docker_reachable || warn "cannot reach the docker daemon as this user — container-dependent checks are skipped (re-run: sudo ./nas doctor)"

  local unit
  for unit in $(selected_units); do
    unit_load "$unit"
    unit_env_load
    say "doctor: ${unit}"
    if [ -n "$UNIT_ENV_FILE" ] && [ ! -f "$UNIT_ENV_FILE" ]; then
      if [ "$UNIT_STANDALONE" -eq 1 ]; then
        info "not configured yet (${UNIT_ENV_FILE} missing) — run: ./nas configure ${unit}, then: cd pi-hole && sudo docker compose up -d"
      else
        info "not installed yet (${UNIT_ENV_FILE} missing) — run: sudo ./nas install ${unit}"
      fi
      continue
    fi
    doctor_compose_renders
    doctor_container_vs_env
    doctor_ports
    if unit_has_hook unit_doctor; then
      unit_doctor
    fi
  done

  if [ "$DOCTOR_FAILURES" -gt 0 ]; then
    say "${DOCTOR_FAILURES} check(s) failed"
    exit 1
  fi
  say "All checks passed"
  exit 0
}

doctor_usage() {
  cat <<EOF
nas doctor [unit...]

Read-only checks per unit: compose config renders, container not older than
its .env files (the "401 means stale container, not wrong key" trap), no
foreign listener on the unit's ports, docker-socket access for the units that
mount it, and unit-specific probes (render device, allowed hosts, pihole DNS).
EOF
}

doctor_compose_renders() {
  local flags
  flags=$(compose_env_flags)
  # shellcheck disable=SC2086
  if docker compose ${UNIT_PROJECT:+-p "$UNIT_PROJECT"} $flags -f "$UNIT_COMPOSE_FILE" config >/dev/null 2>&1; then
    doctor_pass "compose config renders"
  else
    doctor_fail "compose config does not render" \
      "docker compose ${UNIT_PROJECT:+-p ${UNIT_PROJECT} }${flags# } -f ${UNIT_COMPOSE_FILE} config"
  fi
}

# The apps read their API key from the environment at every start; a container
# created before its .env changed still holds the old value, and every 401
# that "should" work traces back to this.
doctor_container_vs_env() {
  local created created_epoch f mtime stale=""
  created=$(docker inspect -f '{{.Created}}' "$UNIT_CONTAINER" 2>/dev/null) || return 0
  created_epoch=$(date -d "$created" +%s 2>/dev/null) || return 0
  for f in $UNIT_ENV_FILES $UNIT_ENV_FILE; do
    [ -f "$f" ] || continue
    mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$mtime" -gt "$created_epoch" ] && stale="${stale} ${f}"
  done
  if [ -n "$stale" ]; then
    doctor_fail "container is older than:${stale} — it still runs with the previous values (a 401 here means stale container, not wrong key)" \
      "sudo ./nas recreate ${UNIT_NAME}"
  else
    doctor_pass "container is newer than its env files"
  fi
}

doctor_ports() {
  local flags port state=""
  docker_reachable && state=$(container_state "$UNIT_CONTAINER")
  flags=$(compose_env_flags)
  # shellcheck disable=SC2086
  for port in $(docker compose ${UNIT_PROJECT:+-p "$UNIT_PROJECT"} $flags -f "$UNIT_COMPOSE_FILE" config 2>/dev/null \
      | awk '/published:/ {gsub(/"/,"",$2); print $2}' | sort -u); do
    if [ "$state" = "running" ]; then
      doctor_pass "port ${port} owned by the running container"
      continue
    fi
    if listener_on_port "$port"; then
      if docker_reachable; then
        doctor_fail "port ${port}: ${UNIT_NAME} is not running but something listens there" \
          "identify it: sudo ss -ltnp 'sport = :${port}'"
      else
        info "port ${port} has a listener — cannot attribute it without docker access (sudo ./nas doctor)"
      fi
    else
      doctor_pass "port ${port} free"
    fi
  done
}

listener_on_port() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${1}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${1}$"
  else
    return 1
  fi
}

# Socket access is a DAC problem: pass = the socket's group equals the GID in
# the container's Config.User (the primary-GID idiom — a `docker exec` session
# gets fresh credentials, so it proves nothing about the server process).
doctor_socket_access() {
  local sock_gid cfg_user container_gid
  [ -S /var/run/docker.sock ] || { info "no /var/run/docker.sock here — skipped"; return 0; }
  docker_reachable || { info "docker unreachable — socket check skipped"; return 0; }
  cfg_user=$(docker inspect -f '{{.Config.User}}' "$UNIT_CONTAINER" 2>/dev/null) \
    || { info "${UNIT_CONTAINER} not created — socket check skipped"; return 0; }
  sock_gid=$(stat -c %g /var/run/docker.sock 2>/dev/null) || return 0
  container_gid="${cfg_user##*:}"
  if [ "$container_gid" = "$sock_gid" ]; then
    doctor_pass "socket GID ${sock_gid} matches Config.User ${cfg_user}"
    return 0
  fi
  doctor_fail "socket is group ${sock_gid} but ${UNIT_CONTAINER} runs as '${cfg_user}' — EACCES means found-and-refused, not a path problem" \
    "set DOCKER_GID=${sock_gid} in shared.env, then: sudo ./nas recreate ${UNIT_NAME}"
  info "mechanism trail:"
  info "  docker inspect ${UNIT_CONTAINER} --format '{{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}'"
  info "  docker exec ${UNIT_CONTAINER} cat /proc/1/status | grep -E 'Groups|CapEff'"
  info "  dmesg | grep -i denied   # AppArmor"
}

# Every name/address Homepage is reached AT must be listed literally — no
# wildcard or CIDR matching exists, and an unlisted Host header gets a 400.
doctor_allowed_hosts() {
  local hosts="${HOMEPAGE_ALLOWED_HOSTS:-}" short want_host missing=""
  [ "$hosts" = "*" ] && { doctor_pass "HOMEPAGE_ALLOWED_HOSTS=* (check disabled)"; return 0; }
  short=$(hostname -s 2>/dev/null || true)
  for want_host in ${short:+${short}.local} ${LAN_HOST:-}; do
    case ",${hosts}," in
      *",${want_host},"*) ;;
      *) missing="${missing} ${want_host}" ;;
    esac
  done
  if [ -n "$missing" ]; then
    doctor_fail "HOMEPAGE_ALLOWED_HOSTS is missing:${missing} — requests at those names get a 400" \
      "add them (comma-separated, literal) to homepage.env, then: sudo ./nas recreate homepage"
  else
    doctor_pass "HOMEPAGE_ALLOWED_HOSTS covers ${short}.local and ${LAN_HOST:-LAN_HOST}"
  fi
}
