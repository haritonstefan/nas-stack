# nas-stack

## Goal

Self-hosted service stacks for a UGreen NAS (UGOS, `apollo.local`), as Docker Compose files in git — so the whole setup is reproducible from a fresh clone with `sudo ./up.sh` and reversible with `./down.sh`.

One standalone `docker-compose.<tier>.yml` per tier, no shared compose file, no runtime coupling between stacks beyond the `nas-net` network:

- **`core`** — `nas-net` and Homepage (dashboard on `:80`, the entrypoint to everything). Everything else depends on it; it depends on nothing.
- **`jellyfin`** — built.
- **`arr`** — sonarr/radarr/prowlarr/qbittorrent/seerr, plus byparr, configarr and ofelia. Built.
- **`pihole`** — not yet built.

Bring-up order: `core` first, then consumer stacks in any order.

### Files

- `docker-compose.<tier>.yml` + `<tier>.env.example` — one self-contained pair per tier.
- `up.sh` / `down.sh` / `arr-bootstrap.sh` / `arr-indexers.sh` / `configure.sh` — the automation, all with `--help`.
  `jellyfin-bootstrap.sh` has no `--help`; don't repeat that gap in new scripts.
- `arr-indexers.sh` — adds the trackers to Prowlarr (the `byparr` tag, the Byparr proxy,
  the public and private indexers). Deliberately **not** called by `up.sh` — run it by
  hand after the bring-up. Idempotent and re-runnable, which matters because Prowlarr
  fetches its Cardigann definitions shortly after start, so a definition missing on the
  first run often appears on a later one.
- `configure.sh` — optional interactive wizard that fills in the `.env` files before
  `up.sh` (detects host facts, asks shared values once, stages + confirms per file).
  It never touches the up.sh-generated secrets, and `up.sh` stays fully non-interactive
  without it.
- `apollo-nas-stack-spec.md` — target state and the **reasoning** behind each constraint.
  Read it before proposing an architectural change.
- `homepage-config/` — templates (`docker.yaml`, `services.yaml`, `bookmarks.yaml`) that `up.sh` installs
  into the Homepage config dir only when absent, so on-NAS edits survive.
- `qbittorrent-config/qBittorrent.conf` — same install-only-when-absent idiom. `up.sh`
  substitutes the `__PLACEHOLDER__` tokens (password hash, paths, seed cap) at install time.
- `reference/` — the vendored API specs: Jellyfin's (JSON — query it with `jq`, never `Read`
  it) and Seerr's (`seerr-api.yml`, multi-line YAML, safe to grep + line-read). Recipes in
  `reference/README.md`.
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
- Ports: `80` → Homepage (bound directly). `8096`/`7359`/`1900` → Jellyfin (host networking). `8989`/`7878`/`9696`/`8080` → Sonarr/Radarr/Prowlarr/qBittorrent, `6881` tcp+udp torrent, `5055` → Seerr. `0.0.0.0:53` free → PiHole. UGOS on 9999.
- Docker daemon API `1.54` — pin images to exact patch versions and check compatibility against this.
- Compose files must not hardcode host paths — all via `.env` (gitignored; `<tier>.env.example` is the template).

## Running

`sudo ./up.sh` takes a fresh clone to running: env files, host dirs + ownership, generated arr secrets, core then jellyfin then arr, both bootstraps, restart. Idempotent. `./down.sh` reverses it. Both have `--help`.

Underneath it's plain compose. Compose does **not** read `<tier>.env` on its own, and all tiers share one directory — so `--env-file` and `-p nas-<tier>` are required on every call, or the stacks collapse into one project and report each other as orphans:

```
docker compose -p nas-core --env-file core.env -f docker-compose.core.yml up -d   # creates nas-net
docker compose -p nas-jellyfin --env-file jellyfin.env -f docker-compose.jellyfin.yml up -d
docker compose -p nas-arr --env-file arr.env -f docker-compose.arr.yml up -d
```

`down.sh` invariant to preserve: **nothing outside `/volume2/docker` can be deleted** — delete targets come from a sourced `.env`, so every path is validated against that root and rejected if it escapes, contains `..`, or is the root itself. `.env` files survive teardown (so no re-prompt for the Jellyfin password, and the arr API keys are not lost). The download tree survives too, though it is inside the root — see `## Arr`. Stacks come down **arr-first, core-last**, since core owns `nas-net` and arr joins it as external.

## Networking & routing

Homepage binds host `:80`, so `apollo.local` opens the dashboard; every other service is reached on its own port via a dashboard tile. Plain HTTP.

