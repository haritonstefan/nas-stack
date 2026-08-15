# nas-stack

Docker Compose stacks for services running on a UGreen NAS (UGOS, Docker-capable, SSH access available).
Each stack is a **standalone, self-contained** `docker-compose.<tier>.yml` file — no shared compose file between tiers, no runtime dependency between stacks other than the shared Docker network.

## Repo layout — tiered

Flat folder, one compose file per tier:

- **`docker-compose.core.yml`** — the foundational tier: defines/creates the `nas-net` network, Traefik (reverse proxy / routing), Homepage (dashboard). This is the LAN service-exposure backbone; every other stack depends on `nas-net` existing and on Traefik for routing, but core itself depends on nothing else.
- `docker-compose.jellyfin.yml` — consumer stack
- `docker-compose.arr.yml` (sonarr, radarr, prowlarr, torrent client — more \*arr services may be added later) — consumer stack, **not yet built**
- `docker-compose.pihole.yml` — consumer stack, **not yet built**

Each stack has a matching `.env.example` (e.g. `core.env.example`) documenting required variables. Actual `.env` files are gitignored.

Two scripts sit alongside the compose files:

- **`up.sh`** — the entry point. Fresh-clone-to-running in one command; see "Running a stack" below.
- **`jellyfin-bootstrap.sh`** — configures Jellyfin over its API (wizard, admin user, libraries, QSV, base URL). Called by `up.sh`, but standalone and idempotent, so it can be re-run on its own.
- **`down.sh`** — the inverse of `up.sh`: stops both stacks, removes `nas-net`, and deletes `/volume2/docker/{traefik,homepage,jellyfin}`. See "Tearing down" below.

Bring-up order: `core` first (creates routing/dashboard), then any consumer stack, in any order.

## Host environment facts

- NAS: UGreen, UGOS, Docker + Docker Compose available, SSH access.
- Docker daemon API version on this NAS: `1.54` (confirm via `docker version --format '{{.Server.APIVersion}}'` if it ever changes after a UGOS update). Traefik versions before v3.6.16 fail against this daemon with `client version 1.24 is too old` — the fix was upgrading Traefik (currently pinned to `v3.7.10`), not pinning `DOCKER_API_VERSION`; modern Traefik negotiates the API version with the daemon automatically. If a future service hits the same error, prefer upgrading that service's image first before reaching for a `DOCKER_API_VERSION` override.
- Volumes:
  - `/volume1/Media/{Movies,Series,Music}` — HDD, media storage only.
  - `/volume2/docker` — SSD, holds all container configs, logs, and this repo. Nothing that causes idle HDD spin-up lives here.
- Repo is portable: compose files must not hardcode absolute paths inline — all host paths are supplied via `.env` files so the same compose file works regardless of where the repo is cloned.
- PUID/PGID for container users: `1000:10` (confirm per-service if a service misbehaves on permissions).
- Ports 80 and 443 on the host are free (UGOS admin UI runs on a separate port) — reserved for Traefik. Port 53 is bound only on `127.0.0.1` by the host, so `0.0.0.0:53` is free for PiHole DNS.
- PiHole web UI is mapped to host port `8081` (not 80, since 80 belongs to Traefik) and is reached at `apollo.local/pihole` once behind Traefik.
- Timezone for all containers: `TZ=Europe/Bucharest`.

## Networking

- One shared Docker network, `nas-net`, is defined and created by `docker-compose.core.yml` (not `external: true` there) — bringing up `core` creates it, so no manual `docker network create` step is needed.
- Every consumer stack's compose file joins `nas-net` as an **external** network (it must already exist, created by `core`) — this allows cross-stack, container-name-based resolution (e.g. Sonarr reaching Prowlarr by hostname).
- Do not use `network_mode: host` unless a specific service strictly requires it — prefer bridge + shared network so container-name resolution keeps working.

## Running a stack

From a fresh clone, `./up.sh` does everything:

```
git clone <repo> && cd nas-stack
sudo ./up.sh              # --dry-run to see the plan first
```

