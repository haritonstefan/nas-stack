#!/usr/bin/env bash
# The stack's lifecycle CLI. Compose doesn't read .env files on its own and
# every unit shares this directory, so each call needs -p nas-<unit> and both
# --env-file flags, or the units collapse into one project.
set -euo pipefail
cd "$(dirname "$0")"

SAFE_ROOT=/volume2/docker
REPO=$(pwd -P)
ARR="sonarr radarr lidarr prowlarr qbittorrent seerr byparr"
# Units whose API key the repo mints. Jellyfin's key is pasted in by hand.
KEYED="sonarr radarr lidarr prowlarr seerr"
ALL=$(for f in docker-compose.*.yml; do f=${f#docker-compose.}; printf '%s ' "${f%.yml}"; done)
ALL=${ALL% }

DRY_RUN=0 YES=0 CONTAINERS_ONLY=0 SPARED=0 UNITS="" FAILED=""

say()  { printf '==> %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

usage() {
  cat <<EOF
sudo ./nas install [--dry-run] [unit...]
    Network, .env files from the examples (never overwritten), API keys
    (generated once), host dirs + ownership, Homepage templates when absent,
    compose up. Idempotent.

sudo ./nas destroy [--dry-run] [--yes] [--containers] [unit...]
    Shows the plan, asks you to type 'delete', saves logs, removes the
    containers and the unit's dir under ${SAFE_ROOT}. The .env files and the
    download tree always survive. qBittorrent is spared unless named.
    --containers removes containers only and deletes no data.

./nas compose <unit> <args...>
    docker compose with the unit's project and env files, e.g.
    ./nas compose sonarr logs -f   |   sudo ./nas compose sonarr ps

No unit means all. Units: ${ALL}
Alias: arr = ${ARR}
EOF
}

select_units() { # select_units <verb> [token...]
  local verb=$1 t u expanded named=""
  shift
  [ $# -gt 0 ] || set -- all
  for t in "$@"; do
    case $t in
      all) expanded=$ALL ;;
      arr) expanded=$ARR ;;
      *) in_list "$t" "$ALL" || die "unknown unit '$t' (units: ${ALL}; aliases: arr, all)"
         expanded=$t; named="$named $t" ;;
    esac
    for u in $expanded; do in_list "$u" "$UNITS" || UNITS="$UNITS $u"; done
  done
  # Through an alias or the default, destroy leaves qBittorrent seeding.
  if [ "$verb" = destroy ] && in_list qbittorrent "$UNITS" && ! in_list qbittorrent "$named"; then
    UNITS=$(for u in $UNITS; do [ "$u" = qbittorrent ] || printf ' %s' "$u"; done)
    SPARED=1
  fi
}

load_env() { # load_env <unit>: the values compose will see
  local f
  set -a
  for f in shared.env "$1.env"; do
    # shellcheck disable=SC1090
    if [ -f "$f.example" ]; then . "./$f.example"; fi
    # shellcheck disable=SC1090
    if [ -f "$f" ]; then . "./$f"; fi
  done
  set +a
}

compose() { # compose <unit> <args...>
  local u=$1
  shift
  run docker compose -p "nas-$u" --env-file shared.env --env-file "$u.env" -f "docker-compose.$u.yml" "$@"
}

under_root() {
  case $1 in "$SAFE_ROOT"/?*) ;; *) return 1 ;; esac
  case $1 in *..*) return 1 ;; esac
  return 0
}

