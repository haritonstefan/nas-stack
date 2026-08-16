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

**Today `nas-net` carries no traffic.** Homepage is its only member, and Jellyfin is
host-networked, so nothing currently resolves anything by container name — Homepage reads
Jellyfin's tile over the Docker socket, not the wire. Do not debug a connectivity problem
on the assumption that the two share a network. It is provisioned ahead of the `arr` stack,
whose services do talk to each other by name.

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

- LAN networks: restrict to the local subnet.
- Known proxies: none — nothing proxies Jellyfin.
- Base URL: empty.

---

## 6. Filesystem layout

```
/volume2/docker/            # SSD — all container config and logs
├── homepage/config/
└── jellyfin/
    ├── config/             # SQLite databases
    └── cache/              # transcode scratch
```

```
/volume1/Media/             # HDD — library root, mounted :ro into Jellyfin
├── Movies/
├── Series/
└── Music/
```

Config on the **SSD**; nothing that spins up the HDD at idle belongs there. Media on the
**HDD**, mounted read-only wherever a service only reads. Note the capitalisation.

Compose files must not hardcode these paths — they come from `<tier>.env` (gitignored,
with `<tier>.env.example` as the template).

### btrfs copy-on-write

If `/volume2` is btrfs, disabling CoW on database and cache directories avoids
fragmentation and write amplification. Confirm the filesystem first — on ext4/xfs this is a
no-op:

```bash
findmnt -T /volume2/docker -o TARGET,SOURCE,FSTYPE
```

**`chattr +C` only takes effect on an empty directory**, so it must be applied at creation,
before any data is written. Verify with `lsattr -d`. This disables checksums on those
paths — acceptable for SQLite and transcode scratch. Never apply it to the media library.

---

## 7. Homepage

The dashboard at `apollo.local` and the entrypoint to everything. Binds host `:80`.

Tiles come from `homepage.*` **Docker labels in each service's own compose file**, so the
dashboard is a derived artifact of the stack definition — adding a service adds its tile,
with no dashboard config to maintain. Labels alone suffice; `server` and `container` are
inferred.

Two config files, installed by `up.sh` only when absent so on-NAS edits survive:

- `docker.yaml` — declares the socket, enabling container status and stats.
- `services.yaml` — for things that are **not containers on this host** and so cannot be
  auto-discovered (UGOS at `apollo.local:9999`). Containers must not be listed here.

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

For the arr stack specifically:

- They need **write** access to the media paths, so Jellyfin's read-only mount is not
  enough — mount read-write for them, or split into separate download/library trees.
- Use **identical mount paths** across all containers (e.g. `/media` everywhere) so
  hardlinks and atomic moves work instead of slow cross-filesystem copies.
- They are bridge services on `nas-net`: only Jellyfin needs host networking.

---

## 9. Remote access

Tailscale runs on the NAS host, outside this stack.

`.local` names do **not** resolve over the tailnet — mDNS is link-local by definition.
Remote access is by tailnet IP or MagicDNS hostname, on the same ports. Add any such
hostname to `HOMEPAGE_ALLOWED_HOSTS` or Homepage rejects the request.

---

## 10. Running

`sudo ./up.sh` takes a fresh clone to running: env files from the examples, host
directories with correct ownership, `core` then `jellyfin`, then Jellyfin's API bootstrap.
Idempotent — existing `.env` files are never overwritten and configured steps are skipped.
`./down.sh` reverses it and is a **dry run by default**.

Underneath it is plain compose. Compose does not read `<tier>.env` on its own and all tiers
share one directory, so `--env-file` and `-p nas-<tier>` are required on every call:

```
docker compose -p nas-core --env-file core.env -f docker-compose.core.yml up -d
docker compose -p nas-jellyfin --env-file jellyfin.env -f docker-compose.jellyfin.yml up -d
```

`down.sh` invariant: **nothing outside `/volume2/docker` can be deleted.** Delete targets
come from a sourced `.env` and every path is validated against that root — rejected if it
escapes, contains `..`, or is the root itself. `.env` files survive teardown.

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

### The standing assumption

This design assumes the LAN is trusted and single-user — both the plain-HTTP decision and
the Docker socket mount rest on it. If the NAS ever becomes reachable from outside the LAN,
**both need revisiting before that happens**, not after.
