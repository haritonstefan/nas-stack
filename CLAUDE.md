# nas-stack

## Goal

Self-hosted service stacks for a UGreen NAS (UGOS, `apollo.local`), as Docker Compose files in git — so the whole setup is reproducible from a fresh clone with `sudo ./up.sh` and reversible with `./down.sh`.

One standalone `docker-compose.<tier>.yml` per tier, no shared compose file, no runtime coupling between stacks beyond the `nas-net` network:

- **`core`** — `nas-net` and Homepage (dashboard on `:80`, the entrypoint to everything). Everything else depends on it; it depends on nothing.
- **`jellyfin`** — built.
- **`arr`** (sonarr/radarr/prowlarr/torrent), **`pihole`** — not yet built.

Bring-up order: `core` first, then consumer stacks in any order.

### Files

- `docker-compose.<tier>.yml` + `<tier>.env.example` — one self-contained pair per tier.
- `up.sh` / `down.sh` / `jellyfin-bootstrap.sh` — the automation. All have `--help`.
- `apollo-nas-stack-spec.md` — target state and the **reasoning** behind each constraint.
  Read it before proposing an architectural change.
- `homepage-config/` — templates (`docker.yaml`, `services.yaml`, `bookmarks.yaml`) that `up.sh` installs
  into the Homepage config dir only when absent, so on-NAS edits survive.
- `reference/` — the vendored Jellyfin OpenAPI spec (query it with `jq`, never `Read` it)
  plus recipes in `reference/README.md`.
- `TODO-healthchecks.md` — the one open work item.

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
- LAN IP `192.168.0.231` (DHCP reservation), `apollo.local` via mDNS.
- Bind-mount sources are **not** auto-created with correct ownership — `up.sh` mkdir+chowns them, so run it as root.
- Ports: `80` → Homepage (bound directly). `8096`/`7359`/`1900` → Jellyfin (host networking). `0.0.0.0:53` free → PiHole. UGOS on 9999.
- Docker daemon API `1.54` — pin images to exact patch versions and check compatibility against this.
- Compose files must not hardcode host paths — all via `.env` (gitignored; `<tier>.env.example` is the template).

## Running

`sudo ./up.sh` takes a fresh clone to running: env files, host dirs + ownership, core then jellyfin, bootstrap, restart. Idempotent. `./down.sh` reverses it. Both have `--help`.

Underneath it's plain compose. Compose does **not** read `<tier>.env` on its own, and all tiers share one directory — so `--env-file` and `-p nas-<tier>` are required on every call, or the stacks collapse into one project and report each other as orphans:

```
docker compose -p nas-core --env-file core.env -f docker-compose.core.yml up -d   # creates nas-net
docker compose -p nas-jellyfin --env-file jellyfin.env -f docker-compose.jellyfin.yml up -d
```

`down.sh` invariant to preserve: **nothing outside `/volume2/docker` can be deleted** — delete targets come from a sourced `.env`, so every path is validated against that root and rejected if it escapes, contains `..`, or is the root itself. `.env` files survive teardown (so no re-prompt for the Jellyfin password). Stacks come down jellyfin-first, core-last, since core owns `nas-net` and later bridged tiers will hold references to it.

## Networking & routing

Homepage binds host `:80`, so `apollo.local` opens the dashboard; every other service is reached on its own port via a dashboard tile. Plain HTTP.

- Adding a service: publish its port, give it `homepage.*` labels, done.
- `nas-net` is defined by `core` (not `external:` there); consumer stacks join it as `external: true`. Bridge by default — `network_mode: host` only for a service that strictly needs broadcast/multicast on the LAN (Jellyfin is the one exception).
- **`nas-net` carries no traffic today** — Homepage is its only member and Jellyfin is host-networked, so nothing resolves anything by container name yet. It exists for the `arr` stack, whose services talk to each other by name. Don't assume Homepage and Jellyfin share a network when debugging.
- Homepage's Docker integration needs both the socket mount *and* `docker.yaml` in its config dir (template: `homepage-config/docker.yaml`). Labels are read over the **Docker socket API, not the network**, so host-networked and off-`nas-net` containers still auto-discover.
- **Socket access is a DAC problem, and `EACCES` is not a path problem.** `/var/run/docker.sock` is `root:docker` `0660` (`DOCKER_GID=121`). Homepage sets identity via `user: "${PUID}:${DOCKER_GID}"` — *not* the image's `PUID`/`PGID`, which decide it inside the entrypoint where `docker inspect` can't see the result, and *not* `group_add`, whose supplementary GID a privilege drop can discard. A primary GID survives, and matching the socket's group needs no `DAC_OVERRIDE`. `/app/config` is owned by `PUID`, so it stays writable. When discovery fails, no container is listed at all and Homepage renders only `services.yaml` — it looks like one service being ignored, not a dead integration. Diagnose by mechanism, in order: `ENOENT` means the path is wrong, `EACCES` means it was found and refused — so check `docker inspect` for `CapDrop`/`SecurityOpt`, `/proc/1/status` for `CapEff` and PID 1's real `Groups` (a `docker exec` session gets fresh credentials and can differ from the server process), and `dmesg | grep denied` for AppArmor. `:ro` on the socket restricts nothing about the API.
- Granting a container the docker group is **root-equivalent host access**. Accepted here for Homepage on a LAN-only box with no forwarded ports; a read-only socket proxy is the alternative if that changes.
- `homepage.href` values are real addresses (`http://apollo.local:8096`), and tiles are the only way in — a wrong href is a user-visible dead end.
- `HOMEPAGE_ALLOWED_HOSTS` must list **every** name/address Homepage is reached *at* — the NAS's own name and IP, not the clients'. An unlisted Host header gets a 400. **No wildcard or CIDR support**: `192.168.0.*` is matched literally and rejects everything, so each address is listed in full (`*` alone disables the check entirely).
- Anything not a container (UGOS on 9999) can't be auto-discovered — hand-add it in `services.yaml`.
- After any change, verify assets (JS/CSS/API) load — not just that the landing HTML returns 200.

