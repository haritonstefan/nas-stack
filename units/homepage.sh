# shellcheck shell=bash
UNIT_PORT=80
UNIT_PORT_VAR=HOMEPAGE_HTTP_PORT
UNIT_DIRS="HOMEPAGE_CONFIG_DIR"
UNIT_TEMPLATES="homepage-config/docker.yaml:HOMEPAGE_CONFIG_DIR
homepage-config/services.yaml:HOMEPAGE_CONFIG_DIR
homepage-config/bookmarks.yaml:HOMEPAGE_CONFIG_DIR
homepage-config/settings.yaml:HOMEPAGE_CONFIG_DIR
homepage-config/widgets.yaml:HOMEPAGE_CONFIG_DIR"

unit_configure() {
  local cur def t val
  cur=$(wiz_get homepage HOMEPAGE_ALLOWED_HOSTS)
  def="$cur"
  for t in $DET_HOSTNAME $DET_LAN_IP; do
    [ -n "$t" ] || continue
    case ",${def}," in
      *",${t},"*) ;;
      *) def="${def:+${def},}${t}" ;;
    esac
  done
  info "Every name and address Homepage is reached AT — the NAS's own, not clients'."
  info "Comma-separated, no wildcards or CIDR (each entry is matched literally)."
  while :; do
    wiz_ask "HOMEPAGE_ALLOWED_HOSTS" "$def"
    val="${REPLY_VALUE// /}"
    is_hosts_list "$val" && break
  done
  stage homepage HOMEPAGE_ALLOWED_HOSTS "$val"
}

unit_doctor() {
  doctor_socket_access
  doctor_allowed_hosts
}
