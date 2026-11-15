# Manual service setup

`nas install` brings the containers up, wired together, with their API keys.
Everything inside each app is set up by hand in its UI. This is the list of
settings that are easy to get wrong. Anything not listed here is a free choice.

The API keys are in each unit's `.env` (`sonarr.env` → `SONARR_API_KEY`, and so
on). Don't change a key in an app's UI: the env var overrides it at every
start, so a change there is gone after the next restart.

Containers reach each other by container name over `nas-net`
(`http://sonarr:8989`). The one exception is Jellyfin. It is host-networked, so
anything that talks to it uses `LAN_HOST` (`http://192.168.0.231:8096`).

## qBittorrent — `:8080`

- First boot prints a temporary WebUI password in `docker logs qbittorrent`. Set
  the login to `ADMIN_USER`/`ADMIN_PASSWORD` from `shared.env`, or the Homepage
  widget can't log in.
- Default save path `/downloads/complete`, incomplete `/downloads/incomplete`.
  These paths must match what the arr apps see, or imports fail silently.
- Seeding limits: ratio 2, 20160 minutes (14 days), action **Stop torrent**.
  Not "Remove torrent and its files". The arr apps do the deleting (see below),
  and only after import. qBittorrent-side removal can delete a download that
  hasn't been imported yet. The arr apps also refuse to save a download client
  that points at a qBittorrent set to remove at the limit.

## Sonarr `:8989` / Radarr `:7878` / Lidarr `:8686`

- Root folder: `/media/series`, `/media/movies`, `/media/music`. These are
  container paths, not host paths.
- Download client qBittorrent: host `qbittorrent`, port `8080`, the admin
  login, **Remove Completed on**. This is the other half of the "Stop torrent"
  pairing above: once qBittorrent stops a torrent at the cap, the app removes
  it and its files.
- Quality profiles are your call. The existing installs still have
  `WEB-1080p` (Sonarr) and `HD Bluray + WEB` (Radarr) from the old TRaSH
  sync. They live in the apps' own databases, so they stay until you delete
  them.
- API versions differ: Sonarr/Radarr are `/api/v3`, Lidarr/Prowlarr `/api/v1`.
  A wrong version 404s, which looks like a bad key.

## Prowlarr — `:9696`

- Settings → Apps: add Sonarr, Radarr and Lidarr. "Prowlarr Server" is
  `http://prowlarr:9696`, and the app's server is `http://sonarr:8989` etc.
  The two fields are easy to swap.
- Settings → Indexers: add a **FlareSolverr** proxy at `http://byparr:8191`
  with tag `byparr`. Byparr speaks the FlareSolverr API, and there is no
  "Byparr" type. Prowlarr only routes an indexer through the proxy when they
  share a tag, so tag every indexer `byparr`.
- Indexers are added by hand. Private trackers test their login on save.

## Jellyfin — `:8096`

- **The setup wizard is one-shot.** Finish it with an admin account
  (convention: the same `ADMIN_USER`). Closing it without a user leaves a login
  screen with no account. The only fix is wiping `/config`.
- Libraries: Movies → `/media/movies`, Shows → `/media/series`, Music →
  `/media/music`. Turn **real-time monitoring off**: inotify on the media HDD
  keeps it spinning.
- Playback → transcoding: Intel QuickSync (QSV), device
  `/dev/dri/renderD128`.
- Networking: leave **Base URL empty**. A value moves the whole API under a
  prefix and breaks the Homepage widget and Seerr. Set LAN networks to
  `192.168.0.0/24` (tailnet clients then count as remote), and leave known
  proxies empty.
- DLNA is a plugin (Catalog → DLNA), then restart Jellyfin.
- Homepage widget, optional: Dashboard → API Keys, create one, put it in
  `jellyfin.env` as `JELLYFIN_API_KEY`. Get the scan task id with
  `curl -s -H "X-Emby-Token: <key>" http://192.168.0.231:8096/ScheduledTasks | jq -r '.[] | select(.Key=="RefreshLibrary") | .Id'`
  and save it as `JELLYFIN_SCAN_TASK_ID`. Then `sudo ./nas install jellyfin`.
  Labels are baked in at container create, so `docker restart` doesn't pick
  them up.

## Seerr — `:5055`

- Sign in with Jellyfin at `192.168.0.231`, port `8096`, not a container name.
  The first account to sign in becomes Seerr's admin.
- Add Sonarr (`sonarr:8989`, `/media/series`) and Radarr (`radarr:7878`,
  `/media/movies`) with their keys. Seerr doesn't do music, so no Lidarr.
- Until setup is done, Homepage's Seerr widget shows 403. The cause is no
  user yet, not a bad key.

## Unmanic — `:8888`

- **Add a worker.** A fresh Unmanic has zero workers and processes nothing.
  One is enough for remuxing.
- Libraries `/media/movies` and `/media/series`. Turn file monitoring
  (inotify) on and the library scanner off: a scheduled scan walks the whole
  library and wakes the HDD.
- Plugins: `keep_original_language_audio` (Radarr `http://radarr:7878` and
  Sonarr `http://sonarr:8989` plus their keys) and `keep_stream_by_language`.
  Watch out for an empty subtitle-language list in the second one: it means
  "keep none" and strips all subtitles. Use `*` to keep everything.
- The audio plugin matches files to movies/series by path prefix. That's why
  Unmanic's mounts use the same container paths as Radarr/Sonarr.

## Homepage — `:80`

Nothing to click. If a tile or widget is missing, see CLAUDE.md
§Networking & routing. A widget that errors usually means its key or login is
missing from the `.env`.