## Compose conventions

- Minimal comments; be explicit at the configuration level instead.
- Every service: exact image tag, `container_name`, `restart`, explicit `networks: [nas-net]` (unless it uses `network_mode: host`, which is exclusive of both `networks:` and `ports:`), explicit volumes (config vs media separated), `logging:` capped (`json-file`, `max-size: 10m`, `max-file: 5`).
- Every `${VAR}` gets a `:-default` matching the `.env.example` — **except** secrets, which must fail loudly when unset.

## Jellyfin

- **`network_mode: host`** — the one exception to the bridge rule. Client auto-discovery (`7359/udp`) and SSDP/DLNA (`1900/udp`) are broadcast/multicast, which Docker bridge port publishing does not forward, so discovery cannot work behind a bridge. Jellyfin binds `8096`, `7359` and `1900` on the host directly, so `ports:` does not apply and must never be added. UGOS's own DLNA responder is disabled to free `1900`.
- `/config` + `/cache` on SSD; `/media/*` `:ro` from the HDD. Transcodes default to `/cache/transcodes`, already on SSD.
- `jellyfin-bootstrap.sh` does the whole first-boot setup over the API (wizard, admin user, libraries, QSV, and asserts an empty base URL) and is idempotent. It fails safe by design: `api()` returns 22 on any non-2xx, and under `set -e` that aborts *before* `/Startup/Complete`, leaving the wizard open and the script re-runnable. **Preserve that.**
- **The wizard is one-shot.** `POST /Startup/Complete` closes `/Startup/*` forever; doing it with no admin user leaves a login screen with no account. Each config wipe buys exactly one attempt.
- **`{}` is not a no-op.** `/System/Configuration/*` and `/Startup/Configuration` deserialize over the entire config object — an empty body resets every field.
- **Base URL must stay empty, and is asserted last.** Jellyfin serves from the root of `:8096`. Bootstrap clears `BaseUrl` if anything set it, and does so last because a non-empty value moves the whole API under that prefix — no call may follow it. Changing it needs a container restart.
- Libraries: `collectionType` is a lowercase enum — `movies`, `tvshows` (not `series`), `music`. Paths are **container** paths (`/media/series`). Created with `EnableRealtimeMonitor: false` so inotify can't spin the HDD.
- **`GET /Startup/User` before `POST /Startup/User`.** The GET is not a read — `GetFirstUser()` calls `_userManager.InitializeAsync()`, which lazily creates the default user. `UpdateStartupUser()` only *updates*, returning a bare `NotFound()` when `GetFirstUser()` is null. Skip the GET on a fresh `/config` and the POST 404s; the same script then "works" on any server where someone opened the wizard UI or ran the GET by hand. A 404 here means *no user yet*, not a bad route.
- **An OpenAPI spec lists routes, not preconditions.** `POST /Startup/User` is declared with responses 204/401/403/503 — no 404 — yet returns 404 in exactly the case above. When a documented endpoint fails a way the spec says it can't, the spec is exhausted as evidence: read the controller source for the pinned tag (`raw.githubusercontent.com/jellyfin/jellyfin/v<version>/Jellyfin.Api/Controllers/<Name>Controller.cs`) instead of re-reading the spec.
- **Never send `curl -f` at a diagnostic.** `-f` discards the response body on HTTP errors, which is where Jellyfin puts its ASP.NET `ProblemDetails`. Capture status and body separately (`-w '\n%{http_code}'`). `jellyfin-bootstrap.sh --verbose` logs every request, status, and response body, with `Password` masked.
- **Know Jellyfin's own 404.** It answers with JSON `ProblemDetails` (`type`/`title`/`status`/`traceId`) and `Server: Kestrel` — that shape means the request reached Jellyfin and the route is wrong, not the network. Check `curl -i` headers before guessing.
- **Spec is vendored at `reference/jellyfin-openapi.json`** (recipes in `reference/README.md`). Query it with `jq` — **never `Read` or WebFetch it**: 1.9MB on one line, truncates alphabetically before `/Startup`. Refresh it from the running server, which is the only copy guaranteed to match the binary: `curl -sS http://<host>:8096/api-docs/openapi.json -o reference/jellyfin-openapi.json`, then confirm `jq -r '.info.version'` reports the running version — a vendored copy reading `12.0.0` is from another branch and may not describe your server.

  ```
  jq -r '.paths | to_entries[] | select(.key|test("^/Startup")) | "\(.key) [\(.value|keys|join(","))]"' reference/jellyfin-openapi.json
  ```

- Logs live in `/volume2/docker/jellyfin/config/log/` — inside the directory a reset wipes. Grab them first.
- **DLNA is a plugin** (not core since 10.10) and bootstrap installs it: resolve it in `GET /Packages` (never hardcode the name), `POST /Packages/Installed/{name}`, then poll `GET /Plugins`. The `204` only means *queued* — a failure past it shows up only in the Jellyfin log. Casing differs per endpoint: `PackageInfo` is camelCase (`name`/`guid`), `PluginInfo` is PascalCase (`Name`/`Id`/`Status`). **No mid-run restart** — Jellyfin does not hot-load plugins, so a new one sits at `Status: Restart` and rides the existing deferred-restart channel (`exit 10` → `up.sh` restarts → scan). Every DLNA call is non-fatal: a failed install must not abort before the base URL is asserted. `JELLYFIN_INSTALL_DLNA=0` skips it.