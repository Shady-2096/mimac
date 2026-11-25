# Mimac — Phase-by-Phase Technical Plan

> The development sequence as concrete technical plans: *how, in what order, and when a phase is
> done*. Where this conflicts with `FEASIBILITY.md` (measured reality), the measurement wins.
>
> **Status legend:** ✅ done · 🟡 partially done / gate open · ⬜ not started

| Phase | Name | Status |
|---|---|---|
| 0 | Feasibility spike | 🟡 matrix complete; 1-hour pilot pending |
| 1 | Telemetry collector daemon | ✅ done |
| 2 | Identity resolver | 🟡 implementation landed; real-workflow gate pending |
| 3 | Live interface (SwiftUI app) | 🟡 implementation landed; workday gate pending |
| 4 | Historical storage | 🟡 implementation landed; 7-day gate pending |
| 5 | Battery attribution + Battery History screen | 🟡 implementation landed; calibration gate pending |
| 5b | Extended history (7 / 30 days) | 🟡 implementation landed; 30-day soak gate pending |
| 6 | Insights v2, baselines, efficiency, shell integration | ⬜ |
| 7 | Polish, packaging, launch | ⬜ |

---

## Phase 0 — Feasibility spike 🟡

**Goal:** prove every metric in Appendix A is readable on the development machine before any UI exists.

**What exists:** `Sources/mimac-spike/` probes all 22 metrics and writes `FEASIBILITY.md`.

**Key results (drive all later phases):**

- **Per-process energy counters are populated for a plain-user third-party caller** (`ri_energy_nj`,
  `ri_billed_energy`, `ri_penergy_nj` on 408/598 pids). The measured-first attribution model is viable —
  the project's single biggest unknown resolved in our favor.
- **P/E-core and QoS CPU splits work** (`RUSAGE_INFO_V6` perf-level fields). The heuristic pool can
  be QoS-weighted as designed.
- **Coalitions are unavailable** (`PROC_PIDCOALITIONINFO` rc=-2). Grouping must be reconstructed
  entirely from process tree + bundle IDs + responsible-pid heuristics. This makes the identity
  resolver (Phase 2) load-bearing for *all* grouping, not just dev workloads.
- **Gas gauge, SMC power rails, system-wide GPU, brightness, assertions, ports, thermal, memory
  pressure: all readable without privileges.** No privileged helper is needed for MVP.
- **Per-process GPU: unavailable** (as expected). Estimate-only forever; UI must label it.
- **Per-process network: estimable** via private `NetworkStatistics.framework` (symbols present,
  not exercised). Treat as post-MVP; fall back to socket existence via `proc_pidfdinfo`.

**Remaining work to close the gate:**

1. **One-hour unplugged pilot**: sample gas gauge + per-process energy deltas for
   ~60 min of normal work; require < 25% reconciliation error *after* modeling coarse residual
   buckets (display via brightness × screen-on time, idle SoC baseline). The 10-second pilot's 97.9%
   residual is expected on an idle system over a short window and is not the gate number.
2. **Resolve the counter question:** the spike shows `ri_energy_nj` and `ri_billed_energy` disagree
   wildly per process (e.g. Spotify Helper: 1621 J vs 0.055 J). Determine empirically which counter
   (or which sum, e.g. `energy_nj` for self-execution + billed for work done on the process's
   behalf) reconciles best against the gas gauge. Document the decision in `FEASIBILITY.md`; the
   Phase 5 attribution engine consumes exactly that counter.
3. Mark gate **GO** in `FEASIBILITY.md`.

**Definition of done:** gate marked GO with the pilot reconciliation number recorded.

---

## Phase 1 — Telemetry collector daemon ✅

**Goal:** productionize the spike into a persistent LaunchAgent that samples continuously whether or
not any UI is open.

**Delivered** (`Sources/mimacd/`, `Sources/mimacctl/`, `LaunchAgents/`, see `STAGE1.md`):

- `mimacd`: sampling daemon with launchd Mach service; adaptive rates (2 s visible / 5 s active /
  15 s idle-AC / 30 s idle-battery); monotonic-counter baselines with delta derivation.
- `mimacctl`: JSON CLI over XPC (`snapshot`, `health`, `watch` with visibility hints; hint dropped
  automatically on client XPC invalidation).
- Self-reporting overhead (own CPU + RSS in every sample) — the "self-row" foundation.
- Per-metric failure isolation: a failing probe lands in `errors`, never kills the daemon.

