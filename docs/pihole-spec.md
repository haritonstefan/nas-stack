# PiHole — standalone unit specification

Status: built as a **standalone macvlan unit** in `pi-hole/` (compose + `.env` +
`.env.example`), deliberately outside the shared lifecycle dispatch — the CLI covers
it read-only (§CLI coverage). Untested on the NAS yet; facts marked **verify** must
be confirmed on the box.

## Role

LAN-wide DNS ad blocking. The router's DHCP hands out **`192.168.0.53`** (PiHole's own
macvlan address — not the NAS's `.231`) as DNS; PiHole answers on `:53` there and
forwards upstream. Nothing else in the stack depends on it, and it depends on nothing
else in the stack — destroyable and recreatable alone.

## Architecture: macvlan

The container gets its own IP and MAC on the LAN (`parent: bridge0` — UGOS wraps the
NIC in a bridge, confirmed via `ip route get 1.1.1.1`). No host port is claimed, so
DNS survives anything UGOS does to its own port table (including a stub resolver
appearing on host `:53`); the web UI sits on its natural `:80` at `192.168.0.53`
with no collision with Homepage; and the DHCP DNS option points at an address that
means *only* PiHole, decoupled from every other service on `.231`.

The kernel macvlan rule — host and its macvlan children can't exchange traffic —
has two standing consequences:

- **The NAS itself cannot use PiHole as DNS**, and must keep a public/router resolver.
  Accepted: the NAS is the one device on the LAN that must resolve even when PiHole is
  down.
- **Homepage's widget cannot fetch from `192.168.0.53`** (Homepage queries from the
  NAS). The *tile* still works — `homepage.href` is opened by the client's browser, and
  clients reach `.53` normally. Auto-discovery also works (labels are read over the
  Docker socket, not the network). Fixing the widget needs a macvlan shim interface on
  the host — deferred, see open questions.

## Requirements (as built)

- **P1 — Self-contained unit.** Lives in `pi-hole/`: `docker-compose.yml` owns its
  `pihole_macvlan` network (not `external:`, unlike every nas-net unit), `.env` is read
  automatically by compose from the same directory — no `--env-file` flags, no
  `-p` juggling, no involvement of the shared lifecycle verbs. Exact image pin
  (`pihole/pihole:2026.09.0` — **verify** the tag exists and check against daemon API
  1.54), `container_name: pihole`, capped json-file logging, config bind at
  `/volume2/docker/pihole` → `/etc/pihole`, all host facts via `.env`
  (`MACVLAN_PARENT`, `LAN_SUBNET`, `LAN_GATEWAY`, `PIHOLE_IP`).
- **P2 — Own LAN address.** `192.168.0.53`, static via compose `ipv4_address`. Must
  stay outside the router's DHCP pool or carry a reservation (confirmed fine). No
  `ports:` anywhere — macvlan exposes everything on the container's own IP. DHCP module
  stays off; the router remains the DHCP server, so no `67/udp`, no NET_ADMIN.
- **P4 — Own credential, not the shared identity.** `PIHOLE_PASSWORD` in `pi-hole/.env`
  (gitignored via the root `*.env` rule), injected as
  `FTLCONF_webserver_api_password` — v6 login is password-only, no username. This
  *diverges* from the shared-`ADMIN_PASSWORD` idea deliberately: the unit reads no
  `shared.env`, and a standalone unit with a reach into `shared.env` would be
  self-contained in name only. Set declaratively at create; secret has no default, so
  compose fails loudly if unset.
- **P5 — Upstream DNS** via `PIHOLE_UPSTREAMS` (`FTLCONF_dns_upstreams`,
  semicolon-separated), default Cloudflare `1.1.1.1;1.0.0.1`. The container resolves
  through itself with a `1.1.1.1` fallback for blocklist pulls before FTL is up.
  Conditional forwarding off; `apollo.local` stays mDNS — PiHole never serves `.local`
  (RFC 6762), and the no-custom-DNS decision in `apollo-nas-stack-spec.md` stands.
- **P6 — Homepage: tile yes, widget deferred.** `homepage.*` labels give a tile with
  `href: http://192.168.0.53/admin` (client-opened, works). The widget is blocked by
  macvlan host isolation until a shim exists — do not wire a widget credential that can
  only ever time out.
- **P7 — The LAN must survive PiHole being down.** Unchanged and still the sharpest
  requirement: `restart: unless-stopped`, and the router keeps a public resolver as
  secondary DNS. This is the one unit whose failure is felt outside the NAS.
- **P8 — Zero bootstrap.** Held: password, upstreams and address are all env/compose
  values. Nothing needed the API.

## CLI coverage

The CLI knows pihole exists but never manages its lifecycle (`UNIT_STANDALONE` in
its unit file — `docs/cli-spec.md` §Code layout):

- `nas configure pihole` — fills `pi-hole/.env` from its example like any other
  unit's. Its questions never include the shared identity: `PIHOLE_PASSWORD` is its
  own credential (P4).
- `nas status` — container state over the docker socket, `pi-hole/.env` presence.
- `nas logs pihole` — plain `docker logs pihole`.
- `nas doctor` — DNS answering probed via `docker exec` from inside the container
  (**verify** the image ships a resolver client); the NAS cannot reach
  `192.168.0.53` (macvlan), so the LAN-side check is printed as a command for a
  client, never attempted locally.
- `nas install|destroy|recreate|post-install pihole` — refused, pointing at the
  standalone bring-up: `cd pi-hole && sudo docker compose up -d` / `down`. Lifecycle
  integration would make the macvlan network script-managed like `nas-net`; this
  spec gets revisited if that ever happens.

## Explicitly out of scope

- PiHole as DHCP server.
- Per-device DNS policies / groups (hand-configured in the UI if ever wanted; config
  survives recreate via the P1 bind mount).
- DNS names for stack services (`jellyfin.local` etc.) — rejected in
  `apollo-nas-stack-spec.md` §2, unchanged by having a DNS server available.
- CLI lifecycle integration — bounded in §CLI coverage.

## Open questions

- **Macvlan shim on the host** — a `macvlan` sub-interface on `bridge0` with its own IP
  would let the NAS (and Homepage's widget) reach `.53`. Worth it only if the widget is
  missed; adds a boot-time host config step that survives nothing UGOS reprovisions.
  **Verify** UGOS tolerates it before speccing.
- **verify on first bring-up:** `pihole/pihole:2026.09.0` exists; macvlan on
  `parent: bridge0` passes traffic on UGOS (some bridge setups need promiscuous mode on
  the parent); `.53` answers from a LAN client (`dig @192.168.0.53 example.com`) and
  from the NAS it deliberately does *not*.
