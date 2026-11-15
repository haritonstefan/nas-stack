# shellcheck shell=bash
UNIT_PORT=8096   # fixed: host networking, no ports: mapping to vary
UNIT_DIRS="JELLYFIN_CONFIG_DIR JELLYFIN_CACHE_DIR"
UNIT_CHECK_DIRS="MEDIA_MOVIES_DIR MEDIA_SERIES_DIR MEDIA_MUSIC_DIR"
UNIT_LOG_PATHS="JELLYFIN_CONFIG_DIR/log"

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
