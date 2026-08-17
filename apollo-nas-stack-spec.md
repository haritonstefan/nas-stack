# Apollo NAS — Docker Service Stack Specification

Target state of the system and the constraints behind it.

**Homepage is the entrypoint; everything else is reached on its own port by clicking a
tile.** Plain HTTP, one name (`apollo.local`), no custom DNS.

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
| 9696 | Prowlarr |
| 8080 | qBittorrent web UI |
| 6881 tcp+udp | qBittorrent torrent traffic |
| 53 | PiHole (planned) |

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

One user-defined bridge network, `nas-net`, defined by `core` and joined by consumer stacks
as `external: true`.

- Services that talk to each other by container name share `nas-net`.
- Services users reach directly publish a host port.
- **Jellyfin is the exception**: `network_mode: host`, so it is on no Docker network.

**`nas-net` carries real traffic as of the `arr` stack**, which is what it was provisioned
for. Prowlarr pushes indexers to `http://sonarr:8989` and `http://radarr:7878`, both reach
`http://qbittorrent:8080`, and Homepage's widgets poll all four by container name.

**Jellyfin is still not on it.** It stays host-networked, so Homepage reads its tile over the
Docker socket rather than the wire. A container-name address that works from Sonarr will not
work from or to Jellyfin — do not debug a connectivity problem on the assumption that
everything in the stack shares one network.

Note the split this forces in the arr tier's Homepage labels: `homepage.href` is a host
address (`http://apollo.local:8989`, resolved by the browser), while `homepage.widget.url` is
a container address (`http://sonarr:8989`, resolved by Homepage). They are not
interchangeable, and a wrong `href` is a user-visible dead end.

No internal/backend network — nothing runs a database yet. Add one when something needs it.

---

## 5. Jellyfin

### Host networking

DLNA uses **SSDP multicast on 1900**; Jellyfin's client auto-discovery uses **broadcast on
7359**. Docker bridge port publishing only NATs **unicast** traffic to the host's IP:port,
so neither reaches a bridged container — discovery does not work behind a bridge.

`network_mode: host` is therefore required. Jellyfin binds 8096, 7359 and 1900 directly.

Constraints that follow:

- `network_mode: host` **ignores `ports:`** — never add that block.
- Jellyfin is not on `nas-net` and has no container-name resolution. Nothing needs it.
- It forfeits Docker network isolation — the one documented exception to bridge-by-default.
- Homepage still discovers its tile: labels are read over the **Docker socket API, not the
  network**.

### Base URL stays empty

Jellyfin serves from the root of `:8096`, so `BaseUrl` must stay empty.
`jellyfin-bootstrap.sh` asserts this last, clearing it if anything set it: a non-empty
value relocates the **entire API** under that prefix, so no call may follow. Changing it
needs a container restart.

### GPU passthrough

`RENDER_GID=105`, passed via `group_add`, with `/dev/dri/renderD128` in `devices:`. Confirm
rather than copy if the host changes:

```bash
stat -c '%g %G' /dev/dri/renderD128
```

`jellyfin-bootstrap.sh` configures QSV (hardware decode + encode, low-power H.264/HEVC).
Verify with `intel_gpu_top` during an actual transcode — a config value alone proves
nothing.

### DLNA

DLNA is a **plugin** as of Jellyfin 10.10, not core. Until it is installed *and loaded*,
DLNA browsing does not work regardless of networking.

`jellyfin-bootstrap.sh` installs it over the API rather than through the dashboard: it
resolves the entry in `GET /Packages` (the display name is never hardcoded), posts to
`/Packages/Installed/{name}`, then polls `GET /Plugins` — the install is asynchronous, so
the `204` means *queued*, not installed. Jellyfin does not hot-load plugins, so a new one
reports `Status: Restart` and is activated by the deferred restart the base URL already
uses, rather than a restart mid-bootstrap. `JELLYFIN_INSTALL_DLNA=0` skips the step.

