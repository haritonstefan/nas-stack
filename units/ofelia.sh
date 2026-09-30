# shellcheck shell=bash
UNIT_DIRS="OFELIA_CONFIG_DIR"
UNIT_TEMPLATES="configarr-config/ofelia.ini:OFELIA_CONFIG_DIR"

unit_doctor() {
  doctor_socket_access
}
