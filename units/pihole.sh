# shellcheck shell=bash
# Standalone macvlan unit (docs/pihole-spec.md): the CLI covers configure and
# the read-only verbs; its lifecycle stays `cd pi-hole && sudo docker compose`.
UNIT_STANDALONE=1
UNIT_PROJECT=""
UNIT_CONTAINER="pihole"
UNIT_COMPOSE_FILE="pi-hole/docker-compose.yml"
UNIT_ENV_FILE="pi-hole/.env"
UNIT_ENV_FILES=""
UNIT_REQUIRED="PIHOLE_PASSWORD"

# Own credential, not the shared identity (P4): a standalone unit reading
# shared.env would be self-contained in name only.
unit_configure() {
  local cur
  cur=$(wiz_get pihole PIHOLE_PASSWORD)
  if [ -n "$cur" ]; then
    if ! ui_confirm "PIHOLE_PASSWORD is already set — keep it?" Y; then
      wiz_ask_secret "New PiHole web password"
      stage pihole PIHOLE_PASSWORD "$REPLY_VALUE"
    fi
  else
    wiz_ask_secret "PiHole web password (its own credential, not the shared identity)"
    stage pihole PIHOLE_PASSWORD "$REPLY_VALUE"
  fi
}

unit_doctor() {
  local state
  docker_reachable || { info "docker unreachable — container checks skipped"; return 0; }
  state=$(container_state pihole)
  if [ "$state" != "running" ]; then
    doctor_fail "pihole container is ${state:-absent}" \
      "cd pi-hole && sudo docker compose up -d"
    return 0
  fi
  # The NAS itself cannot reach the macvlan address (kernel rule), so the
  # only local probe is from inside the container.
  if docker exec pihole sh -c 'command -v dig >/dev/null 2>&1'; then
    if docker exec pihole dig +short +time=3 @127.0.0.1 example.com >/dev/null 2>&1; then
      doctor_pass "pihole answers DNS from inside the container"
    else
      doctor_fail "pihole is running but DNS does not answer inside the container" \
        "docker logs pihole"
    fi
  else
    info "no dig inside the pihole image — skipping the in-container probe"
  fi
  info "LAN-side check (run from a client, never from the NAS):"
  info "  dig @${PIHOLE_IP:-192.168.0.53} example.com"
}
