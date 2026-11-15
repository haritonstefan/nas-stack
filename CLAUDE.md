# nas-stack

## Goal

Self-hosted service stacks for a UGreen NAS (UGOS, `apollo.local`), as Docker
Compose files in git, driven by one small CLI. A fresh clone brings back the
containers and their wiring with `sudo ./nas install`: same network, same
directories, same API keys. **It does not configure the services.** Libraries,
download clients, indexers and profiles are set up by hand in each UI, using
`docs/manual-setup.md`. That is deliberate: the API-driven setup scripts were
removed because they were too brittle to maintain. Don't reintroduce
service-side automation without being asked.

One standalone `docker-compose.<unit>.yml` per service: no shared compose
file, no `depends_on`, no shared volumes between units. What units have in
common is the `nas-net` network (created by the CLI, owned by no compose file)
and `shared.env` (vars reused by more than one unit). Units:

- `homepage`: the dashboard on `:80`.
- `jellyfin`: the media server, host-networked.
- `sonarr` / `radarr` / `lidarr` / `prowlarr` / `qbittorrent` / `seerr` / `byparr`:
  the arr stack (the `arr` alias).
- `unmanic`: post-import audio/subtitle cleanup on the movie/series library.
- `pihole`: standalone macvlan compose in `pi-hole/` with its own `.env` and LAN
  IP `192.168.0.53`. The CLI doesn't know it: run it with
  `cd pi-hole && sudo docker compose up -d`. The NAS itself can't reach that IP
  (kernel macvlan rule). See `docs/pihole-spec.md`.

### Files

- `nas`: the CLI, one bash file (`install`, `destroy`, `compose`; `--help`).
- `docker-compose.<unit>.yml` + `<unit>.env.example`: one self-contained pair
  per unit. A var used by exactly one unit lives only in that unit's file. The
  CLI finds units by globbing the compose files and works by naming convention:
  `<UNIT>_CONFIG_DIR` (its parent is the destroy target), optional
  `<UNIT>_CACHE_DIR`, and `<UNIT>_API_KEY` for the units in `KEYED`. A new unit
  that follows the convention needs no CLI change.
- `shared.env.example`: `TZ`, `PUID`, `PGID`, `UMASK`, `DOCKER_GID`,
  `LAN_HOST`, `DOWNLOADS_DIR`, `ADMIN_USER`/`ADMIN_PASSWORD` (the qBittorrent
  login, read by its Homepage widget).
- `homepage-config/`: templates `nas install` copies only when absent (every
  `*.yaml` in the folder).
- `docs/manual-setup.md`: the non-obvious settings to apply by hand per service.
- `apollo-nas-stack-spec.md`: the reasoning behind each architectural
  constraint. Read it before proposing an architectural change.

## Your role

You are the senior DevOps engineer on this box. It is a live NAS with real data
on it, not a lab.

- **Probe with `GET` only.** A write request is not a discovery tool.
- **Dry-run before mutating**: `./nas install --dry-run`, `./nas destroy --dry-run`.
- **Collect logs before anything destructive.** `nas destroy` saves them to
  `/volume2/docker/_saved-logs/` on its own. Anything you wipe by hand, save first.
- **GET-modify-PUT** for config objects. Never send a partial body to an
  endpoint that deserializes over a whole object.
- **Pin exact patch versions.** Never `:latest`, never a floating tag.
- **A status code tells you *that* something failed, rarely *why*.** Read the
  service's logs.
- Prefer upgrading an image over adding a compatibility shim.

### You are not on the NAS

You work from a workstation with this repo and nothing else. You can't reach
`apollo.local`, its Docker daemon, its volumes or its services, and the
`/volume1`, `/volume2`, `/dev/dri` paths don't exist where you run. So **you
can't test your own work**:

- Never claim something works when you only reasoned about it. Say what you
  checked (`bash -n`, `shellcheck`, a dry run) and what's untested.
- To learn anything about the NAS, give the user one copy-pasteable command and
  wait for the output. Don't guess.
- Don't build local stubs or fake directory trees. They test the stub.

## Host facts

- `/volume1/Media/{Movies,Series,Music}`: HDD, media only. Mounted `:ro` where a
  service only reads.
- `/volume2/docker`: SSD, all container config + this repo. Nothing that spins
  up the HDD at idle lives here.
- PUID/PGID `1000:10`. `RENDER_GID=105` (Intel iGPU, `/dev/dri/renderD128`).
  `TZ=Europe/Bucharest`.
- LAN IP `192.168.0.231` (DHCP reservation), `apollo.local` via mDNS.
- Ports: `80` Homepage, `8096`/`7359`/`1900` Jellyfin (host networking),
  `8989`/`7878`/`8686`/`9696`/`8080` Sonarr/Radarr/Lidarr/Prowlarr/qBittorrent,
  `6881` tcp+udp torrent, `5055` Seerr, `8888` Unmanic, `53` PiHole, `9999` UGOS.
- Docker daemon API `1.54`.
- Bind-mount sources aren't auto-created with the right ownership. `nas install`
  mkdir+chowns them, which is one reason it needs root.

## Running

`sudo ./nas install [unit...]` per selected unit (default: all): `nas-net`,
`.env` files from the examples (never overwritten), generated API keys (once,
never regenerated), host dirs + ownership, Homepage templates when absent,
compose up. A run that created a new `.env` stops after the keys, so the
values get reviewed before anything starts. Idempotent. A missing required value (e.g. `ADMIN_PASSWORD`) fails
that unit through compose's `${VAR:?}`. The other units still start, and the
run exits non-zero. A same-named container outside `nas-<unit>` is skipped
with a warning, never touched.

