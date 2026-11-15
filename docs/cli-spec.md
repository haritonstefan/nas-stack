# `nas` CLI — specification

Status: implemented.

One executable at the repo root: `./nas` — the operator interface for every unit's
lifecycle. It runs on the NAS, resolves its own directory (`dirname "$0"`) and operates
from there — the caller's cwd never matters. Root is required by the mutating verbs
(`install`, `destroy`, `recreate`); the read-only verbs run unprivileged. It refuses
politely, naming the verb, when run without root where root is needed — never failing
halfway through.

The CLI brings containers up and wires them together. It never talks to a service's API:
what lives inside each service is set up by hand (`docs/manual-setup.md`).

## Verbs

```
nas install      [unit...|all]    # bring units up (default: all)
nas destroy      [unit...|all]    # tear units down (plan + confirm; --yes to skip)
nas recreate     <unit...>        # destroy + install, per unit
nas status       [unit...]        # per-unit state table
nas logs         <unit> [--follow] [--since ...]
nas doctor       [unit...]        # health checks, read-only
nas help / nas <verb> --help
```

Unit arguments accept unit names, the two aliases (`core`, `arr`) and `all`. Unknown names
fail before anything runs, listing the valid set. Units are always processed in
`UNITS_ALL` order, whatever the argv order.

`pihole` is a valid unit name for the read-only verbs (`status`, `logs`, `doctor`); the
lifecycle verbs refuse it with a pointer to its standalone bring-up
(`docs/pihole-spec.md` §CLI coverage). `all` and the aliases never expand to a standalone
unit — only naming it explicitly earns the refusal.

`nas update <unit>` (bump an image pin, recreate) is a **reserved verb**: the name is
claimed so nothing else takes it, but it is not designed yet
(requirements.md §Open questions). Today it exits with the manual alternative: edit the
pin, then `nas recreate <unit>`.

### `nas install`

`--dry-run` prints every mutating command instead of running it, and skips the root
check. Per selected unit:

1. Preconditions: root, `docker` and `docker compose` (v2) present, the daemon reachable
   (a dry run only warns). `nas-net` exists — created if missing with a plain
   `docker network create nas-net`, default bridge driver, no options.
2. Env files: `shared.env` and each unit's own `.env` are created from their `.example`;
   an existing one is never overwritten (R5). Generated keys (`UNIT_GENERATED`) are
   written exactly once — even under `--dry-run`, into a `.env` that already exists
   (docs/units.md §Generated secrets).
3. Required values (`UNIT_REQUIRED`): any still empty stops the run before any directory
   or container is touched, naming each `unit:VAR` and pointing at the `.env` to edit.
   On a fresh clone this is where the first run ends — `ADMIN_PASSWORD` in `shared.env`
   is empty until the operator fills it in. A dry run warns and continues.
4. Host directories: `UNIT_DIRS` are mkdir'd + chowned, deduped across units;
   `UNIT_CHECK_DIRS` are only checked and warned about.
