# Apollo NAS — Docker Service Stack Specification

Target state of the system and the constraints behind it.

**Homepage is the entrypoint; everything else is reached on its own port by clicking a
tile.** Plain HTTP, one name (`apollo.local`), no custom DNS.

A fresh clone reproduces the containers and their wiring: network, mounts, ports,
identities, API keys and dashboard tiles. It does not reproduce what lives inside each
service (libraries, download clients, indexers, plugins). That is set up by hand in each
service's own UI; the settings that are easy to get wrong are listed in
`docs/manual-setup.md`.

---

## 1. Hardware and platform

| Item | Value |
|---|---|
| Device | UGREEN DXP4800 Plus |
| CPU | Intel Pentium Gold 8505, UHD Graphics (Xe-LP), Quick Sync capable |
| OS | UGOS (Debian-based) |
| Hostname | `apollo` — resolves as `apollo.local` via mDNS out of the box |
| LAN IP | `192.168.0.231`, static via DHCP reservation |
| Storage | `/volume1` btrfs pool, 2× 14 TB HDD. `/volume2` SSD |
| Docker | Daemon API `1.54` — check image compatibility against this |
| Router | Cannot host custom DNS records — hard constraint |

### Host ports

| Port | Owner |
|---|---|
| 80 | Homepage — `apollo.local` with no port |
| 9999 | UGOS web UI |
| 8096 | Jellyfin web UI/API |
| 7359/udp | Jellyfin client auto-discovery |
| 1900/udp | Jellyfin DLNA / SSDP |
| 8989 | Sonarr |
| 7878 | Radarr |
| 8686 | Lidarr |
| 9696 | Prowlarr |
| 8080 | qBittorrent web UI |
| 6881 tcp+udp | qBittorrent torrent traffic |
| 5055 | Seerr |
| 8888 | Unmanic web UI |
| — | PiHole claims no host port: macvlan gives it its own LAN IP (`192.168.0.53`, see `docs/pihole-spec.md`) |

Publishing ports is the design. Every user-facing service claims a host port and is linked
from a dashboard tile.

---

## 2. Naming

`apollo.local` resolves via mDNS (Avahi), which UGOS provides. **It is the only name in
use and needs no configuration.** Services are reached as `apollo.local:<port>` — nobody
types those, since Homepage lists them all as tiles.

Per-service names (`jellyfin.local`) are out of scope: mDNS has no wildcards, so each name
needs its own supervised `avahi-publish` process, and appliance firmware may reset such
units on OS update.

**TV browsers** (Samsung Tizen, LG webOS) generally do not resolve `.local` at all. This
does not matter: the TV uses the native Jellyfin app or DLNA, both of which discover rather
than resolve.

---

## 3. No TLS

**`.local` is an mDNS-reserved namespace (RFC 6762). No public CA will issue a certificate
for it.** That rules out Let's Encrypt and DNS-01 entirely. The alternative — a self-signed
internal CA — requires installing a root certificate on every client, which is workable for
a phone and laptop but impractical for a TV and for guests.

So the LAN runs plain HTTP. Credentials cross it in cleartext; the threat model is someone
already inside a trusted single-user home network.

Browser-trusted TLS requires abandoning `.local` for a **registered domain** with DNS-01
wildcard issuance, which needs a local DNS server, which needs a capable router or a DNS
container. **That is a different architecture, not an incremental change.**

---

## 4. Network topology

One user-defined bridge network, `nas-net`, created and removed directly by the CLI
(`nas install`, plain `docker network create`; nothing removes it) — no compose file owns it.
Every unit's compose file, including Homepage's, joins it as `external: true`.

- Services that talk to each other by container name share `nas-net`.
- Services users reach directly publish a host port.
- **Jellyfin is the exception**: `network_mode: host`, so it is on no Docker network.

**`nas-net` carries real traffic.** Prowlarr pushes indexers to `http://sonarr:8989`,
`http://radarr:7878` and `http://lidarr:8686`, all three reach `http://qbittorrent:8080`,
and Homepage's widgets poll everything by container name.

**Jellyfin is not on it.** It stays host-networked, so Homepage reads its tile over the
Docker socket rather than the wire. A container-name address that works from Sonarr will not
work from or to Jellyfin — do not debug a connectivity problem on the assumption that
everything in the stack shares one network.

