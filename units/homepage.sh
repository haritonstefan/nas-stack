# shellcheck shell=bash
UNIT_PORT=80
UNIT_PORT_VAR=HOMEPAGE_HTTP_PORT
UNIT_DIRS="HOMEPAGE_CONFIG_DIR"
UNIT_TEMPLATES="homepage-config/docker.yaml:HOMEPAGE_CONFIG_DIR
homepage-config/services.yaml:HOMEPAGE_CONFIG_DIR
homepage-config/bookmarks.yaml:HOMEPAGE_CONFIG_DIR
homepage-config/settings.yaml:HOMEPAGE_CONFIG_DIR
homepage-config/widgets.yaml:HOMEPAGE_CONFIG_DIR"

unit_doctor() {
  doctor_socket_access
  doctor_allowed_hosts
}
