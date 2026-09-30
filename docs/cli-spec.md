# `nas` CLI — specification

Status: implemented — see §Migration.

One executable at the repo root: `./nas` — the operator interface for everything; the
bootstrap scripts survive as API drivers it shells out to. It runs on
the NAS, resolves its own directory (`dirname "$0"`) and operates from there — the
caller's cwd never matters. Root is required by the mutating verbs (`install`,
`post-install`, `destroy`, `recreate`); `configure` and the read-only verbs run
unprivileged. It must refuse politely, naming the verb, when run without root where
root is needed — not fail halfway through.

## Verbs

```
nas configure    [unit...]        # the wizard — see docs/wizard-spec.md
nas install      [unit...|all]    # bring units up (default: all); chains post-install
nas post-install [unit...|all]    # per-unit API configuration, re-runnable
nas destroy      [unit...|all]    # tear units down (interactive confirm; --yes to skip)
nas recreate     <unit...>        # destroy + install, per unit
nas status       [unit...]        # per-unit state table
nas logs         <unit> [--follow] [--since ...]
nas doctor       [unit...]        # health checks, read-only
nas indexers                      # Prowlarr tracker wiring (today's arr-indexers.sh)
nas help / nas <verb> --help
```

Unit arguments accept unit names and the two aliases (`core`, `arr`). Unknown names fail
before anything runs, listing the valid set.

`pihole` is a valid unit name for `configure` and the read-only verbs (`status`,
`logs`, `doctor`); the lifecycle verbs refuse it with a pointer to its standalone
bring-up (`docs/pihole-spec.md` §CLI coverage). `all` and the aliases never expand
to a standalone unit — only naming it explicitly earns the refusal.

`nas update <unit>` (bump an image pin, recreate) is a **reserved verb**: the name is
claimed so nothing else takes it, but it is not designed yet
(requirements.md §Open questions).

### `nas install`

Per selected unit:

1. Preconditions: root privileges, docker reachable, `nas-net` exists (create if
   missing: plain `docker network create nas-net`, default bridge driver, no
   options).
2. Env files: create each missing `.env` from its `.example`; never overwrite an existing
   one (R5). Generate per-unit secrets exactly once. If required values are missing
   (empty `ADMIN_PASSWORD` when jellyfin/qbittorrent/seerr selected), stop and point at
   `nas configure` — with a TTY, offer to run it right there (gum confirm). seerr is
   deliberately in that trigger list: without it, a seerr-only bring-up stalls on an
   empty password with no prompt.
3. Host directories: mkdir + chown per unit.
4. Config templates installed only when absent (homepage, qbittorrent seed with
   placeholder substitution, configarr, ofelia).
5. Compose up per unit: `-p nas-<unit>`, `--env-file shared.env --env-file <unit>.env`,
   plus the configarr exceptions (four env files, `up -d --no-start`, profile). Ofelia's
   dispatch ensures the configarr container exists even when configarr wasn't selected
   (R7).
6. `nas post-install` for the selected units (next section). `--no-post-install`
   stops after compose up.
7. Summary: one line per unit with outcome; non-zero exit if anything failed, with the
   failures named in a banner.

Interactive dressing (TTY only): gum spinners around slow steps, styled summary. None of
it may change behavior; `nas install` piped to a file produces plain log lines and
identical results (R6).

### `nas post-install`

Everything that configures a *running* service over its API, a step of its own after
the containers are up — re-runnable at any time without touching containers:

1. Per selected unit, core calls the unit's `post_install` hook (Code layout below),
   in the fixed order jellyfin → arr → seerr (R8). Units without a hook are skipped
   silently (homepage, ofelia, byparr, pihole).
2. The hooks wrap the bootstrap scripts, which survive as standalone API drivers
   (§Migration): jellyfin (wizard, admin user, libraries, QSV, DLNA, Homepage key),
   arr (download clients, root folders, configarr preflight + run), seerr (sign-in,
   libraries, arr wiring, initialize).
3. Optional depth beyond the bootstraps lands here as it gets designed — additional
   Jellyfin/Seerr users for family members, library edits. Same contract as the
   bootstraps: idempotent, skip what already exists.
4. The jellyfin hook mints the Homepage widget key into `jellyfin.env`; when the
   running homepage container's `homepage.widgets[0].key` label lags the file, core
   recreates homepage via compose — labels bake in at container create, `docker
   restart` never refreshes them. This is the fourth cross-unit coupling (R7).
5. Failure semantics unchanged: exit 10 = deferred restart (chained from `install`,
   the restart + re-run happens automatically; standalone, it prints what to restart),
   exit 22 = API failure, seerr failure deferred not fatal (R8).