DLNA has no authentication — anything on the LAN can browse exposed libraries. The TV and
NAS must be on the **same layer-2 segment**; multicast does not cross VLANs, and many APs
block it by default. That is the most common cause of DLNA not appearing.

### Jellyfin's own network settings

All three live on the same `NetworkConfiguration` object, which deserializes over
the whole object — so `jellyfin-bootstrap.sh` sets them in one GET-modify-POST,
never as separate partial bodies.

- **LAN networks**: restricted to the local subnet (`JELLYFIN_LOCAL_SUBNET`,
  `192.168.0.0/24`). This is what Jellyfin uses to decide which clients are local,
  which gates LAN-only behaviour like bitrate limits and DLNA visibility.
  **This reclassifies tailnet clients as remote** (§9): left empty, Jellyfin infers
  local networks from its own interfaces, and host networking meant that included
  the tailscale interface. They still connect — remote access is enabled — but a
  remote-bitrate limit added later would apply to tailnet playback too.
- **Known proxies**: none — nothing proxies Jellyfin, and a stray entry would make
  it trust `X-Forwarded-For` from anyone. Set explicitly to empty rather than left
  at the default.
- **Base URL**: empty, and settled **last** within that single POST — a non-empty
  value relocates the entire API under the prefix, so no call may follow it.

---

## 6. Filesystem layout

```
/volume2/docker/            # SSD — all container config and logs
├── homepage/config/
├── jellyfin/
│   ├── config/             # SQLite databases
│   └── cache/              # transcode scratch
├── sonarr/config/
├── radarr/config/
├── prowlarr/config/
├── qbittorrent/config/     # qBittorrent.conf, seeded once by up.sh
├── configarr/
│   ├── config/             # config.yml, installed by up.sh when absent
│   └── repos/              # cached TRaSH + Recyclarr template clones
├── ofelia/config/          # ofelia.ini — the configarr sync schedule
└── downloads/              # torrents seed from here; NOT deleted by down.sh
    ├── incomplete/
    └── complete/
```

