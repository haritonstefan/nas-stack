# nas-stack

## Goal

Self-hosted service stacks for a UGreen NAS (UGOS, `apollo.local`), as Docker Compose files in git, driven by one CLI. A fresh clone reproduces the whole box with `./nas configure && sudo ./nas install && ./nas indexers`; `sudo ./nas recreate <unit>` tears down and recreates exactly one unit while it stays wired into the rest of the stack — same network, same shared identity, same API keys (each unit's own, in its own `<unit>.env`).

One standalone `docker-compose.<unit>.yml` per **service** — no shared compose
file, no `depends_on`, no shared volumes between units. The only things units
have in common are the `nas-net` network (created by the CLI, not by any
compose file) and `shared.env` (the vars genuinely reused by more than one
unit: identity, host facts). The CLI is the only place that knows how units
relate to each other — compose files stay ignorant of one another. Thirteen
units:

- **`homepage`** — the dashboard on `:80`, the entrypoint to everything.
- **`jellyfin`** — the media server, host-networked.
- **`sonarr` / `radarr` / `lidarr` / `prowlarr` / `qbittorrent` / `seerr` / `byparr` / `configarr` / `ofelia`** — the arr stack.
- **`tdarr`** — post-import track cleanup on the movie/series library. Not in the `arr` alias. See `## Tdarr`.
- **`pihole`** — deliberately standalone: macvlan compose in `pi-hole/` with its
  own `.env` (auto-read, no `--env-file`), own LAN IP `192.168.0.53`.
  `nas configure` and the read-only verbs cover it; the lifecycle verbs refuse
  it. The NAS itself can't reach that IP (kernel macvlan rule) — tile works,
  Homepage widget doesn't. See `docs/pihole-spec.md`.

`core` and `arr` are selection aliases the CLI resolves: `core` → `homepage`,
`arr` → the nine arr units above.

Bring-up order: `nas-net` first (script-managed, owned by no compose file),
then any unit in any order — nothing hard-depends on another unit being up.
The known cross-unit couplings live in the CLI, never in a compose file:
configarr's and tdarr's extra `--env-file` flags, configarr's `--no-start`, ofelia's "ensure the
configarr container exists" (see `## Arr`), and the jellyfin→homepage
widget-key recreate (see `## Jellyfin`).

### Files

- `nas` — the entrypoint: `configure`, `install`, `post-install`, `destroy`,
  `recreate`, `status`, `logs`, `doctor`, `indexers`, all with `--help`. It
  resolves its own directory, so the caller's cwd never matters. Spec:
  `docs/cli-spec.md`.
- `lib/` — shared plumbing (unit selection, env loading, compose invocation,
  delete-path validation, gum wrappers with plain fallbacks) plus one
  `cmd_<verb>.sh` per verb. `lib/http.sh` is the curl/masking layer
  `arr-bootstrap.sh`, `seerr-bootstrap.sh` and `arr-indexers.sh` share
  (jellyfin-bootstrap carries its own `api()` — Jellyfin's bodies are PascalCase).
- `units/<unit>.sh` — one file per unit: everything the CLI knows about it.
  Contract in `docs/cli-spec.md` §Code layout, values tabulated in
  `docs/units.md`. Cross-unit knowledge never lives in a unit file.
- `vendor/gum/<version>/` — the pinned, checksummed gum binary. Presentation
  only: no TTY, a missing binary or a failed checksum degrades to plain
  prompts — a gum problem can never change what the CLI does.
- `jellyfin-bootstrap.sh` / `arr-bootstrap.sh` / `seerr-bootstrap.sh` /
  `arr-indexers.sh` — the four surviving API drivers, all with `--help`,
  runnable standalone; the CLI shells out to them (`nas post-install`,
  `nas indexers`). Contracts: `docs/cli-spec.md` §Surviving script contracts.
- `nas indexers` (wrapping `arr-indexers.sh`) is deliberately **not** part of
  `install` — Prowlarr fetches its Cardigann definitions shortly after start,
  so a definition missing on the first run often appears on a later one.
  Idempotent and re-runnable.
- `shared.env.example` (→ `shared.env`, gitignored) — vars reused by more than
  one unit: `TZ`, `PUID`, `PGID`, `UMASK`, `DOCKER_GID`, `LAN_HOST` (the
  `192.168.0.231` fact), `DOWNLOADS_DIR`, and the shared `ADMIN_USER`/
  `ADMIN_PASSWORD` identity (Jellyfin admin + qBittorrent WebUI login; Seerr
  rides it too, via `/auth/jellyfin`, without a credential of its own). Every
  `docker compose` invocation passes `--env-file shared.env` first, then the
  unit's own — so a same-named var in the unit's file would win, but none
  should ever duplicate a shared.env name.
- `docker-compose.<unit>.yml` + `<unit>.env.example` — one self-contained pair
  per unit. A variable used by exactly one unit lives only in that unit's own
  file (ports, config dirs, `RENDER_GID`, indexer lists, `ARR_MOVIES_DIR`/
  `ARR_SERIES_DIR`/`ARR_MUSIC_DIR`, etc.) — the same "single-consumer stays
  local" rule `shared.env` itself follows in reverse.
- `tdarr-plugins/` — the Tdarr plugin that keeps original audio + chosen
  subtitles, mounted read-only into the container (not a template).
- `homepage-config/`, `qbittorrent-config/`, `configarr-config/` — config
  templates that `nas install` copies only when absent, so on-NAS edits
  survive. `qBittorrent.conf` additionally gets its `__PLACEHOLDER__` tokens
  substituted at install time (map: `docs/units.md`). A new homepage template
  must also be declared in `units/homepage.sh`'s `UNIT_TEMPLATES` or it
  silently never reaches the NAS.
- `apollo-nas-stack-spec.md` — the as-built record and the **reasoning**
  behind each constraint. Read it before proposing an architectural change.
  `docs/` holds the CLI, wizard, unit and pihole specs, and the documentation
  policy (`docs/requirements.md` §Documentation policy).
- `reference/` — the vendored API specs: Jellyfin's (JSON — query it with
  `jq`, never `Read` it) and Seerr's (`seerr-api.yml`, multi-line YAML, safe
  to grep + line-read). Recipes in `reference/README.md`.