`nas install` chains it, so a fresh clone is still wizard + one install command.

### `nas destroy`

Tear-down is **plan, then confirm** — never silent, never a reflex y/N over data.

1. Build the plan: containers to remove, config directories to delete, what survives
   (`.env` files, download tree — R2, R3). Validate every delete path against
   `/volume2/docker` (R1) *before* showing the plan, so the plan is the truth.
2. Show the plan. With a TTY: gum confirm, default **No**. Without a TTY: print the plan
   and exit 2 (refused) unless `--yes` was given. `--dry-run` prints the plan and
   exits 0. No unit argument means `all` — same default as install; the plan+confirm
   gate is the protection, not the argument.
3. Offer (TTY) / accept a flag (`--save-logs`) to copy each unit's logs out before
   deletion — the evidence a wipe destroys (R9). Jellyfin's logs live inside the config
   dir being deleted; this is not optional politeness, it is the only copy. Saved to
   `/volume2/docker/_saved-logs/<UTC timestamp>/<unit>/`: the `docker logs` capture
   plus every `UNIT_LOG_PATHS` directory. That path is under the delete root but
   never a delete target.
4. When the confirmed plan deletes data (not `--containers`), the TTY confirmation
   is typing the word `delete`, not a y/N — a reflex Enter shouldn't wipe config.
5. Execute. `nas-net` removed last, only when nothing is attached. configarr torn down
   with its profile flag plus the by-name backstop (`docker rm -f configarr` — a
   plain `down` ignores profiled services, and the backstop catches containers
   created outside the `-p` convention).

Two more invariants:

- `--containers` — stop and remove containers, delete no data, lighter confirm.
- **The qBittorrent sparing rule.** In scope only via `arr` or the no-args default,
  qbittorrent is left entirely alone — still running, still seeding — unless
  `--wipe-qbittorrent`; naming it explicitly always includes it. When spared,
  `nas-net` survives too (qbittorrent is still attached).

### `nas recreate <unit>`

`destroy` then `install` for each named unit, one confirmation up front covering both.
Exists because "tear down and recreate exactly one unit while it stays wired into the
stack" is the operation this whole per-unit architecture was built for; it deserves one
verb, not a remembered two-command incantation.

If destroy succeeds and install then fails, `recreate` exits with the failure and the
summary says the unit is **down**, not restored; re-running `nas install <unit>`
resumes from there.

### `nas status`

Read-only, no root needed. Per unit, one row:

| Column | Source |
|---|---|
| unit | — |
| state | not-installed / created / running / exited (docker ps, `-p nas-<unit>`) |
| env | `<unit>.env` present, required vars non-empty |
| config | config dir exists; templates drifted from repo copies (N4) |
| tile | TCP connect to the unit's web port on `127.0.0.1` — answering or not. `—` for units without a port (configarr, ofelia) and for standalone units the NAS cannot reach (pihole, macvlan) |

Template drift = byte inequality against the repo copy. `qBittorrent.conf` is exempt:
it is a placeholder-substituted first-boot seed that qBittorrent itself rewrites on
clean shutdown, so inequality there is normal life, not drift.

gum table with a TTY, tab-separated plain text without. `nas status <unit>` adds detail
(image + pin, ports, mounts).

`status` is cheap by construction: filesystem and docker-socket checks plus one TCP
connect per tile — it never calls a service API. Post-install state probing is
reserved for a future `--deep` flag, not designed.

### `nas logs <unit>`

`docker logs` on the unit's container with `--follow`/`--since` passed through, plus one
piece of knowledge the raw command lacks: for configarr it prints the named container's
logs (run-to-completion — `docker logs` works on an exited container) and always appends
a pointer that scheduled-run history lives in `docker logs ofelia`. Same output with or
without a TTY.

### `nas doctor`

Read-only diagnosis of the known failure modes, so debugging starts from mechanism
instead of guesswork. Checks, per applicable unit:

- socket access (homepage, ofelia): pass = `stat -c %g /var/run/docker.sock` equals
  the GID in the container's `docker inspect .Config.User` (the primary-GID idiom —
  a `docker exec` session gets fresh credentials, so it proves nothing). On failure
  print the mechanism trail: `.HostConfig.CapDrop`/`.SecurityOpt`, PID 1's real
  `Groups:` from `/proc/1/status`, and `dmesg | grep -i denied` for AppArmor.
- port collisions: every host port the selected units publish (from rendered compose
  config) is either owned by that unit's container or free — a foreign listener is
  the failure, named by PID/process.