It checks prerequisites, creates `<tier>.env` from each `.example` (never overwriting an existing one), creates host directories and chowns them to `PUID:PGID`, installs Homepage's `docker.yaml`, brings up core then jellyfin, runs `jellyfin-bootstrap.sh`, and restarts Jellyfin to activate the base URL. Idempotent — re-running reconciles rather than recreating. Flags: `--dry-run`, `--no-bootstrap`, and `core` / `jellyfin` to scope to one stack.

**Run it as root** (or a user that can `chown` into `/volume2/docker`) — ownership is skipped with a notice otherwise, and Jellyfin then fails to write `/config`. The one interactive prompt is the Jellyfin admin password when `JELLYFIN_ADMIN_PASSWORD` is unset; it's written back to `jellyfin.env` with `chmod 600`. Warnings (missing media dirs, missing `/dev/dri/renderD128`, a `RENDER_GID` that doesn't match the host's render group) are non-fatal by design so a partial setup still comes up.

Underneath it's plain compose — Compose does not read `<tier>.env` automatically, so it must be passed explicitly every time. Each tier also gets its **own project name** (`-p nas-<tier>`): all the compose files share one directory, so without it they collapse into a single directory-derived project and every `up` reports the other stack's containers as orphans.

```
docker compose -p nas-core --env-file core.env -f docker-compose.core.yml up -d   # creates nas-net
docker compose -p nas-jellyfin --env-file jellyfin.env -f docker-compose.jellyfin.yml up -d
```

Containers created before the `-p` convention live under the old project name; `docker compose -f <file> down` them once (or just `docker rm -f`) and re-run `up.sh` to re-adopt them. `container_name` is explicit on every service, so names don't change either way.

## Tearing down

`./down.sh` reverses `up.sh` — stops both stacks, removes `nas-net`, and deletes the persistent config under `/volume2/docker`.

```
./down.sh                 # dry run (the default) — lists what would go, with sizes
sudo ./down.sh --yes      # actually do it; prompts once, type "delete" to confirm
sudo ./down.sh --containers   # stop/remove containers only, keep all data
sudo ./down.sh --yes jellyfin # scope to one stack
```

**A dry run is the default** — `--yes` is required to change anything, and deleting data additionally needs an interactive `delete` confirmation (`--force` bypasses it for scripted use, and without a TTY the script refuses rather than assuming consent).

Safety invariants worth preserving if this script is ever edited:

- **Nothing outside `/volume2/docker` can be deleted.** Every path is validated against that root and rejected if it escapes, contains `..`, or resolves to the root itself — the delete targets come from a sourced `.env`, so a mistyped or empty value must not be able to expand into something outside it. Verified by pointing `JELLYFIN_CONFIG_DIR` at `/` and `HOMEPAGE_CONFIG_DIR` at `/volume1/Media/Movies`: both are refused and dropped from the plan. The plan's "NOT touched" section states this as the root-level invariant; it deliberately does **not** enumerate media paths — `down.sh` has no business reading `MEDIA_*_DIR` at all, and listing them made the script read as if media were in scope.
- **`.env` files survive** a teardown, so `up.sh` afterwards doesn't re-prompt for the Jellyfin admin password. Delete them by hand for a truly clean slate.
- Stacks come down **jellyfin-first, core-last**, since core owns `nas-net` and consumers join it as external — the reverse order leaves the network in use. Stray containers predating the `-p nas-<tier>` convention are then removed by name.

Everything Jellyfin knows — users, libraries, watch state, downloaded metadata — is in `/volume2/docker/jellyfin` and does not survive a full teardown. Re-running `up.sh` afterwards rebuilds it from scratch via `jellyfin-bootstrap.sh`.

## Routing (Traefik) and dashboard (Homepage) — both in `docker-compose.core.yml`