5. Config templates installed only when absent (Homepage's five files).
6. Compose up per unit: `-p nas-<unit>`, one `--env-file` per `UNIT_ENV_FILES` entry,
   `up -d`. When a container with the unit's name already exists under another compose
   project (or none), `up` would die on the name clash: the unit's `unit_adopt` hook runs
   instead, or without one the unit fails with the move-over command
   (`nas destroy <unit> --containers`, then `nas install <unit>`).
7. Summary: one line per unit with outcome; non-zero exit if anything failed, with the
   failures named in a banner. The units that did come up stay up.

### `nas destroy`

Tear-down is **plan, then confirm** — never silent, never a reflex y/N over data.

1. Build the plan: containers to remove, config directories to delete, what survives
   (`.env` files, download tree — R2, R3). Validate every delete path against
   `/volume2/docker` (R1) *before* showing the plan, so the plan is the truth. The
   default delete target is the parent of the unit's config dir; byparr has none.
2. Show the plan. `--dry-run` prints it and exits 0. No unit argument means `all` — same
   default as install; the plan+confirm gate is the protection, not the argument.
3. Confirm. With a TTY: typing the word `delete` when the plan deletes data, a y/N
   (default No) with `--containers`. Without a TTY, or on a refused confirmation: exit 2,
   nothing changed, unless `--yes` was given.
4. Offer (TTY, default yes) / accept a flag (`--save-logs`) to copy each unit's logs out
   before deletion — the evidence a wipe destroys (R9). Jellyfin's and Unmanic's logs
   live inside the config dir being deleted; this is the only copy. Saved to
   `/volume2/docker/_saved-logs/<UTC timestamp>/<unit>/`: the `docker logs` capture plus
   every `UNIT_LOG_PATHS` entry. That path is under the delete root but never a delete
   target.
5. Execute: `compose down --remove-orphans` per unit, then a by-name `docker rm -f` as a
   backstop for containers created outside the `-p` convention, then `nas-net` removal
   (a warning, not a failure, while anything is still attached), then the data.

Two more invariants:

- `--containers` — stop and remove containers, delete no data, lighter confirm.
- **The qBittorrent sparing rule.** In scope only via `arr`, `all` or the no-args
  default, qbittorrent is left entirely alone — still running, still seeding — unless
  `--wipe-qbittorrent`; naming it explicitly always includes it. When spared, `nas-net`
  is kept too (qbittorrent is still attached).

### `nas recreate <unit>`

`destroy` then `install` for each named unit, one confirmation up front covering both.
Exists because "tear down and recreate exactly one unit while it stays wired into the
stack" is the operation this whole per-unit architecture was built for; it deserves one
verb, not a remembered two-command incantation. Takes `--yes`, `--dry-run` and
`--wipe-qbittorrent`; there is no `all` default.

The unit comes back with the same network and the same API key (its `.env` survived).
With its data deleted, the service itself is blank and is set up again by hand.

If destroy succeeds and install then fails, `recreate` exits 1 and the banner says the
unit is **down**, not restored; re-running `nas install <unit>` resumes from there.

### `nas status`

Read-only, no root needed. Per unit, one row:

| Column | Source |
|---|---|
| unit | — |
| state | not-installed / created / running / exited from `docker inspect`; `unknown` when the daemon is unreachable as this user |
| env | `<unit>.env` missing, `empty:<VAR>` for the first empty `UNIT_REQUIRED` var, else ok |
| config | config dir absent / ok / `drift:N` templates differing from the repo copies (N4); `—` for units without a config dir |
| tile | TCP connect to the unit's web port on `127.0.0.1`: `up:<port>` / `down:<port>`. `—` for units without a port (byparr) and for standalone units the NAS cannot reach (pihole, macvlan) |

Template drift = byte inequality against the repo copy. Plain columns, same output with or
without a TTY. `nas status <unit>` adds detail (image, created, ports, mounts).

`status` is cheap by construction: filesystem and docker-socket checks plus one TCP
connect per tile — it never calls a service API.

### `nas logs <unit>`

`docker logs` on the unit's container, with `--follow`/`--since`/`--tail`/`--timestamps`
passed through. Works for pihole too.

### `nas doctor`

Read-only diagnosis of the known failure modes, so debugging starts from mechanism
instead of guesswork. A unit whose `.env` does not exist yet is reported as not installed
and skipped. Checks, per applicable unit:

- compose config renders (`docker compose config` with `UNIT_ENV_FILES`; the exit code
  is the check).
- container older than its env: `docker inspect .Created` earlier than the mtime of any
  file in `UNIT_ENV_FILES` → the "401 means stale container, not wrong key" trap,
  surfaced proactively with the recreate command.
- port collisions: every host port the unit publishes (from the rendered compose config)
  is either owned by its running container or free. A foreign listener is the failure,
  with the `ss` command that names it.
- socket access (homepage): pass = `stat -c %g /var/run/docker.sock` equals the GID in
  the container's `docker inspect .Config.User` (the primary-GID idiom — a `docker exec`
  session gets fresh credentials, so it proves nothing). On failure print the mechanism
  trail: `.HostConfig.CapDrop`/`.SecurityOpt`, PID 1's real `Groups:` from
  `/proc/1/status`, and `dmesg | grep -i denied` for AppArmor.
- `HOMEPAGE_ALLOWED_HOSTS` contains both the detected `hostname -s`.local and `LAN_HOST`,
  as literal entries (no wildcard/CIDR matching exists).
- jellyfin: `/dev/dri/renderD128` exists and its group matches `RENDER_GID` — without the
  device the container fails to start.
- pihole: container running, DNS answering via `docker exec` from inside the container
  — the NAS itself cannot reach `192.168.0.53` (macvlan), so the true LAN-side check is
  printed as a command to run from a client, never attempted locally.

