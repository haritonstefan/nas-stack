# shellcheck shell=bash
# The two API keys are read from their owners' files, never copied into
# configarr.env — a rotated key would go stale in a copy nobody remembers
# to update.
UNIT_ENV_FILES="shared.env sonarr.env radarr.env configarr.env"
# Naming the service enables its profiles: [configarr] implicitly; --no-start
# because a started sync would race Sonarr/Radarr's startup. A plain `down`
# ignores profiled services, hence the explicit --profile.
UNIT_UP_ARGS="--no-start configarr"
UNIT_DOWN_ARGS="--profile configarr"
UNIT_DIRS="CONFIGARR_CONFIG_DIR CONFIGARR_REPOS_DIR"
UNIT_TEMPLATES="configarr-config/config.yml:CONFIGARR_CONFIG_DIR"
UNIT_REQUIRED="SONARR_API_KEY RADARR_API_KEY"
UNIT_POST_INSTALL="arr"