- Host: UGreen NAS is reachable via mDNS as `apollo.local`. mDNS resolves exact single names only — it does **not** support wildcard/subdomain resolution (`jellyfin.apollo.local` will not resolve without a real DNS server answering it). Until PiHole (or another local DNS) is configured per-device as the resolver, routing is **path-based**, not subdomain-based.
- Traefik binds host port 80 (`TRAEFIK_HTTP_PORT`), uses the Docker provider (`exposedbydefault=false`, scoped to `nas-net`) — every routable service must opt in explicitly via `traefik.enable=true` labels in its own compose file.
- Port 443/TLS: intentionally not configured yet (HTTP-only for now). Add later without disrupting routing.
- Traefik dashboard has its **own entrypoint/port** (`TRAEFIK_DASHBOARD_PORT`, default 8082 → container port 8080), reachable at `apollo.local:8082/dashboard/`. It is deliberately NOT routed through the `/` path on the `web` entrypoint — `api@internal`'s dashboard assets request absolute paths (`/dashboard/*`, `/api/*`) that a stripped path-prefix breaks, and it would otherwise collide with Homepage's catch-all at `/`.
- Homepage is the landing dashboard at `apollo.local/` (root `PathPrefix`, priority 1, catch-all), auto-discovers tiles via `homepage.*` labels on each service's own compose file.
- Homepage Docker integration is two parts: (1) the socket mount (`/var/run/docker.sock:ro`) on the homepage service itself, AND (2) a `docker.yaml` file in `${HOMEPAGE_CONFIG_DIR}` declaring `my-docker: {socket: /var/run/docker.sock}` — a template lives at `homepage-config/docker.yaml` in this repo, copy it into the config dir before first boot. Without it, `homepage.*` labels still render tiles but container stats/status won't resolve.
- **Routing priority convention**: Homepage's router uses `PathPrefix(\`/\`)` with `traefik.http.routers.homepage.priority=1` as a catch-all. Every other service's path route (e.g. `/jellyfin`, `/pihole`) is more specific and Traefik already prioritizes longer/more-specific rules higher by default — but if a future service ever also needs an explicit `priority`, it must be a number greater than 1 to win over Homepage's catch-all.
- Path-based routing caveat: apps that don't support being served from a subpath natively need a Traefik `stripprefix` middleware (strips e.g. `/jellyfin` before proxying) AND, if the app itself generates absolute links/redirects, a matching "URL base" setting in that app. Configure per-service as each stack is built, and verify by checking that page assets (JS/CSS/API calls) actually load — not just that the landing HTML returns 200.
- Homepage config dir (`${HOMEPAGE_CONFIG_DIR}`) needs the `docker.yaml` above; Homepage generates the rest of its skeleton config (`settings.yaml`/`services.yaml`/etc.) on first boot if absent.
- Migration path to subdomains later: point specific devices' DNS at PiHole manually (router-wide DNS override isn't available in this environment), then switch each service's Traefik rule from `PathPrefix` to `Host`.

## Working against live services

- **Never use write requests to discover an API on a running instance.** Fetch the spec and read it offline first; probe with reads (`GET`, `/System/Info/Public`) only. Learning the Jellyfin API by POSTing to `/Startup/*` closed the setup wizard and reset the server name on a live server — and the `405` vs `404` signal it produced was misleading anyway (`/Startup/FirstUser` is GET-only, a dead end). The spec answered in one `jq` query what the probing got wrong.
- Prefer the service's own logs and the published spec over inference from status codes. A status code tells you *that* something failed, rarely *why*.
- Before any destructive recovery step (config wipe, `down.sh`, `rm -rf`), collect the evidence that step destroys — logs especially.

## Conventions for compose files

- Minimal comments. Be verbose at the configuration level instead (explicit env vars, explicit port mappings, explicit volume paths, restart policies, healthchecks where sensible) rather than relying on image defaults.
- Every service pinned to an explicit image tag, exact patch version — never `:latest`, never a floating minor/major tag.
- Every service: explicit `container_name`, explicit `restart` policy, explicit volume mounts (config vs data/media separated per the volume layout above), explicit `networks: [nas-net]`, explicit `logging:` limits (`json-file`, `max-size: "10m"`, `max-file: "5"`) so container logs can't grow unbounded on the SSD volume.
- Config/log data for a service lives under `/volume2/docker/<service>/...`; media libraries are mounted read-only where the service only needs to read (e.g. Jellyfin) and read-write where it needs to manage files (e.g. \*arr apps).
- Every `${VAR}` interpolation in a compose file has a `:-default` fallback matching that stack's `.env.example`, since most values aren't sensitive — the stack should come up correctly even if `--env-file` is forgotten. Only genuinely sensitive values (credentials, API keys) should be left without a default so a missing `.env` fails loudly instead of silently using a bogus secret.

## Jellyfin

