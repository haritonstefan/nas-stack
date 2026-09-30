# Comment & documentation audit

Status: applied in full on 2026-09-30, except the NAS-side verifications (the
jellyfin-bootstrap dry-run masking output and the `UNVERIFIED` note in
`jellyfin-bootstrap.sh`). The body below stays as the record of what was found; line
numbers are as of the audit (branch `main`, uncommitted per-unit split included), and
the policy the fixes followed is `docs/requirements.md` §Documentation policy.

Legend: **stale** = references retired structure (`arr.env`, tier layout,
`docker-compose.core.yml`) or contradicts current behavior; **verbose** = narrates WHAT
instead of WHY, or duplicates a fact that has a better home.

## Priority 0 — wrong, not just stale

1. **`jellyfin-bootstrap.sh` L88-90 — behavior, not wording.** Dry-run `api()` prints
   request bodies unmasked, so `--dry-run` output includes the `ADMIN_PASSWORD` in the
   `POST /Startup/User` body. The other three scripts mask dry-run output on purpose ("a
   dry run is the thing most likely to be pasted"). Fix the code, then the docs.
2. **`prowlarr.env.example` L6-9.** Claims losing `PROWLARR_API_KEY` breaks Configarr —
   Configarr reads only the Sonarr/Radarr keys. Copy-paste from sonarr/radarr's block.
3. **`apollo-nas-stack-spec.md` L533.** "Rotating [the shared password] means re-running
   the bootstraps that seed each" — probably false: `qBittorrent.conf` installs only when
   absent, jellyfin-bootstrap never changes an existing password, arr-bootstrap skips an
   existing download client. Rotation currently has *no* working path; say that instead
   (and it feeds the wizard spec's Future section).
4. **`core.env.example` — whole file.** Still tracked in git for a unit that no longer
   exists; its contents were split into `shared.env.example` / `homepage.env.example`.
   Delete it. (Also: a leftover gitignored `arr.env` exists on the workstation disk —
   local cleanup, not a repo change.)
5. **`qbittorrent-config/qBittorrent.conf` L6-7.** Placeholder list names 5 tokens; the
   template has 7 (`__WEBUI_PORT__`, `__WEBUI_USER__` missing) and `up.sh` substitutes
   all 7.
6. **`homepage-config/widgets.yaml` L5.** Names `docker-compose.core.yml`; should be
   `docker-compose.homepage.yml`.

## Priority 1 — stale history in load-bearing files

- **`arr-bootstrap.sh` L55-57**: describes an `arr.env`/`jellyfin.env` split in
  seerr-bootstrap that no longer exists; "all four" at L89 vs five `have_*` flags.
- **`seerr-bootstrap.sh` L28-29, L244-246**: `arr.env` history; "the old code asserted…"
  changelog.
- **`configure.sh`**: L692-698 and L867-869 mention `arr.env`/tier history; functions
  `write_tier`/`walk_tier` are tier-named but operate on single files; L255-256
  `ARR_CONFIGURE_SEERR` branch in `validator_for` is unreachable; L29-30 usage text
  omits `SEERR_API_KEY` and the bootstrap-minted Jellyfin values.
- **`down.sh`**: L22-37 split-era narration (qBittorrent keep rule stated 3×: L25-37,
  L90-92, L142-143); `TIER_PROFILES` variable name; L61/L80 tier-shaped
  `core|jellyfin|arr` handling.
- **`up.sh`**: L549-551 "old core-first ordering" (order actually comes from
  `UNITS_ALL`); L669-673 "what used to happen" changelog.
- **`jellyfin-bootstrap.sh`**: L27-28 ties `--scan-only` to base-URL restarts only
  (up.sh runs it on every bootstrap when `JELLYFIN_SCAN_ON_BOOTSTRAP=1`); header L2-5
  omits the Homepage key/task-id minting; L7 "fresh (never-configured)" contradicts L4
  "idempotent"; L13/L47 default `JELLYFIN_URL` (`apollo.local`) disagrees with
  `jellyfin.env.example` (`127.0.0.1`); L534-536 `UNVERIFIED` note — verify on the NAS
  and delete, or keep deliberately.
- **`reference/README.md`**: L83 attributes the Seerr facts to `arr-bootstrap.sh`
  (now `seerr-bootstrap.sh`); refresh curl and 12.0.0 trap each written twice
  (L12/L50, L18-25/L46-47).
- **`TODO-healthchecks.md`**: L3 "either stack" tier wording; L20 scope covers only
  Homepage/Jellyfin/Seerr, ignoring the arr units, ofelia, configarr (n/a).
- **`shared.env.example` L35-38**: "the same way it used to prompt…" history.
- **`jellyfin.env.example` L39-42**: "…anymore" history pointer, shrink to one line.
- **`apollo-nas-stack-spec.md`**: L322 "only externally-reachable service in `core`" —
  tier wording *and* no longer true; L399-402 self-contradicting parenthetical;
  L405-410 `arr.env`/`JELLYFIN_ADMIN_USER` changelog; L87, L474, L496, L526, L534
  "now/no longer/anymore" narration; base URL explained twice (L123-128, L175-176).
- **`CLAUDE.md`**: L56-59, L67-68, L204, L208, L224, L227, L228 (names `arr.env`)
  history narration; L230 DLNA bullet sits under `## Arr` but is about Jellyfin;
  L181 bootstrap feature list incomplete; L128 restart ordering wrong (happens after
  the Jellyfin bootstrap, not last); L173 "minimal comments" contradicted by
  `docker-compose.configarr.yml` (0.89 comment ratio).

## Priority 2 — verbosity and repetition

Same fact written N times — pick the home, keep one copy, others become at most a
one-line pointer:

| Fact | Copies | Keep in |
|---|---|---|
| Byparr GET-only / FlareSolverr implementation | `arr-indexers.sh` L198-206, header L2-4, `docker-compose.byparr.yml` L2-7, CLAUDE L208 | byparr compose (tag rule stays in arr-indexers) |
| configarr's 4 `--env-file` / no-copy reasoning | compose L15-17, `configarr.env.example` L5-8, `arr-bootstrap.sh` L480-488, `config.yml` L4-7, CLAUDE L144-147 | configarr.env.example |
| Seerr → Jellyfin via LAN_HOST | `seerr-bootstrap.sh` L100-103, `seerr.env.example` L17-19, compose L4-6, CLAUDE L226, spec L384-386 | spec |
| seerr exit-code/initialize-still-runs rationale | `seerr-bootstrap.sh` L34-37, L425-428, L515-517 | header only |
| "not piped" rationale | `up.sh` L582-583, L649-651, L686-688 | first occurrence |
| single-quote escaping | `up.sh` L373-376, L396-400 | first occurrence |
| dry-run-mask + "failing status is the point" | copy-pasted across all four scripts' `api()` | `lib-http.sh` (or accept as idiom, one line each) |
| qBittorrent stop-vs-remove reasoning | `qBittorrent.conf` L21-27, CLAUDE L203-205, spec L429-450 | spec (conf keeps the enum-string trap) |
| downloads/hardlinks trade | `shared.env.example` L24-30, sonarr compose L25-27, CLAUDE L202, spec §6 | spec |

Plus single-file verbosity: `up.sh` L195-204 (per-template walkthrough repeating each
template's own header), L158-161, L326-330, L534-538; `arr-bootstrap.sh` L85-92
(narrates the env-file gating — two lines suffice), L514-516 (repeats compose),
L221; `jellyfin-bootstrap.sh` L256-263; `docker-compose.ofelia.yml` L10-12 (repeats
`ofelia.ini`); `lib-http.sh` L2-4 parenthetical; `byparr.env.example` 4 lines for an
empty file.

## Priority 3 — CLAUDE.md ↔ spec deduplication

~18 topics duplicated nearly verbatim. Direction per requirements.md policy: the spec
owns reasoning/design, CLAUDE.md owns operator/agent rules and traps, each side keeping
at most a one-line pointer to the other. The full topic table from the audit:

| Topic | Better home | Other side keeps |
|---|---|---|
| Running commands + compose block + configarr flags | CLAUDE.md | spec: one sentence of reasoning |
| down.sh invariants (.env/download survival) | CLAUDE.md | spec: table row |
| nas-net script-managed / Jellyfin off it | spec §4 | CLAUDE: 1-line debugging warning |
| Docker socket DAC mechanism | spec §7 | CLAUDE: diagnostic checklist (CapEff, /proc/1/status, dmesg) |
| HOMEPAGE_ALLOWED_HOSTS rules | spec | — (also in homepage.env.example) |
| Jellyfin host networking | spec §5 | CLAUDE: "never add ports:" |
| Base URL empty, asserted last | spec (once) | CLAUDE: 1-line trap |
| DLNA plugin install flow | spec §5 | CLAUDE: casing + 204 traps, moved to ## Jellyfin |
| Copies-not-hardlinks | spec §6 | — |
| Seed cap / arr deletion pairing | spec | CLAUDE: "do not fix back" + enum trap |
| qBittorrent PBKDF2 seeding | spec | — |
| API keys load-bearing | spec | CLAUDE: "401 = stale container" tip |
| Seerr identity/wiring | spec | — |
| seerr-bootstrap ordering + deferred failure | CLAUDE.md | spec: table row |
| Per-service structure + aliases | CLAUDE.md L7-34 | spec: table row L526 only |
| Host facts | spec §1/§6 | CLAUDE: behavior-affecting facts only |
| shared.env single-consumer rule | CLAUDE.md | — |
| Byparr replaces FlareSolverr | spec (reason) | CLAUDE (wiring) |

## Suggested execution order

1. P0 items (one small commit each; #1 is a code fix and needs a NAS-side dry-run
   check of the masked output).
2. P1 stale sweep, per file.
3. P2 dedup, per fact.
4. P3 CLAUDE.md ↔ spec restructure — last, in one deliberate pass, because both files
   change shape at once. Do it after (or together with) the CLI spec landing, since the
   Running/up.sh/down.sh sections will be rewritten by the migration anyway
   (`docs/cli-spec.md` §Migration, phase 3).

Open notes, not defects: `reference/README.md` L71-72 recipe uses `python3`/`/tmp`
while the repo has been shedding python3 deps — decide if doc recipes are exempt;
`arr-indexers.sh` L89 "opt-in" claim vs `prowlarr.env.example` L32 shipping a default
tracker list — decide which is intended.
