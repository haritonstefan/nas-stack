# Requirements — nas-stack management CLI

The as-built record of the system, and the reasoning behind it, is
`apollo-nas-stack-spec.md`. This file holds what the CLI must keep guaranteeing.

## Vision

This repo manages the NAS. One small CLI (`./nas`) installs and destroys apps on
`apollo.local`, individually, without ever taking down the rest of the stack. A fresh
clone, one install run, the `.env` files filled in and a second install run reproduce
every container and its wiring. What lives inside each service is set up by hand in its
own UI (`docs/manual-setup.md`).

## Goals

1. **Single entrypoint.** All lifecycle operations go through `./nas`.
2. **Per-app lifecycle.** Install and destroy operate on one unit at a time by
   default. Destroying `radarr` must not disturb `sonarr`, `nas-net`, or any other unit's
   API keys — a hard requirement to preserve.
3. **Wiring in code, service setup by hand.** The repo owns everything outside a
   service: network, mounts, ports, identities, API keys, dashboard tiles. Inside a
   service, its own UI is the source of truth.
4. **PiHole, standalone.** The CLI doesn't know it; its lifecycle is its own
   two-command compose (spec: `docs/pihole-spec.md` §CLI coverage).
5. **Lean documentation**, per the policy below.

## Non-goals

- Configuring services over their APIs. Setup flows that are one-shot or change between
  upstream releases make that automation more fragile than the clicks it saves.
- A generic "add any app" framework. The unit set is the known apps listed below. New apps
  are added by hand, following the existing per-unit pattern, not by a plugin mechanism.
- TLS, reverse proxy, custom DNS names, external exposure. The architecture decisions in
  `apollo-nas-stack-spec.md` §2–3 stand.
- Multi-user or multi-host. This is one person's NAS; the CLI may assume a single
  operator.

## Scope: the units

Ten managed units, each a self-contained `docker-compose.<unit>.yml` + `<unit>.env`
pair, plus standalone pihole. The CLI drives them by naming convention (`CLAUDE.md`
§Files):

| Unit | Role |
|---|---|
| homepage | dashboard, entrypoint, `:80` |
| jellyfin | media server, host networking |
| sonarr / radarr / prowlarr | arr apps |
| lidarr | music arr |
| qbittorrent | download client |
| seerr | request front-end |
| byparr | Cloudflare solver for Prowlarr |
| unmanic | post-import audio/subtitle cleanup |
| pihole | DNS ad-blocking, standalone (`docs/pihole-spec.md`) |

`arr` is a selection alias only (sonarr, radarr, lidarr, prowlarr, qbittorrent, seerr,
byparr).

## Hard requirements

The numbers are stable: code comments cite them, so a dropped requirement leaves a gap
rather than renumbering the rest.

- **R1 — Destruction is scoped.** Nothing outside `/volume2/docker` can ever be deleted.
  Delete targets sourced from `.env` files are validated against that root: rejected if
  they escape it, contain `..`, or are the root itself.
- **R2 — `.env` files survive teardown.** They hold the only copy of each unit's API key.
  Losing one silently breaks every place that key was pasted (Prowlarr, Seerr, Unmanic)
  and the Homepage widget for that unit.
- **R3 — The download tree survives teardown.** Config is reproducible from this repo; a
  still-seeding torrent is not.
- **R4 — Destructive operations preview first.** `nas destroy` shows the full plan
  (containers, on-disk paths) and requires confirmation; `--yes` skips it for scripted
  use.
- **R5 — Idempotent install.** Running install twice is safe: existing `.env` files are
  never overwritten, generated keys are generated once, config templates are installed
  only when absent (on-NAS edits survive).
- **R6 — Non-interactive operation.** Every verb must be runnable without a TTY. A
  prompt is never the only path: without a TTY, a verb either proceeds on a flag
  (`--yes`) or refuses with a clear exit code.
- **R7 — Cross-unit knowledge lives in the CLI only.** Compose files stay ignorant of each
  other: no `depends_on`, no shared volumes, `nas-net` script-managed. The aliases and
  the qBittorrent sparing rule live in the CLI, never in a compose file.
- **R9 — Live-NAS discipline.** GET-only probing, dry-run before mutating, logs collected
  before any wipe, exact image pins. (These are operator rules as much as CLI rules; the
  CLI encodes them where it can — e.g. `destroy` always saves logs first.)

## CLI requirements

- **N1 — As small as the guarantees allow:** `install`, `destroy`, and `compose` (plain
  `docker compose` with the unit's project and env files, for everything else: logs,
  status, restarts). Behavior is in `./nas --help`.

## Documentation policy

- A comment earns its place only by stating a **why**: a trap, a non-obvious constraint,
  a decision that looks wrong but isn't (host networking ignores `ports:`, `docker
  restart` never refreshes labels, `EACCES` is not a path problem). Narration of what the
  next line does is deleted.
- One home per fact. The spec files own the reasoning; `CLAUDE.md` owns only what an
  agent needs to behave correctly in this repo, and points to the spec for the rest.
  Near-verbatim duplication between the two is a bug.
- Stale references (deleted files, renamed variables, retired structure) are removed on
  sight, not annotated.
- Decisions are recorded as their outcome, never as decision trees. Rejected
  alternatives and "earlier drafts did X" narration are deleted; a question is either
  listed under Open questions or resolved and gone.
