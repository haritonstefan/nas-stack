# Shared by up.sh, down.sh, configure.sh: sourced, not run directly.
# The single source of truth for the flat unit list and the core/arr aliases
# it backs — a unit added here is addressable by every script that sources it,
# instead of needing the same three edits kept in lockstep by hand.

UNITS_ALL="homepage jellyfin sonarr radarr prowlarr qbittorrent seerr byparr configarr ofelia"
ARR_UNITS="sonarr radarr prowlarr qbittorrent seerr byparr configarr ofelia"

UNITS=""

is_unit() { case " $UNITS_ALL " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
add_unit() { case " $UNITS " in *" $1 "*) ;; *) UNITS="${UNITS} ${1}" ;; esac; }
want() { case " $UNITS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
