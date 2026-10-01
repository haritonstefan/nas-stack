# shellcheck shell=bash
# The plugin reads the Radarr/Sonarr keys from their owners' files, never a
# copy in tdarr.env — same rule as configarr.
UNIT_ENV_FILES="shared.env sonarr.env radarr.env tdarr.env"
UNIT_PORT=8265
UNIT_PORT_VAR=TDARR_WEBUI_PORT
# The first entry's parent is the destroy target, so it must be a subdir of
# TDARR_DATA_DIR — listing TDARR_DATA_DIR itself would make it /volume2/docker.
UNIT_DIRS="TDARR_DATA_DIR/server TDARR_DATA_DIR/configs TDARR_DATA_DIR/logs TDARR_DATA_DIR/cache"
UNIT_CHECK_DIRS="TDARR_MOVIES_DIR:w TDARR_SERIES_DIR:w"
UNIT_REQUIRED="SONARR_API_KEY RADARR_API_KEY"
UNIT_LOG_PATHS="TDARR_DATA_DIR/logs"
