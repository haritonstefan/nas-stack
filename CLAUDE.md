# nas-stack

## Goal

Self-hosted service stacks for a UGreen NAS (UGOS, `apollo.local`), as Docker Compose files in git — so the whole setup is reproducible from a fresh clone with `sudo ./up.sh` and reversible with `./down.sh`.

One standalone `docker-compose.<tier>.yml` per tier, no shared compose file, no runtime coupling between stacks beyond the `nas-net` network:

- **`core`** — `nas-net`, Traefik (routing), Homepage (dashboard). Everything else depends on it; it depends on nothing.
- **`jellyfin`** — built.
- **`arr`** (sonarr/radarr/prowlarr/torrent), **`pihole`** — not yet built.

Bring-up order: `core` first, then consumer stacks in any order.

## Your role

You are the senior DevOps engineer on this box. It is a live NAS with real data on it, not a lab. Standing behaviors:

- **Read the spec offline before touching a running service.** Probe with `GET` only. A write request is not a discovery tool — one closed Jellyfin's one-shot setup wizard permanently.
- **Dry-run before mutating.** `up.sh --dry-run`, `down.sh` (dry by default), `jellyfin-bootstrap.sh --dry-run`.
- **Collect the evidence a destructive step destroys — logs first**, before any config wipe, `rm -rf`, or `down.sh`.
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
  docker compose -p nas-jellyfin --env-file jellyfin.env -f docker-compose.jellyfin.yml config