- Adding a service: publish its port, give it `homepage.*` labels, done.
- `nas-net` is defined by `core` (not `external:` there); consumer stacks join it as `external: true`. Bridge by default — `network_mode: host` only for a service that strictly needs broadcast/multicast on the LAN (Jellyfin is the one exception).
- **`nas-net` carries real traffic now** — the arr services resolve each other by container name over it (Prowlarr → `http://sonarr:8989`, Sonarr → `http://qbittorrent:8080`, Homepage widgets → all of them). **Jellyfin is still not on it** (host-networked), so don't assume Homepage and Jellyfin share a network when debugging. A container-name address that works from Sonarr will not work from Jellyfin.
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

- **The Homepage widget secrets are bootstrap-minted, not up.sh-generated.** `jellyfin-bootstrap.sh` creates the `Homepage` API key via `/Auth/Keys` (keys live in Jellyfin's database and cannot be env-seeded) and resolves the `RefreshLibrary` scheduled-task id, writing both back to `jellyfin.env`. They reach Homepage as container labels (`homepage.widgets[N].*`), which are **baked in at container create — `docker restart` never refreshes them** — so `up.sh` recreates the container via compose when the `homepage.widgets[0].key` label lags the file. Empty on first bring-up by necessity, so unlike other secrets these two default to empty in the compose file. The widget URLs use `JELLYFIN_LAN_HOST` (host LAN IP) because Homepage fetches them itself and Jellyfin is host-networked. A wiped Jellyfin config invalidates the key; a bootstrap re-run mints a fresh one and triggers the recreate.
- Logs live in `/volume2/docker/jellyfin/config/log/` — inside the directory a reset wipes. Grab them first.

## Arr

- **`arr.env` is load-bearing forever, not just at first run.** The API keys are injected as `SONARR__AUTH__APIKEY` etc., which the apps read at every start *in place of* `config.xml` — so the key is never persisted there. Lose the file and each app silently generates and persists a new random key, breaking Prowlarr's sync, Configarr and all three Homepage widgets at once, with no error anywhere. `up.sh` generates them once and never regenerates. **A 401 from a bootstrap step usually means a container older than the current `arr.env`**, not a wrong key — recreate it.
- **Imports are copies, not hardlinks, on purpose.** Downloads live on `/volume2` (SSD) and the library on `/volume1` (HDD): different filesystems, so no hardlink is possible and every import is a full copy. The trade was deliberate — seeding runs off the SSD and never holds the media HDD awake. Consequences to keep in mind: transient 2× space for the file being imported, and `copyUsingHardlinks` is asserted but inert. Moving downloads to `/volume1` is what would make hardlinks work.
- **The seed cap stops torrents; the arr apps delete them.** `Session\ShareLimitAction=Stop` in `qBittorrent.conf` (with `GlobalMaxRatio` / `GlobalMaxSeedingMinutes`) pairs with `removeCompletedDownloads: true` on the Sonarr/Radarr download clients: the app removes a torrent **and its files** only once qBittorrent reports it stopped at the cap — never mid-seed, and never before import — which is what frees the SSD. Config traps: the key is **not** `MaxRatioAction` (obsolete), and the value is the enum's **string name** — qBittorrent serialises enums via `Utils::String::fromEnum`, so an integer fails to parse and silently falls back to the default.
- **Do not "fix" this back to qBittorrent-side removal.** `RemoveWithContent` + `removeCompletedDownloads: false` looks equivalent but can delete a download that has not been imported yet (cap reached while the import is queued or stuck), and Sonarr/Radarr's download-client POST/PUT hard-rejects a qBittorrent set to remove-at-limit (HTTP 400, `isWarning: false`). The bootstrap deliberately does **not** `forceSave` past that test — it now guards the pairing, and it is also the connection/auth check. The old claim that `removeCompletedDownloads: true` kills seeding right after import was v2-era behavior, long gone from the pinned versions.
- **Two accepted costs of arr-side removal:** a torrent added outside the arr apps (or in a foreign category) stops at the cap but is never deleted — manual cleanup; and a failed import holds its data on the SSD until someone resolves it in the Activity queue, instead of being silently reaped.
- **qBittorrent mints a new random WebUI password on every start unless one is stored.** The sole trigger is an empty stored password (`WEBUI_PORT` is unrelated), and the temporary one is per-session, never persisted — so without pre-seeding, every restart invalidates the credentials Sonarr and Radarr hold. `up.sh` seeds a PBKDF2 hash (SHA-512, 100000 iterations, 16-byte salt, 64-byte key, `base64(salt):base64(key)` inside `@ByteArray(...)`) before first start. qBittorrent **rewrites this file on clean shutdown**, so it is a first-boot seed, not ongoing config management.
- **Adding a Prowlarr indexer is GET-schema-modify-POST, and that is enforced by code.** `IndexerResource.ToModel()` looks every non-standard field up in the cached Cardigann definition and throws `ArgumentOutOfRangeException` on anything unrecognised, so a hand-written body is rejected. Fetch `/api/v1/indexer/schema`, select by `definitionName`, modify, POST. **The schema's `appProfileId` is a placeholder `0` that fails validation** (`'App Profile Id' must be greater than '0'`, HTTP 400, on `forceSave` bodies too) — resolve the real sync-profile id from `GET /api/v1/appprofile` and patch it in; this and the rest of the tracker wiring live in `arr-indexers.sh`, not the bootstrap. Every indexer is POSTed **without** `forceSave` first, so the create path tests each one — for private trackers that test is the login check, the only automatic one they ever get. On failure `arr-indexers.sh` prompts (via `/dev/tty` — stdin carries the indexer list): retry / update credentials / save untested (`?forceSave=true`) / skip; with `--non-interactive` or no terminal it saves untested with a warning instead, so unattended runs never hang. Private indexers ride the same path via `ARR_INDEXERS_PRIVATE` + `ARR_INDEXER_<NAME>_USER`/`_PASS` in `arr.env` (username/password logins only; anything cookie/2FA-based is skipped with its field names printed). Credentials fixed at the prompt live only in Prowlarr — the script warns to copy them back into `arr.env`, which a re-run after a wipe would otherwise reuse stale.
- **Byparr is the Cloudflare solver, registered under Prowlarr's `FlareSolverr` implementation** — it speaks that API, and there is no "Byparr" implementation. Prowlarr routes a request through the proxy only when it detects a Cloudflare challenge *and* the indexer shares a tag with the proxy, so `arr-indexers.sh` tags every indexer with `byparr` — free on unprotected trackers, future-proof for the rest. A proxy with no matching tagged indexer is a Prowlarr health warning (which is why the proxy moved to `arr-indexers.sh` along with the indexers). Byparr is GET-only: `request.post` is accepted but degrades to a GET — acceptable because the Cloudflare-protected trackers here all search via GET; an indexer that needs POST-through-solver is the one reason to reconsider. `POST /api/v1/indexerproxy` tests the proxy on create exactly like indexers do, with the same no-forceSave-then-fallback idiom (byparr may still be starting). FlareSolverr itself was replaced because it stopped clearing modern Cloudflare managed challenges; the swap is one image line plus this wiring.
- **Prowlarr is API v1; Sonarr and Radarr are v3.** The wrong version 404s, which reads as a bad key rather than a bad path.
- In `/api/v1/applications`, **`prowlarrUrl` is Prowlarr's own address and `baseUrl` is the target app's.** Easy to swap, and confusing when swapped.
- **`/api/v3/config/mediamanagement` is PUT-over-whole-object** — GET-modify-PUT, never a partial body.
- Don't transcribe TRaSH `trash_id`s. Configarr pulls the profiles and custom formats from the Recyclarr community templates, listed as `include:` entries in `configarr-config/config.yml` (installed into the config dir only when absent, so on-NAS edits survive). Chosen over Recyclarr, which cannot read credentials from the environment — using it would mean a generate-then-rewrite step patching placeholders into its generated config; configarr resolves `!env` natively.
- **`include:` names are template *file basenames*, not Recyclarr CLI template ids.** `web-1080p` and `hd-bluray-web` are CLI ids and do **not** resolve here; the real names are `sonarr-v4-quality-profile-web-1080p`, `radarr-quality-profile-hd-bluray-web`, and so on. The two namespaces are unrelated and **a name that doesn't resolve is not an error — it is a silently missing profile.** The Sonarr/Radarr asymmetry is real: there is no `radarr-quality-profile-web-1080p`; `hd-bluray-web` is Radarr's analogue of Sonarr's `web-1080p`. The two resolve to the profiles `WEB-1080p` and `HD Bluray + WEB`.
- **`recyclarrRevision` is pinned, and must stay pinned.** Recyclarr v8 deleted the `includes/` tree from `recyclarr/config-templates`, so every `include:` only resolves at `4ae377bb…`. That is configarr's own built-in default (`DEFAULT_RECYCLARR_REVISION`), spelled out in the config so a future change to that default can't move it. Pointing it at `master` breaks every include at once. Only the TRaSH custom-format *data* tracks upstream; the templates are frozen.
- **Configarr exits 0 even when an instance fails.** The per-instance error is caught, counted and the run continues, so a dead Radarr is invisible to any exit-code check. The container sets `STOP_ON_ERROR=true` and `CONFIGARR_ENFORCE_CONFIG_VALIDATION=true` (the latter because an invalid config otherwise only warns and silently drops keys) to make failures real. `DRY_RUN=true` performs a genuine read-only run and prints the diff it would apply — that is the preflight, and `arr-bootstrap.sh --dry-run` uses it.
- **Configarr is run-to-completion, and that shapes the compose entry.** `restart: "no"` because a restart policy makes the daemon respawn it about once a minute, and `profiles: [configarr]` to keep it out of a plain `up -d` — this stack has no `depends_on`, so an auto-started sync would race Sonarr/Radarr's startup and fail at every bring-up. Naming a profiled service on the command line enables its profile implicitly; `docker compose down` however **ignores it** unless `--profile` is passed, which is why `down.sh` passes it *and* keeps the by-name backstop.
- **Ofelia is the scheduler, because configarr has none and upstream won't add one.** `job-run` with `container = configarr` starts an *existing* container by name, waits, and captures its logs — it **never creates one**. So `up.sh` must create it (`up -d --no-start configarr`) or the daily job fails on inspect, visible only in `docker logs ofelia`. Ad-hoc runs pass their own `--name` to avoid colliding with it. `ARR_RUN_CONFIGARR=0` skips only the bootstrap's immediate sync, never the container creation — otherwise it would silently kill the schedule too.
- **Ofelia is the second container with the docker socket**, after Homepage — root-equivalent host access, accepted for the same reasons and set up the same way (primary GID via `user: "${PUID}:${DOCKER_GID}"`, which survives a privilege drop; `:ro` restricts nothing about the API).
- **What configarr is deliberately not allowed to manage**, all of it left to `arr-bootstrap.sh`: `download_clients` (it would rewrite the qBittorrent password, and the client definition is `arr-bootstrap.sh`'s contract — including `removeCompletedDownloads: true`), `root_folders` (deletes and recreates to match the file), `delay_profiles` (deletes any profile not listed, and its example is usenet-defaulted), `media_naming` (would rename the existing library), and every `delete_unmanaged_*` toggle.
- **`down.sh` never deletes the download tree**, though it sits under `SAFE_ROOT` and would be accepted. Config comes back from this repo; a part-done or still-seeding torrent does not.
- **Seerr is the request front-end** (`ghcr.io/seerr-team/seerr` — the merged successor of Jellyseerr/Overseerr; those names live on only as Homepage widget aliases). Not an LSIO image: identity via compose `user:`, config at `/app/config`. Its API key is injected as the `API_KEY` env var, which Seerr **writes over `settings.json`'s stored `apiKey` at every start** — so `arr.env` is the only source of truth and rotating the key in the Seerr UI silently doesn't survive a restart. Auth header is `X-Api-Key`, same as the arr apps.
- **Seerr's setup is re-runnable until `POST /api/v1/settings/initialize`** — nothing is one-shot like Jellyfin's wizard, which is why the bootstrap calls initialize last, only after everything else succeeded. `POST /api/v1/auth/jellyfin` needs **no prior auth**: with no users it creates Seerr's admin (user 1) from the Jellyfin account given — which must be a Jellyfin **administrator**, else 403 — and stores the media-server settings; `serverType` is the numeric enum (`2` = Jellyfin). On later runs the same call is a plain sign-in. After user 1 exists, `X-Api-Key` acts as admin for everything.
- **Seerr reaches Jellyfin at the host LAN address (`192.168.0.231:8096`), never a container name** — Jellyfin is host-networked and off `nas-net`, and mDNS doesn't resolve inside containers. Sonarr/Radarr are wired by container name (`sonarr:8989`, `radarr:7878`) like all other nas-net traffic. The Jellyfin admin credentials come from `jellyfin.env`, extracted in a **subshell** — never `set -a`-sourced into the arr shell (shared names would collide, see `arr.env.example`).
- **The Seerr bootstrap section runs after configarr and is non-fatal throughout** — after, because it binds requests to the TRaSH profiles (`WEB-1080p` / `HD Bluray + WEB`) that configarr creates, falling back to the first profile with a warning; non-fatal, because a dead or not-yet-built Jellyfin must not abort the arr bring-up (it warns and skips, and a re-run picks up where it left off). `GET /settings/jellyfin/library?enable=` **replaces** the enabled set — any library not listed is disabled — so the bootstrap only touches it pre-initialize.
- **DLNA is a plugin** (not core since 10.10) and bootstrap installs it: resolve it in `GET /Packages` (never hardcode the name), `POST /Packages/Installed/{name}`, then poll `GET /Plugins`. The `204` only means *queued* — a failure past it shows up only in the Jellyfin log. Casing differs per endpoint: `PackageInfo` is camelCase (`name`/`guid`), `PluginInfo` is PascalCase (`Name`/`Id`/`Status`). **No mid-run restart** — Jellyfin does not hot-load plugins, so a new one sits at `Status: Restart` and rides the existing deferred-restart channel (`exit 10` → `up.sh` restarts → scan). Every DLNA call is non-fatal: a failed install must not abort before the base URL is asserted. `JELLYFIN_INSTALL_DLNA=0` skips it.