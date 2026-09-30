# `nas configure` — configuration wizard specification

Status: draft, deliberately shallow. The identity model will be designed in depth later;
this spec fixes only the contract the rest of the CLI relies on, and marks where the
future work plugs in.

## Purpose

Fill in `shared.env` and each selected unit's `.env` interactively, before
`nas install`, so install itself stays fully non-interactive. Successor of
the retired `configure.sh`; same contract, gum front-end.

## Contract (fixed now)

- **W1 — Wizard is optional.** `nas install` works without it if the `.env` files were
  filled by hand or already exist. The wizard is convenience, not a gate.
- **W2 — Never touches generated secrets.** The per-unit API keys are `install`'s
  business, generated once. The wizard neither shows nor regenerates them.
- **W3 — Detect, then ask.** Host facts that can be read are read and offered as
  defaults, not asked blind: TZ, `DOCKER_GID`, render GID, LAN IP, hostname
  (§Detection). Volume paths are prompted, not detected — with an existence warning
  only, since a first run may predate the dirs. Everything detected is still
  confirmable — detection can be wrong on a changed host.
- **W4 — Shared values asked once.** The wizard's core job. One pass over `shared.env`
  (identity, host facts), then per selected unit only that unit's own values.
- **W5 — Stage and confirm per file.** Nothing is written until the diff for that file is
  shown and accepted. Re-running shows current values as defaults; it edits, never resets.
- **W6 — Secrets prompted masked** (gum input `--password`), never echoed, never logged.
- **W7 — Non-interactive degradation.** Without a TTY the wizard exits 1 with a pointer
  to the `.example` files — it is the one verb allowed to require a terminal, because its
  whole job is asking.

## The shared identity (the part to deepen later)

Today's model, restated as the wizard's v1 scope:

- One `ADMIN_USER` / `ADMIN_PASSWORD` pair in `shared.env`.
- Consumers: Jellyfin (admin account, created by its bootstrap), qBittorrent (WebUI
  credential, seeded as a PBKDF2 hash at first boot), Seerr (admin via `/auth/jellyfin` —
  no credential of its own).
- The wizard asks for it once, with a strength nudge (a warning below 12 characters)
  but no enforcement (single-user LAN).

### Future (reserved, not designed)

Space the v1 wizard must leave open — meaning: no design decision below is made yet, but
nothing in v1 may make these impossible without a rework:

- **Rotation.** There is no working path today: `qBittorrent.conf` installs only when
  absent, jellyfin-bootstrap never changes an existing password, arr-bootstrap skips an
  existing download client. A future `nas configure --rotate-identity` would build one. Implication for v1: the wizard keeps identity in `shared.env`
  as the single source of truth and never lets a consumer hold a value the file doesn't.
- **Per-app divergence.** A future option to give one app its own credential (e.g.
  qBittorrent separate from Jellyfin). Implication for v1: consumers reference the shared
  pair by sourcing `shared.env`, not by copies baked into unit files at wizard time.
- **More of the identity** (email for Jellyfin user, additional non-admin users for
  family members in Jellyfin/Seerr). Implication for v1: none — just noted.

When this gets designed, it replaces this section in place.

## Flow (sketch, not binding)

1. Unit selection: gum multi-choose over the twelve units + aliases, default all,
   or taken from argv. Aliases expand and dedupe silently against explicit names.
2. Host facts: detected values shown, confirmed or edited.
3. Identity: user + masked password (+ confirmation entry).
4. Per unit, in a fixed order: only the values that unit's `.env.example` defines and the
   shared pass didn't cover.
5. Per file: staged diff → confirm → write.
6. Exit summary: which files were written, and the next command (`sudo ./nas install …`).

## Detection

Each probe degrades to empty — the example default then stands; never fatal. A
detected value is offered only while the current `.env` still equals the example
default: a hand-changed value is never overridden by a probe.

| fact | var | probes, in order |
|---|---|---|
| timezone | `TZ` | `/etc/timezone`; else `readlink /etc/localtime` stripped to the zone name |
| docker group | `DOCKER_GID` | `getent group docker`, field 3 |
| render group | `RENDER_GID` | `stat -c %g /dev/dri/renderD128`; else `getent group render` |
| LAN IP | `LAN_HOST` | `ip route get 1.1.1.1` → the `src` field; else first word of `hostname -I` |
| hostname | seeds `HOMEPAGE_ALLOWED_HOSTS` | `hostname -s` + `.local` |
| local subnet | `JELLYFIN_LOCAL_SUBNET` | derived, not probed: LAN IP with last octet → `.0/24` |

## Writing

- **In-place line edit, never whole-file regeneration**: the first `NAME=` line is
  replaced, preserving order and comments; a name the file lacks is appended under
  an `# --- added by configure ---` marker. Hand-added content survives (W5).
- Values are quoted for dual parsing (shell `source` + compose dotenv): bare when
  matching `^[A-Za-z0-9_./:@,+=-]*$`, else single-quoted with close-escape-reopen.
  Install's env writer uses the identical rule — the two must stay
  quoting-equivalent.
- Nothing touches disk before the per-file review (Enter = write · edit one item ·
  skip file · quit). A missing `.env` is created from its example only at write
  time; Ctrl-C removes staged temp files and reports what was already written.
- Files carrying secrets get `chmod 600`.
- Drift against the example: vars new in the example are staged at the example
  default; vars the example dropped are warned about, never deleted.

## Question sourcing

Hybrid, and the split maps onto the CLI's unit files (cli-spec §Code layout):

- **Core owns the cross-unit passes**: the shared identity and host facts; the
  media directories asked **once** and staged into every consumer (jellyfin's
  `MEDIA_*_DIR` and sonarr/radarr/lidarr's `ARR_*_DIR` from the same answer); and the
  generic per-unit walk over `.env.example` (file order; the contiguous `#` block
  above a var is its help text; `UNIT_GENERATED` vars are never staged, shown, or
  cleared — W2).
- **`unit_configure` hooks own what needs logic**: homepage's allowed-hosts
  seeding, jellyfin's server/subnet values, prowlarr's indexer dialogs (enable +
  credentials per private tracker; the `ARR_INDEXER_<NAME>_*` key derivation must
  match `arr-indexers.sh` exactly — uppercase, every non-alphanumeric → `_`).
- `ADMIN_PASSWORD` is a chosen credential, not a generated secret: re-runs offer
  keep-or-replace, masked and confirmed twice (W6).

## Validation

Applied by variable-name pattern on every entry, including review-time edits:
`*_PORT` 1–65535 · `PUID`/`PGID`/`UMASK`/`*_GID` numeric · `*_DIR`/`*_ROOT_FOLDER`
absolute path without `..` · `JELLYFIN_LOCAL_SUBNET` real IPv4 CIDR (octets ≤ 255,
mask ≤ 32) · `HOMEPAGE_ALLOWED_HOSTS` comma-separated hostnames/IPs, no wildcards
or CIDR (a bare `*` accepted with a "disables the check" warning) · 0/1 toggles ·
indexer lists CSV without spaces. A `*_CONFIG_DIR` or `DOWNLOADS_DIR` outside
`/volume2/docker` warns that destroy will refuse to clean it (R1).
