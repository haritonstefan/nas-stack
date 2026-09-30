# shellcheck shell=bash
UNIT_PORT=8096   # fixed: host networking, no ports: mapping to vary
UNIT_DIRS="JELLYFIN_CONFIG_DIR JELLYFIN_CACHE_DIR"
UNIT_CHECK_DIRS="MEDIA_MOVIES_DIR MEDIA_SERIES_DIR MEDIA_MUSIC_DIR"
UNIT_REQUIRED="ADMIN_PASSWORD"
UNIT_MINTED="JELLYFIN_API_KEY JELLYFIN_SCAN_TASK_ID"
UNIT_POST_INSTALL="jellyfin-bootstrap.sh"
UNIT_LOG_PATHS="JELLYFIN_CONFIG_DIR/log"

unit_configure() {
  local cur ex def det_subnet=""

  wiz_ask "Server name (JELLYFIN_SERVER_NAME)" "$(wiz_get jellyfin JELLYFIN_SERVER_NAME)" is_nonempty
  stage jellyfin JELLYFIN_SERVER_NAME "$REPLY_VALUE"

  cur=$(wiz_get jellyfin RENDER_GID); ex=$(wiz_get_example jellyfin RENDER_GID)
  def=$(pick_default "$cur" "$ex" "$DET_RENDER_GID")
  if [ -z "$DET_RENDER_GID" ]; then
    info "render GID not detectable here — confirm with: stat -c '%g' /dev/dri/renderD128"
  fi
  if [ "$ADVANCED" -eq 1 ]; then
    wiz_ask "RENDER_GID" "$def" is_gid
    def="$REPLY_VALUE"
  fi
  stage jellyfin RENDER_GID "$def"

  cur=$(wiz_get jellyfin JELLYFIN_LOCAL_SUBNET); ex=$(wiz_get_example jellyfin JELLYFIN_LOCAL_SUBNET)
  [ -n "$DET_LAN_IP" ] && det_subnet="${DET_LAN_IP%.*}.0/24"
  def=$(pick_default "$cur" "$ex" "$det_subnet")
  if [ "$ADVANCED" -eq 1 ]; then
    wiz_ask "JELLYFIN_LOCAL_SUBNET" "$def" is_subnet
    def="$REPLY_VALUE"
  fi
  stage jellyfin JELLYFIN_LOCAL_SUBNET "$def"
}

unit_doctor() {
  # Hardware transcoding needs the render node; without it the container
  # fails to start because the device bind has no source.
  if [ -e /dev/dri/renderD128 ]; then
    local actual_gid
    actual_gid=$(stat -c %g /dev/dri/renderD128 2>/dev/null || true)
    if [ -n "$actual_gid" ] && [ "$actual_gid" != "${RENDER_GID:-105}" ]; then
      doctor_fail "RENDER_GID is ${RENDER_GID:-105} but this host's render group is ${actual_gid}" \
        "update RENDER_GID in jellyfin.env, then: sudo ./nas recreate jellyfin"
    else
      doctor_pass "render device present, RENDER_GID matches"
    fi
  else
    doctor_fail "/dev/dri/renderD128 missing" \
      "remove the devices: block from docker-compose.jellyfin.yml or the container will not start"
  fi
}