- `TODO-healthchecks.md` — the one open work item.

## Your role

You are the senior DevOps engineer on this box. It is a live NAS with real data on it, not a lab. Standing behaviors:

- **Read the spec offline before touching a running service.** Probe with `GET` only. A write request is not a discovery tool — one closed Jellyfin's one-shot setup wizard permanently.
- **Dry-run before mutating.** `./nas install --dry-run`, `nas destroy` (plan + confirm; `--dry-run` prints the plan and exits), `jellyfin-bootstrap.sh --dry-run`.
- **Collect the evidence a destructive step destroys — logs first**, before any config wipe, `rm -rf`, or `nas destroy` (which offers `--save-logs` for exactly this).
- **GET-modify-POST** for config objects. Never POST a partial body to something that deserializes over a whole object.
- **Pin exact patch versions.** Never `:latest`, never a floating tag.
- **A status code tells you *that* something failed, rarely *why*.** Go to the service's own logs and its published spec.
- Prefer upgrading a service's image over adding a compatibility shim (e.g. `DOCKER_API_VERSION`).

### You are not on the NAS

You develop from a workstation that has this repo checked out and nothing else. You are **not** running on `apollo.local`, you have no access to it, and you cannot reach the Docker daemon, the volumes, or any running service. The paths in this file (`/volume1/...`, `/volume2/...`, `/dev/dri/renderD128`) do not exist where you run.

So **you cannot test your own work.** Every real test happens on the NAS, run by the user.

- **Never claim something is verified, working, or confirmed when you only reasoned about it.** Say what you checked (`bash -n`, a dry run, reading the control flow) and what remains untested. "This should work, untested" is a fine thing to say; "verified" for something you never ran is not.
- **To learn anything about the NAS, ask.** Give the user one copy-pasteable command and wait for the output. Do not guess the state of a running service, a directory, a GID, or a port.
- **`--dry-run` and `bash -n` are the ceiling of local verification.** They catch syntax errors and show intent; they prove nothing about behavior against a live daemon.
- Local sandboxes, stub binaries, and fake directory trees are usually not worth building — they test the stub, not the NAS. Prefer asking the user to run the real thing.

Asking looks like this:

```
Run this on the NAS and paste the output:
  docker compose -p nas-jellyfin --env-file shared.env --env-file jellyfin.env -f docker-compose.jellyfin.yml config
```

## Host facts

