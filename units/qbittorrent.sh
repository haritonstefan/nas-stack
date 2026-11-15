# shellcheck shell=bash
UNIT_PORT=8080
UNIT_PORT_VAR=QBITTORRENT_PORT
UNIT_DIRS="QBITTORRENT_CONFIG_DIR DOWNLOADS_DIR DOWNLOADS_DIR/complete DOWNLOADS_DIR/incomplete"
UNIT_REQUIRED="ADMIN_PASSWORD"

# Adopted, not recreated, so it keeps seeding. It must still agree with this
# repo on three things: /downloads is the path the arr apps import from (a
# mismatch is a silent remote-path-mapping failure), /config is the dir destroy
# would delete, and nas-net is how they reach http://qbittorrent.
unit_adopt() {
  local c="$UNIT_CONTAINER" mounts nets rc=0
  mounts=$(docker inspect -f '{{range .Mounts}}{{.Destination}}={{.Source}}{{"\n"}}{{end}}' "$c") || return 1
  adopt_check_mount "$mounts" /config \
    "${QBITTORRENT_CONFIG_DIR:-/volume2/docker/qbittorrent/config}" \
    "QBITTORRENT_CONFIG_DIR (qbittorrent.env)" || rc=1
  adopt_check_mount "$mounts" /downloads \
    "${DOWNLOADS_DIR:-/volume2/docker/downloads}" \
    "DOWNLOADS_DIR (shared.env — sonarr/radarr/lidarr mount it too)" || rc=1
  if [ "$rc" -ne 0 ]; then
    warn "${c} not adopted — make the env match what the container really mounts, then re-run install"
    return 1
  fi

  nets=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c")
  case " ${nets} " in
    *" nas-net "*) ;;
    *) run docker network connect nas-net "$c" || return 1
       info "attached ${c} to nas-net" ;;
  esac
  [ "$(container_state "$c")" = "running" ] || run docker start "$c" || return 1
  info "${c} adopted ($(docker inspect -f '{{.Config.Image}}' "$c")) — to put it under ${UNIT_PROJECT} instead: sudo ./nas destroy qbittorrent --containers && sudo ./nas install qbittorrent"
}

adopt_check_mount() { # adopt_check_mount <mounts> <container path> <expected host path> <where it is set>
  local got want="${3%/}"
  got=$(printf '%s\n' "$1" | sed -n "s|^${2}=||p")
  [ "$got" = "$want" ] && return 0
  warn "${UNIT_CONTAINER} mounts ${2} from '${got:-nothing}', but ${4} says '${want}'"
  return 1
}