# Delete targets come from .env files, so a typo must not reach outside the
# root, the repo (its .env files hold the only copy of the API keys) or the
# download tree (a seeding torrent can't be rebuilt from git).
deletable() {
  local dl=${DOWNLOADS_DIR:-}
  under_root "$1" || return 1
  case "$REPO/" in "$1"/*) return 1 ;; esac
  case "$dl/" in "$1"/*) return 1 ;; esac
  case "$1/" in "$dl"/*) return 1 ;; esac
  return 0
}

# Only ever the dir itself: a chown -R would walk Jellyfin's whole metadata
# tree on every run.
make_dir() {
  [ -n "$1" ] || return 0
  under_root "$1" || { warn "not creating $1: outside $SAFE_ROOT"; return 0; }
  if [ ! -d "$1" ]; then run mkdir -p "$1"; fi
  run chown "${PUID:-1000}:${PGID:-10}" "$1"
}

# The arr apps read their key from the environment at every start and never
# persist it, so it's minted once and never regenerated.
gen_key() { # gen_key <unit>
  local f="$1.env" var key
  var="$(upper "$1")_API_KEY"
  # shellcheck disable=SC1090
  if [ -f "$f" ] && (. "./$f" && [ -n "${!var:-}" ]); then return 0; fi
  if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] generate %s in %s\n' "$var" "$f"; return 0; fi
  key=$(od -vAn -N16 -tx1 /dev/urandom | tr -d ' \n')
  if grep -q "^$var=" "$f"; then
    sed -i "s/^$var=.*/$var=$key/" "$f"
  else
    printf '%s=%s\n' "$var" "$key" >> "$f"
  fi
  # load_env already exported it empty, and compose lets the shell environment
  # win over --env-file.
  export "$var=$key"
  chmod 600 "$f"
  if [ -n "${SUDO_UID:-}" ]; then chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$f"; fi
  say "generated $var in $f"
}

cmd_install() {
  local u U f v owner dl_done=0 created=0
  docker network inspect nas-net >/dev/null 2>&1 || run docker network create nas-net

  for u in shared $UNITS; do
    f=$u.env
    [ ! -f "$f" ] || continue
    run cp "$f.example" "$f"
    [ "$DRY_RUN" -eq 0 ] || continue
    # Created under sudo, it would be root-owned inside a user-owned repo.
    if [ -n "${SUDO_UID:-}" ]; then chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$f"; fi
    say "created $f from $f.example"
    created=1
  done

  for u in $UNITS; do
    if in_list "$u" "$KEYED"; then load_env "$u"; gen_key "$u"; fi
  done
  # Nothing gets created or started on defaults nobody has looked at yet.
  if [ "$created" -eq 1 ]; then
    say "new .env files above: fill in the empty values (ADMIN_PASSWORD at least), then re-run"
    exit 0
  fi

  for u in $UNITS; do
    load_env "$u"
    U=$(upper "$u")

    for v in "${U}_CONFIG_DIR" "${U}_CACHE_DIR"; do make_dir "${!v:-}"; done
    if in_list "$u" "sonarr radarr lidarr qbittorrent" && [ "$dl_done" -eq 0 ]; then
      for v in "" /complete /incomplete; do make_dir "${DOWNLOADS_DIR:-}$v"; done
      dl_done=1
    fi

    if [ "$u" = homepage ]; then
      for f in homepage-config/*.yaml; do
        [ ! -e "${HOMEPAGE_CONFIG_DIR:?}/${f##*/}" ] || continue
        run cp "$f" "$HOMEPAGE_CONFIG_DIR/"
        run chown "${PUID:-1000}:${PGID:-10}" "$HOMEPAGE_CONFIG_DIR/${f##*/}"
      done
    fi

    # Compose finds its containers by project label, so a same-named
    # container from another project makes `up` die on a name clash.
    owner=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$u" 2>/dev/null) || owner="nas-$u"
    if [ "$owner" != "nas-$u" ]; then
      warn "$u exists outside nas-$u (project: ${owner:-none}), left alone." \
        "To move it over: sudo ./nas destroy $u --containers && sudo ./nas install $u"
      continue
    fi
    say "starting $u"
    compose "$u" up -d || FAILED="$FAILED $u"
  done

  [ -z "$FAILED" ] || die "failed:$FAILED. Fix the cause above, then: sudo ./nas install$FAILED"
}