- `/volume1/Media/{Movies,Series,Music}` — HDD, media only. Mounted `:ro` where a service only reads.
- `/volume2/docker` — SSD, all container config/logs + this repo. Nothing that spins up the HDD at idle lives here.
- PUID/PGID `1000:10`. `RENDER_GID=105` (Intel iGPU, `/dev/dri/renderD128`). `TZ=Europe/Bucharest`.
- LAN IP `192.168.0.231` (DHCP reservation), `apollo.local` via mDNS.
- Bind-mount sources are **not** auto-created with correct ownership — `nas install` mkdir+chowns them, which is one reason it needs root.
- Ports: `80` → Homepage (bound directly). `8096`/`7359`/`1900` → Jellyfin (host networking). `8989`/`7878`/`8686`/`9696`/`8080` → Sonarr/Radarr/Lidarr/Prowlarr/qBittorrent, `6881` tcp+udp torrent, `5055` → Seerr, `8265` → Tdarr. `0.0.0.0:53` free → PiHole. UGOS on 9999.
- Docker daemon API `1.54` — pin images to exact patch versions and check compatibility against this.
- Compose files must not hardcode host paths — all via `.env` (gitignored; `shared.env.example` / `<unit>.env.example` are the templates).

## Running

`sudo ./nas install` takes a fresh clone to running, per selected unit
(default: all): `nas-net`, `.env` files from the examples (never overwritten),
host dirs + ownership, generated per-unit secrets (once, never regenerated),
config templates when absent, compose up, then it chains `nas post-install`:
the bootstraps in the fixed order jellyfin → arr → seerr. The jellyfin step
restarts or recreates the container right after its own bootstrap when needed
(exit 10, or the widget-key label lagging `jellyfin.env`) and runs the library
scan **after** that restart, so the restart can't cut the scan short. A seerr
failure is deferred, not fatal: stack stays up, banner in the summary,
non-zero exit. Missing required values (e.g. `ADMIN_PASSWORD` when jellyfin,
qbittorrent or seerr is selected) stop the run and point at `./nas configure`
— with a TTY, install offers to run it on the spot. Idempotent. Root is
required by the mutating verbs (`install`, `post-install`, `destroy`,
`recreate`); `configure`, `status`, `logs`, `doctor` run unprivileged.
Everything has `--help`; the full behavior spec is `docs/cli-spec.md`.