Underneath it's plain compose. Compose doesn't read `.env` on its own and all
units share one directory, so `--env-file shared.env --env-file <unit>.env` and
`-p nas-<unit>` are required on every call. Without them the units collapse
into one project and report each other as orphans. `./nas compose <unit> ...`
adds them for you: `logs -f`, `ps`, `restart`, `up -d --force-recreate`.

There is no `recreate` verb. A container older than its `.env` gets fixed with
`sudo ./nas install <unit>`, because compose recreates when the resolved config
changed. A clean slate is `destroy <unit>` then `install <unit>`.

`nas destroy` invariants to preserve:

- **Nothing outside `/volume2/docker` can be deleted.** Delete targets come from
  a sourced `.env`, so every path is checked against that root (`deletable`).
  The repo dir and the download tree are refused too.
- **Plan, then confirm.** Deleting data takes typing `delete`. `--yes` skips it,
  `--dry-run` prints the plan, `--containers` deletes no data. Logs are always
  saved first (Jellyfin's and Unmanic's live inside the dir being deleted).
- **`.env` files and the download tree survive.** The `.env` files are the only
  copy of the API keys. A still-seeding torrent can't be rebuilt from git.
- **qBittorrent sparing.** In scope only via `arr` or the no-args default,
  qbittorrent keeps running and seeding. It only goes if named explicitly.
  `nas-net` is never removed.

## Networking & routing

Homepage binds `:80`. Every other service is reached on its own port via a
dashboard tile. Plain HTTP (spec §2–3).

- Adding a service: publish its port, give it `homepage.*` labels, done.
- Bridge on `nas-net` by default. `network_mode: host` only for something that
  needs LAN broadcast/multicast (Jellyfin, the one exception).
- **Jellyfin is not on `nas-net`.** Containers reach each other by name
  (`http://sonarr:8989`), but anything talking to Jellyfin uses `LAN_HOST`.
- Homepage's Docker integration needs the socket mount *and* `docker.yaml`.
  Labels are read over the socket API, so host-networked containers still show up.
- **Socket access is a DAC problem.** When discovery fails, no container is
  listed and Homepage renders only `services.yaml`. Diagnose in this order.
  `ENOENT` means the path is wrong. `EACCES` means found and refused: check
  `docker inspect` for `CapDrop`/`SecurityOpt`, PID 1's real `Groups`/`CapEff`
  in `/proc/1/status`, and `dmesg | grep denied`. The identity setup (primary
  GID via `user: "${PUID}:${DOCKER_GID}"`) is spec §7. Quick check:
  `DOCKER_GID` in `shared.env` must equal `stat -c %g /var/run/docker.sock`.
- `homepage.href` is what the browser opens (`http://apollo.local:8096`).
  `homepage.widget.url` is fetched by the Homepage container, so it uses
  container names. The two aren't interchangeable.
- Non-containers (UGOS on 9999) are hand-added in `services.yaml`.

## Compose conventions

- Comments follow `docs/requirements.md` §Documentation policy: a comment states
  a why (a trap, a constraint, a decision that looks wrong). Narration goes.
- Every service: exact image tag, `container_name`, `restart`, explicit
  `networks: [nas-net]` (unless `network_mode: host`, which excludes `networks:`
  and `ports:`), explicit volumes (config vs media separated), capped `logging:`
  (`json-file`, `max-size: 10m`, `max-file: 5`).
- Every `${VAR}` gets a `:-default` matching the `.env.example`, **except**
  secrets, which use `:?` to fail loudly when unset. The Jellyfin widget key
  defaults to empty: it's optional and filled in by hand.
- Compose files must not hardcode host paths. Everything goes through `.env`.

## Service traps that shape the repo

- **Each arr unit's API key in its own `.env` is load-bearing forever.** It's
  injected as `SONARR__AUTH__APIKEY` etc. (Seerr: `API_KEY`), which the app reads
  at every start *instead of* persisting it. Lose the file and the app silently
  mints a new key, breaking Prowlarr sync and the Homepage widget with no error.
  **A 401 usually means a container older than its `.env`**, not a wrong key.
  `sudo ./nas install <unit>` recreates it.
- **Jellyfin: never add `ports:`.** Host networking is required because client
  discovery (`7359/udp`) and DLNA (`1900/udp`) are broadcast/multicast, which
  bridge publishing doesn't forward (spec §5). UGOS's own DLNA responder is off
  to free `1900`.
- **Jellyfin widget labels are baked in at container create.** After filling in
  `JELLYFIN_API_KEY`/`JELLYFIN_SCAN_TASK_ID`, `sudo ./nas install jellyfin`
  recreates the container. `docker restart` won't.
- **Never mount the download tree into Unmanic.** It rewrites files in place.
  The library is only safe to rewrite because imports are cross-filesystem
  copies, not the seeding file (spec §6).
- **Unmanic's media mounts must keep Radarr/Sonarr's container paths**
  (`/media/movies`, `/media/series`). Its audio plugin matches files by path
  prefix. Change one side and every file is skipped silently.
- `DOWNLOADS_DIR` is mounted at `/downloads` in qbittorrent and the arr apps.
  qBittorrent reports absolute paths, so any drift silently breaks imports.
