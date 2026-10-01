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
  (`dirname $<UNIT>_CONFIG_DIR`) — one path covers configarr's `config/` + `repos/`.

| unit | tile port (var) | dirs created (vars) | checked only, warn (vars) | templates → destination | generated / required vars |
|---|---|---|---|---|---|
| homepage | 80 (`HOMEPAGE_HTTP_PORT`) | `HOMEPAGE_CONFIG_DIR` | — | `homepage-config/{docker,services,bookmarks,settings,widgets}.yaml` → config dir | — |
| jellyfin | 8096 (fixed; host networking) | `JELLYFIN_CONFIG_DIR`, `JELLYFIN_CACHE_DIR` | `MEDIA_MOVIES_DIR`, `MEDIA_SERIES_DIR`, `MEDIA_MUSIC_DIR` (exists) | — | required: `ADMIN_PASSWORD` (prompted). Minted by its bootstrap, not by install: `JELLYFIN_API_KEY`, `JELLYFIN_SCAN_TASK_ID` |
| sonarr | 8989 (`SONARR_PORT`) | `SONARR_CONFIG_DIR` + downloads trio | `ARR_SERIES_DIR` (exists + writable) | — | generated + required: `SONARR_API_KEY` |
| radarr | 7878 (`RADARR_PORT`) | `RADARR_CONFIG_DIR` + downloads trio | `ARR_MOVIES_DIR` (exists + writable) | — | generated + required: `RADARR_API_KEY` |
| lidarr | 8686 (`LIDARR_PORT`) | `LIDARR_CONFIG_DIR` + downloads trio | `ARR_MUSIC_DIR` (exists + writable) | — | generated + required: `LIDARR_API_KEY` |
| prowlarr | 9696 (`PROWLARR_PORT`) | `PROWLARR_CONFIG_DIR` | — | — | generated + required: `PROWLARR_API_KEY` |
| qbittorrent | 8080 (`QBITTORRENT_PORT`) | `QBITTORRENT_CONFIG_DIR` + downloads trio | — | `qbittorrent-config/qBittorrent.conf`, substituted (below) | required: `ADMIN_PASSWORD` |
| seerr | 5055 (`SEERR_PORT`) | `SEERR_CONFIG_DIR` | — | — | generated + required: `SEERR_API_KEY` |
| byparr | — (no port, no tile) | — (stateless: no volumes, no vars of its own) | — | — | — |
| configarr | — | `CONFIGARR_CONFIG_DIR`, `CONFIGARR_REPOS_DIR` | — | `configarr-config/config.yml` → config dir | required (cross-unit, via extra env files): `SONARR_API_KEY`, `RADARR_API_KEY` |
| ofelia | — | `OFELIA_CONFIG_DIR` | — | `configarr-config/ofelia.ini` → config dir | — |
| unmanic | 8888 (`UNMANIC_PORT`) | `UNMANIC_CONFIG_DIR`, `UNMANIC_CACHE_DIR` | `UNMANIC_MOVIES_DIR`, `UNMANIC_SERIES_DIR` (exists + writable) | — | — (its bootstrap reads `SONARR_API_KEY`/`RADARR_API_KEY` from their owners' files) |
| pihole | — (standalone; NAS can't reach it) | — (compose-relative bind `./etc-pihole`) | — | — | required: `PIHOLE_PASSWORD` (hand-set, own credential — P4) |

**Downloads trio**: when any of sonarr / radarr / lidarr / qbittorrent is selected,
`DOWNLOADS_DIR` plus its `complete/` and `incomplete/` subdirs are created too,
deduped across them. It is under the delete root but **never** a delete
target (R3).

## Generated secrets

`SONARR_API_KEY`, `RADARR_API_KEY`, `LIDARR_API_KEY`, `PROWLARR_API_KEY`,
`SEERR_API_KEY` — one per file, matching what the apps would mint themselves:

- 32 lowercase hex chars: `od -vAn -N16 -tx1 /dev/urandom | tr -d ' \n'`.
- Written into the unit's `.env` (single-quoted writer, `chmod 600`), exactly once:
  a non-empty value is never regenerated (R2).
- Generated **even under `--dry-run`**: the compose files declare them `${VAR:?}`,
  so nothing — not even `docker compose config` — interpolates while they're
  empty; writing a gitignored `.env` is not the kind of change a dry run withholds.

`JELLYFIN_API_KEY` / `JELLYFIN_SCAN_TASK_ID` are different: minted by
`jellyfin-bootstrap.sh` over the API (keys live in Jellyfin's database and can't be
env-seeded) and written back into `jellyfin.env`. Legitimately empty until the
first post-install.

## configarr + ofelia specials

- configarr env files, in order: `shared.env sonarr.env radarr.env configarr.env` —
  the two keys are read from their owners' files, never copied.
- Up: `up -d --no-start configarr` — naming the service enables its
  `profiles: [configarr]` implicitly; `--no-start` because a started sync would
  race Sonarr/Radarr's startup.
- Down: `--profile configarr` (a plain `down` ignores profiled services) **plus**
  sonarr.env/radarr.env when present (the compose file must interpolate even for
  `down`), **plus** the by-name backstop `docker rm -f configarr`.
- Ofelia's coupling: when ofelia is selected and configarr isn't, run configarr's
  up-with-`--no-start` anyway (its `job-run` starts an existing container by name,
  never creates one). If sonarr.env / radarr.env / configarr.env aren't all
  present yet, warn and skip — never fail.
- Ad-hoc syncs use a throwaway `--name configarr-sync` / `configarr-dryrun` via
  `compose run --rm`, so they never collide with the scheduler-target container.

## unmanic

- Plain two-file unit: the compose file needs no arr key. `unmanic-bootstrap.sh` reads
  `sonarr.env`/`radarr.env` itself (like `seerr-bootstrap.sh`) and writes the keys into
  the audio plugin's per-library settings — a copy, re-synced on every run.
- `UNIT_LOG_PATHS`: `$UNMANIC_CONFIG_DIR/.unmanic/logs` — inside the directory destroy
  deletes, hence `--save-logs`.
- Plugins: zips pinned to a commit + sha256 in `unmanic-bootstrap.sh`, uploaded over
  the API. No plugin code lives in this repo.

## qBittorrent first-boot seed

Installed only when absent; qBittorrent rewrites the file on clean shutdown, so
this is a seed, not managed config. Token map:

| token | value |
|---|---|
| `__PASSWORD_PBKDF2__` | hash of `ADMIN_PASSWORD` (recipe below) |
| `__WEBUI_PORT__` | `QBITTORRENT_PORT` (default 8080) |
| `__WEBUI_USER__` | `ADMIN_USER` |
| `__SAVE_PATH__` | `/downloads/complete` (container path, literal) |
| `__TEMP_PATH__` | `/downloads/incomplete` (container path, literal) |
| `__SEED_RATIO__` | `QBITTORRENT_SEED_RATIO` (default 2) |
| `__SEED_MINUTES__` | `QBITTORRENT_SEED_MINUTES` (default 20160) |

Hash: PBKDF2-HMAC-SHA512, 100000 iterations, 16-byte random salt, 64-byte key,
rendered `base64(salt):base64(key)` inside the conf's `@ByteArray(...)`. Built
with `openssl kdf` (needs OpenSSL ≥ 3.0; its absence is a hard error with that
diagnosis). After substitution, assert no `__[A-Z0-9_]{3,}__` token survives
(digits included — `__PASSWORD_PBKDF2__` contains one) — leftovers are exit 1.
Installed file: chown `PUID:PGID`, `chmod 600`.

## Jellyfin specials

- `ADMIN_PASSWORD` prompt: silent read, non-empty, entered twice — a typo would
  survive Jellyfin's one-shot wizard.
- Widget-key recreate: after its post-install, re-source `jellyfin.env` in a
  subshell (the parent shell holds pre-bootstrap values) and compare
  `JELLYFIN_API_KEY` against the running container's `homepage.widgets[0].key`
  label (`docker inspect`). Differ → full compose recreate (which also satisfies
  any pending exit 10); exit 10 alone → plain `docker restart jellyfin`.
- The library scan (`--scan-only`, on by default via `JELLYFIN_SCAN_ON_BOOTSTRAP`)
  runs **after** any restart, so the restart can't cut the HDD scan short; its
  failure only warns.
- `UNIT_LOG_PATHS`: `$JELLYFIN_CONFIG_DIR/log` — inside the directory destroy
  deletes, hence `--save-logs`.

## Lidarr

The music arr, same shape as sonarr/radarr. Slots after radarr in `UNITS_ALL`.
Decisions:

- LSIO image, exact tag pinned (`linuxserver/lidarr:3.1.0.4875-ls42` — **verify**
  on the NAS against daemon API 1.54, like every pin). Identity via `PUID`/`PGID`
  env, `UMASK`, the LSIO idiom.
- Vars: `LIDARR_CONFIG_DIR=/volume2/docker/lidarr/config`, `LIDARR_PORT=8686`
  (**verify** the host port is free on the NAS), `ARR_MUSIC_DIR=/volume1/Media/Music`
  (single-consumer, mirrors `ARR_SERIES_DIR`/`ARR_MOVIES_DIR`), `LIDARR_API_KEY`
  (generated, fail-loud `${VAR:?}` in compose, injected as `LIDARR__AUTH__APIKEY` —
  **verify** on the NAS that the env-config idiom works on the pinned version like
  it does on sonarr/radarr). Bootstrap-only: `LIDARR_URL=http://127.0.0.1:8686`,
  `LIDARR_ROOT_FOLDER=/media/music`.
- Mounts: `ARR_MUSIC_DIR` → `/media/music` (rw — imports write there; jellyfin
  keeps its own `:ro` mount of the same host path), `DOWNLOADS_DIR` → `/downloads`.
- **API is v1, not v3** — same trap class as Prowlarr: the wrong version 404s and
  reads as a bad key.
- arr-bootstrap has a lidarr section (env-file-presence gating like the others,
  `LIDARR_ENV_FILE` override): root folder `/media/music` (with real
  `qualityProfileId`/`metadataProfileId` resolved first — a bare `{path}` 400s),
  qBittorrent download client with category `lidarr` and
  `removeCompletedDownloads: true` (the same guarded pairing — do not diverge),
  media management GET-modify-PUT. Prowlarr carries a Lidarr application
  (`baseUrl http://lidarr:8686`, music sync categories).
- **Deliberately outside configarr/TRaSH scope**: the frozen Recyclarr template
  tree has no Lidarr profiles and configarr's Lidarr support is experimental —
  default quality profiles stand until that changes.
- **No seerr wiring** — Seerr does not do music requests.
- Homepage: tile + `lidarr` widget with `LIDARR_API_KEY`, same label pattern as
  sonarr.
- Wizard: the music directory is asked once and staged into both jellyfin's
  `MEDIA_MUSIC_DIR` and lidarr's `ARR_MUSIC_DIR` (same dual-staging as
  movies/series).

## pihole (standalone)

Differences from every root unit: single auto-read `pi-hole/.env` (no
`--env-file`, no `-p`), compose-owned macvlan network instead of external
`nas-net`, duplicates `TZ` instead of consuming `shared.env`, no homepage labels,
zero bootstrap. Full spec: `docs/pihole-spec.md`.