Underneath it's plain compose. Compose does **not** read `.env` files on its own, and every
unit shares one directory — so `--env-file` (shared.env first, then the unit's own) and
`-p nas-<unit>` are required on every call, or the units collapse into one project and
report each other as orphans:

```
docker network create nas-net   # nas install, idempotent — no compose file owns this
docker compose -p nas-homepage --env-file shared.env --env-file homepage.env -f docker-compose.homepage.yml up -d
docker compose -p nas-jellyfin --env-file shared.env --env-file jellyfin.env -f docker-compose.jellyfin.yml up -d
docker compose -p nas-radarr   --env-file shared.env --env-file radarr.env   -f docker-compose.radarr.yml   up -d
```

`configarr` is the one unit that takes four `--env-file` flags (`shared.env`, `sonarr.env`,
`radarr.env`, `configarr.env`) instead of two — its compose file needs `SONARR_API_KEY`/
`RADARR_API_KEY`, which live in sonarr's/radarr's own files, not a second copy in
`configarr.env` (a rotated key would go stale in a copy nobody remembers to update). It is
also the one unit the CLI never brings up with a plain `up -d`: always
`up -d --no-start configarr`, because a compose profile (`profiles: [configarr]`) keeps it
out of any generic dispatch, and starting it outright would race Sonarr/Radarr's own
startup. `ofelia`'s dispatch ensures that `configarr` container exists the same way, even
when `configarr` itself wasn't named — see `## Arr`.

`nas destroy` invariants to preserve:

- **Nothing outside `/volume2/docker` can be deleted** — delete targets come
  from a sourced `.env`, so every path is validated against that root and
  rejected if it escapes, contains `..`, or is the root itself (R1).
- **Plan, then confirm.** The full plan (containers, delete paths, what
  survives) prints first; deleting data requires typing the word `delete`, not
  a reflex y/N. `--yes` skips it for scripted use, `--dry-run` prints the plan
  and exits, `--containers` stops/removes containers and deletes no data,
  `--save-logs` copies each unit's logs out first — Jellyfin's only live
  inside the directory being deleted.
- **`.env` files survive teardown** (no re-prompt for the admin password, no
  lost API keys), and **the download tree survives too**, though it sits
  inside the root: config comes back from this repo, a still-seeding torrent
  does not.
- **The qBittorrent sparing rule.** In scope only via `arr` or the no-args
  default, qbittorrent is left entirely alone — still running, still seeding —
  unless named explicitly or `--wipe-qbittorrent`. When spared, `nas-net`
  survives too; otherwise `nas-net` is removed last, once nothing is attached.

## Networking & routing

Homepage binds host `:80`, so `apollo.local` opens the dashboard; every other service is reached on its own port via a dashboard tile. Plain HTTP (why: spec §2–3).

- Adding a service: publish its port, give it `homepage.*` labels, done.
- Bridge on `nas-net` by default — `network_mode: host` only for a service that strictly needs broadcast/multicast on the LAN (Jellyfin, the one exception).
- **Jellyfin is not on `nas-net`** (host-networked), so don't assume Homepage and Jellyfin share a network when debugging. Everything on `nas-net` resolves by container name (`http://sonarr:8989`); traffic to Jellyfin from any container uses `LAN_HOST` instead — a container-name address that works from Sonarr will not work from or to Jellyfin. Topology: spec §4.
- Homepage's Docker integration needs both the socket mount *and* `docker.yaml` in its config dir. Labels are read over the **Docker socket API, not the network**, so host-networked and off-`nas-net` containers still auto-discover.
- **Socket access is a DAC problem, and `EACCES` is not a path problem.** When discovery fails, no container is listed at all and Homepage renders only `services.yaml` — it looks like one service being ignored, not a dead integration. Diagnose by mechanism, in order: `ENOENT` means the path is wrong; `EACCES` means it was found and refused — check `docker inspect` for `CapDrop`/`SecurityOpt`, `/proc/1/status` for `CapEff` and PID 1's real `Groups` (a `docker exec` session gets fresh credentials and can differ from the server process), and `dmesg | grep denied` for AppArmor. `:ro` on the socket restricts nothing about the API. The identity mechanism (primary GID via `user: "${PUID}:${DOCKER_GID}"`, and why not `group_add` or the image's `PUID`/`PGID`) is spec §7.
- `homepage.href` values are real addresses (`http://apollo.local:8096`), and tiles are the only way in — a wrong href is a user-visible dead end. `homepage.widget.url` follows container-name resolution instead; the two are not interchangeable.
- Anything not a container (UGOS on 9999) can't be auto-discovered — hand-add it in `services.yaml`.
- After any change, verify assets (JS/CSS/API) load — not just that the landing HTML returns 200.

## Compose conventions

- Comments follow `docs/requirements.md` §Documentation policy: a comment earns its place only by stating a why — a trap, a non-obvious constraint, a decision that looks wrong but isn't. Narration of what the next line does is deleted.
- Every service: exact image tag, `container_name`, `restart`, explicit `networks: [nas-net]` (unless it uses `network_mode: host`, which is exclusive of both `networks:` and `ports:`), explicit volumes (config vs media separated), `logging:` capped (`json-file`, `max-size: 10m`, `max-file: 5`).
- Every `${VAR}` gets a `:-default` matching the `.env.example` — **except** secrets, which must fail loudly when unset.

## Jellyfin