```
/volume1/Media/             # HDD — library root
├── Movies/                 # :ro into Jellyfin, rw into Radarr
├── Series/                 # :ro into Jellyfin, rw into Sonarr
└── Music/                  # :ro into Jellyfin
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
  and `copyUsingHardlinks` is asserted in Sonarr/Radarr but inert.
- The SSD would fill without a bound, so qBittorrent stops torrents at ratio 2.0 or 14 days
  and Sonarr/Radarr then delete them *and their content*. That hand-off is the only thing
  draining the tree; see section 8.

The alternative — download tree under `/volume1` next to `Media/` — buys instant hardlinked
imports and no duplicate space, at the cost of keeping the HDD awake for as long as anything
is seeding. Moving `DOWNLOADS_DIR` is the whole change if that trade ever looks better.

Note this is a deliberate departure from the TRaSH guides' single-`/data`-mount
recommendation, which exists precisely to make hardlinks work.

Compose files must not hardcode these paths — they come from `<tier>.env` (gitignored,
with `<tier>.env.example` as the template).

### btrfs copy-on-write — not applicable here

**Settled: `/volume2` is ext4, not btrfs.** Confirmed on the box:

```
$ findmnt -T /volume2/docker -o TARGET,SOURCE,FSTYPE
TARGET   SOURCE                                         FSTYPE
/volume2 /dev/mapper/ug_A9B5AA_1786551201_pool2-volume1 ext4
```

`chattr +C` is a btrfs-only attribute, so there is nothing to disable and `up.sh`
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

Three config files, installed by `up.sh` only when absent so on-NAS edits survive:

- `docker.yaml` — declares the socket, enabling container status and stats.
- `services.yaml` — for things that are **not containers on this host** and so cannot be
  auto-discovered (UGOS at `apollo.local:9999`). Containers must not be listed here.
- `bookmarks.yaml` — intentionally empty. Homepage writes its own sample Developer/Social/
  Entertainment bookmarks when the file is absent; installing an empty one suppresses them.

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
Homepage is the only externally-reachable service in `core`: pin it, update deliberately.

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

Sonarr, Radarr, Prowlarr and qBittorrent, plus Flaresolverr (no published port, so no tile),
Configarr (no port, run-to-completion) and Ofelia (the scheduler that starts it). All bridge
services on `nas-net`; only Jellyfin needs host networking.

- Media is mounted **read-write** here, unlike Jellyfin's `:ro`. Sonarr and Radarr each see
  only the tree they manage (`/media/series`, `/media/movies`), and their root folders are the
  existing `/volume1/Media/{Series,Movies}` — no migration, and Jellyfin's mounts are unchanged.
- **The download path must be the identical container path in qBittorrent, Sonarr and Radarr**
  (`/downloads`). qBittorrent reports absolute paths, so a mismatch produces a remote-path-
  mapping failure on every import. This is required regardless of the hardlink question.
- Identical mount paths do **not** buy hardlinks here, because the download tree is on a
  different filesystem from the library by design — see section 6.
- **Identity is set via `PUID`/`PGID` environment, not compose `user:`.** LinuxServer.io images
  usermod internally in their entrypoint. Section 7's objection to image-level `PUID`/`PGID` is
  scoped to Homepage, where the identity must be inspectable from outside because it gates
  socket access; none of these containers touch the socket. `UMASK=002` keeps what they write
  group-readable for Jellyfin, which runs as the same `1000:10`.

### Secrets in this tier

Each app's API key is injected as `<APP>__AUTH__APIKEY`, read at every start **in place of**
`config.xml`, so the key is never persisted by the app. `up.sh` generates the three keys and
the qBittorrent password into `arr.env` on first run and never regenerates them.

`arr.env` therefore holds the only copy. Losing it does not error — each app quietly mints and
persists a *new* key, and Prowlarr's sync, Configarr and all three Homepage widgets break at
once. `down.sh` preserves `.env` files for this reason.

The keys also appear in `homepage.widget.key` labels, and labels are readable by anything that
can read the Docker socket or run `docker inspect`. Accepted on the same basis as the socket
mount itself: LAN-only, single-user, no forwarded ports. It needs revisiting alongside that
decision if the box ever becomes externally reachable.

### qBittorrent first-boot config

qBittorrent generates a **new random WebUI password on every start unless one is already
stored** — the sole trigger is an empty stored password, and the temporary one is per-session
and never persisted. Without pre-seeding, every container restart would invalidate the
credentials Sonarr and Radarr hold. So `up.sh` writes `qBittorrent.conf` before first start
with a PBKDF2 hash (SHA-512, 100000 iterations, 16-byte salt, 64-byte key,
`base64(salt):base64(key)` wrapped in `@ByteArray(...)`).

qBittorrent **rewrites that file on clean shutdown**, so it is a first-boot seed, not ongoing
config management — it is installed only when absent, and edits made on the NAS survive.

The seed cap lives there too: `Session\ShareLimitAction=Stop`, so qBittorrent **stops** a
torrent at `GlobalMaxRatio` / `GlobalMaxSeedingMinutes` and deletes nothing. Two config
details are easy to get wrong:

- The key is `Session\ShareLimitAction`. `MaxRatioAction` is obsolete.
- The value is the enum's **string name**, not its integer — enums serialise via
  `Utils::String::fromEnum`, so a numeric value fails to parse and silently falls back to
  the default. The enum is non-sequential (`Stop = 0`, `Remove = 1`,
  `EnableSuperSeeding = 2`, `RemoveWithContent = 3`), so guessing the number is doubly
  unsafe.

Deletion is the arr apps' half of the hand-off: **`removeCompletedDownloads` is `true`** on
the Sonarr/Radarr download clients, and the pinned versions only remove a torrent — *with*
its files — once qBittorrent reports it stopped at the cap, never mid-seed. (The old caveat
that this setting removed torrents right after import, defeating the cap, was v2-era
behavior.) The rejected alternative, `ShareLimitAction=RemoveWithContent` with arr-side
removal off, frees the same space but can delete a download the arr app has not imported
yet — and Sonarr/Radarr's download-client POST/PUT refuses (HTTP 400) any qBittorrent
configured to remove at the limit, so the pairing is enforced by their own validation.
Accepted costs: torrents added outside the arr apps (or in a foreign category) stop at the
cap but are never deleted, and a failed import holds its data on the SSD until resolved in
the Activity queue rather than being silently reaped.

---

## 9. Remote access

Tailscale runs on the NAS host, outside this stack.

`.local` names do **not** resolve over the tailnet — mDNS is link-local by definition.
Remote access is by tailnet IP or MagicDNS hostname, on the same ports. Add any such
hostname to `HOMEPAGE_ALLOWED_HOSTS` or Homepage rejects the request.

---

## 10. Running

`sudo ./up.sh` takes a fresh clone to running: env files from the examples, host
directories with correct ownership, generated arr secrets, `core` then `jellyfin` then `arr`,
then each stack's API bootstrap. Idempotent — existing `.env` files are never overwritten and
configured steps are skipped. `./down.sh` reverses it and is a **dry run by default**.

Underneath it is plain compose. Compose does not read `<tier>.env` on its own and all tiers
share one directory, so `--env-file` and `-p nas-<tier>` are required on every call:

```
docker compose -p nas-core --env-file core.env -f docker-compose.core.yml up -d
docker compose -p nas-jellyfin --env-file jellyfin.env -f docker-compose.jellyfin.yml up -d
docker compose -p nas-arr --env-file arr.env -f docker-compose.arr.yml up -d
```

Bring-up order is `core` first (it defines `nas-net`); teardown is the reverse, `arr` first,
since `arr` joins that network as `external` and holds a reference to it.

`down.sh` invariant: **nothing outside `/volume2/docker` can be deleted.** Delete targets
come from a sourced `.env` and every path is validated against that root — rejected if it
escapes, contains `..`, or is the root itself. `.env` files survive teardown, which for `arr`
also means the API keys survive. The download tree is exempted by name rather than by the
root check: it *is* inside `/volume2/docker` and would pass validation, but a still-seeding
torrent is not a config artifact and is not reproducible from this repo.

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
| Downloads on the SSD | Seeding never holds the media HDD awake | No hardlinks — every import is a full copy, transient 2× space |
| Seed cap stops; arr apps delete | Nothing is removed before import; the arr apps drain the SSD tree | Torrents outside the arr apps stop at the cap but are never deleted |
| arr root folders on the existing `Media/` dirs | No migration of a live library; Jellyfin unchanged | Keeps the capitalised, non-TRaSH layout |
| `PUID`/`PGID` as env for arr | What LinuxServer.io images support; no socket access to gate | Inconsistent with Homepage/Jellyfin's `user:` |
| API keys generated into `arr.env` | Breaks the key-distribution cycle; bring-up is one pass | `arr.env` is the only copy and is load-bearing forever |
| Keys in `homepage.widget.*` labels | Widgets need them; tile config stays with the service | Readable via `docker inspect` |
| No VPN for torrent traffic | Nothing to configure or keep alive | Torrent traffic uses the LAN's own egress |
| Configarr over Recyclarr | Reads `!env` natively, so the bootstrap needs no fragile generate-then-rewrite credential patching; actively tracks upstream template churn | Younger project; no built-in scheduler, so one is bolted on |
| Ofelia as that scheduler | Keeps the daily cadence inside compose — no host cron for `down.sh` to clean up | A **second** container with root-equivalent socket access |
| `down.sh` keeps the download tree | Config is reproducible from the repo; a part-done torrent is not | A "clean slate" needs one manual `rm` |

### The standing assumption

This design assumes the LAN is trusted and single-user — both the plain-HTTP decision and
the Docker socket mount rest on it. If the NAS ever becomes reachable from outside the LAN,
**both need revisiting before that happens**, not after.