Exit non-zero if any check fails; each failure states the mechanism and the fix.

## Language

The CLI is bash, and needs nothing on the NAS beyond docker and docker compose v2. Prompts
are plain `read`; the only TTY-dependent behavior is whether a prompt can be asked at all
(R6). Aesthetics never justifies a language switch.

## Code layout

```
nas                # entrypoint: arg parsing, verb dispatch
lib/               # shared plumbing: unit selection and aliases, env loading and key
                   # generation, compose invocation, R1 path validation, output and
                   # prompts — plus one cmd_<verb>.sh per verb
units/<unit>.sh    # one file per unit: everything the CLI knows about that unit
```

Core loads one unit file at a time and resets every declaration and hook between units,
so every unit file uses the same vocabulary — no per-unit prefixes. The values each file
carries are tabulated in `docs/units.md`; the contract is below. Everything is plain
strings and space-delimited word lists — no bash arrays.

### Declarations

- `UNIT_PROJECT` — compose project. Default `nas-<unit>`; pihole: empty (compose's own
  directory-based default).
- `UNIT_CONTAINER` — container name. Default `<unit>`.
- `UNIT_COMPOSE_FILE` — default `docker-compose.<unit>.yml`; pihole:
  `pi-hole/docker-compose.yml`.
- `UNIT_ENV_FILE` — the unit's own env file: created from its `.example` by install,
  where generated keys are written, checked by status and doctor. Default `<unit>.env`;
  pihole: `pi-hole/.env`.
- `UNIT_ENV_FILES` — ordered `--env-file` list, later wins. Default
  `shared.env <unit>.env`; pihole: empty (compose auto-reads `pi-hole/.env`).
- `UNIT_DIRS` — env-var **names**, not paths, resolved after env loading and deduped
  across units; each value is mkdir'd + chowned per docs/units.md. A `VAR/sub` entry
  means a subdirectory of that var's value (the downloads trio). The first entry is the
  config dir, whose parent is the default destroy target.
- `UNIT_CHECK_DIRS` — var names checked for existence (`VAR:w`: existence +
  writability) and warned about, never created: the media libraries are not the CLI's
  to make.
- `UNIT_TEMPLATES` — `source:DEST_VAR` pairs, newline- or space-separated, installed
  into the destination dir only when the file is absent (R5).
- `UNIT_GENERATED` — generated-key var names (32-hex recipe in docs/units.md); install
  generates each once.
- `UNIT_REQUIRED` — vars that must be non-empty: install stops and names them, status's
  env column checks them. In practice: the compose `${VAR:?}` fail-loud set.
- `UNIT_PORT` — tile TCP port; empty = `—` in status.
- `UNIT_PORT_VAR` — env var whose value, when set, overrides `UNIT_PORT`.
- `UNIT_LOG_PATHS` — log locations beyond `docker logs`, for `--save-logs`, in the
  `VAR/sub` form (jellyfin: `JELLYFIN_CONFIG_DIR/log`).
- `UNIT_STANDALONE` — set only by pihole: read-only verbs cover it, lifecycle verbs
  refuse it.

### Hooks

Optional functions, called with the env files already sourced (`set -a`) and cwd at the
repo root. Non-zero return marks the unit failed in the summary; it never aborts the
other units.

- `unit_templates` — replaces the default copy-when-absent template step. No unit
  defines it today.
- `unit_adopt` — called instead of `compose up` when a container with the unit's name
  already exists under another compose project (or none). qbittorrent only: keeps an
  existing container seeding — refuses unless its `/config` and `/downloads` mounts match
  the env, attaches it to `nas-net` if needed, starts it if stopped.
- `unit_destroy_plan` — extra delete targets on stdout, one per line, each still
  validated by core against R1. No unit defines it today.
- `unit_doctor` — unit-specific checks, mechanism + fix on failure: homepage (socket
  access, allowed hosts), jellyfin (render device), pihole (container + in-container
  DNS).

A unit with default declarations and no hooks is a near-empty file, and that is the
point: the common path lives once, in core. Cross-unit knowledge never lives in a unit
file — ordering, the aliases and the qBittorrent sparing rule stay in core (R7).

## Exit codes

The CLI exits with exactly three codes: `0` success; `1` any failure (precondition, usage,
a failed doctor check, or one-or-more units failed — the summary banner names each failed
unit and its return code); `2` refused (confirmation denied, or no TTY without `--yes`).