- Bridge network (`nas-net`), not `network_mode: host` — consistent with the networking convention above. Direct access ports are published explicitly instead: `8096` (HTTP/web), `7359/udp` (auto-discovery broadcast), `1900/udp` (DLNA — confirmed free; UGOS's own DLNA/SSDP responder was intentionally disabled on this NAS in favor of Jellyfin's).
- Hardware transcoding: Intel iGPU passthrough via `/dev/dri/renderD128` + `group_add: [\"${RENDER_GID}\"]`. `RENDER_GID` is host-specific — found via `getent group render | cut -d: -f3` over SSH (confirmed `105` on this NAS). `user: \"${PUID}:${PGID}\"` matches the rest of the stack. Before first `up`, confirm the device node exists: `ls -l /dev/dri` should show `renderD128`.
- Storage split: `/config` and `/cache` on `/volume2/docker/jellyfin/...` (SSD); `/media/{movies,series,music}` mounted `:ro` from `/volume1/Media/...` (HDD) — Jellyfin never writes to media, all metadata/subtitle writes land in `/config`. Transcode temp files default to `/cache/transcodes` inside the container (no separate mount needed) — already on the SSD via the `/cache` mount, satisfying the "don't spin up the HDD" goal without extra config.
- **Prerequisite**: bind-mount source directories are NOT auto-created with correct ownership. Before first `up`, on the NAS: `mkdir -p /volume2/docker/jellyfin/{config,cache}` then `chown -R 1000:10` those paths — otherwise the container (running as `1000:10` via `user:`) can't write `/config` and fails.
- **Unattended setup — `jellyfin-bootstrap.sh`.** Everything except the DLNA plugin is configured over the API, so first boot needs no dashboard clicking:

  ```
  docker compose --env-file jellyfin.env -f docker-compose.jellyfin.yml up -d
  ./jellyfin-bootstrap.sh --dry-run   # prints every request without sending it
  ./jellyfin-bootstrap.sh
  docker restart jellyfin             # activates the base URL
  ```

  It runs the startup wizard (server name, admin user, metadata locale), creates the three libraries, enables Intel QSV, and sets the base URL. Idempotent — re-running skips the wizard if complete, skips libraries that already exist, and skips the base URL if already set. Config lives in `jellyfin.env` (`JELLYFIN_ADMIN_PASSWORD` has no default, so a missing value fails loudly rather than setting a bogus one).
- **Why API and not pre-seeded XML.** `system.xml` / `network.xml` / `encoding.xml` *can* be written directly, and the API endpoints (`POST /System/Configuration{,/network,/encoding}`) just serialize the same objects to those same files — so nothing in them is API-blocked. But the admin user and libraries cannot be seeded as files at all: users are rows in an EF Core database (`/config/data/jellyfin.db`) with salted password hashes, and libraries are database rows *plus* a `.mblink` shortcut tree under `/config/root/default/`. Since the script is needed for those regardless, doing everything through it keeps one mechanism instead of two. `IsStartupWizardCompleted` is the one field with no API setter — `POST /Startup/Complete` flips it, which is the correct way to end the wizard anyway. Never write it as `true` onto an instance with no user: that yields a login screen with no account and no route back into the wizard.
- **The API spec is vendored at `reference/jellyfin-openapi.json` — read it, don't probe for it.** See `reference/README.md` for query recipes. **Don't open it with WebFetch or `Read`**: it's ~1.9MB on one line and truncates alphabetically, before `/Startup` ever appears. Use `jq`:
  ```
  jq -r '.paths | to_entries[] | select(.key|test("^/Startup")) | "\(.key) [\(.value|keys|join(","))]"' reference/jellyfin-openapi.json
  jq '.components.schemas.StartupUserDto' reference/jellyfin-openapi.json
  ```