Note the split this forces in the arr units' Homepage labels: `homepage.href` is a host
address (`http://apollo.local:8989`, resolved by the browser), while `homepage.widget.url` is
a container address (`http://sonarr:8989`, resolved by Homepage). They are not
interchangeable, and a wrong `href` is a user-visible dead end.

No internal/backend network — nothing runs a database yet. Add one when something needs it.

---

## 5. Jellyfin

The settings below that live inside Jellyfin (base URL, QSV, DLNA, network settings) are
applied by hand; the exact values are in `docs/manual-setup.md`.

### Host networking

DLNA uses **SSDP multicast on 1900**; Jellyfin's client auto-discovery uses **broadcast on
7359**. Docker bridge port publishing only NATs **unicast** traffic to the host's IP:port,
so neither reaches a bridged container — discovery does not work behind a bridge.

`network_mode: host` is therefore required. Jellyfin binds 8096, 7359 and 1900 directly.

Constraints that follow:

- `network_mode: host` **ignores `ports:`** — never add that block.
- Jellyfin is not on `nas-net` and has no container-name resolution. Anything that talks
  to it (Homepage's widget, Seerr) uses the LAN IP, `shared.env`'s `LAN_HOST`.
- It forfeits Docker network isolation — the one documented exception to bridge-by-default.
- Homepage still discovers its tile: labels are read over the **Docker socket API, not the
  network**.

### Base URL stays empty

Jellyfin serves from the root of `:8096`, and every tile, widget URL and Seerr's
connection assume it. A non-empty base URL relocates the **entire API** under that prefix
and breaks all of them at once. Changing it needs a container restart.

### GPU passthrough

`RENDER_GID=105`, passed via `group_add`, with `/dev/dri/renderD128` in `devices:`. Confirm
rather than copy if the host changes; it must match `RENDER_GID` in `jellyfin.env`:

```bash
stat -c '%g %G' /dev/dri/renderD128
```

The passthrough only makes the device visible. QSV itself is switched on in Jellyfin's
transcoding settings. Verify with `intel_gpu_top` during an actual transcode — a config
value alone proves nothing.

### DLNA

DLNA is a **plugin** as of Jellyfin 10.10, not core. Until it is installed *and loaded*,
DLNA browsing does not work regardless of networking. Jellyfin does not hot-load plugins,
so a newly installed one does nothing until the container restarts.

DLNA has no authentication — anything on the LAN can browse exposed libraries. The TV and
NAS must be on the **same layer-2 segment**; multicast does not cross VLANs, and many APs
block it by default. That is the most common cause of DLNA not appearing.

### Jellyfin's own network settings

- **LAN networks** are set to the local subnet. This is what Jellyfin uses to decide which
  clients are local, which gates LAN-only behaviour like bitrate limits and DLNA
  visibility. Left empty, Jellyfin infers local networks from its own interfaces, and
  host networking means that includes the tailscale interface (§9). With the subnet set,
  tailnet clients count as remote. They still connect, but a remote-bitrate limit would
  apply to tailnet playback too.
- **Known proxies** stay empty. Nothing proxies Jellyfin, and a stray entry would make it
  trust `X-Forwarded-For` from anyone.

---

## 6. Filesystem layout

```
/volume2/docker/            # SSD — all container config and logs
├── homepage/config/
├── jellyfin/
│   ├── config/             # SQLite databases, logs in log/
│   └── cache/              # transcode scratch
├── sonarr/config/
├── radarr/config/
├── lidarr/config/
├── prowlarr/config/
├── qbittorrent/config/     # qBittorrent.conf, written by qBittorrent itself
├── seerr/config/           # settings.json + SQLite; users and request history
├── unmanic/                # config/ (database, plugins, logs in .unmanic/), cache/
└── downloads/              # torrents seed from here; never a nas destroy target
    ├── incomplete/
    └── complete/
```

```
/volume1/Media/             # HDD — library root
├── Movies/                 # :ro into Jellyfin, rw into Radarr and Unmanic
├── Series/                 # :ro into Jellyfin, rw into Sonarr and Unmanic
└── Music/                  # :ro into Jellyfin, rw into Lidarr
```

Config on the **SSD**; nothing that spins up the HDD at idle belongs there. Media on the
**HDD**, mounted read-only wherever a service only reads. Note the capitalisation.

### Downloads on the SSD: copies, not hardlinks

The download tree lives on `/volume2` while the library lives on `/volume1`. These are
different filesystems, so **hardlinks are impossible and every import is a full copy**. That
is the intended trade:

- Seeding runs entirely off the SSD, so a seeding torrent never holds the media HDD awake —
  the same rule that keeps config off `/volume1`.
- Cost: transient 2× space for the file being imported, one cross-filesystem copy per import,
  and the arr apps' "use hardlinks" setting does nothing.
- The SSD would fill without a bound, so qBittorrent stops torrents at a seed cap and the
  arr apps then delete them *and their content*. That hand-off is the only thing draining
  the tree; see section 8.

The alternative — download tree under `/volume1` next to `Media/` — buys instant hardlinked
imports and no duplicate space, at the cost of keeping the HDD awake for as long as anything
is seeding. Moving `DOWNLOADS_DIR` is the whole change if that trade ever looks better.

This is a deliberate departure from the TRaSH guides' single-`/data`-mount recommendation,
which exists precisely to make hardlinks work.

Compose files must not hardcode these paths — they come from `shared.env` (for `DOWNLOADS_DIR`,
which sonarr, radarr, lidarr and qbittorrent all read identically) or a `<unit>.env` (for a
single-consumer path like `ARR_MOVIES_DIR`), both gitignored, with `shared.env.example` /
`<unit>.env.example` as the templates.

### btrfs copy-on-write — not applicable here

**Settled: `/volume2` is ext4, not btrfs.** Confirmed on the box:

```
$ findmnt -T /volume2/docker -o TARGET,SOURCE,FSTYPE
TARGET   SOURCE                                         FSTYPE
/volume2 /dev/mapper/ug_A9B5AA_1786551201_pool2-volume1 ext4
```

`chattr +C` is a btrfs-only attribute, so there is nothing to disable and `nas install`
correctly does not try. `lsattr -d` on the config and cache directories shows only
`e` (extent mapping), the normal ext4 flag.

Kept as a note because it is a real concern *if the storage layout ever changes*: on
btrfs, disabling CoW on database and cache directories avoids fragmentation and write
amplification, **`chattr +C` only takes effect on an empty directory** so it must be
applied at creation, and it disables checksums on those paths — acceptable for SQLite
and transcode scratch, never for the media library. Re-run the `findmnt` above before
assuming any of that applies.

---

## 7. Homepage

The dashboard at `apollo.local` and the entrypoint to everything. Binds host `:80`.

Tiles come from `homepage.*` **Docker labels in each service's own compose file**, so the
dashboard is a derived artifact of the stack definition — adding a service adds its tile,
with no dashboard config to maintain. Labels alone suffice; `server` and `container` are
inferred.

Five config files, installed by `nas install` only when absent so on-NAS edits survive:

- `docker.yaml` — declares the socket, enabling container status and stats.
- `services.yaml` — for things that are **not containers on this host** and so cannot be
  auto-discovered (UGOS at `apollo.local:9999`). Containers must not be listed here.
  Also carries the `Upcoming` calendar tile: its `integrations` reference the
  docker-discovered Sonarr/Radarr widgets by `service_group`/`service_name`, so it
  needs no URL or API key of its own.
- `bookmarks.yaml` — intentionally empty. Homepage writes its own sample Developer/Social/
  Entertainment bookmarks when the file is absent; installing an empty one suppresses them.
- `settings.yaml` — title, theme, `statusStyle: dot`, quicklaunch, and the group layout.
  Layout keys must match group names exactly as the `homepage.group=` labels spell them
  (`Core`, `Media`) and `services.yaml` (`NAS`) — a mismatch silently renders an empty
  duplicate group.
- `widgets.yaml` — the header info row: search, resources (CPU/RAM/uptime and disk
  gauges), open-meteo weather, clock. The disk paths are **container** paths, which is
  why the compose file bind-mounts `/volume1` and `/volume2` `:ro` into Homepage —
  read-only visibility adds nothing on top of the docker socket it already holds.

Tiles also carry `homepage.siteMonitor` labels (HTTP up/down + response time). The probe
runs from the Homepage container, so the URL follows the `widget.url` resolution rule:
container names over `nas-net`, the LAN IP for host-networked Jellyfin and for UGOS.

`HOMEPAGE_ALLOWED_HOSTS` must list **every** name and address Homepage is reached at — the
mDNS name, the LAN IP, any tailnet name. These are the NAS's own addresses, not the
clients'. An unlisted Host header gets a 400, easily misdiagnosed as a network fault.

It is a comma-separated list with **no wildcard or CIDR support** — `192.168.0.*` and
`192.168.0.0/24` are matched literally and reject everything, so each address is listed in
full. Setting it to `*` disables the check entirely; that is only tolerable because nothing
forwards a port to this box, and the explicit list is preferred.

**Docker socket:** Homepage mounts `/var/run/docker.sock:ro`. The `:ro` applies to the
socket file, not the Engine API through it — anything compromising Homepage can create a
privileged container. Accepted for a single-user LAN, because the socket is what makes
tiles self-maintaining. Mediating access to the socket is the mitigation if that trade
stops holding.

Reaching the socket is a **DAC problem**, and the mechanism is load-bearing enough to
pin down: the socket is `root:docker` `0660`, so Homepage sets its identity with
`user: "${PUID}:${DOCKER_GID}"` — its **primary GID** is the host docker group.

- Not the image's `PUID`/`PGID`: those are applied inside the entrypoint, after the
  point where `docker inspect` could show what identity the server process ended up with.
- Not `group_add`: a supplementary GID can be discarded by a privilege drop. A primary
  GID survives, and matching the socket's group needs no `DAC_OVERRIDE`.
- `/app/config` is owned by `PUID`, so it stays writable.

When this fails, **no container is listed at all** and Homepage renders only
`services.yaml` — it looks like one service being ignored, not a dead integration.
Diagnose by mechanism: `ENOENT` means the path is wrong, `EACCES` means the socket was
found and refused.

Homepage is the front door for every browser on the LAN: pin it, update deliberately.

---

## 8. Adding services (arr stack and others)

```yaml
  <service>:
    image: <image>:<exact-tag>
    container_name: <service>
    restart: unless-stopped
    ports:
      - "${<SERVICE>_PORT:-<port>}:<port>"
    volumes:
      - ${<SERVICE>_CONFIG_DIR:-/volume2/docker/<service>/config}:/config
    networks:
      - nas-net
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    labels:
      - homepage.group=<Group>
      - homepage.name=<Name>
      - homepage.icon=<icon>.png
      - homepage.href=http://apollo.local:<port>
      - homepage.description=<what it does>
```

No routing config, no name registration — publish the port, add the labels.

### The arr stack as built

Sonarr, Radarr, Lidarr, Prowlarr and qBittorrent, plus Seerr (the request front-end — users
sign in with their Jellyfin account, request media, and Seerr forwards to Sonarr/Radarr and
tracks availability) and Byparr (the Cloudflare solver; no published port, so no tile). Each
is its own compose project (`docker-compose.<unit>.yml`, `-p nas-<unit>`) — there is no
single `arr` compose file, no `depends_on`, and no shared volume between them; `arr` is a
convenience alias the CLI expands to all seven. All bridge services on `nas-net`; only
Jellyfin needs host networking.

Byparr replaced FlareSolverr, which stopped clearing modern managed challenges. It speaks
the same API, so Prowlarr registers it as a FlareSolverr-type indexer proxy
(`docs/manual-setup.md`).

Lidarr is the music arr, same shape as Sonarr/Radarr. It has no Seerr wiring — Seerr does
not do music requests, so music is requested in Lidarr itself.

- Media is mounted **read-write** here, unlike Jellyfin's `:ro`. Sonarr, Radarr and Lidarr
  each see only the tree they manage (`/media/series`, `/media/movies`, `/media/music`), and
  their root folders are the existing `/volume1/Media/{Series,Movies,Music}` — no migration,
  and Jellyfin's mounts are unchanged.
- **The download path must be the identical container path in qBittorrent and every arr app**
  (`/downloads`). qBittorrent reports absolute paths, so a mismatch produces a remote-path-
  mapping failure on every import. This is required regardless of the hardlink question.
- Identical mount paths do **not** buy hardlinks here, because the download tree is on a
  different filesystem from the library by design — see section 6.
- **Identity is set via `PUID`/`PGID` environment, not compose `user:`.** LinuxServer.io images
  usermod internally in their entrypoint. Section 7's objection to image-level `PUID`/`PGID` is
  scoped to Homepage, where the identity must be inspectable from outside because it gates
  socket access; none of these containers touch the socket. `UMASK=002` keeps what they write
  group-readable for Jellyfin, which runs as the same `1000:10`.
- **Seerr is the exception to the previous point** — not an LSIO image (runs as `node`, 1000),
  so it takes compose `user:`. Its API key is injected as the `API_KEY` environment variable,
  which Seerr writes over the `apiKey` stored in its `settings.json` at **every** start —
  same never-persisted idiom as the arr keys, and it means a key rotated in the Seerr UI
  does not survive a restart. It reaches Sonarr/Radarr by container name over `nas-net`, but
  Jellyfin at `LAN_HOST`: Jellyfin is host-networked and not on `nas-net`, and mDNS does not
  resolve inside containers. Seerr keeps no credential of its own — its admin is whichever
  Jellyfin account signs in first.

### The seed cap: qBittorrent stops, the arr apps delete

qBittorrent **stops** a torrent at its seed cap and deletes nothing. The arr apps' download
clients have "Remove Completed" on, and they remove a torrent — *with* its files — only once
qBittorrent reports it stopped at the cap: never mid-seed, never before import.

The alternative, qBittorrent removing torrent and content at the cap, frees the same space
but can delete a download the arr app has not imported yet. The arr apps refuse to save a
download client pointing at a qBittorrent set that way, so the pairing is enforced by their
own validation. The exact settings are in `docs/manual-setup.md`.

Accepted costs: torrents added outside the arr apps (or in a foreign category) stop at the
cap but are never deleted, and a failed import holds its data on the SSD until resolved in
the Activity queue rather than being silently reaped.

### Unmanic

Post-import cleanup of the movie and series library: it remuxes each file to drop
unwanted audio and subtitle tracks (stream copy, no re-encode). It is its own unit,
outside the `arr` alias — nothing in the arr stack calls it, and `nas destroy arr`
should not take its database with it. Worker, libraries and plugins are set up by hand
(`docs/manual-setup.md`); the reasons behind those settings are below.

- **It mounts the library read-write and never the download tree.** Unmanic replaces
  the original file in place. Imports are cross-filesystem copies (section 6), so the
  library file and the seeding file are different inodes — rewriting one cannot corrupt
  the other. Mounting `/downloads` would remove that guarantee.
- **The cache (`/tmp/unmanic`) is on the SSD.** The rewritten file is built there and
  then replaces the original, so the HDD reads the source once and writes the result
  once. It needs free space for the largest file in flight.
- **One worker, no GPU.** A remux is disk-bound, and a second parallel job only makes
  the HDD seek between two files. `/dev/dri` is not passed through because nothing
  re-encodes. Enabling transcoding would mean revisiting both. A fresh Unmanic ships
  with **zero** workers and processes nothing until one is added.
- **Two community plugins.** Audio: `keep_original_language_audio` looks up
  `originalLanguage` on the Radarr movie / Sonarr series whose path prefixes the file's
  path, and removes audio in other languages. Subtitles: `keep_stream_by_language` keeps
  only the subtitles in the listed languages. An empty list there means "keep none", not
  "keep all".
- **The path match only works because the container paths are shared.** Unmanic mounts
  the library at `/media/movies` and `/media/series`, exactly like Radarr and Sonarr, so
  the audio plugin needs no path mapping. Change one side and every file is skipped,
  silently.
- **It fails safe.** Any failure of the audio lookup — Radarr/Sonarr down, no matching
  item, no original language, no audio track tagged in it — leaves the file unchanged,
  and neither plugin ever removes the last audio track. A file whose lookup failed is not
  retried on its own; only a later scan or a new write to that file tests it again.
- **The arr keys live in a copy.** The audio plugin reads the Radarr/Sonarr URL and key
  from its per-library settings in Unmanic's config dir — no environment option exists. The
  keys never rotate on their own (Secrets, below), so the copy stays valid. The URLs are
  the nas-net names (`http://radarr:7878`).
- **inotify on, scanner off.** The library scanner walks the whole tree on a schedule
  and wakes the HDD. The file monitor is event-driven: it fires when Radarr/Sonarr write
  a file, when the disk is awake anyway. It walks the directory tree once at container
  start to place its watches. Files already in the library are never queued by it — a
  one-off scan from the UI does that.
- Identity via `PUID`/`PGID` env. The image has no umask variable, so what it writes
  gets 022 — harmless, since every service runs as the same PUID. Its entrypoint chowns
  `/config` recursively at every start. Unmanic has no API auth; the box is LAN-only.

### Secrets, and what actually lives in shared.env

Each app's API key is injected as `<APP>__AUTH__APIKEY`, read at every start **in place of**
`config.xml`, so the key is never persisted by the app; Seerr's rides the same flow as
`API_KEY`. `nas install` generates each of the five keys once, into that unit's own `.env`
(`sonarr.env`/`radarr.env`/`lidarr.env`/`prowlarr.env`/`seerr.env`) — one file, one key,
one unit — and never regenerates it. Because the key exists before the app first starts,
the Homepage widget labels carry it from the first bring-up.

Each unit's own `.env` therefore holds the only copy of its key. Losing one does not error —
that app quietly mints and persists a *new* key, and every place the old one was pasted
(Prowlarr's apps, Seerr, Unmanic's plugin) plus that unit's Homepage widget break at once,
with no error anywhere. The per-unit split confines the damage to whichever unit actually
lost its file. `nas destroy` preserves every `.env` for this reason.

`shared.env` holds what more than one unit reuses: `TZ`/`PUID`/`PGID`/`UMASK`/`DOCKER_GID`,
`LAN_HOST`, `DOWNLOADS_DIR`. It also holds `ADMIN_USER`/`ADMIN_PASSWORD`, which only
qBittorrent's Homepage widget reads. Nothing sets that login in any service: it is typed into
qBittorrent by hand, and using it for Jellyfin's admin too is a convention no file enforces.
No API key lives in `shared.env`: a key is exactly one unit's concern, so it stays in that
unit's own file.

The keys also appear in `homepage.widget.key` labels, and labels are readable by anything that
can read the Docker socket or run `docker inspect`. Accepted on the same basis as the socket
mount itself: LAN-only, single-user, no forwarded ports. It needs revisiting alongside that
decision if the box ever becomes externally reachable.

---

## 9. Remote access

Tailscale runs on the NAS host, outside this stack.

`.local` names do **not** resolve over the tailnet — mDNS is link-local by definition.
Remote access is by tailnet IP or MagicDNS hostname, on the same ports. Add any such
hostname to `HOMEPAGE_ALLOWED_HOSTS` or Homepage rejects the request.

---

## 10. Running

One small CLI, `./nas`, is the operator interface: `install` and `destroy` (root), plus
`compose`, which runs plain `docker compose` with the unit's project and env files. The
invariants an operator or agent must preserve are in `CLAUDE.md` §Running. Underneath it is ordinary compose — one project per
**service**, `--env-file shared.env` first, then the unit's own.

A fresh box comes up in four steps:

1. `sudo ./nas install` creates `nas-net`, every `.env` from its example, and the per-unit
   API keys, then stops: nothing is created on disk or started on defaults nobody has
   reviewed.
2. Fill in the `.env` files it created — `ADMIN_PASSWORD` in `shared.env` at least, and
   any host fact that differs from the defaults.
3. `sudo ./nas install` again: host directories and ownership, Homepage templates,
   containers.
4. Configure each service in its own UI, following `docs/manual-setup.md`. Jellyfin's
   Homepage widget needs an API key that only exists once Jellyfin is set up: put it and
   the scan task id in `jellyfin.env`, then `sudo ./nas install jellyfin`. That recreates
   the container, because labels are baked in at create and `docker restart` never
   refreshes them.

The reasoning the CLI encodes:

- **Idempotent install.** Existing `.env` files are never overwritten, keys are generated
  exactly once, config templates install only when absent. Running it twice is safe.
- **Per-unit lifecycle.** `sudo ./nas destroy radarr && sudo ./nas install radarr` tears
  down and recreates exactly one unit while it stays wired into the rest of the stack:
  same network, same API key. With
  its data deleted, the service itself comes back blank and is set up again by hand — but
  its key survives, so every copy of that key elsewhere keeps working. `arr` is a
  selection alias only, not a compose or network concept.
- **Destruction is scoped and previewed.** Nothing outside `/volume2/docker` can be
  deleted, and the plan is shown before anything runs. `.env` files survive teardown —
  they hold the only copy of each key. The download tree is exempted by name rather than
  by the root check: it *is* inside `/volume2/docker` and would pass validation, but a
  still-seeding torrent is not a config artifact and is not reproducible from this repo.
- **Bring-up order has no constraint.** `nas-net` exists before any unit starts and
  nothing hard-depends on another unit being up. `nas-net` is never removed: an empty
  network costs nothing, and removing it would cut off anything still attached.

---

## 11. Design decisions

| Decision | Reason | Cost |
|---|---|---|
| Homepage on :80 | `apollo.local` opens the dashboard with no port | It must not fail to start |
| One port per service | No routing layer to configure or keep running | Ports visible in URLs; no central access log |
| Tiles from Docker labels | Dashboard is a derived artifact — a fresh clone reproduces it with zero dashboard config | Non-containers need a `services.yaml` entry |
| Jellyfin on host networking | Only reliable way to get SSDP/broadcast discovery | No network isolation for that container |
| HTTP only | `.local` cannot receive a public certificate (RFC 6762) | No transport encryption on the LAN |
| `apollo.local` only | No per-name systemd units to maintain across OS updates | Service URLs carry port numbers |
| Exact image pins | Reproducible; the daemon API is old enough that floating tags break | Manual update step |
| Services configured by hand in their UIs | Each service's own UI is the source of truth; no automation to break when an upstream API or setup flow changes | A wiped config dir means redoing that service's setup by hand (`docs/manual-setup.md`) |
| Downloads on the SSD | Seeding never holds the media HDD awake | No hardlinks — every import is a full copy, transient 2× space |
| Seed cap stops; arr apps delete | Nothing is removed before import; the arr apps drain the SSD tree | Torrents outside the arr apps stop at the cap but are never deleted |
| arr root folders on the existing `Media/` dirs | No migration of a live library; Jellyfin unchanged | Keeps the capitalised, non-TRaSH layout |
| `PUID`/`PGID` as env for arr | What LinuxServer.io images support; no socket access to gate | Inconsistent with Homepage/Jellyfin's `user:` |
| Each arr unit's API key generated into its own `.env` | Known before the app first starts, so widget labels carry it from the first bring-up; a lost key only breaks that one unit | That `.env` is the only copy and is load-bearing forever |
| Per-service compose files + `shared.env`, `arr` as an alias only | Destroying and reinstalling `radarr` touches exactly one unit; the CLI is the only place that knows how units relate | Ten compose files instead of one; the qBittorrent sparing rule lives in the CLI, not a compose file |
| Keys in `homepage.widget.*` labels | Widgets need them; tile config stays with the service | Readable via `docker inspect` |
| No VPN for torrent traffic | Nothing to configure or keep alive | Torrent traffic uses the LAN's own egress |
| `nas destroy` keeps the download tree | Config is reproducible from the repo; a part-done torrent is not | A "clean slate" needs one manual `rm` |
| Seerr as one of the `arr`-alias units | Same lifecycle as the Sonarr/Radarr it forwards to | `nas destroy arr` (and the no-args default) deletes its request history; it is not strictly an "arr" app |
| Seerr → Jellyfin by LAN IP | Host-networked Jellyfin is off `nas-net`; container names and mDNS don't resolve | Breaks if the DHCP reservation ever moves |

### The standing assumption

This design assumes the LAN is trusted and single-user — both the plain-HTTP decision and
the Docker socket mount rest on it. If the NAS ever becomes reachable from outside the LAN,
**both need revisiting before that happens**, not after.