cmd_destroy() {
  local u U d v src targets="" reply ts
  for u in $UNITS; do
    load_env "$u"
    U=$(upper "$u")
    v="${U}_CONFIG_DIR"
    [ -n "${!v:-}" ] || continue
    d=$(dirname "${!v}")
    if deletable "$d"; then targets="$targets $d"; else warn "refusing to delete '$d'"; fi
  done
  [ "$CONTAINERS_ONLY" -eq 0 ] || targets=""

  say "Containers to remove:${UNITS:- none}"
  if [ "$SPARED" -eq 1 ]; then echo "  qbittorrent stays up and seeding (name it to include it)"; fi
  say "Data to DELETE:${targets:- none}"
  for d in $targets; do
    echo "  $d ($( [ -d "$d" ] && du -sh "$d" | cut -f1 || echo absent))"
  done
  say "Kept: every .env file, ${DOWNLOADS_DIR:-the download tree}, anything outside $SAFE_ROOT"
  [ "$DRY_RUN" -eq 0 ] || exit 0
  [ -n "$UNITS" ] || exit 0

  if [ "$YES" -eq 0 ]; then
    [ -t 0 ] || die "no TTY to confirm on; pass --yes if you mean it"
    if [ -n "$targets" ]; then
      # A typed word, so a reflex Enter can't wipe config.
      read -rp 'Type "delete" to confirm: ' reply
      [ "$reply" = delete ] || die "not confirmed, nothing changed"
    else
      read -rp 'Remove these containers? [y/N] ' reply
      case $reply in [Yy]*) ;; *) die "not confirmed, nothing changed" ;; esac
    fi
  fi

  # docker logs die with the container, and Jellyfin's and Unmanic's log
  # files live inside the dir being deleted.
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  for u in $UNITS; do
    load_env "$u"
    d="$SAFE_ROOT/_saved-logs/$ts/$u"
    mkdir -p "$d"
    if docker inspect "$u" >/dev/null 2>&1; then docker logs "$u" > "$d/docker.log" 2>&1 || true; fi
    case $u in
      jellyfin) src="${JELLYFIN_CONFIG_DIR:-}/log" ;;
      unmanic)  src="${UNMANIC_CONFIG_DIR:-}/.unmanic/logs" ;;
      *)        src="" ;;
    esac
    if [ -n "$src" ] && [ -d "$src" ]; then cp -a "$src" "$d/" || true; fi
  done
  say "logs saved to $SAFE_ROOT/_saved-logs/$ts"

  for u in $UNITS; do
    say "removing $u"
    if [ -f "$u.env" ]; then compose "$u" down || warn "compose down failed for $u"; fi
    # Catches a container started outside nas-<unit>, which compose down misses.
    docker rm -f "$u" >/dev/null 2>&1 || true
  done
  for d in $targets; do
    if [ -d "$d" ]; then rm -rf "$d"; echo "  deleted $d"; fi
  done
  say "done. Bring it back with: sudo ./nas install$UNITS"
}

cmd_compose() {
  [ $# -ge 2 ] || die "usage: ./nas compose <unit> <compose args...>"
  in_list "$1" "$ALL" || die "unknown unit '$1' (units: ${ALL})"
  compose "$@"
}

VERB=${1:-}
[ $# -eq 0 ] || shift
case $VERB in
  install|destroy)
    args=()
    for a in "$@"; do
      case $a in
        --dry-run)    DRY_RUN=1 ;;
        --yes|-y)     YES=1 ;;
        --containers) CONTAINERS_ONLY=1 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "unknown flag '$a'" ;;
        *)            args+=("$a") ;;
      esac
    done
    select_units "$VERB" ${args[@]+"${args[@]}"}
    [ "$DRY_RUN" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "$VERB needs root: sudo ./nas $VERB $*"
    "cmd_$VERB" ;;
  compose)         cmd_compose "$@" ;;
  help|-h|--help)  usage ;;
  *)               usage >&2; exit 1 ;;
esac