- **The OpenAPI document versions independently of the server.** That file reports `info.version: 12.0.0` while describing a 10.11.x server — **there is no Jellyfin 12**. The release line is 10.x; newest published image is `10.11.11` (confirm against Docker Hub tags, not a version string found inside a spec). Because "stable" runs ahead of the pinned image, treat what it says as a strong hint, not proof, for this server.
- **Config POSTs take the whole object — `{}` is not a no-op.** `/System/Configuration/*` and `/Startup/Configuration` deserialize the posted body over the entire config object, so an empty body *resets every field* (this is how `ServerName` got wiped back to the container ID). Always GET-modify-POST, as the script does for `encoding` and `network`.
- **The wizard is one-shot.** `POST /Startup/Complete` closes `/Startup/*` permanently; doing that on an instance with no admin user yields a login screen with no account and no way back in. Each config wipe buys exactly one attempt — get the script right before spending it.
- **`jellyfin-bootstrap.sh` fails safe, deliberately.** `curl -fsS` under `set -e` aborts on the first HTTP error, which is *before* `/Startup/Complete` — so a mid-wizard failure leaves the wizard open and the script re-runnable. Preserve that property when editing.
- **Grab the logs before any reset.** Jellyfin writes to `/volume2/docker/jellyfin/config/log/jellyfin*.log` — inside the directory the reset wipes. Full reset:
  ```
  docker compose -p nas-jellyfin --env-file jellyfin.env -f docker-compose.jellyfin.yml down
  rm -rf /volume2/docker/jellyfin/config/*
  sudo ./up.sh jellyfin
  ```
- **Ordering constraint — base URL goes last.** Once `BaseUrl` takes effect the entire API moves under `${JELLYFIN_BASE_URL}` (`:8096/jellyfin/...`), so the script sets it as its final call and every earlier call targets the bare root. It needs a container restart to activate. If you ever re-run the script against an instance that *already* has the base URL set, point `JELLYFIN_URL` at the prefixed root (`http://apollo.local:8096/jellyfin`).
- **Library `collectionType` values are lowercase enum names** — `movies`, `tvshows`, `music`. Note `tvshows`, not `series`, despite the directory being `/volume1/Media/Series`. Paths sent to the API are **container** paths (`/media/series`), never host paths. Libraries are created with `EnableRealtimeMonitor: false` so inotify watching the media HDD can't defeat the no-idle-spin-up goal.
- **Still manual after bootstrap**: to use Jellyfin as the LAN's DLNA server (in place of UGOS's, which was disabled for this), Dashboard → Plugins → Catalog → install the DLNA plugin (built into core before v10.10, a separate plugin since). Nothing to pre-bake into the compose file.
- Exposed both ways per your choice: through Traefik (`apollo.local/jellyfin`, path-based) and directly (`apollo.local:8096/jellyfin` — prefixed, once the base URL is set) — the direct port matters for native/TV client auto-discovery (UDP broadcast to Jellyfin's own port, not the reverse proxy). `jellyfin-bootstrap.sh` runs against the *unprefixed* `apollo.local:8096` since it configures the server before the base URL exists.

## Open / future items

- **UNRESOLVED: `POST /Startup/User` returns 404 on 10.11.11.** The endpoint is correct and documented (`{Name, Password}`, spec lists responses 204/401/403/503 — no 404), so this is *not* a renamed endpoint, and `/Startup/FirstUser` is GET-only so it's not the replacement. Every `/Startup/*` route shares one policy (`FirstTimeSetupOrElevated`), yet `/Startup/Configuration` returned 204 while `/Startup/User` returned 404 on the same server seconds apart — so the 404 originates inside the handler, not in routing or auth. Cause still unverified; server logs unread. **Discriminating test**, read-only, on a fresh instance with the wizard still open (`FirstTimeSetupOrElevated` passes unauthenticated there):
  ```
  curl -sS -w '\n%{http_code}\n' http://apollo.local:8096/Startup/User \
    -H 'Authorization: MediaBrowser Client="probe", Device="probe", DeviceId="p1", Version="1.0.0"'
  ```
  A user object → the row exists and the 404 is elsewhere in the handler. Empty or 404 → no first user is auto-created on this version, which makes the "updates the auto-created first user" assumption in `jellyfin-bootstrap.sh` the actual bug, and the fix a different creation path.

- More \*arr services (e.g. bazarr, lidarr) may be added to the arr stack — keep that compose file structured so adding a service is a simple copy-paste block.
- HTTPS/TLS on Traefik: not yet configured, add later.
- Subdomain-based routing: possible later once PiHole is set as DNS resolver on specific devices (see Routing section above).
- mDNS auto-broadcast per container: considered and parked — not worth the complexity (would need host networking, conflicting with the shared bridge network model) versus the simpler path-based routing already in place.
