# Healthchecks — open

No service in either stack defines a `healthcheck:` in the compose files. This is the
only genuinely open item in the repo. (Exception that needs no work: byparr's image ships
its own `HEALTHCHECK` — `curl http://127.0.0.1:8191/health`, 15m interval — so it already
reports healthy/unhealthy without a compose-level entry.)

## Why bother

- `docker ps` shows a container as `Up` even when the process inside is wedged — Homepage
  stuck loading config, Jellyfin's web server hung. A healthcheck turns "the process
  started" into "the service answers."
- `restart: unless-stopped` does **not** restart a container that is running but
  unresponsive. Only a failing healthcheck (plus something acting on it) catches that.
- Homepage surfaces container status on the dashboard via its Docker socket integration,
  so healthy/unhealthy would show up where you already look.

## Scope

Three services: Homepage, Jellyfin and Seerr.

### Homepage

No documented built-in health endpoint for the pinned version, so a raw HTTP check against
its internal port:

```yaml
healthcheck:
  test: ["CMD", "wget", "--spider", "-q", "http://localhost:3000/"]
  interval: 30s
  timeout: 5s
  retries: 3
```

Confirm `wget` or `curl` actually exists in the image first — some slim images ship
neither.

Homepage binds host `:80` and is the entrypoint to everything, so it is the service where
"running but wedged" is most user-visible. Best candidate to do first.

### Seerr

Upstream's own docs ship a compose healthcheck, so this one is closest to copy-paste-ready
— deliberately deferred with the others rather than being the only service that has one:

```yaml
healthcheck:
  test: wget --no-verbose --tries=1 --spider http://localhost:5055/api/v1/status || exit 1
  start_period: 20s
  timeout: 3s
  interval: 15s
  retries: 3
```

Same caveat as Homepage: confirm `wget` exists in `ghcr.io/seerr-team/seerr:v3.4.1`
(`docker exec seerr which wget curl`) before trusting it — upstream documenting it is a
strong hint, not proof for this exact tag.

### Jellyfin

Exposes `/health` on its web port:

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8096/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 60s
```

`start_period` matters — startup (library scan, plugin load) can outlast a normal
interval/retries window and get falsely flagged unhealthy.

Note that Jellyfin runs with `network_mode: host`, so `localhost:8096` inside the container
is the host's `:8096`. Fine for this check, but not the usual container-local semantics.

## Before landing

Verify every command and endpoint against the actual pinned images — this file is a
starting point, not copy-paste-ready config. Check that the binary used in `test:` exists
in the image, and confirm the endpoint responds on a running container:

```bash
docker exec homepage which wget curl
docker exec jellyfin curl -fsS http://localhost:8096/health
```
