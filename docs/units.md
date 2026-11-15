# Unit reference

The per-unit data the CLI drives each unit with — the values `units/<unit>.sh`
transcribe (contract: `docs/cli-spec.md` §Code layout). The compose files and
`.env.example`s stay the source of truth; if they disagree with this table, they
win and this file is stale.

Uniform conventions (every unit, unless its row says otherwise):

- project `nas-<unit>`, container `<unit>`, compose file `docker-compose.<unit>.yml`,
  env files `shared.env` then `<unit>.env` (later wins).
- dirs are mkdir'd + chowned `PUID:PGID`. An existing dir is chowned
  **non-recursively** (a recursive chown would walk Jellyfin's metadata on every
  run); a new dir recursively.
- delete target on destroy: the **parent** of the unit's config dir
  (`dirname $<UNIT>_CONFIG_DIR`) — one path covers jellyfin's and unmanic's
  `config/` + `cache/`.

| unit | tile port (var) | dirs created (vars) | checked only, warn (vars) | templates → destination | generated / required vars |
|---|---|---|---|---|---|
| homepage | 80 (`HOMEPAGE_HTTP_PORT`) | `HOMEPAGE_CONFIG_DIR` | — | `homepage-config/{docker,services,bookmarks,settings,widgets}.yaml` → config dir | — |
| jellyfin | 8096 (fixed; host networking) | `JELLYFIN_CONFIG_DIR`, `JELLYFIN_CACHE_DIR` | `MEDIA_MOVIES_DIR`, `MEDIA_SERIES_DIR`, `MEDIA_MUSIC_DIR` (exists) | — | — |
| sonarr | 8989 (`SONARR_PORT`) | `SONARR_CONFIG_DIR` + downloads trio | `ARR_SERIES_DIR` (exists + writable) | — | generated + required: `SONARR_API_KEY` |
| radarr | 7878 (`RADARR_PORT`) | `RADARR_CONFIG_DIR` + downloads trio | `ARR_MOVIES_DIR` (exists + writable) | — | generated + required: `RADARR_API_KEY` |
| lidarr | 8686 (`LIDARR_PORT`) | `LIDARR_CONFIG_DIR` + downloads trio | `ARR_MUSIC_DIR` (exists + writable) | — | generated + required: `LIDARR_API_KEY` |
| prowlarr | 9696 (`PROWLARR_PORT`) | `PROWLARR_CONFIG_DIR` | — | — | generated + required: `PROWLARR_API_KEY` |
| qbittorrent | 8080 (`QBITTORRENT_PORT`) | `QBITTORRENT_CONFIG_DIR` + downloads trio | — | — | required: `ADMIN_PASSWORD` (shared.env) |
| seerr | 5055 (`SEERR_PORT`) | `SEERR_CONFIG_DIR` | — | — | generated + required: `SEERR_API_KEY` |
| byparr | — (no port, no tile) | — (stateless: no volumes, no vars of its own) | — | — | — |
| unmanic | 8888 (`UNMANIC_PORT`) | `UNMANIC_CONFIG_DIR`, `UNMANIC_CACHE_DIR` | `UNMANIC_MOVIES_DIR`, `UNMANIC_SERIES_DIR` (exists + writable) | — | — |
| pihole | — (standalone; NAS can't reach it) | — (compose-relative bind via `PIHOLE_CONFIG_DIR`, default `./etc-pihole`) | — | — | required: `PIHOLE_PASSWORD` (own credential — P4) |

Hooks and extra log paths:

- homepage, jellyfin, pihole: `unit_doctor` (socket access + allowed hosts; render
  device; container + in-container DNS).
- qbittorrent: `unit_adopt` (below).
- jellyfin: `UNIT_LOG_PATHS=JELLYFIN_CONFIG_DIR/log`. unmanic:
  `UNIT_LOG_PATHS=UNMANIC_CONFIG_DIR/.unmanic/logs`. Both sit inside the directory
  destroy deletes, hence `--save-logs`.

**Downloads trio**: when any of sonarr / radarr / lidarr / qbittorrent is selected,
`DOWNLOADS_DIR` plus its `complete/` and `incomplete/` subdirs are created too,
deduped across them. It is under the delete root but **never** a delete
target (R3).

## Generated secrets

`SONARR_API_KEY`, `RADARR_API_KEY`, `LIDARR_API_KEY`, `PROWLARR_API_KEY`,
`SEERR_API_KEY` — one per file, matching what the apps would mint themselves:

- 32 lowercase hex chars: `od -vAn -N16 -tx1 /dev/urandom | tr -d ' \n'`.
- Written into the unit's `.env` (`chmod 600`), exactly once: a non-empty value is
  never regenerated (R2).
- Injected as `<APP>__AUTH__APIKEY` (Seerr: `API_KEY`), which the apps read at every
  start in place of their stored key — so the `.env` is the only copy.
- Generated **even under `--dry-run`** when the `.env` already exists (a dry run does
  not create it): the compose files declare them `${VAR:?}`, so nothing — not even
  `docker compose config` — interpolates while they're empty; writing a gitignored
  `.env` is not the kind of change a dry run withholds.

`JELLYFIN_API_KEY` / `JELLYFIN_SCAN_TASK_ID` are different: Jellyfin keeps its keys
in its own database, so they can only be created once Jellyfin is set up, and are
copied into `jellyfin.env` by hand (`docs/manual-setup.md`). They default to empty
in the compose file — the widget just shows an error until then. `sudo ./nas install
jellyfin` afterwards recreates the container, because the labels that carry them are
baked in at create.

## qbittorrent adoption

An existing `qbittorrent` container that compose did not create under `nas-qbittorrent`
is adopted rather than replaced, so it keeps seeding. It must still agree with this repo:

- its `/config` mount source equals `QBITTORRENT_CONFIG_DIR` — the dir destroy would
  delete;
- its `/downloads` mount source equals `DOWNLOADS_DIR` — the path the arr apps import
  from, where a mismatch is a silent remote-path-mapping failure.

A mismatch refuses adoption and fails the unit. Otherwise it is attached to `nas-net` if
needed (the arr apps reach it as `http://qbittorrent`) and started if stopped. To put it
under the CLI's own project instead: `nas destroy qbittorrent --containers`, then
`nas install qbittorrent`.

## Lidarr

The music arr, same shape as sonarr/radarr. Slots after radarr in `UNITS_ALL`.

- LSIO image, exact tag pinned (`linuxserver/lidarr:3.1.0.4875-ls42` — **verify**
  on the NAS against daemon API 1.54, like every pin). Identity via `PUID`/`PGID`
  env, `UMASK`, the LSIO idiom.
- Vars: `LIDARR_CONFIG_DIR`, `LIDARR_PORT=8686`, `ARR_MUSIC_DIR=/volume1/Media/Music`
  (single-consumer, mirrors `ARR_SERIES_DIR`/`ARR_MOVIES_DIR`), `LIDARR_API_KEY`
  (generated, injected as `LIDARR__AUTH__APIKEY` — **verify** on the NAS that the
  env-key idiom works on the pinned version like it does on sonarr/radarr).
- Mounts: `ARR_MUSIC_DIR` → `/media/music` (rw — imports write there; jellyfin
  keeps its own `:ro` mount of the same host path), `DOWNLOADS_DIR` → `/downloads`.
- **API is v1, not v3** — same trap class as Prowlarr: the wrong version 404s and
  reads as a bad key.
- No Seerr wiring — Seerr does not do music requests.

## pihole (standalone)

Differences from every root unit: single auto-read `pi-hole/.env` (no
`--env-file`, no `-p`), compose-owned macvlan network instead of external
`nas-net`, duplicates `TZ` instead of consuming `shared.env`, no homepage labels.
`pi-hole/.env` is copied from its example and filled in by hand — install never
touches this unit. Full spec: `docs/pihole-spec.md`.