- `HOMEPAGE_ALLOWED_HOSTS` contains both the detected `hostname -s`.local and
  `LAN_HOST`, as literal entries (no wildcard/CIDR matching exists).
- container older than its env: `docker inspect .Created` earlier than the mtime of
  any file in `UNIT_ENV_FILES` → the "401 means stale container, not wrong key"
  trap, surfaced proactively with the recreate command.
- compose config renders per unit (`docker compose config` with `UNIT_ENV_FILES`,
  exit code is the check).
- pihole: container running, DNS answering via `docker exec` from inside the container
  — the NAS itself cannot reach `192.168.0.53` (macvlan), so the true LAN-side check
  is printed as a command to run from a client, never attempted locally.

Exit non-zero if any check fails; each failure states the mechanism and the fix.

### `nas indexers`

Today's `arr-indexers.sh`, as a verb. Same contract: idempotent, re-runnable,
deliberately not part of `install`; interactive per-indexer retry/fix/skip prompts
(gum-ified) with `--non-interactive` saving untested with a warning.

## Language

The CLI is bash; gum (vendored, below) is the presentation layer. The bootstrap
scripts stay bash API drivers (§Migration). Aesthetics never justifies a language
switch — gum is the aesthetics budget.

## Vendoring gum

- Pinned exact version, embedded at `vendor/gum/<version>/gum-linux-amd64` with
  `gum-linux-amd64.sha256` beside it (`shasum -a 256 -c` format). The version and hash
  are recorded at vendoring time, in the same commit as the binary. The CLI verifies
  the checksum on every run before the first gum call; a mismatch or missing binary
  degrades to plain mode with a warning, never a refusal to operate. No runtime
  download.
- The NAS is the only place the CLI runs; linux-amd64 is the only vendored binary.
- Git cost: ~10 MB per binary per version. Acceptable for a single-user repo; old
  versions are deleted, not accumulated.
- **gum is presentation only.** Every gum call has a plain-text fallback: no TTY, or a
  missing/failed-checksum binary, degrades to `read`-based prompts or non-interactive
  defaults per verb (R6). A gum upgrade can never change what the CLI does.

## Code layout

```
nas                # entrypoint: arg parsing, alias expansion, verb dispatch
lib/               # shared plumbing: env loading, compose invocation, R1 path
                   # validation, gum wrappers with their plain fallbacks (R6)
units/<unit>.sh    # one file per unit: everything the CLI knows about that unit
```

Core loads one unit file at a time and resets state between units, so every unit file
uses the same vocabulary — no per-unit prefixes. The values each file carries are
tabulated in `docs/units.md`; the contract is below. Everything is plain strings and
space-delimited word lists — no bash arrays.

### Declarations

- `UNIT_PROJECT` — compose project. Default `nas-<unit>`.
- `UNIT_CONTAINER` — container name. Default `<unit>`.
- `UNIT_ENV_FILES` — ordered `--env-file` list, later wins. Default
  `shared.env <unit>.env`; configarr: `shared.env sonarr.env radarr.env
  configarr.env`; pihole: empty (compose auto-reads `pi-hole/.env`).
- `UNIT_UP_ARGS` / `UNIT_DOWN_ARGS` — appended to the compose `up` / `down`.
  configarr: `--no-start configarr` (naming the service enables its profile) /
  `--profile configarr`.
- `UNIT_DIRS` — env-var **names**, not paths, resolved after env loading and
  deduped across units; each value is mkdir'd + chowned per docs/units.md. A
  `VAR/sub` entry means a subdirectory of that var's value (the downloads trio).
- `UNIT_CHECK_DIRS` — var names checked (existence, or existence + writability)
  and warned about, never created: the media libraries are not the CLI's to make.
- `UNIT_TEMPLATES` — `source:DEST_VAR` pairs, installed only when the destination
  file is absent (R5).
- `UNIT_GENERATED` — generated-secret var names (32-hex recipe in docs/units.md).
  The wizard never asks, shows, or clears these (W2); install generates each once.
- `UNIT_REQUIRED` — vars that must be non-empty: install stops and points at
  `nas configure`, status's env column checks them. In practice: the compose
  `${VAR:?}` fail-loud set plus the prompted identity.
- `UNIT_PORT` — tile TCP port; empty = `—` in status.
- `UNIT_LOG_PATHS` — log locations beyond `docker logs`, for `--save-logs`
  (jellyfin: `$JELLYFIN_CONFIG_DIR/log`).