- **Never add `ports:`** — `network_mode: host` ignores it, and host networking is required because client auto-discovery (`7359/udp`) and SSDP/DLNA (`1900/udp`) are broadcast/multicast, which bridge port publishing does not forward (spec §5). UGOS's own DLNA responder is disabled to free `1900`.
- `/config` + `/cache` on SSD; `/media/*` `:ro` from the HDD. Transcodes default to `/cache/transcodes`, already on SSD.
- `jellyfin-bootstrap.sh` does the whole first-boot setup over the API — wizard, admin user, libraries, QSV, the DLNA plugin, the network settings (LAN subnet, no known proxies, empty base URL), and the Homepage widget credentials — and is idempotent. It fails safe by design: `api()` returns 22 on any non-2xx, and under `set -e` that aborts *before* `/Startup/Complete`, leaving the wizard open and the script re-runnable. **Preserve that.**
- **The wizard is one-shot.** `POST /Startup/Complete` closes `/Startup/*` forever; doing it with no admin user leaves a login screen with no account. Each config wipe buys exactly one attempt.
- **`{}` is not a no-op.** `/System/Configuration/*` and `/Startup/Configuration` deserialize over the entire config object — an empty body resets every field.
- **Base URL must stay empty, and is asserted last** — a non-empty value moves the whole API under that prefix, so no call may follow it, and changing it needs a container restart. Reasoning: spec §5.
- Libraries: `collectionType` is a lowercase enum — `movies`, `tvshows` (not `series`), `music`. Paths are **container** paths (`/media/series`). Created with `EnableRealtimeMonitor: false` so inotify can't spin the HDD.
- **`GET /Startup/User` before `POST /Startup/User`.** The GET is not a read — `GetFirstUser()` calls `_userManager.InitializeAsync()`, which lazily creates the default user. `UpdateStartupUser()` only *updates*, returning a bare `NotFound()` when `GetFirstUser()` is null. Skip the GET on a fresh `/config` and the POST 404s; the same script then "works" on any server where someone opened the wizard UI or ran the GET by hand. A 404 here means *no user yet*, not a bad route.
- **An OpenAPI spec lists routes, not preconditions.** `POST /Startup/User` is declared with responses 204/401/403/503 — no 404 — yet returns 404 in exactly the case above. When a documented endpoint fails a way the spec says it can't, the spec is exhausted as evidence: read the controller source for the pinned tag (`raw.githubusercontent.com/jellyfin/jellyfin/v<version>/Jellyfin.Api/Controllers/<Name>Controller.cs`) instead of re-reading the spec.
- **Never send `curl -f` at a diagnostic.** `-f` discards the response body on HTTP errors, which is where Jellyfin puts its ASP.NET `ProblemDetails`. Capture status and body separately (`-w '\n%{http_code}'`). `jellyfin-bootstrap.sh --verbose` logs every request, status, and response body, with `Password` masked.
- **Know Jellyfin's own 404.** It answers with JSON `ProblemDetails` (`type`/`title`/`status`/`traceId`) and `Server: Kestrel` — that shape means the request reached Jellyfin and the route is wrong, not the network. Check `curl -i` headers before guessing.
- **Spec is vendored at `reference/jellyfin-openapi.json`** (recipes in `reference/README.md`). Query it with `jq` — **never `Read` or WebFetch it**: at 1.9MB it truncates before `/Startup`. It is the per-release file from `repo.jellyfin.org/files/openapi/stable/jellyfin-openapi-<version>.json`, and `jq -r '.info.version'` must match the pinned image tag — refresh it in the same change as any image bump. The running server's `curl -sS http://<host>:8096/api-docs/openapi.json` is the final word on what the binary serves.

  ```
  jq -r '.paths | to_entries[] | select(.key|test("^/Startup")) | "\(.key) [\(.value|keys|join(","))]"' reference/jellyfin-openapi.json
  ```