```

## Host facts

- `/volume1/Media/{Movies,Series,Music}` — HDD, media only. Mounted `:ro` where a service only reads.
- `/volume2/docker` — SSD, all container config/logs + this repo. Nothing that spins up the HDD at idle lives here.
- PUID/PGID `1000:10`. `RENDER_GID=105` (Intel iGPU, `/dev/dri/renderD128`). `TZ=Europe/Bucharest`.
- Bind-mount sources are **not** auto-created with correct ownership — `up.sh` mkdir+chowns them, so run it as root.
- Ports: 80/443 free → Traefik (443/TLS not configured yet). `0.0.0.0:53` free → PiHole. Traefik dashboard on 8082.
- Docker daemon API `1.54`; Traefik pinned `v3.7.10` (older Traefik fails against this daemon).
- Compose files must not hardcode host paths — all via `.env` (gitignored; `<tier>.env.example` is the template).

## Running

`sudo ./up.sh` takes a fresh clone to running: env files, host dirs + ownership, core then jellyfin, bootstrap, restart. Idempotent. `./down.sh` reverses it. Both have `--help`.

Underneath it's plain compose. Compose does **not** read `<tier>.env` on its own, and all tiers share one directory — so `--env-file` and `-p nas-<tier>` are required on every call, or the stacks collapse into one project and report each other as orphans:

```
docker compose -p nas-core --env-file core.env -f docker-compose.core.yml up -d   # creates nas-net
docker compose -p nas-jellyfin --env-file jellyfin.env -f docker-compose.jellyfin.yml up -d
```

`down.sh` invariant to preserve: **nothing outside `/volume2/docker` can be deleted** — delete targets come from a sourced `.env`, so every path is validated against that root and rejected if it escapes, contains `..`, or is the root itself. `.env` files survive teardown (so no re-prompt for the Jellyfin password). Stacks come down jellyfin-first, core-last, since core owns `nas-net`.

## Networking & routing

- `nas-net` is defined by `core` (not `external:` there); every consumer stack joins it as `external: true`. Bridge, never `network_mode: host` — container-name resolution must keep working.
- mDNS resolves single names only, so **routing is path-based, not subdomain-based**: `apollo.local/jellyfin`, `apollo.local/pihole`. Subdomains become possible once PiHole is the resolver on specific devices; then swap `PathPrefix` → `Host`.
- Traefik: Docker provider, `exposedbydefault=false` — a service opts in with `traefik.enable=true` in its own compose file.
- Homepage is the catch-all at `/` (`PathPrefix(/)`, `priority=1`). Any explicit priority elsewhere must be > 1. Homepage's Docker integration needs both the socket mount *and* `docker.yaml` in its config dir (template: `homepage-config/docker.yaml`).
- Path-based routing needs a `stripprefix` middleware **and** a matching "base URL" setting in the app itself if it emits absolute links. Verify assets (JS/CSS/API) load — not just that the landing HTML returns 200.

## Compose conventions

- Minimal comments; be explicit at the configuration level instead.
- Every service: exact image tag, `container_name`, `restart`, explicit `networks: [nas-net]`, explicit volumes (config vs media separated), `logging:` capped (`json-file`, `max-size: 10m`, `max-file: 5`).
- Every `${VAR}` gets a `:-default` matching the `.env.example` — **except** secrets, which must fail loudly when unset.

## Jellyfin

- Bridge network + explicit ports: `8096` (web), `7359/udp` (discovery), `1900/udp` (DLNA — UGOS's own responder was disabled for this). Direct port access matters for TV client auto-discovery.
- `/config` + `/cache` on SSD; `/media/*` `:ro` from the HDD. Transcodes default to `/cache/transcodes`, already on SSD.
- `jellyfin-bootstrap.sh` does the whole first-boot setup over the API (wizard, admin user, libraries, QSV, base URL) and is idempotent. It fails safe by design: `curl -fsS` under `set -e` aborts *before* `/Startup/Complete`, leaving the wizard open and the script re-runnable. **Preserve that.**
- **The wizard is one-shot.** `POST /Startup/Complete` closes `/Startup/*` forever; doing it with no admin user leaves a login screen with no account. Each config wipe buys exactly one attempt.
- **`{}` is not a no-op.** `/System/Configuration/*` and `/Startup/Configuration` deserialize over the entire config object — an empty body resets every field.
- **Base URL goes last.** Once set, the whole API moves under `/jellyfin` and needs a container restart. Re-running the script afterwards means pointing `JELLYFIN_URL` at the prefixed root.
- Libraries: `collectionType` is a lowercase enum — `movies`, `tvshows` (not `series`), `music`. Paths are **container** paths (`/media/series`). Created with `EnableRealtimeMonitor: false` so inotify can't spin the HDD.
- **`GET /Startup/User` before `POST /Startup/User`.** The GET is not a read — `GetFirstUser()` calls `_userManager.InitializeAsync()`, which lazily creates the default user. `UpdateStartupUser()` only *updates*, returning a bare `NotFound()` when `GetFirstUser()` is null. Skip the GET on a fresh `/config` and the POST 404s; the same script then "works" on any server where someone opened the wizard UI or ran the GET by hand. A 404 here means *no user yet*, not a bad route.
- **An OpenAPI spec lists routes, not preconditions.** `POST /Startup/User` is declared with responses 204/401/403/503 — no 404 — yet returns 404 in exactly the case above. When a documented endpoint fails a way the spec says it can't, the spec is exhausted as evidence: read the controller source for the pinned tag (`raw.githubusercontent.com/jellyfin/jellyfin/v<version>/Jellyfin.Api/Controllers/<Name>Controller.cs`) instead of re-reading the spec.
- **Never send `curl -f` at a diagnostic.** `-f` discards the response body on HTTP errors, which is where Jellyfin puts its ASP.NET `ProblemDetails`. Capture status and body separately (`-w '\n%{http_code}'`). `jellyfin-bootstrap.sh --verbose` logs every request, status, and response body, with `Password` masked.
- **Tell Jellyfin's 404 from a proxy's.** Jellyfin answers with JSON `ProblemDetails` (`type`/`title`/`status`/`traceId`) and `Server: Kestrel`; Traefik answers with a bare `404 page not found`. Check `curl -i` headers before blaming routing.
- **Spec is vendored at `reference/jellyfin-openapi.json`** (recipes in `reference/README.md`). Query it with `jq` — **never `Read` or WebFetch it**: 1.9MB on one line, truncates alphabetically before `/Startup`. Refresh it from the running server, which is the only copy guaranteed to match the binary: `curl -sS http://<host>:8096/api-docs/openapi.json -o reference/jellyfin-openapi.json`, then confirm `jq -r '.info.version'` reports the running version — a vendored copy reading `12.0.0` is from another branch and may not describe your server.

  ```
  jq -r '.paths | to_entries[] | select(.key|test("^/Startup")) | "\(.key) [\(.value|keys|join(","))]"' reference/jellyfin-openapi.json
  ```

- Logs live in `/volume2/docker/jellyfin/config/log/` — inside the directory a reset wipes. Grab them first.
- Still manual: Dashboard → Plugins → Catalog → DLNA plugin.