- `UNIT_POST_INSTALL` — the post-install driver: `jellyfin-bootstrap.sh`,
  `seerr-bootstrap.sh`, the group token `arr`, or empty. `arr` maps six units
  (sonarr radarr lidarr prowlarr qbittorrent configarr) onto **one**
  `arr-bootstrap.sh` run, at most once per invocation — the script scopes itself
  by which env files exist, and the wiring is inherently group-shaped
  (Prowlarr→Sonarr), so `nas post-install sonarr` may legitimately touch a
  sibling's wiring.
- `UNIT_STANDALONE` — set only by pihole: `configure` + read-only verbs cover it,
  lifecycle verbs refuse it.

### Hooks

Optional functions, called with `shared.env` + the unit's own env already sourced
(`set -a`) and cwd at the repo root. Non-zero return marks the unit failed in the
summary; it never aborts the other units.

- `unit_configure` — the unit's wizard section beyond the generic walk
  (wizard-spec §Question sourcing).
- `unit_templates` — replaces the default copy-when-absent template step.
  qbittorrent only: placeholder substitution + the leftover-token assert
  (docs/units.md §qBittorrent first-boot seed).
- `unit_post_install` — only for needs beyond the `UNIT_POST_INSTALL` driver
  (none today; the family-users feature lands here). Driver exit codes pass
  through untouched (10/22 semantics).
- `unit_destroy_plan` — extra delete targets on stdout, one per line, each still
  validated by core against R1. Without the hook the plan is the default: the
  parent of the unit's config dir; byparr contributes nothing.
- `unit_doctor` — unit-specific checks: mechanism + fix on failure.

A unit with default declarations and no hooks is a near-empty file, and that is the
point: the common path lives once, in core. Cross-unit knowledge never lives in a
unit file — ordering (always `UNITS_ALL` order, whatever the argv order), the
aliases, the ofelia→configarr "ensure the scheduler target exists" branch, and the
jellyfin→homepage widget-key recreate stay in core (R7).

## Surviving script contracts

The API drivers the CLI shells out to. Common ground: `set -euo pipefail`, exit `1` on
precondition failures, `22` when an unguarded API call returns non-2xx, and cwd =
repo root (none of the four `cd` on their own; `./nas` guarantees it).

| script | flags | env inputs (override var) | notes |
|---|---|---|---|
| `jellyfin-bootstrap.sh` | `--dry-run --verbose --scan-only --help` | shared.env; jellyfin.env (`ENV_FILE`) | exit `10` = success, restart needed. Writes `JELLYFIN_API_KEY` + `JELLYFIN_SCAN_TASK_ID` back into its env file. |
| `arr-bootstrap.sh` | `--dry-run --verbose --help` | shared/sonarr/radarr/lidarr/prowlarr/qbittorrent/configarr `.env`, each with a `*_ENV_FILE` override | Scope = which env files exist; none present = "nothing to configure", exit 0. A failed configarr sync is also exit 0 (warn only — ofelia retries on schedule). |
| `seerr-bootstrap.sh` | `--dry-run --verbose --help` | shared (`SHARED_ENV_FILE`), seerr (`ENV_FILE`), sonarr/radarr (`*_ENV_FILE`) | `SEERR_CONFIGURE != 1` = deliberate skip, exit 0. Prints observed state on every failure, never an asserted cause. |
| `arr-indexers.sh` | `--dry-run --verbose --non-interactive --help` | prowlarr.env (`ENV_FILE`) | Prompts via `/dev/tty`; no terminal = save-untested with warnings. Exit 0 can still mean trackers were skipped — the output must be read. |

## Migration

Status: executed in one pass — `up.sh`, `down.sh` and `configure.sh` are deleted and the
CLI owns everything they did. The bootstrap scripts (`jellyfin-bootstrap.sh`,
`arr-bootstrap.sh`, `seerr-bootstrap.sh`) and `arr-indexers.sh` **survive** as standalone
API drivers the CLI shells out to — they have their own idempotency contracts (above) and
are not operator interface.

## Exit codes

- The CLI itself exits with exactly three codes: `0` success; `1` any failure
  (precondition, usage, or one-or-more units failed — the summary banner names each
  failed unit and the code its script returned, R6/R8); `2` refused (confirmation
  denied, or non-TTY without `--yes`).
- `10` and `22` belong to the bootstrap scripts' contract, unchanged: the CLI
  *consumes* 10 (performs the deferred restart + re-run) and *reports* 22 per unit in
  the summary — it never exits with either itself. A deferred seerr failure therefore
  surfaces as exit 1 with `seerr: 22` (or `1`) in the banner.