- **DLNA is a plugin** (not core since 10.10) and the bootstrap installs it: resolve it in `GET /Packages` (never hardcode the name), `POST /Packages/Installed/{name}`, then poll `GET /Plugins`. The `204` only means *queued* — a failure past it shows up only in the Jellyfin log. Casing differs per endpoint: `PackageInfo` is camelCase (`name`/`guid`), `PluginInfo` is PascalCase (`Name`/`Id`/`Status`). **No mid-run restart** — Jellyfin does not hot-load plugins, so a new one sits at `Status: Restart` and rides the deferred-restart channel (`exit 10` → `nas post-install` restarts → scan). Every DLNA call is non-fatal: a failed install must not abort before the base URL is asserted. `JELLYFIN_INSTALL_DLNA=0` skips it.
- **The Homepage widget secrets are bootstrap-minted, not install-generated.** `jellyfin-bootstrap.sh` creates the `Homepage` API key via `/Auth/Keys` (keys live in Jellyfin's database and cannot be env-seeded) and resolves the `RefreshLibrary` scheduled-task id, writing both back to `jellyfin.env`. They reach Homepage as container labels (`homepage.widgets[N].*`), which are **baked in at container create — `docker restart` never refreshes them** — so `nas post-install` recreates the container via compose when the `homepage.widgets[0].key` label lags the file. Empty on first bring-up by necessity, so unlike other secrets these two default to empty in the compose file. The widget URLs use `LAN_HOST` (shared.env) because Homepage fetches them itself and Jellyfin is host-networked. A wiped Jellyfin config invalidates the key; a bootstrap re-run mints a fresh one and triggers the recreate.
- Logs live in `/volume2/docker/jellyfin/config/log/` — inside the directory a wipe deletes. Grab them first (`nas destroy --save-logs`).

## Arr

- **Each arr unit's own `.env` is load-bearing forever, not just at first run.** The API keys are injected as `SONARR__AUTH__APIKEY` etc. (one key, one file, one unit: `sonarr.env`/`radarr.env`/`lidarr.env`/`prowlarr.env`/`seerr.env`), which the apps read at every start *in place of* `config.xml` — so the key is never persisted there. Lose one of these files and that app silently generates and persists a new random key, breaking Prowlarr's sync, Configarr and that unit's Homepage widget at once, with no error anywhere (spec §8). `nas install` generates each key once and never regenerates. **A 401 from a bootstrap step usually means a container older than its current `.env`**, not a wrong key — recreate it (`nas doctor` checks for exactly this).
- **The seed cap stops torrents; the arr apps delete them — do not "fix" this back to qBittorrent-side removal.** `Session\ShareLimitAction=Stop` in `qBittorrent.conf` pairs with `removeCompletedDownloads: true` on the arr download clients: the app removes a torrent **and its files** only once qBittorrent reports it stopped at the cap — never mid-seed, never before import. `RemoveWithContent` + `removeCompletedDownloads: false` looks equivalent but can delete a download that has not been imported yet, and the arr apps' download-client POST/PUT hard-rejects a qBittorrent set to remove-at-limit (HTTP 400, `isWarning: false`) — the bootstrap deliberately does **not** `forceSave` past that test, which guards the pairing and doubles as the connection/auth check. Config traps: the key is **not** `MaxRatioAction` (obsolete), and the value is the enum's **string name** — an integer fails to parse and silently falls back to the default. Full reasoning: spec §8.
- **Two accepted costs of arr-side removal:** a torrent added outside the arr apps (or in a foreign category) stops at the cap but is never deleted — manual cleanup; and a failed import holds its data on the SSD until someone resolves it in the Activity queue, instead of being silently reaped.
- **Adding a Prowlarr indexer is GET-schema-modify-POST, and that is enforced by code.** `IndexerResource.ToModel()` looks every non-standard field up in the cached Cardigann definition and throws `ArgumentOutOfRangeException` on anything unrecognised, so a hand-written body is rejected. Fetch `/api/v1/indexer/schema`, select by `definitionName`, modify, POST. **The schema's `appProfileId` is a placeholder `0` that fails validation** (`'App Profile Id' must be greater than '0'`, HTTP 400, on `forceSave` bodies too) — resolve the real sync-profile id from `GET /api/v1/appprofile` and patch it in; this and the rest of the tracker wiring live in `arr-indexers.sh`, not the bootstrap. Every indexer is POSTed **without** `forceSave` first, so the create path tests each one — for private trackers that test is the login check, the only automatic one they ever get. On failure the script prompts (via `/dev/tty` — stdin carries the indexer list): retry / update credentials / save untested (`?forceSave=true`) / skip; with `--non-interactive` or no terminal it saves untested with a warning instead, so unattended runs never hang. Private indexers ride the same path via `ARR_INDEXERS_PRIVATE` + `ARR_INDEXER_<NAME>_USER`/`_PASS` in `prowlarr.env` (username/password logins only; anything cookie/2FA-based is skipped with its field names printed). Credentials fixed at the prompt live only in Prowlarr — the script warns to copy them back into `prowlarr.env`, which a re-run after a wipe would otherwise reuse stale.
- **Byparr is registered under Prowlarr's `FlareSolverr` implementation** — it speaks that API, and there is no "Byparr" implementation (why it replaced FlareSolverr: spec §8). Prowlarr routes a request through the proxy only when it detects a Cloudflare challenge *and* the indexer shares a tag with the proxy, so `arr-indexers.sh` tags every indexer with `byparr` — free on unprotected trackers, future-proof for the rest; a proxy with no matching tagged indexer is a Prowlarr health warning. Byparr is GET-only: `request.post` is accepted but degrades to a GET — acceptable because the Cloudflare-protected trackers here all search via GET; an indexer that needs POST-through-solver is the one reason to reconsider. `POST /api/v1/indexerproxy` tests the proxy on create exactly like indexers do, with the same no-forceSave-then-fallback idiom (byparr may still be starting).
- **Prowlarr and Lidarr are API v1; Sonarr and Radarr are v3.** The wrong version 404s, which reads as a bad key rather than a bad path.
- **Lidarr is deliberately outside configarr/TRaSH** — the frozen Recyclarr template tree has no Lidarr profiles and configarr's Lidarr support is experimental, so default quality profiles stand. **No Seerr wiring either**: Seerr does not do music requests. Its root-folder POST requires real `qualityProfileId`/`metadataProfileId` values resolved first — a bare `{path}` body 400s; `arr-bootstrap.sh` resolves them.
- In `/api/v1/applications`, **`prowlarrUrl` is Prowlarr's own address and `baseUrl` is the target app's.** Easy to swap, and confusing when swapped.
- **`/api/v3/config/mediamanagement` is PUT-over-whole-object** — GET-modify-PUT, never a partial body.
- Don't transcribe TRaSH `trash_id`s. Configarr pulls the profiles and custom formats from the Recyclarr community templates, listed as `include:` entries in `configarr-config/config.yml` (installed only when absent, so on-NAS edits survive). Why configarr over Recyclarr: spec §11.
- **`include:` names are template *file basenames*, not Recyclarr CLI template ids.** `web-1080p` and `hd-bluray-web` are CLI ids and do **not** resolve here; the real names are `sonarr-v4-quality-profile-web-1080p`, `radarr-quality-profile-hd-bluray-web`, and so on. The two namespaces are unrelated and **a name that doesn't resolve is not an error — it is a silently missing profile.** The Sonarr/Radarr asymmetry is real: there is no `radarr-quality-profile-web-1080p`; `hd-bluray-web` is Radarr's analogue of Sonarr's `web-1080p`. The two resolve to the profiles `WEB-1080p` and `HD Bluray + WEB`.
- **`recyclarrRevision` is pinned, and must stay pinned.** Recyclarr v8 deleted the `includes/` tree from `recyclarr/config-templates`, so every `include:` only resolves at `4ae377bb…`. That is configarr's own built-in default (`DEFAULT_RECYCLARR_REVISION`), spelled out in the config so a future change to that default can't move it. Pointing it at `master` breaks every include at once. Only the TRaSH custom-format *data* tracks upstream; the templates are frozen.
- **Configarr exits 0 even when an instance fails.** The per-instance error is caught, counted and the run continues, so a dead Radarr is invisible to any exit-code check. The container sets `STOP_ON_ERROR=true` and `CONFIGARR_ENFORCE_CONFIG_VALIDATION=true` (the latter because an invalid config otherwise only warns and silently drops keys) to make failures real. `DRY_RUN=true` performs a genuine read-only run and prints the diff it would apply — that is the preflight, and `arr-bootstrap.sh --dry-run` uses it.
- **Configarr is run-to-completion, and that shapes the compose entry.** `restart: "no"` because a restart policy makes the daemon respawn it about once a minute, and `profiles: [configarr]` to keep it out of a plain `up -d` — this stack has no `depends_on`, so an auto-started sync would race Sonarr/Radarr's startup and fail at every bring-up. Naming a profiled service on the command line enables its profile implicitly; `docker compose down` however **ignores it** unless `--profile` is passed, which is why `nas destroy` passes it *and* keeps the by-name backstop.
- **Ofelia is the scheduler, because configarr has none and upstream won't add one.** `job-run` with `container = configarr` starts an *existing* container by name, waits, and captures its logs — it **never creates one**. So `nas install` must create it (`up -d --no-start configarr`, even when only ofelia was selected) or the daily job fails on inspect, visible only in `docker logs ofelia`. Ad-hoc runs pass their own `--name` to avoid colliding with it. `ARR_RUN_CONFIGARR=0` skips only the bootstrap's immediate sync, never the container creation — otherwise it would silently kill the schedule too.
- **Ofelia is the second container with the docker socket**, after Homepage — same accepted trade and same primary-GID setup (spec §7).
- **What configarr is deliberately not allowed to manage**, all of it left to `arr-bootstrap.sh`: `download_clients` (it would rewrite the qBittorrent password, and the client definition is `arr-bootstrap.sh`'s contract — including `removeCompletedDownloads: true`), `root_folders` (deletes and recreates to match the file), `delay_profiles` (deletes any profile not listed, and its example is usenet-defaulted), `media_naming` (would rename the existing library), and every `delete_unmanaged_*` toggle.
- **Seerr's API key is injected as the `API_KEY` env var, which Seerr writes over `settings.json`'s stored `apiKey` at every start** — `seerr.env` is the only source of truth, and a key rotated in the Seerr UI silently doesn't survive a restart. Auth header is `X-Api-Key`, same as the arr apps. Image and identity details: spec §8.
- **Seerr's setup is re-runnable until `POST /api/v1/settings/initialize`** — nothing is one-shot like Jellyfin's wizard, which is why `seerr-bootstrap.sh` calls initialize last, only after everything else succeeded. `POST /api/v1/auth/jellyfin` needs **no prior auth**: with no users it creates Seerr's admin (user 1) from the Jellyfin account given and stores the media-server settings; `serverType` is the numeric enum (`2` = Jellyfin). On later runs the same call is a plain sign-in. After user 1 exists, `X-Api-Key` acts as admin for everything.
- **`mediaServerType` is `MediaServerType`, and `4` means nothing was ever configured.** From the pinned image's own source (`server/constants/server.ts`): `PLEX = 1, JELLYFIN = 2, EMBY = 3, NOT_CONFIGURED = 4`. `GET /api/v1/settings/public` reporting `mediaServerType: 4` with `initialized: false` is a **pristine** Seerr, not a broken one — and `plexClientIdentifier` is populated on first boot regardless, so it is not evidence of Plex. Read the enum before concluding anything from that number.
- **A 403 on `/api/v1/auth/jellyfin` has more than one cause, and the first-user path is not one of them.** Per the spec the first user is created with full admin rights *unconditionally*, so that path cannot 403 over admin status — only the path where a user already exists can. A 403 with no user 1 therefore points at the upstream Jellyfin error in `docker logs seerr`, not at the account's role. `seerr-bootstrap.sh` prints the observed state (`initialized`, decoded `mediaServerType`, whether user 1 exists, the raw body) instead of asserting a cause — keep it that way.
- **A 403 from `/api/v1/request/count` (Homepage's widget) usually means Seerr has no user, not a bad key** — the API key only carries admin rights once user 1 exists, so an unconfigured Seerr 403s every authenticated route with a perfectly valid key.
- **`seerr-bootstrap.sh` must run after `arr-bootstrap.sh`** — it binds requests to the TRaSH profiles (`WEB-1080p` / `HD Bluray + WEB`) that configarr creates, falling back to the first profile with a warning. **A failure that cannot be distinguished from a deliberate skip is the bug**: it exits non-zero (`1` precondition, `22` API) and prints the state it saw, and `nas install` defers that rc — stack stays up, banner in the summary, non-zero exit. `SEERR_CONFIGURE=0` is the deliberate skip and stays exit 0.
- **It reads four env files**: `shared.env` for `ADMIN_USER`/`ADMIN_PASSWORD` and `LAN_HOST`, `seerr.env` for its own key and settings, and `sonarr.env`/`radarr.env` for their keys and root folders. Each path resolves `./`-prefixed for a bare filename, so a run from another cwd cannot silently read nothing; the usual `*_ENV_FILE` variables override each one. `ADMIN_PASSWORD` is a required var for jellyfin, qbittorrent **and** seerr, so a seerr-only `nas install` stops at the wizard pointer instead of stalling on an empty password.
- `GET /settings/jellyfin/library?enable=` **replaces** the enabled set — any library not listed is disabled — so the bootstrap only touches it pre-initialize.

## Tdarr

- **Never mount the download tree into Tdarr.** It rewrites files in place; the library is safe to rewrite only because imports are cross-filesystem copies, not the seeding file (spec §8 Tdarr).
- **The plugin finds a file's movie/series by path prefix, so Tdarr's media mounts must keep the exact container paths Radarr/Sonarr use** (`/media/movies`, `/media/series`). Change one side and every file is skipped as "no arr item".
- **The plugin takes config from the container environment only** — never add plugin inputs for keys or URLs (they'd be copies in Tdarr's database). API failures throw on purpose; don't turn them into skips (spec §8 Tdarr).
- **Its libraries live in its database, set in the web UI** — no compose var or env file configures them, and `nas recreate tdarr` starts from an empty database. Any library setting that polls or re-scans on a schedule wakes the HDD; don't propose one.
- Sized for remuxing (one CPU worker, no `/dev/dri`). A flow that re-encodes is a different unit shape — revisit both before adding one.
