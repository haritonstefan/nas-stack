# Requirements — nas-stack management CLI

Status: draft for review. This is a requirements document, not an implementation plan.
The as-built record of the current system stays in `apollo-nas-stack-spec.md`; this file
describes where the repo is going.

## Vision

This repo manages the NAS. One CLI (`./nas`) installs, configures, destroys and recreates
apps on `apollo.local`, individually, without ever taking down the rest of the stack. A
fresh clone plus one wizard run plus one install command reproduces the whole box.

## Goals

1. **Single entrypoint.** All lifecycle operations go through `./nas` (spec:
   `docs/cli-spec.md`). The old `up.sh`/`down.sh` are absorbed and deleted.
2. **Per-app lifecycle.** Install, destroy and recreate operate on one unit at a time by
   default. Destroying `radarr` must not disturb `sonarr`, `nas-net`, shared identity, or
   any other unit's API keys — this already works today and is a hard requirement to
   preserve.
3. **Terminal configuration wizard.** A gum-based wizard collects the stack's
   configuration before first install: host facts, per-app values, and one shared
   user/password identity reused across apps (spec: `docs/wizard-spec.md`). The identity
   concept will be deepened later; the wizard spec leaves explicit room for that.
4. **PiHole, standalone.** The CLI covers it via `configure` and the
   read-only verbs; its lifecycle stays its own two-command compose
   (spec: `docs/pihole-spec.md` §CLI coverage).
5. **Leaner documentation.** Comments and docs get audited and trimmed
   (`docs/comment-audit.md`); the policy going forward is in "Documentation policy" below.

## Non-goals

- A generic "add any app" framework. The unit set is the known apps listed below. New apps are
  added by hand, following the existing per-unit pattern, not by a plugin mechanism.
- TLS, reverse proxy, custom DNS names, external exposure. The architecture decisions in
  `apollo-nas-stack-spec.md` §2–3 stand.
- Multi-user or multi-host. This is one person's NAS; the CLI may assume a single
  operator and may embed tooling (gum) that only needs to run on two machines
  (the NAS and the workstation).

## Scope: the units

The thirteen units, each a self-contained `docker-compose.<unit>.yml` + `<unit>.env`
pair. The per-unit data the CLI drives them with (dirs, templates, ports, secrets,
delete targets) is tabulated in `docs/units.md`:

| Unit | Role | Bootstrap |
|---|---|---|
| homepage | dashboard, entrypoint, `:80` | none (config templates) |
| jellyfin | media server, host networking | `jellyfin-bootstrap.sh` |
| sonarr / radarr / prowlarr | arr apps | `arr-bootstrap.sh` |
| lidarr | music arr (`docs/units.md` §Lidarr) | `arr-bootstrap.sh` |
| qbittorrent | download client | `arr-bootstrap.sh` (+ seeded conf) |
| byparr | Cloudflare solver | via `arr-indexers.sh` |
| configarr | TRaSH sync, run-to-completion | `arr-bootstrap.sh` (dry-run preflight) |
| ofelia | scheduler for configarr | none |
| seerr | request front-end | `seerr-bootstrap.sh` |
| tdarr | post-import audio/subtitle cleanup | none (flows set up in its UI) |
| pihole | DNS ad-blocking | see `docs/pihole-spec.md` |

`core` and `arr` remain selection aliases only (`core` → homepage, `arr` → sonarr,
radarr, lidarr, prowlarr, qbittorrent, seerr, byparr, configarr, ofelia). The CLI
keeps them.

## Hard requirements (carried over from the current scripts)

These are behaviors the current scripts guarantee. The CLI must preserve every one of
them; a migration step that loses one is a regression, not a simplification.

- **R1 — Destruction is scoped.** Nothing outside `/volume2/docker` can ever be deleted.
  Delete targets sourced from `.env` files are validated against that root: rejected if
  they escape it, contain `..`, or are the root itself.
- **R2 — `.env` files survive teardown.** They hold the only copy of each unit's API key
  and the shared identity. Losing one silently breaks Prowlarr sync, Configarr and the
  Homepage widget for that unit.
