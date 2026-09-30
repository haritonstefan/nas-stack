# shellcheck shell=bash
UNIT_PORT=9696
UNIT_PORT_VAR=PROWLARR_PORT
UNIT_DIRS="PROWLARR_CONFIG_DIR"
UNIT_GENERATED="PROWLARR_API_KEY"
UNIT_REQUIRED="PROWLARR_API_KEY"
UNIT_POST_INSTALL="arr"

unit_configure() {
  local cur enabled="" def key user pass have defyn seen=""

  if ui_confirm "Install the public indexers at bootstrap?" Y; then
    stage prowlarr ARR_INSTALL_INDEXERS 1
    wiz_ask "Public indexers (Prowlarr definition names)" "$(wiz_get prowlarr ARR_INDEXERS)" is_csv
    stage prowlarr ARR_INDEXERS "$REPLY_VALUE"
  else
    stage prowlarr ARR_INSTALL_INDEXERS 0
    info "Prowlarr will be left empty for hand-adding"
  fi

  info "Private indexers need a username + password login; anything cookie/passkey/"
  info "2FA-based is skipped at bootstrap and must be added in the Prowlarr UI."
  cur=$(wiz_get prowlarr ARR_INDEXERS_PRIVATE)
  for def in $(printf '%s,%s' "$cur" "$(wiz_get_example prowlarr ARR_INDEXERS_PRIVATE)" | tr ',' ' '); do
    [ -n "$def" ] || continue
    case " $seen " in *" $def "*) continue ;; esac
    seen="${seen} ${def}"
    # kinozal -> ARR_INDEXER_KINOZAL_USER / _PASS — must derive exactly as
    # arr-indexers.sh does.
    key=$(indexer_env_key "$def")
    user=$(wiz_get prowlarr "ARR_INDEXER_${key}_USER")
    pass=$(wiz_get prowlarr "ARR_INDEXER_${key}_PASS")
    have="no credentials stored"
    if [ -n "$user" ]; then
      have="user ${user}"
      [ -n "$pass" ] && have="${have}, password stored"
    fi
    defyn=N
    case ",${cur}," in
      *",${def},"*) [ -n "$user" ] && [ -n "$pass" ] && defyn=Y ;;
    esac
    if ui_confirm "Enable ${def}? (${have})" "$defyn"; then
      wiz_ask "${def} username" "$user" is_nonempty
      user="$REPLY_VALUE"
      if [ -z "$pass" ] || ! ui_confirm "Keep the stored password for ${def}?" Y; then
        wiz_ask_secret "${def} password"
        pass="$REPLY_VALUE"
      fi
      stage prowlarr "ARR_INDEXER_${key}_USER" "$user"
      stage prowlarr "ARR_INDEXER_${key}_PASS" "$pass"
      enabled="${enabled:+${enabled},}${def}"
    elif [ -n "$user" ] || [ -n "$pass" ]; then
      if ui_confirm "Clear the stored credentials for ${def}?" N; then
        stage prowlarr "ARR_INDEXER_${key}_USER" ""
        stage prowlarr "ARR_INDEXER_${key}_PASS" ""
      fi
    fi
  done

  while ui_confirm "Add another private indexer?" N; do
    wiz_ask "Prowlarr definition name" "" is_defname
    def="$REPLY_VALUE"
    key=$(indexer_env_key "$def")
    wiz_ask "${def} username" "$(wiz_get prowlarr "ARR_INDEXER_${key}_USER")" is_nonempty
    user="$REPLY_VALUE"
    wiz_ask_secret "${def} password"
    stage prowlarr "ARR_INDEXER_${key}_USER" "$user"
    stage prowlarr "ARR_INDEXER_${key}_PASS" "$REPLY_VALUE"
    enabled="${enabled:+${enabled},}${def}"
  done

  # Rebuilt from the enabled set only — a name listed without both credentials
  # would just be warn-and-skipped by arr-indexers.sh.
  stage prowlarr ARR_INDEXERS_PRIVATE "$enabled"
}
