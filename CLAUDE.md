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

Bring-up order: `core` first (creates routing/dashboard), then any consumer stack, in any order.

## Host environment facts

- NAS: UGreen, UGOS, Docker + Docker Compose available, SSH access.
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

Compose does not read `<tier>.env` automatically — it must be passed explicitly, every time:

```
docker compose --env-file core.env -f docker-compose.core.yml up -d   # creates nas-net
docker compose --env-file jellyfin.env -f docker-compose.jellyfin.yml up -d
```

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
- **Required manual post-first-boot steps** (in order):
  1. First bring-up must be reached via the **direct port**, `apollo.local:8096` — the path route `apollo.local/jellyfin` does not work yet at this point.
  2. Complete the Jellyfin setup wizard at `apollo.local:8096`.
  3. Dashboard → Advanced → Networking → Base URL → set to `/jellyfin`, then restart the container. Base URL is not an env var or compose setting — Traefik's `PathPrefix(\`/jellyfin\`)` label only works once Jellyfin itself is told to expect that prefix (no `stripprefix` middleware is used; the path is passed through unchanged). After this, `apollo.local/jellyfin` works.
  4. To use Jellyfin as the LAN's DLNA server (in place of UGOS's, which was disabled for this): Dashboard → Plugins → Catalog → install the DLNA plugin (built into core before v10.10, a separate plugin since). Plugins install through this same UI — nothing to pre-bake into the compose file.
- Exposed both ways per your choice: through Traefik (`apollo.local/jellyfin`, path-based, after Base URL is set) and directly (`apollo.local:8096`) — the direct port matters for native/TV client auto-discovery (UDP broadcast to Jellyfin's own port, not the reverse proxy) and is required for the initial setup wizard.

## Open / future items

- More \*arr services (e.g. bazarr, lidarr) may be added to the arr stack — keep that compose file structured so adding a service is a simple copy-paste block.
- HTTPS/TLS on Traefik: not yet configured, add later.
- Subdomain-based routing: possible later once PiHole is set as DNS resolver on specific devices (see Routing section above).
- mDNS auto-broadcast per container: considered and parked — not worth the complexity (would need host networking, conflicting with the shared bridge network model) versus the simpler path-based routing already in place.