**Carry-forward obligations (owed to later phases):**

- Overhead budget enforcement: < 1% avg CPU, < 100 MB RSS for the daemon — assert in Phase 3+ once
  real UI clients hold the fast sampling rate.
- Sleep-gap handling (Appendix B #5): a wall-clock jump without samples must be recorded as a sleep
  period, never interpolated. Must be in place before Phase 4 persists anything.
- Event-driven wakes (app launch/quit, power-source change) on top of the interval timer.

---

## Phase 2 — Identity resolver 🟡 (implementation landed; acceptance gate pending)

**Goal:** convert raw pids into human-readable entities and workloads — the product's core moat.
Runs inside `mimacd`; the XPC snapshot starts returning *entities* instead of (only) raw processes.

**Implementation status (2026-07-13):** the daemon now has a reusable process-probe module, cached
identity evidence, stable hashed entity IDs, built-in and persisted user rules, bundle/signature and
parent-tree fallback, Git/package project discovery, entity/workload aggregation, and XPC rule CRUD.
The real-workflow acceptance gate (Slidekit + ChatAPI + Storefront, ≥ 90% correct with zero wrong
merges) remains open until those sessions are observed together.

### 2.1 Evidence collection per process

The daemon already samples pids; add an identity pass that gathers, per process (cheap fields every
sample, expensive fields cached until exec/start-time changes):

- Bundle metadata (bundle ID, display name, icon path) via `NSRunningApplication` / bundle lookup
  from the executable path.
- Code-signing identity (`SecCodeCopySigningInformation` — team ID, signing ID); cache by path.
- Executable path, args, cwd, parent chain — already probed in the spike (`ProcessProbes.swift`);
  port into a reusable module shared by `mimacd`.
- Git repository root: walk up from cwd looking for `.git` (bounded depth, cached per directory,
  invalidated on cwd change).
- Package metadata at the repo/cwd root: `package.json` name, `pyproject.toml`, `Cargo.toml`
  (read once, cache by path + mtime).
- Listening ports via `proc_pidfdinfo` socket enumeration (spike item 20).

### 2.2 Resolution pipeline (plan

Evidence combines in strict precedence — later sources refine, user rules always win:

1. User-defined rule (matched by executable path / command pattern / project dir / bundle ID /
   parent — whichever key the rule was saved with)
2. Rules database match (path/args/port patterns)
3. Bundle + signature identity (normal apps)
4. Parent-tree fallback (anonymous helpers like `1.0.207` inherit their nearest identified
   ancestor's entity, marked low-confidence)
5. Bare executable name (last resort, logged as a rule candidate)

Output per process: `entity ID` (stable across restarts — hash of the matched key, not the pid),
display name, kind (app / dev-server / agent / helper / system), project (from Git root or package
name), confidence, and `groupedAutomatically` flag for weak merges (plan — never silent).

### 2.3 Grouping into entities and workloads

- **Coalitions are unavailable (Phase 0)**, so grouping is fully ours: helpers fold under their
  parent app via process tree + shared bundle prefix / team ID; browsers become one expandable row.
- **Terminal disaggregation:** long-running children of terminal apps (node, python, codex, claude)
  resolve independently via cwd/args/repo and leave the terminal's row; the terminal keeps only its
  own cost (plan, no shell integration needed for this).
- **Workload sessions:** processes sharing a project root group into a project workload
  ("Storefront development") aggregating CPU/memory/energy across its members.

### 2.4 Rules database

- Local, versioned (ships with the app, updatable each release): recognition rules for Next.js,
  Vite, Astro, Python/uvicorn/Jupyter, Docker (VM as one entity), Postgres, Supabase CLI, Firebase
  emulators, Codex, Claude Code, VS Code/Cursor, Xcode, common Electron apps.
- Rule shape: match pattern (path/args/port) + display name + category + grouping behavior.
- Unrecognized processes logged locally as candidates for new rules (compounding moat,.

### 2.5 User corrections (daemon API now, UI in Phase 3)

- XPC endpoints: save/delete a naming rule (choice of matching key), list rules. Persisted to a
  local store so renames survive daemon restarts. Phase 3 builds the two-click UI on top.

**Definition of done:** on a real multi-project workflow — Slidekit + ChatAPI + Storefront
sessions running simultaneously — ≥ 90% of active processes resolve to a correct human-readable
entity with **zero wrong merges**; `mimacctl snapshot` shows named entities and workloads; weak
merges carry the `groupedAutomatically` flag.

---

## Phase 3 — Live interface 🟡

**Goal:** the SwiftUI app whose Live screen already beats Activity Monitor for the target user,
*before any history exists*.

**Implementation status (2026-07-13):** the SwiftPM `Mimac` app target now renders daemon-owned
system summaries, ranked entities, active project workloads, expandable process/raw evidence, and
the persisted rename-rule flow. Its XPC client holds the visibility hint only while active,
reconnects with exponential backoff, and offers launchd start/retry controls when the daemon is
offline. See `PHASE3.md`. The full-workday replacement and combined-overhead acceptance gate is
still open.

### 3.1 App target & plumbing

- New `Mimac` app target in `Package.swift` (or migrate to an Xcode project now — needed anyway for
  signing/notarization in Phase 7; decide here, once). SwiftUI, AppKit interop where needed.
- **XPC client layer:** connect to `mimacd`'s Mach service; hold the visibility hint while the Live
  screen is frontmost (exactly what `mimacctl watch` does today); reconnect with backoff on daemon
  restart; degrade to a "daemon not running — start it?" state instead of crashing.
- Snapshot decoding into a UI-side view model. The UI does **zero aggregation** — it renders what
  the daemon computed. If a number the UI wants requires computation, that computation moves
  into `mimacd` and onto the XPC surface.

### 3.2 Live screen

- **Top summary bar:** discharge watts (gas gauge), total CPU, system-wide GPU, memory pressure,
  disk + network throughput, thermal state, est. time remaining. "Higher than normal" qualifier is
  Phase 6 (needs baselines) — omit until then, don't fake it.
- **Ranked entity list:** entity / CPU / GPU / memory / power / disk / network. Default sort =
  power label. GPU column shows system-wide-derived estimates only with an "est." marker, or "—".
- **Status labels** (Idle → Very High + Abnormal) computed daemon-side from thresholds; each label
  may carry a one-line cause string when a rule matches (e.g. dev server rebuilding).
- **Expandable trees:** entity → child processes → Level-3 raw detail (pid, path, args, cwd, ports,
  start time, signature). Raw view is reachable but never the default.
- **Rename flow:** right-click → rename → pick matching key (app suggests one) → persisted via the
  Phase 2 daemon API → list re-resolves live.

### 3.3 Performance & self-credibility

- The app's own row (UI + daemon) appears in the list from day one.
- List diffing keyed by stable entity IDs so 2-second refreshes don't churn the whole table;
  target < 5% CPU for the UI process while frontmost, ~0 when hidden (drop visibility hint,
  daemon slows down automatically).

**Definition of done:** the app replaces Activity Monitor for a full workday; every simultaneous
project session appears as a correctly-named workload; renames stick across daemon restarts; UI +
daemon combined overhead within budget.

---

## Phase 4 — Historical storage 🟡

**Goal:** tiered time-series persistence in the daemon, powering past-hour / past-24 h queries.

**Implementation status (2026-07-13):** `mimacd` now exclusively owns a raw-SQLite WAL database,
persists entity and system samples, records sampled lifecycle/power/gap events, maintains idempotent
minute/hour/day tiers, and enforces retention plus a 200 MB cap. Entity, top-N, system timeline, and
storage-health queries are exposed over XPC and `mimacctl`. See `PHASE4.md`. The seven-day soak,
fill-rate validation, and final overhead gate remain open.

### 4.1 Store

- SQLite in WAL mode via **GRDB** (or raw sqlite3; decide once, Appendix B #3), owned exclusively
  by `mimacd`. The UI never opens the DB — history arrives over XPC like everything else.
- Schema (initial):
  - `samples_raw` — per-entity seconds-level rows (retention ~2 h)
  - `minutes` — per-entity 1-min rollups (retention ~7 d)
  - `hours` — per-entity hourly rollups (retention ~90 d)
  - `days` — per-entity daily rollups (retention: forever)
  - `entities` — stable entity registry (identity key → display name, kind, first/last seen), so
    history survives pid churn and daemon restarts
  - `system_samples` / rollups — gas gauge, totals, thermal, power source, screen state
  - `events` — sleep/wake, power-source changes, app launch/quit, charge sessions
- Counters stored as monotonic totals; deltas derived at query time; counter resets detected via
  process start time (Appendix B #4). Energy stored in **joules** end-to-end.

### 4.2 Aggregation & retention

- Rollup jobs inside the daemon: raw→minute each minute, minute→hour on the hour, hour→day at
  midnight; each job idempotent and resumable (a killed daemon re-rolls the incomplete window on
  restart).
- Eviction after each rollup tier; hard DB size cap (~200 MB) with oldest-tier eviction; `VACUUM`
  / incremental autovacuum strategy decided under measurement, not guesswork.
- Sleep gaps and charging periods recorded as first-class intervals — Phase 5 must exclude them
  from attribution windows.

### 4.3 Query surface

- XPC endpoints: entity timeline (range, resolution), top-N entities by metric over range,
  system-power timeline. These power the app-detail page's simple timeline (Phase 3 screen,
  Phase 4 data).

**Definition of done:** 7 uninterrupted days on the development machine; DB size within cap; rollups
verified against raw sums; queries for past-hour/past-24 h return in < 100 ms; daemon overhead
still within budget with persistence on.

---

## Phase 5 — Battery attribution + Battery History screen 🟡

**Goal:** implement the attribution model fully, validate it, then ship the Battery History screen (hour + 24 h).

**Implementation status (2026-07-13):** completed unplugged minutes are now gas-gauge integrated,
attributed into measured and heuristic entity energy plus explicit Display/System/Radios/Unattributed
buckets, persisted with confidence and foreground/background splits, and exposed over XPC, CLI, and
the new Battery History screen. The repeatable `mimac-calibrate` harness is included. The workload
matrix, Phase 0 counter decision, and ≥90% / <15% ship gate still require unplugged
30–60 minute runs. See `PHASE5.md`.

### 5.1 Attribution engine (daemon-side)

Runs per attribution window (aligned to minutes; windows on wall power or spanning sleep excluded):

1. **E_total:** trapezoidal integration of gas-gauge V×I over the window (never battery %).
2. **E_measured per entity:** deltas of the per-process energy counter chosen in Phase 0's counter
   study, summed across each entity's processes, converted from nJ. Marked `measured`.
3. **Residual = E_total − ΣE_measured**, split into: Display (brightness × screen-on time model),
   System, Radios, heuristic pool, and **Unattributed** (always allowed to be > 0).
4. **Heuristic pool split** across counter-less processes by QoS/cluster-weighted activity score
   S_i = w_p·T_P + w_e·T_E + w_g·G + w_d·D + w_n·N + w_w·W — no memory term; w_p ≫ w_e with actual
   ratios from calibration.
5. **Battery %:** E_i / (current FullChargeCapacity × V_nominal). Use aged capacity
   (`AppleRawMaxCapacity`), matching the menu-bar indicator.
6. **Confidence** (High/Medium/Low) attached to every figure and carried through XPC to
   the UI — an estimate rendering without confidence is a bug (Appendix B #6).

Persist per-entity per-window: joules (measured + heuristic separately), battery %, foreground vs
background split, confidence. Roll up alongside Phase 4 tiers.

### 5.2 Calibration harness (build first, keep forever)

- Repeatable script driving the workload matrix (idle, 1080p video, pinned compile loop, GPU
  export, Next.js with file churn, Claude Code/Codex session, large download, background Electron),
  30–60 min each, on battery, fixed brightness; `powermetrics` run manually as reference.
- Output per run: reconciliation error, entity ranking vs expected dominant consumer.
- **Ship criterion: dominant consumer ranked #1 in ≥ 90% of runs, total reconciliation error
  < 15%.** This harness is also the regression suite for every future macOS update (Appendix B #8).

### 5.3 Battery History screen (UI)

- Ranges: past hour, past 24 h. Table: entity / est. battery % / share of drain, plus Display,
  System, Unattributed rows — never a forced-100% app list.
- Row expansion: Wh, foreground/background split, active duration, avg + peak watts, confidence,
  dominant cause. Drain-rate timeline with charging periods shaded/excluded.
- Display rule everywhere: "**5.2%** · Confidence: High" — one decimal max, never "5.237%".

**Definition of done:** calibration ship criterion met and the numbers written down (they go on the
website in Phase 7); Battery History renders real data from daily use.

---

## Phase 5b — Extended history 🟡

**Goal:** 7-day and 30-day battery views on the hourly/daily tiers; retention hardening.

**Implementation status (2026-07-14):** schema v4 adds hourly/daily battery window and attribution
tiers, rolled directly from minute windows with exact local-day bucketing (correct in half-hour
timezones), worst-of confidence, preserved measured/heuristic and foreground/background splits, and
bucket rows. Queries union rolled tiers with a live tail so today/current hour always appear;
`mimacctl battery --days 7|30` and the app's 7 D / 30 D ranges with daily bars and hour drill-down
are live. Materialization now resumes from the last window (pre-sleep minutes are never lost) and
rollups use lower bounds that prevent partial re-rolls at retention edges. Fill-rate telemetry is in
`history health`. See `PHASE5B.md`. The 30-day continuous-data gate remains open.

- Attribution rollups: window-level → hourly → daily, preserving the measured/heuristic split,
  confidence (worst-of or weighted), and bucket rows.
- 7 d / 30 d range pickers on Battery History; daily bars with drill-down to hours.
- Retention/eviction hardening: fill-rate telemetry, cap enforcement under multi-week load, DB
  migration story (schema version table + forward migrations from day one).
- Edge cases: clock changes, timezone shifts, weeks containing sleep-heavy or charge-only days.

**Definition of done:** 30 days of continuous real data; DB within cap; 30-day query < 500 ms.

---

## Phase 6 — Insights v2, baselines, efficiency, shell integration ⬜

*(The 5 deterministic MVP insight rules of — forgotten dev server, abnormal background
consumer, top drain cause, sleep prevention, thermal explanation — need no baselines and should
land with Phases 3–5 as the daemon-side rule engine matures; this phase adds everything
history-dependent.)*

### 6.1 Baselines

- Daily daemon job: per-entity rolling **median + MAD** of hourly energy, CPU, background activity.
- Hard cold-start rule: no baseline insight until ≥ 7 days of data for that entity; UI shows
  "learning your Mac's normal" instead. Never a comparison from insufficient data.

### 6.2 Baseline-driven rules & efficiency

- Rules: "used N× more energy than usual today", background-waste regressions,
  drain-increased-after-X correlations (e.g. external monitor connected). Every insight links its
  evidence (the actual numbers and window).
- Efficiency metrics on the app-detail page: battery per active hour / per background hour, avg
  foreground vs background watts, today-vs-usual. Full spike timeline replaces the simple one.

### 6.3 Shell integration (optional, off by default)

- Hooks for zsh/bash/fish reporting session ID, cwd, command, terminal app, tab/pane, Git repo,
  command start/end to the daemon over a local Unix socket (auth: socket file perms, same-user).
- Enables per-command energy accounting and labels like "Ghostty — Codex / Storefront". One-command
  install, fully removable; **nothing else may depend on it**.

**Definition of done:** after 7+ days, baseline insights fire on real anomalies (validated by
deliberately inducing one, e.g. a runaway loop); no baseline insight ever renders pre-threshold.

---

## Phase 7 — Polish, packaging, launch ⬜

**Goal:** turn the working app into an installable, trustworthy release.

- **Packaging:** Xcode project with proper app bundle; daemon managed via `SMAppService`
  (replaces the dev plist in `LaunchAgents/`); Developer ID signing + notarization in CI;
  Sparkle with signed appcast. MAS is permanently out (sandboxing kills process enumeration).
- **Onboarding & permissions:** ask only for launch-at-login at first run; every later capability
  requested at the moment its feature is enabled, with plain-language justification.
- **Trust assets:** publish the attribution methodology write-up (model + calibration numbers)
  and the measured overhead benchmark.
- **Quality pass:** accessibility (VoiceOver on the entity list), keyboard navigation, charts
  polish (Swift Charts), menu-bar extra (watts + top consumer, nothing more), data export
  (user-initiated CSV/JSON), crash reporting strictly opt-in and content-free.

**Definition of done:** a stranger can download the DMG, install, and within 10 minutes see a
correctly-attributed battery history — with no step requiring the developer's help.

---

## Cross-phase invariants (checked at every phase boundary)

1. `FEASIBILITY.md` overrides assumptions; re-run the spike on every new macOS release.
2. All aggregation in the daemon; the UI renders, never computes.
3. Joules internally; Wh / % only at display. Monotonic counters + query-time deltas.
4. Sleep gaps are never drain; charging windows are never attribution windows.
5. Every estimate carries confidence into the UI. Unattributed is never forced to zero.
6. Per-metric failure isolation — one dead probe never degrades the rest.
7. Daemon budget: < 1% avg CPU, < 100 MB RSS, DB < 200 MB — measured by the app itself.
8. No private API becomes load-bearing without a defined fallback (Appendix A column 5).
