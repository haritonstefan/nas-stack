# Healthchecks

## The problem

`CLAUDE.md`'s own stated convention lists "healthchecks where sensible" as
part of "Conventions for compose files" — but neither `docker-compose.core.yml`
(Traefik, Homepage) nor `docker-compose.jellyfin.yml` (Jellyfin) has one.

Related: Homepage's `depends_on: [traefik]` in `docker-compose.core.yml`
currently only controls **start order** (Compose default condition is
`service_started`, i.e. "the container process started," not "the service is
actually ready"). Since Traefik discovers routes dynamically at runtime via
the Docker provider, this `depends_on` doesn't actually gate anything
meaningful today — Homepage doesn't need Traefik to be ready to start, it
just needs Traefik to eventually pick up its labels. Worth deciding whether
to keep, remove, or upgrade it once healthchecks exist.

## Why add healthchecks at all

- `docker compose ps` / `docker ps` currently show every service as
  `Up`/running even if the process inside is wedged (e.g. Homepage stuck
  during config load, Jellyfin's web server hung). A healthcheck turns
  "process is running" into "service is actually responding."
- `restart: unless-stopped` alone doesn't restart a container that's running
  but unresponsive — only a failed healthcheck (combined with something
  acting on it) catches that class of failure.
- If `depends_on` conditions are upgraded to `service_healthy` later (see
  below), start-order actually becomes meaningful instead of cosmetic.

## What each service's healthcheck would check

### Traefik
`traefik` doesn't have a dedicated health endpoint enabled by default, but
exposes a `/ping` endpoint when `--ping=true` is set (on the traefik entrypoint
or its own). Command would be something like:
```yaml
healthcheck:
  test: ["CMD", "traefik", "healthcheck", "--ping"]
  interval: 30s
  timeout: 5s
  retries: 3
```
Requires adding `--ping=true` to Traefik's command args first.

### Homepage
No official built-in healthcheck endpoint documented as of the pinned
version — likely needs a raw HTTP check against `/` on its internal port
(3000), e.g.:
```yaml
healthcheck:
  test: ["CMD", "wget", "--spider", "-q", "http://localhost:3000/"]
  interval: 30s
  timeout: 5s
  retries: 3
```
Needs confirming `wget` (or `curl`) actually exists in the Homepage image —
some slim images ship neither.

### Jellyfin
Jellyfin exposes a `/health` endpoint on its web port. Likely:
```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8096/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 60s
```
`start_period` matters here — Jellyfin's startup (library scan, plugin load)
can take longer than a typical `interval`/`retries` window would tolerate
before falsely flagging unhealthy. Needs confirming `curl` exists in the
Jellyfin image (it's a fuller image than most \*arr apps, likely does).

All of the above commands/endpoints need verifying against the actual pinned
image versions before landing — this doc is a starting point, not
copy-paste-ready config.

## Open questions for this session
- Once healthchecks exist, do you want `depends_on` conditions upgraded to
  `service_healthy` (e.g. Homepage waits for Traefik to be healthy, not just
  started) — or is that unnecessary given Traefik's dynamic discovery means
  Homepage doesn't actually need to wait on it?
- Any interest in surfacing healthcheck status on the Homepage dashboard
  itself (it can show container status via the existing Docker socket
  integration) once these exist?