# Manual service setup

`nas install` brings the containers up, wired together. Everything inside each
app is set up by hand in its UI. This is the list of settings that are easy to
get wrong. Anything not listed here is a free choice.

Containers reach each other by container name over `nas-net`
(`http://qbittorrent:8080`). The one exception is Jellyfin. It is
host-networked, so anything that talks to it uses `LAN_HOST`
(`http://192.168.0.231:8096`).

## qBittorrent — `:8080`

- First boot prints a temporary WebUI password in `docker logs qbittorrent`. Set
  the login to `ADMIN_USER`/`ADMIN_PASSWORD` from `shared.env`, or the Homepage
  widget can't log in.
- Default save path `/downloads/complete`, incomplete `/downloads/incomplete`.
  Anything that imports from qBittorrent must see the same paths, or imports
  fail silently.
- Seeding limits: ratio 2, 20160 minutes (14 days), action **Stop torrent**.
  Nothing in this repo deletes a stopped torrent: whatever imports from
  qBittorrent (with "Remove Completed" on) or you, by hand, clears them.
  "Remove torrent and its files" would free the space on its own, but can delete
  a download that hasn't been imported yet.

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
  prefix and breaks the Homepage widget. Set LAN networks to
  `192.168.0.0/24` (tailnet clients then count as remote), and leave known
  proxies empty.
- DLNA is a plugin (Catalog → DLNA), then restart Jellyfin.
- Homepage widget, optional: Dashboard → API Keys, create one, put it in
  `jellyfin.env` as `JELLYFIN_API_KEY`. Get the scan task id with
  `curl -s -H "X-Emby-Token: <key>" http://192.168.0.231:8096/ScheduledTasks | jq -r '.[] | select(.Key=="RefreshLibrary") | .Id'`
  and save it as `JELLYFIN_SCAN_TASK_ID`. Then `sudo ./nas install jellyfin`.
  Labels are baked in at container create, so `docker restart` doesn't pick
  them up.

## Unmanic — `:8888`

- **Add a worker.** A fresh Unmanic has zero workers and processes nothing.
  One is enough for remuxing.
- Libraries `/media/movies` and `/media/series`. Turn file monitoring
  (inotify) on and the library scanner off: a scheduled scan walks the whole
  library and wakes the HDD.
- Plugins: `keep_original_language_audio` (the URL and API key of a Radarr and
  a Sonarr, which this repo no longer runs) and `keep_stream_by_language`.
  Watch out for an empty subtitle-language list in the second one: it means
  "keep none" and strips all subtitles. Use `*` to keep everything.
- The audio plugin matches files to movies/series by path prefix. Radarr/Sonarr
  must see the library at the same container paths as Unmanic
  (`/media/movies`, `/media/series`). Without a reachable Radarr/Sonarr it
  leaves every file unchanged.

## GitLab Runner — no UI

- Create a project runner tagged `apollo`, with "Run untagged jobs" off. In the
  UI that's the project's Settings → CI/CD → Runners → **New project runner**.
  With glab:

  ```
  glab api --method POST user/runners -f runner_type=project_type \
    -F project_id=<id> -f description=apollo -f tag_list=apollo \
    -F run_untagged=false -F locked=true
  ```

  The `token` in the response is the `glrt-` token, shown once. Tags and
  "run untagged" must be set here: `register` ignores them with a `glrt-` token.
- The pipeline opts in with `tags: [apollo]` under `default:` in its
  `.gitlab-ci.yml`. Leave the project's instance runners on: GitLab Duo flows
  only run on those.
- `sudo ./nas install runner`, then register. The running container picks up
  the new `config.toml` within seconds, no restart needed:

  ```
  sudo ./nas compose runner run --rm runner register --non-interactive \
    --url https://gitlab.com --token glrt-... --executor docker \
    --description apollo --docker-image alpine:3.24.4 \
    --docker-cpus 4 --docker-memory 1536m --docker-pull-policy if-not-present \
    --docker-volumes /volume2/docker/runner/cache:/cache
  ```

  The `--docker-volumes` bind is `RUNNER_CACHE_DIR`. Without it each job slot
  gets its own cache volume, and a cache one job pushes misses in the others.

- `register` writes `concurrent = 1`, and has no flag for it. Raise it to 3:
  `sudo sed -i 's/^concurrent = 1$/concurrent = 3/' /volume2/docker/runner/config/config.toml`.
  Three jobs × 1.5 GB leaves Jellyfin and the rest about 3.5 GB of the 8.
  `cpus` is a per-job cap, not a reservation: the three jobs share the 6
  cores. A job killed with exit code 137 hit the memory cap.
- **Never** set `privileged = true` in `config.toml`, and never add
  `/var/run/docker.sock`, `/volume1` or the download tree to its `volumes`.
  Each one hands every job root on the NAS or its data (spec §8). The cache
  dir is the only host path jobs get.
- Job containers, images and cache volumes live in `/volume2/@docker`
  and nothing removes them. Check with `sudo docker system df`. Clean up with:

  ```
  sudo docker container prune -f --filter label=com.gitlab.gitlab-runner.managed=true
  sudo docker volume prune -af --filter label=com.gitlab.gitlab-runner.managed=true
  sudo docker image prune -af
  ```

  The image prune removes every image no container uses, a destroyed unit's
  too; the next `nas install` pulls it again. The CI cache cleans itself:
  `runner-cache-cleaner` deletes what no job has written in 30 days, and
  `sudo docker logs runner-cache-cleaner` lists what it removed.
- After `nas destroy runner`, delete the old runner in GitLab and register a
  new one.

## Homepage — `:80`

Nothing to click. If a tile or widget is missing, see CLAUDE.md
§Networking & routing. A widget that errors usually means its key or login is
missing from the `.env`.
