# Traefik dashboard + Docker socket exposure

## The problem

Two related gaps, both currently wide open on the LAN:

1. **No authentication on the Traefik dashboard.** `apollo.local:8082/dashboard/`
   exposes the full Traefik API (`api@internal`) to anything on the LAN —
   routes, backend addresses, TLS config (once added) — with zero auth
   middleware in front of it.

2. **Unrestricted Docker socket access from two containers.** Both `traefik`
   and `homepage` mount `/var/run/docker.sock:ro` in `docker-compose.core.yml`.
   The `:ro` flag only makes the **socket file** read-only — it does nothing
   to restrict what the Docker Engine API reachable *through* that socket can
   do. Anyone who can reach that API (i.e. anyone who compromises either
   container, e.g. via a future CVE or a bad label injected by a compromised
   third container on `nas-net`) can create a new container with
   `-v /:/host` and get full read/write root access to the NAS's filesystem.
   This is a bigger blast radius than "read-only" sounds like it should be.

## Why this matters here specifically
- Traefik and Homepage are both **internet-adjacent-ish** by design — Traefik
  terminates all inbound routed traffic, Homepage is the public landing page.
  They're exactly the two containers you'd expect an attacker to reach first
  if any vulnerability surfaces.
- The whole `nas-net` is shared across every stack (core, jellyfin, future
  arr/pihole) — a socket compromise via Traefik/Homepage is a compromise of
  the whole NAS, not just those two services.

## Options for the dashboard auth

### Option A — Traefik basic auth middleware
Add a `traefik.http.middlewares.dashboard-auth.basicauth.users` label with a
htpasswd-hashed credential, attach it to the `traefik-dashboard` router.
Lowest complexity, no new services, credentials live in an env var /
Docker secret. Downside: basic auth only, no MFA, credentials shared if
multiple people access it (not a concern for a single-user NAS).

### Option B — restrict dashboard reachability at the network level
Bind `TRAEFIK_DASHBOARD_PORT` to `127.0.0.1` only and reach it via SSH tunnel
when needed, or firewall the port to specific LAN IPs. Removes the "anything
on the LAN" exposure without adding auth complexity, but less convenient for
casual access from any device.

### Option C — both
Basic auth AND restrict to trusted IPs/tunnel. More defense in depth, more
config to maintain. Probably overkill for a single-user home LAN, but worth
naming as the "if this ever gets internet-exposed" option.

Recommendation to weigh in-session: **Option A** is the standard, low-effort
fix and is what most Traefik guides recommend by default. Revisit B/C only if
the dashboard ever needs to be reachable outside the LAN.

## Options for the Docker socket exposure

### Option A — socket-proxy container (standard mitigation)
Insert a small proxy (commonly `tecnativa/docker-socket-proxy` or
`linuxserver/socket-proxy`) between Traefik/Homepage and the real socket. The
proxy holds the real `docker.sock` mount and exposes a scoped-down HTTP API
(e.g. `CONTAINERS=1, EVENTS=1` for read-only discovery, everything else `0`
including `POST`/exec/create) over the internal network. Traefik/Homepage
then point at the proxy's URL instead of the raw socket, and never touch
`docker.sock` directly.

Pros: this is the well-established pattern for exactly this problem, purpose-built,
low ongoing maintenance once configured.
Costs: one more container to run or two (Traefik and Homepage could share a
proxy or each get one); a small amount of new config to get the allowed-call
list right for each consumer (Traefik needs more than pure read-only —
confirm which endpoints it actually calls before locking it down, so
discovery doesn't silently break).

### Option B — accept the risk, document it
Given this is a single-user home LAN, not multi-tenant or internet-facing,
you could explicitly decide the current risk is acceptable and just document
it as a known tradeoff rather than adding a socket-proxy container. Zero
added complexity, but leaves the actual exposure unchanged — this is a
"write it down and move on" option, not a fix.

Recommendation to weigh in-session: whether **Option A is worth the added
container** depends on how much you weigh "single-user home LAN, low
realistic attacker exposure" against "if it does go wrong, blast radius is
the whole NAS." I don't think this is mine to pre-decide — flagging both
honestly rather than picking one.

## Open questions for this session
- Is the Traefik dashboard something you actually use often enough to want
  frictionless (no-tunnel) access, or is SSH-tunnel-when-needed acceptable?
- Appetite for one more always-on container (socket-proxy) given the
  "avoid unnecessary complexity" goal — or prefer to explicitly accept and
  document the risk for now, revisit if/when the NAS is ever exposed beyond
  the LAN?