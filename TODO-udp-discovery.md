# UDP auto-discovery / DLNA for Jellyfin

## The problem

`docker-compose.jellyfin.yml` publishes `7359/udp` (client auto-discovery) and
`1900/udp` (DLNA/SSDP) on the `nas-net` bridge network. This likely doesn't work:

- Client auto-discovery and SSDP/DLNA depend on **broadcast**
  (`255.255.255.255:7359`) and **multicast** (`239.255.255.250:1900`) traffic.
- Docker's bridge port publishing only NATs **unicast** traffic addressed to
  the host's IP:port into the container. Broadcast/multicast packets arriving
  on the LAN interface are not forwarded across the bridge into the container
  the same way.
- Practical effect: Jellyfin apps/TV clients that rely on "discover server"
  probably won't find it automatically, and other DLNA clients on the LAN
  probably won't see Jellyfin as a DLNA server.

This matters because one stated goal (see `CLAUDE.md` → Jellyfin section) is
for Jellyfin to replace UGOS's own DLNA responder (disabled on this NAS) and
to support native/TV client auto-discovery.

**Not yet confirmed empirically** — this is a networking-model prediction, not
a tested failure. First step in this session should be to actually test it
(see "How to verify" below) before deciding anything needs to change.

## How to verify

From another device on the LAN (not the NAS itself):

- Open the Jellyfin mobile/TV app, use "discover server" / auto-connect —
  does it find `apollo.local:8096` without manually entering the address?
- Open any DLNA client (e.g. VLC's "Local Network" browser, a smart TV's
  media browser) — does Jellyfin appear as a DLNA server?

If both work today, this whole doc is moot — close it out and move on.

## Options, if discovery/DLNA is in fact broken

### Option A — do nothing, accept manual server entry
Jellyfin apps let you type the server address once (`apollo.local:8096` or
the NAS IP) instead of relying on auto-discovery. DLNA (passive browsing from
a smart TV, etc.) would simply not be available. Zero added complexity —
matches the stated goal of not adding unnecessary complexity, at the cost of
losing DLNA + auto-discovery entirely.

### Option B — macvlan network for Jellyfin only
Give the Jellyfin container its own MAC address and IP directly on the LAN,
instead of sitting behind the Docker bridge/NAT.

Pros:
- Genuine broadcast/multicast reachability — auto-discovery and DLNA should
  work exactly as if Jellyfin were a physical device on the LAN.

Costs / complexity introduced:
- Jellyfin leaves `nas-net` — it can no longer resolve or be resolved by
  container name from Traefik or Homepage. Traefik would need to reach it via
  its macvlan IP instead of the container name, which is a real deviation
  from this repo's "every service on `nas-net`, resolve by container name"
  convention.
- Needs a free, stable LAN IP for Jellyfin (own DHCP reservation or static IP
  outside the router's DHCP range), separate from the NAS's own IP.
- Common macvlan gotcha: the Docker **host** itself typically cannot reach a
  macvlan container directly without an extra macvlan shim interface on the
  host — worth confirming if the host (or other containers not on the LAN
  macvlan) need to reach Jellyfin directly.
- Router/switch must tolerate an extra host appearing on the LAN with its own
  IP/MAC — shouldn't be an issue on a normal home LAN, but worth a sanity check.

### Option C — `network_mode: host` for Jellyfin only
Simpler to write than macvlan (no IP planning, no separate MAC), Jellyfin
shares the host's network namespace entirely.

Pros:
- Real broadcast/multicast reachability, same as macvlan, with far less
  config (no static IP, no macvlan driver setup).

Costs / complexity introduced:
- Forfeits Docker's network isolation for this container entirely — it binds
  directly to host ports (no more explicit `ports:` mapping/control).
- Also leaves `nas-net` — same container-name-resolution loss as macvlan.
  Traefik would need to route to Jellyfin via `localhost`/host IP instead of
  container name, so its routing labels need rework.
- Explicitly against this repo's existing convention ("Do not use
  `network_mode: host` unless a specific service strictly requires it").
  Using it here would need to be a deliberate, documented exception.

## Recommendation to weigh in the working session

Test first (see "How to verify"). If discovery/DLNA is genuinely broken and
you care about it: **Option C (host network) is less total complexity than
macvlan** for a single service — no IP/DHCP planning, no macvlan driver
quirks — but costs the same container-name-resolution property. Whichever
of B/C is chosen, Traefik's routing label for Jellyfin needs to change from
container-name-based to IP/host-based reachability.

If auto-discovery/DLNA isn't something you'd actually use day-to-day, Option A
(do nothing) is the lowest-complexity answer and matches the stated goal of
avoiding unnecessary complexity outright.

## Open questions for this session
- Do you actually use DLNA (smart TV browsing to Jellyfin) or Jellyfin's
  client auto-discovery today, or do all your clients already have the server
  address saved?
- If B or C is chosen: what should happen to the Traefik path route
  (`apollo.local/jellyfin`) once Jellyfin is off `nas-net`?
