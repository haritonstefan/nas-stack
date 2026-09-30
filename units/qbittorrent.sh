# shellcheck shell=bash
UNIT_PORT=8080
UNIT_PORT_VAR=QBITTORRENT_PORT
UNIT_DIRS="QBITTORRENT_CONFIG_DIR DOWNLOADS_DIR DOWNLOADS_DIR/complete DOWNLOADS_DIR/incomplete"
UNIT_REQUIRED="ADMIN_PASSWORD"
UNIT_POST_INSTALL="arr"

# PBKDF2 in qBittorrent's stored format: SHA-512, 100000 iterations, 16-byte
# salt, 64-byte key, base64(salt):base64(key). `openssl kdf` needs
# OpenSSL >= 3.0. hexpass/hexsalt sidestep kdfopt value parsing; the password
# on openssl's argv for this one call is the same exposure already accepted
# by keeping it in plain text in shared.env.
gen_qbt_hash() {
  local pw="$1" pw_hex salt_b64 salt_hex key_b64
  salt_b64=$(openssl rand -base64 16 2>/dev/null) || salt_b64=""
  salt_hex=$(printf '%s' "$salt_b64" | openssl base64 -d -A 2>/dev/null \
    | od -vAn -tx1 | tr -d ' \n') || salt_hex=""
  pw_hex=$(printf '%s' "$pw" | od -vAn -tx1 | tr -d ' \n')
  key_b64=$(openssl kdf -binary -keylen 64 \
      -kdfopt digest:SHA512 -kdfopt "hexpass:${pw_hex}" \
      -kdfopt "hexsalt:${salt_hex}" -kdfopt iter:100000 PBKDF2 \
      2>/dev/null | openssl base64 -A) || key_b64=""
  [ -n "$salt_b64" ] && [ -n "$key_b64" ] || return 1
  printf '%s:%s\n' "$salt_b64" "$key_b64"
}

# First-boot seed, not managed config: qBittorrent rewrites the file on clean
# shutdown, so it is installed only when absent and never reconciled.
unit_templates() {
  local qbt_config="${QBITTORRENT_CONFIG_DIR:-/volume2/docker/qbittorrent/config}"
  local qbt_tmp="${qbt_config}/qBittorrent.conf.tmp" qbt_hash
  if [ -f "${qbt_config}/qBittorrent.conf" ]; then
    info "qBittorrent.conf exists, leaving untouched"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would install qBittorrent.conf with a PBKDF2 password hash"
    return 0
  fi
  if [ -z "${ADMIN_PASSWORD:-}" ]; then
    warn "ADMIN_PASSWORD is unset — cannot seed qBittorrent.conf; run: ./nas configure qbittorrent"
    return 1
  fi
  qbt_hash="$(gen_qbt_hash "$ADMIN_PASSWORD")" || qbt_hash=""
  if [ -z "$qbt_hash" ]; then
    warn "could not generate the qBittorrent password hash — 'openssl kdf' failed; OpenSSL >= 3.0 is required (openssl version)"
    return 1
  fi
  sed -e "s|__PASSWORD_PBKDF2__|${qbt_hash}|" \
      -e "s|__WEBUI_PORT__|${QBITTORRENT_PORT:-8080}|" \
      -e "s|__WEBUI_USER__|${ADMIN_USER:-admin}|" \
      -e "s|__SAVE_PATH__|/downloads/complete|" \
      -e "s|__TEMP_PATH__|/downloads/incomplete|" \
      -e "s|__SEED_RATIO__|${QBITTORRENT_SEED_RATIO:-2}|" \
      -e "s|__SEED_MINUTES__|${QBITTORRENT_SEED_MINUTES:-20160}|" \
      qbittorrent-config/qBittorrent.conf > "$qbt_tmp"
  # [A-Z0-9_], not [A-Z_]: __PASSWORD_PBKDF2__ contains a digit, and a
  # leftover placeholder would lock the WebUI with no error to explain why.
  if grep -q '__[A-Z0-9_]\{3,\}__' "$qbt_tmp"; then
    rm -f "$qbt_tmp"
    warn "qBittorrent.conf still has unsubstituted placeholders"
    return 1
  fi
  mv "$qbt_tmp" "${qbt_config}/qBittorrent.conf"
  [ "$IS_ROOT" -eq 1 ] && chown "${PUID:-1000}:${PGID:-10}" "${qbt_config}/qBittorrent.conf"
  chmod 600 "${qbt_config}/qBittorrent.conf"
  info "qBittorrent.conf installed (password hash seeded, seeding capped)"
}