- **R3 — The download tree survives teardown.** Config is reproducible from this repo; a
  still-seeding torrent is not.
- **R4 — Destructive operations preview first.**
  `nas destroy` shows the full plan (containers, volumes-on-disk
  paths) and requires confirmation; `--yes` skips it for scripted use.
- **R5 — Idempotent install.** Running install twice is safe: existing `.env` files are
  never overwritten, generated secrets are generated once, config templates are installed
  only when absent (on-NAS edits survive), bootstraps skip what is already configured.
- **R6 — Non-interactive operation.** Every verb must be runnable without a TTY. gum is
  the interactive skin, never the only path. A bootstrap failure exits non-zero with the
  observed state printed, never a silent skip ("a failure that cannot be distinguished
  from a deliberate skip is the bug").
- **R7 — Ordering knowledge lives in the CLI only.** Compose files stay ignorant of each
  other: no `depends_on`, no shared volumes, `nas-net` script-managed. The four known
  couplings (configarr's extra `--env-file` flags, configarr's `--no-start`, ofelia's
  "ensure configarr exists", the jellyfin→homepage widget-key recreate) live in the
  CLI, nowhere else.
- **R8 — Bootstrap ordering.** jellyfin → arr → seerr, because seerr binds to the quality
  profiles configarr creates. A seerr failure is deferred, not fatal: stack stays up,
  banner in the summary, non-zero exit.
- **R9 — Live-NAS discipline.** GET-only probing, dry-run before mutating, logs collected
  before any wipe, exact image pins. (These are operator rules as much as CLI rules; the
  CLI encodes them where it can — e.g. `destroy` offers to save logs first.)

## New requirements

- **N1 — One CLI, subcommand per operation:** `configure`, `install`, `post-install`,
  `destroy`, `recreate`, `status`, `logs`, `doctor`, `indexers` (`update` reserved,
  undesigned). The operator pipeline is configure → install → post-install, with
  install chaining post-install by default. Full behavior in `docs/cli-spec.md`.
- **N2 — gum, vendored.** The CLI uses gum for prompts, selection, confirmation, spinners
  and tables. The binary is embedded in the repo, pinned to an exact version with a
  recorded checksum (see cli-spec "Vendoring gum"). No network fetch at runtime.
- **N3 — Shared identity is a first-class concept.** One `ADMIN_USER`/`ADMIN_PASSWORD`
  pair, collected once by the wizard, consumed by Jellyfin (admin), qBittorrent (WebUI)
  and Seerr (via `/auth/jellyfin`). The wizard spec reserves space for rotation and
  per-app divergence later — do not design those now, but do not paint them out either.
- **N4 — `status` tells the truth per unit, cheaply:** not installed / created /
  running / exited, plus whether the unit's `.env` exists and whether its config
  templates drifted from the repo copies. Filesystem, docker socket and TCP probes
  only — never a service-API call.
- **N5 — `up.sh`/`down.sh` retirement.** Done — the CLI absorbed their logic and they
  are deleted (cli-spec §Migration). No
  long-term dual maintenance.

## Documentation policy

Applies to everything written from now on, and to the cleanup pass driven by
`docs/comment-audit.md`:

- A comment earns its place only by stating a **why**: a trap, a non-obvious constraint,
  a decision that looks wrong but isn't (one-shot wizard, GET-before-POST, enum string
  names). Narration of what the next line does is deleted.
- One home per fact. The spec files own the reasoning; `CLAUDE.md` owns only what an
  agent needs to behave correctly in this repo, and points to the spec for the rest.
  Near-verbatim duplication between the two is a bug.
- Stale references (deleted files, renamed variables, retired structure) are removed on
  sight, not annotated.
- Decisions are recorded as their outcome, never as decision trees. Rejected
  alternatives and "earlier drafts did X" narration are deleted; a question is either
  listed under Open questions or resolved and gone.

## Open questions

- Whether `nas update <unit>` (bump an image pin, recreate) deserves to be a verb or
  stays a manual edit + `recreate`. Deferred.
- Identity depth (rotation, per-app credentials): deferred by design — see
  `docs/wizard-spec.md` §Future.
