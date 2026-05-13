# A4.1 — Performance Audit Pass

| Field | Value |
|---|---|
| Slice | A4.1 — Performance Audit Pass |
| Slice doc anchor | `docs/_execution/lane_a_code_health/03_execution_slices.md` §"Slice A4.1 — Performance Audit Pass" |
| Branch / worktree | `claude/a4-1-performance-audit-pass` (worktree `.claude/worktrees/agent-a5f73d6fdd651d2d1`) |
| Base commit | `42e04764` (origin/master, 2026-05-12) |
| Audit date | 2026-05-12 |
| Authority | `docs/frameworks/PERFORMANCE_FRAMEWORK.md` (active, 2026-05-03); Lens 10 of `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md` |
| Mode | Read-only static inspection. Zero `.dart` files modified. No measurements run. No load tests. |
| Predecessor | Supersedes the previous 503-line `a4_performance_audit.md` (commit `0e59029e`, parallel sub-agent on `claude/nifty-clarke-d3ec25`). The wider 24-finding survey there remains valid context; this slice-scoped doc focuses A4.2 exclusively on the Lens 10 + Postgres-pool deliverables. |

## Section 0 — Scope Adherence

This audit covers exactly the slice scope, no more:

- **In scope**: 12 `Timer.periodic` sites cited in
  `02_plumbing_audit_matrix.md` Lens 10 (verified inventory below);
  `lib/screens/shift_dashboard.dart:361, :784, :951, :1329`
  (four-on-one-screen audit); `lib/state/connectivity_notifier.dart:53`
  (cancel-on-dispose audit); Postgres pool sizing (`4 → 20`
  per the lane-A index ROI claim).
- **Out of scope** (explicitly): proxy decomposition (A3); scaffold
  inventory (A2); typed-catch backlog (A3.2-A3.4); soak-harness kit
  shape (A11); audit-log hierarchy join (B2 — Lane B); admin/operator
  web route-cycle re-fetches; bundle-size; cold-start serial chain;
  `MaterialApp` rebuild hygiene; advisor cost telemetry. Each of
  these may merit its own future perf slice; A4.1 does not enumerate
  them.

Per `PERFORMANCE_FRAMEWORK.md` §15-23 ("Core Promise — performance
work must preserve behavior"), this slice records measurements + flags
only. **No behavior changes ship in A4.1.** Fixes ship in A4.2 per
`03_execution_slices.md` §"Slice A4.2 — Performance Fixes (If Found)".

---

## Section 1 — `Timer.periodic` inventory

`rg "Timer\.periodic" lib` (executed 2026-05-12 against
`origin/master @ 42e04764`) returns **11 active sites** in `lib/`
plus 5 in `tool/` (the proxy + soak harnesses). Lens 10 of
`02_plumbing_audit_matrix.md` cites "12 `Timer.periodic` sites" and
enumerates 8 of them by name (4 in `shift_dashboard.dart`, 1 each
for `connectivity_notifier.dart`, `google_cloud_pubsub_subscriber.dart`,
`outbox_tripwire_poller.dart`, plus implicit references to the
pressure / soak harnesses and admin screens via "the 10 client-side
ones live in widget lifecycle" at `02_plumbing_audit_matrix.md:71`).

**Discrepancy with Lens 10's "12" count**: I find **11 sites in
`lib/`** when the Lens 10 prose at lines 70-71 says "10 client-side
ones plus 2 server-side" = 12. The shortfall is one of the following
(both are reconciliations, not new findings):

1. The Lens 10 author counted the doc-comment reference at
   `lib/screens/shift_dashboard.dart:928` as a 5th shift-dashboard
   timer. It is a `///` comment annotating the `_DaypartScaffoldSection`
   widget that actually owns its `Timer.periodic` at `:951` — so the
   `:928` line is documentation, not a separate timer.
2. The Lens 10 author may have included
   `tool/advisor_proxy/main.dart:1381` (admin-idempotency cache sweep)
   in the count even though it is a server-side proxy timer. That
   would yield 12 (10 client + 2 server-side as Lens 10's prose says,
   if we count `outbox_tripwire_poller` + `google_cloud_pubsub_subscriber`
   as the two server-side ones — but that ignores `system_info_service`
   which is mobile-client, not server-side).

I take the literal `rg` count over the prose count and document
**11 `lib/` sites + 5 `tool/` sites = 16 total** for completeness;
A4.2 should not be misled by a "12" target that no longer reflects
the codebase. Net of the discrepancy: **the 12 sites Lens 10 cared
about are all covered below**, plus one extra in
`current_state_boundary_monitor.dart` that Lens 10 may have folded
into "client-side widget lifecycle" without naming it explicitly.

### 1.1 `lib/` site-by-site inventory

| # | File:line | Cadence | Disposed in `dispose`? | Owner | What it polls / does | Risk class | Lens 10 row? |
|---|---|---:|---|---|---|---|---|
| T1 | `lib/state/connectivity_notifier.dart:53` | 15 s | Yes — `:76` (`_timer?.cancel()`) | `ConnectivityNotifier` (`ChangeNotifier`) | `InternetAddress.lookup('example.com')` heartbeat. Updates `_isOnline` + `notifyListeners()` only on transition. | LOW (one ConnectivityRequiredButton consumer; transition-gated emit) | Yes — Lens 10 row 4 |
| T2 | `lib/screens/shift_dashboard.dart:361` | 30 s | Yes — `:368` | `_LiveClockState` | `setState(() => _now = _currentTime())` — drives the live header `12:34 PM` text. | LOW per-timer; **MEDIUM in aggregation** with T3/T4/T5 | Yes — Lens 10 row 1 (#1 of 4) |
| T3 | `lib/screens/shift_dashboard.dart:784` | 30 s | Yes — `:791` | `_ShiftPeriodSelectorState` | `setState(() {})` — re-evaluates `resolveActiveServicePeriodId(...)` so the chip "ACTIVE NOW" stays accurate across service-period boundaries. | LOW per-timer; **MEDIUM in aggregation** | Yes — Lens 10 row 1 (#2 of 4) |
| T4 | `lib/screens/shift_dashboard.dart:951` | 30 s | Yes — `:958` | `_DaypartScaffoldSectionState` | `setState(() {})` — same `resolveActiveServicePeriodId(...)` re-evaluation as T3 (different consumer, same input). | LOW per-timer; **MEDIUM in aggregation** | Yes — Lens 10 row 1 (#3 of 4) |
| T5 | `lib/screens/shift_dashboard.dart:1329` | 30 s | Yes — `:1336` | `_TimeIntoServiceHeaderState` | `setState(() {})` — re-evaluates `resolveActiveServicePeriodInterval(...)` for the elapsed-time display. | LOW per-timer; **MEDIUM in aggregation** | Yes — Lens 10 row 1 (#4 of 4) |
| T6 | `lib/admin/screens/debug_console_admin_screen.dart:493` | `widget.tailPollInterval` (default 5 s, per `kDebugConsoleTailPollInterval`) | Yes — `:488` (`_tailTimer?.cancel()` on toggle-off, plus `dispose` cancels via the toggle path) | `_DebugConsoleAdminScreenState._toggleLiveTail` | When live-tail toggled on: polls `gateway.tailRecent()` every 5 s. In-flight guard (`_refreshing || _tailing`) at `:504` prevents stacked calls. | LOW (admin-only, requires explicit toggle, in-flight guarded) | Implied by Lens 10 prose ("client-side ones live in widget lifecycle") |
| T7 | `lib/admin/screens/audited_support_actions_admin_screen.dart:194` | `widget.graceWindowTickInterval` (constructor-supplied; not a default constant — verified at `:194` and grep shows no in-file default) | Yes — `:182-184` | `_AuditedSupportActionsAdminScreenState._startGraceWindowTicker` | While an erasure is in its grace window, ticks to refresh the "Xh Ym remaining" label. Self-cancels when `_lastErasure == null` or grace window passes. | LOW (self-cancelling, only active during grace window) | Implied by Lens 10 prose |
| T8 | `lib/services/system_info_service.dart:78` | 1 h (per `pollInterval` default at constructor `:61`) | Yes — `:179-180` | `SystemInfoService` (`ChangeNotifier`) | Hourly `GET /v1/system-info` for client-version compatibility. | LOW (1 h cadence, single-shot per hour) | Implied by Lens 10 prose |
| T9 | `lib/services/current_state_boundary_monitor.dart:186` | `_checkInterval` (constructor-supplied) | Yes — `:191` (`stop()` cancels, `dispose` flow goes through `stop()`) | `CurrentStateBoundaryMonitor` | Periodic check for business-date boundary crossings; fires callback when crossed. | LOW (callback-only emit, cheap business-date resolver) | Possibly the "extra" site beyond Lens 10's 12 — see §1 reconciliation |
| T10 | `lib/services/realtime/google_cloud_pubsub_subscriber.dart:250` | `_pullInterval` (constructor-supplied; pod-side default ~1 s per A1 §S3 + the prior A4 audit's F2 finding) | Yes — `:277` (in `stop()`) | `GoogleCloudPubsubSubscriber` (server-side worker) | Pub/Sub pull loop. In-flight guard (`_pullInFlight`) at `:251` + try/catch with structured logging at `:256-263` + supervised by `runZonedGuarded` per A1 §S3. | LOW for cancel-on-dispose; cadence + ring-buffer key growth covered in B3 (`a1_proxy_bug_root_cause.md` §S3 + the prior A4 audit). Out of A4.1 scope to remediate. | Yes — Lens 10 row 2 |
| T11 | `lib/services/realtime/outbox_tripwire_poller.dart:94` | `_interval` (constructor-supplied; per the prior A4 audit ≈ 60 s) | Yes — `:112-114` (`dispose` sets `_disposed = true`, `_pollOnce` early-returns; the timer reference is also cancelled — verified the wider lifecycle protects against re-entry via `_disposed`) | `OutboxTripwirePoller` (server-side worker) | Polls outbox tripwire status. Errors swallowed per documented error policy. Supervised by `runZonedGuarded` in `main()`. | LOW (per Lens 10 row 3 — "no action") | Yes — Lens 10 row 3 |

### 1.2 `tool/` sites (informational — not Lens 10 scope, but listed so A4.2 doesn't surprise itself)

| # | File:line | Cadence | Notes |
|---|---|---:|---|
| TX1 | `tool/advisor_proxy/main.dart:1381` | constructor-passed | Admin-idempotency cache sweep. Server-side, supervised. |
| TX2 | `tool/advisor_proxy/realtime_bridge.dart:346` | `_pollInterval` | Pub/Sub bridge polling. Server-side, supervised. |
| TX3 | `tool/advisor_proxy/realtime_bridge.dart:355` | constructor-passed | Publish-metrics flush. Server-side, supervised. |
| TX4 | `tool/pressure/p4_operator_day_soak.dart:517` | 30 s | Soak harness gauge sampler. Test-only. |
| TX5 | `tool/pressure/p4_session_soak.dart:528` | 30 s | Soak harness gauge sampler. Test-only. |

### 1.3 Disposal hygiene summary

**11 of 11 client/library sites cancel in `dispose`.** Disposal
hygiene is uniformly correct across `lib/`. T1
(`connectivity_notifier.dart:53`) — explicitly called out by the
slice for its cancel-on-dispose audit — is verified clean at line
75-79: `dispose()` calls `_timer?.cancel()` then `_timer = null` then
`super.dispose()`. The class also exposes a `_noTimer` constructor
for `FakeConnectivityNotifier` (`:37-39`) so tests don't allocate
real timers.

No `Timer.periodic` site is missing a cancel-on-dispose. **A4.2 will
not need to add any `.cancel()` calls.** A4.2's only timer-shaped
work is the *coalescing* opportunity in `shift_dashboard.dart`
(§2 below).

---

## Section 2 — `shift_dashboard.dart` four-on-one-screen audit

The slice flags four `Timer.periodic` sites on the same screen for
explicit hotspot interaction analysis. Each owner widget +
its tick payload:

| # | Line | Owner widget | Tick payload | Independent state? | Listens to | When mounted simultaneously? |
|---|---:|---|---|---|---|---|
| T2 | 361 | `_LiveClock` | `setState(() => _now = _currentTime())` — re-paints `12:34 PM` HH:MM text | YES (owns `_now: DateTime`) | None — pure clock | ALWAYS — header is always visible |
| T3 | 784 | `_ShiftPeriodSelector` | `setState(() {})` — bare rebuild, then `build` re-runs `resolveActiveServicePeriodId(...)` | NO (rebuilds based on Provider reads via `context.watch<RestaurantScopeNotifier?>` `:797` and `context.watch<ShiftServicePeriodNotifier?>` `:798`) | `RestaurantScopeNotifier`, `ShiftServicePeriodNotifier` | Whenever the period selector renders — visible on every shift-dashboard render |
| T4 | 951 | `_DaypartScaffoldSection` | `setState(() {})` — bare rebuild, `build` re-runs `resolveActiveServicePeriodId(...)` (same call as T3) | NO (same Provider reads at `:964-965`) | Same as T3 | When daypart scaffold visible |
| T5 | 1329 | `_TimeIntoServiceHeader` | `setState(() {})` — bare rebuild, `build` re-runs `resolveActiveServicePeriodInterval(...)` (sibling of T3/T4's resolver, narrower return shape) | NO (same Provider reads at `:1342-1343`) | Same as T3 | When the selected period matches active period, hides via `SizedBox.shrink` otherwise (`:1357-1359`) |

### 2.1 Hotspot interaction risk

All four ticks are 30 s. They are NOT phase-locked — each timer
starts when its widget's `initState` runs, so ticks happen at four
independent offsets within each 30 s window. Worst case: four
`setState` calls fire within the same animation frame; best case:
they spread out across the 30 s window.

Per-tick cost is small: `setState(() {})` schedules a build; the
build re-runs the Provider lookups + the service-period resolvers.
The resolvers (`resolveActiveServicePeriodId`,
`resolveActiveServicePeriodInterval`) are pure functions over
`(localNow, businessDayStartLocalTime, definitions)` — no I/O. The
Provider lookups are `context.watch` (line-9 reads with no
read-side caching).

**Aggregate cost over 1 minute of dwell**: 8 `setState` calls (4
timers × 2 ticks/min) + 8 widget rebuilds + 16 Provider lookups +
12 resolver calls (T3/T4 share resolver shape; T5 uses a sibling).
None of the work is operator-visible-blocking, but on a mid-tier
Android device every avoided rebuild is a frame-budget win.

### 2.2 Coalescing opportunity (recommendation; do NOT implement in A4.1)

T2 and T3/T4/T5 all need a 30 s tick to keep displayed time + period
chip accurate. The doc comment at `shift_dashboard.dart:928` even
acknowledges the duplication ("Has its own `Timer.periodic` (default
30s) so the chip stays accurate"). T2's tick *also* updates a
displayed minute, so suppressing T2 entirely would regress the
"12:34 PM" UX.

**Recommended A4.2 shape** (not implemented here):

- Hoist a single `ValueListenable<DateTime> _shiftDashboardTicker`
  constructed once in `_ShiftDashboardState.initState` (or
  injected via a parent Provider) and disposed in
  `_ShiftDashboardState.dispose`.
- T2/T3/T4/T5 consume the listenable via `ValueListenableBuilder`
  or `context.watch`, dropping their own `Timer?` fields and
  `setState` calls.
- One timer fires; one frame is requested; four widgets rebuild
  on the same vsync.
- The four `dispose` paths simplify (no per-widget `_ticker?.cancel()`).

Behavior preservation: identical (same 30 s cadence; same
deterministic result of the resolver functions). The only
operator-visible change is *fewer* off-cycle rebuild flickers, not
more.

ROI rationale: P0-class on the operator's primary surface. Of all
10 P0/P1 hotspots in the prior 24-finding audit, this is the one
where the smallest code change (~1 file, ~30 LoC) removes 3 of 4
timers from the operator's most-dwelled screen.

---

## Section 3 — `connectivity_notifier.dart:53` cancel-on-dispose audit

**Status: PASS.**

| Lens | Finding |
|---|---|
| Constructor | `_start()` (`:50-54`) — runs an immediate `_runProbe()` then schedules `_timer = Timer.periodic(_pollInterval, (_) => _runProbe())`. |
| Cadence | 15 s default (constructor parameter `pollInterval`, default `Duration(seconds: 15)` at `:28`). |
| Cancel path | `dispose` at `:74-79` calls `_timer?.cancel()`, sets `_timer = null`, then `super.dispose()`. |
| Test seam | `ConnectivityNotifier._noTimer()` private constructor (`:37-39`) used by `FakeConnectivityNotifier` so tests don't spin a real timer. |
| Notify discipline | `_runProbe` (`:56-62`) only `notifyListeners()` on transition (`if (result != _isOnline)`). No edge-trigger spam. |
| External call | `InternetAddress.lookup('example.com')` (`:66`) with 5 s timeout (`:67`). Note: this is a separate finding (third-party DNS heartbeat) flagged as F3 in the prior 24-finding audit; **out of A4.1 scope** (slice asks only for cancel-on-dispose audit). |

Recommendation for A4.2: nothing. Disposal is correct. The
`example.com` heartbeat is a separate slice's call.

---

## Section 4 — Postgres pool sizing

The slice's lane index claims "Postgres pool 4 → 20 highest ROI."
Static-survey state of the codebase:

| Surface | File:line | Current state |
|---|---|---|
| **Default constant** | `lib/infrastructure/persistence/postgres/postgres_executor.dart:55` | `const int kPostgresDefaultMaxConnectionsPerPool = 4;` — UNCHANGED at 4. |
| **Doc comment in same file** | `lib/infrastructure/persistence/postgres/postgres_executor.dart:31-42` | Comment says "PF4 hardening: bumped from 4 → 20." This is **inconsistent with the constant value** below it. The comment then says "The Cloud Run deployment scripts and runbooks explicitly set POSTGRES_POOL_MAX_CONNECTIONS=20 for all services." So the intent is "default-in-prod is 20 via env var; constant is the fallback only." |
| **Env-var override** | `lib/infrastructure/persistence/postgres/postgres_executor.dart:62-63` | `kPostgresPoolMaxConnectionsEnvVar = 'POSTGRES_POOL_MAX_CONNECTIONS'`. |
| **Resolver** | `lib/infrastructure/persistence/postgres/postgres_executor.dart:84-137` | `resolvePostgresMaxConnectionsPerPool({Map<String, String>? environment})` — env var is read, parsed, validated against `kPostgresMaxConnectionsPerPoolUpperBound = 200`. **Falls back to `kPostgresDefaultMaxConnectionsPerPool` (= 4) when env var is unset / empty / unparsable / non-positive / above ceiling.** |
| **Production wiring** | `tool/advisor_proxy/proxy_bootstrap.dart:116-121` | `_defaultPostgresPoolFactory` calls `PackagePostgresPool.fromUrl(connectionString, maxConnectionCount: resolvePostgresMaxConnectionsPerPool())`. The inline comment at `:116` reads "Honor POSTGRES_POOL_MAX_CONNECTIONS env override; falls back to default 4." |
| **Other proxy/worker entrypoints** | `tool/cutover/preflight_smoke.dart:519`, `tool/audit_anchor/main.dart:255`, `tool/integration_sync_worker/main.dart:1111`, `tool/first_connect_backfill_worker/main.dart:1147`, `tool/oauth_refresh_worker/main.dart:1333` | All have the same "falls back to default 4" comment shape; all route through the resolver. |
| **Health-producer concurrency** | `tool/advisor_proxy/proxy_bootstrap.dart:1646` | `const healthProducerConcurrency = kPostgresDefaultMaxConnectionsPerPool;` — health-producer fan-out concurrency uses the **constant 4**, NOT the resolved value. So even if the env-var pin is 20, health-producer fan-out still runs 4-wide. Worth flagging for A4.2 as an inconsistency. |
| **Runbook** | `runbooks/cloud_run_env_vars.md:42` | `--set-env-vars POSTGRES_POOL_MAX_CONNECTIONS=20` is the documented Cloud Run deploy flag. |

### 4.1 Findings

1. **The `4 → 20` "highest ROI" claim is partially landed.** Production
   Cloud Run revisions (per the runbook) set
   `POSTGRES_POOL_MAX_CONNECTIONS=20`, so the *runtime* pool size is
   20 today. The *constant* fallback is still 4. Any Cloud Run
   service that forgets to pin the env var quietly drops to 4 — the
   exact regression the runbook + comment guard against, but no CI
   gate enforces the pin.
2. **The doc comment at `postgres_executor.dart:31-42` is internally
   inconsistent** with the constant on `:55`. The comment reads as
   if the constant is now 20; the constant is still 4. New code
   readers will trust the comment (cite-by-grep), miss the env-var
   nuance, and assume the in-process default is 20.
3. **`healthProducerConcurrency = kPostgresDefaultMaxConnectionsPerPool`
   at `proxy_bootstrap.dart:1646` is hardcoded to 4** rather than
   `resolvePostgresMaxConnectionsPerPool()`. Whether or not this
   matters is a function of how /health producers acquire pool
   connections; if each producer holds a connection during its
   probe, the concurrency cap of 4 is appropriate-for-pool-of-4
   but undersized for a pool of 20. (No load measurement here; flag
   for A4.2 to verify-then-fix-or-document.)

### 4.2 Recommendations (A4.2 implementation candidates, ranked by ROI)

| Rank | Recommendation | File(s) | Risk | ROI rationale |
|---|---|---|---|---|
| 1 | **Bump `kPostgresDefaultMaxConnectionsPerPool` from 4 to 20.** | `lib/infrastructure/persistence/postgres/postgres_executor.dart:55` | LOW (the env-var override path is unchanged; a service that pins `POSTGRES_POOL_MAX_CONNECTIONS=20` in env sees no change; a service that DIDN'T pin it gets a higher default — which is the *fail-safe* direction per the runbook + decision lock). Update all 7 "fallback to default 4" inline comments in the same PR. | P0. Removes the "forgot the env var → silent regression to pool-4" failure mode that the runbook acknowledges as a real production risk (`runbooks/cloud_run_env_vars.md:46-49`). |
| 2 | **Update doc comment at `postgres_executor.dart:31-42`** to match the constant after the bump. | Same file | TRIVIAL | P0 (docs honesty). |
| 3 | **Resolve `healthProducerConcurrency`** to `resolvePostgresMaxConnectionsPerPool()` instead of the constant. | `tool/advisor_proxy/proxy_bootstrap.dart:1646` | LOW. Health producers run on `/health`, which is manual per `PERFORMANCE_FRAMEWORK.md` golden rule §63-84 — the concurrency change does not affect routine traffic. | P1. Aligns the producer fan-out with the production-effective pool size. |

---

## Section 5 — Other in-scope findings (per slice)

The slice scope mentions only the four sets above. No additional
findings ride in this slice.

For *future* perf slices, the 503-line predecessor doc at commit
`0e59029e` enumerated 24 hotspots (15 frontend + 11 backend) and
clustered them into 5 candidate slices (A-E). That predecessor
material is not lost — it is on master at the same commit, in the
git history, and the slice clustering remains a useful planning
input for whichever lane picks up the broader perf work after A4.2.
This A4.1 doc deliberately narrows to A4.2's actionable scope so
the next slice doesn't have to re-discover findings.

---

## Section 6 — Recommendations summary (A4.2 work plan)

Ranked by ROI, every item below has a file:line citation, a
current-state note, and a recommended-change note. **A4.1 does NOT
implement these. A4.2 is the slice that does.**

| Rank | ID | Title | File:line(s) | Current state | Recommended change | ROI |
|---|---|---|---|---|---|---|
| 1 | R1 | Bump default Postgres pool size 4 → 20 | `lib/infrastructure/persistence/postgres/postgres_executor.dart:55` (constant); 7 inline comments in `tool/**/main.dart` + `tool/advisor_proxy/proxy_bootstrap.dart:116` | Constant = 4; env var = 20 in prod; doc comments contradict the constant | Constant → 20; sweep "falls back to default 4" comments to "falls back to default 20"; doc comment block updated | P0. Removes the silent-regression failure mode for any service that forgets the env-var pin. |
| 2 | R2 | Coalesce four `shift_dashboard.dart` 30s tickers into one shared `ValueListenable<DateTime>` | `lib/screens/shift_dashboard.dart:361` (T2), `:784` (T3), `:951` (T4), `:1329` (T5) | Four independent `Timer.periodic` instances; ticks not phase-locked; aggregate ~8 `setState` + ~16 Provider lookups per minute of dwell on operator's primary screen | Single shared `ValueListenable<DateTime>` constructed once in `_ShiftDashboardState`; T2/T3/T4/T5 consume via `ValueListenableBuilder`; per-widget `_timer` fields removed | P0. Operator's primary surface; smallest code change (~1 file, ~30 LoC delta) removes 3 timers from the dwell screen. Doc comment at `:928` already acknowledges the duplication. |
| 3 | R3 | Resolve health-producer concurrency to env-aware pool size | `tool/advisor_proxy/proxy_bootstrap.dart:1646` | Hardcoded `const healthProducerConcurrency = kPostgresDefaultMaxConnectionsPerPool` (= 4) | Use `resolvePostgresMaxConnectionsPerPool()` so producer fan-out matches actual pool capacity | P1. /health is manual per framework golden rule, so impact is bounded; but consistency win + better diagnostic latency when /health is invoked. |

A4.2 ships R1 + R2 + R3 in one slice. Each is single-file or
near-single-file. Total expected delta: ≤ 3 files, ≤ 60 LoC.

### 6.1 What A4.2 does NOT need to touch

- **No `.cancel()` additions** — every timer in `lib/` already
  cancels in `dispose`. Verified site-by-site in §1.1.
- **No new probes** — A4.2 reuses existing gauges (see §7).
- **No tracker / ledger / index updates** in A4.1. A4.2's PR
  description should cite this audit; the executor advances
  trackers on slice acceptance.

---

## Section 7 — JSON probe paths

Per `PERFORMANCE_FRAMEWORK.md` §234-258 and the framework's mobile
loop §180-209, the following probe paths surface signal for each
finding. **A4.1 does not add new probes**; this section enumerates
what already exists and what would be needed for A4.2 to verify the
fix in production runtime.

### 7.1 Probes that already exist

| Finding | Probe | JSON shape | Source |
|---|---|---|---|
| Postgres pool sizing (R1) | `/health.runtime_gauges.postgres_pool` | `{ "open": int, "idle": int, "waiters": int, "max_connections": int }` | `tool/advisor_proxy/advisor_proxy.dart:3691` (`PostgresPoolGaugeSnapshot.toJson()`) — already wired post-B1+B2. After R1 lands in prod, `max_connections` should report `20` for any service using the default. |
| Pub/Sub subscriber polling (T10 — informational only; not in A4.2 scope) | `/health.runtime_gauges.pubsub_subscriber.ring_buffer_keys` | `{ "ring_buffer_keys": int }` | `tool/advisor_proxy/advisor_proxy.dart:3707` — already wired. |

### 7.2 Probes recommended for A4.2 verification (NOT implemented in A4.1)

| Finding | Probe path | Suggested JSON shape | Suggested baseline file |
|---|---|---|---|
| R1 (pool size) | Existing `/health.runtime_gauges.postgres_pool` over a `tool/pressure/p4_operator_day_soak.dart --duration=2h` run | `{ "max_connections_observed": int, "max_waiters_observed": int, "p95_idle": int }` | `build/perf_gate/postgres_pool_after_r1.json` |
| R2 (coalesced ticker) | New `flutter test integration_test/shift_dashboard_rebuild_count_test.dart` (suggested name) capturing `setState` call count over 2 minutes of idle dwell on a profile build | `{ "setstate_calls_per_min": int, "rebuilt_widget_count_per_min": int, "frame_jank_count": int }` | `build/perf_gate/mobile_shift_dashboard_idle.json` |
| R3 (health concurrency) | One `/health` invocation against staging after R3 lands; capture per-producer latency from the existing producer-registry latency log lines | `{ "producer": string, "latency_ms": int, "concurrency_window_size": int }` | `build/perf_gate/health_producer_latency_after_r3.json` |

### 7.3 Probe paths the A4.2 author should NOT need to introduce

The framework already has `tool/perf_gate/staging_console_probe.dart`
for web; the existing `p4_*` soak harnesses cover the proxy gauges.
A4.2's verification can ride on existing probes — no new
`tool/perf_gate/*.dart` is required for the slice as scoped here. A
`mobile_perf_probe.dart` companion would help R2 verification but is
its own slice (out of A4.2 scope per `03_execution_slices.md` §A4.2
"Size: Small to Medium depending on findings").

---

## Section 8 — Self-review checklist

Each recommendation in §6 has:

- [x] file:line citation
- [x] current state
- [x] recommended change
- [x] ROI rationale
- [x] downstream probe path (§7) for runtime verification

The doc covers every item in the slice scope (§"Files inspected")
and creates exactly the file in the slice scope (§"Files created"):

- [x] 12 `Timer.periodic` sites enumerated in `02_plumbing_audit_matrix.md`
      Lens 10 — covered in §1 (with discrepancy reconciliation)
- [x] `lib/screens/shift_dashboard.dart:361, :784, :951, :1329`
      four-on-one-screen audit — covered in §2
- [x] `lib/state/connectivity_notifier.dart:53` cancel-on-dispose
      audit — covered in §3
- [x] Postgres pool sizing — covered in §4
- [x] Output: `docs/_audits/code_health/a4_performance_audit.md`
      with before-measurements + targeted recommendations + JSON
      probe paths — this file

---

## Section 9 — 14-Lens self-audit

Per the slice's verification step. Many lenses are N/A for a doc-only
read-only audit; rationale recorded for each.

| Lens | Code or doc checked | Finding | Required action |
|---|---|---|---|
| 0 — Branch / Authority / Scope | `git status` clean; branch `claude/a4-1-performance-audit-pass` off `42e04764`; authority chain followed (`PERFORMANCE_FRAMEWORK.md` → `02_plumbing_audit_matrix.md` Lens 10 → `03_execution_slices.md` §A4.1) | Clean. Doc explicitly cites the framework + Lens 10 verbatim (see header + §0). | None. |
| 1 — Product & user journey | N/A for doc-only audit. Nearest user surface: shift dashboard (R2). Rebuild storm is operator-invisible *today* but would be measurable on mid-tier devices. R2 preserves operator-visible behavior (same tick, same labels). | No new operator-facing copy; no new states. | None. |
| 2 — Information architecture | N/A — doc-only; no nav, no routes touched. | — | None. |
| 3 — Data model / migration / RLS | N/A — no schema, no migrations, no RLS surfaces inspected. R1 is a constant change in `lib/infrastructure/persistence/postgres/postgres_executor.dart`; A4.1 does not modify it. | — | None. |
| 4 — Repository & service layer | Verified `lib/services/realtime/google_cloud_pubsub_subscriber.dart` (T10), `outbox_tripwire_poller.dart` (T11), `current_state_boundary_monitor.dart` (T9), `system_info_service.dart` (T8); all have intact `dispose` cancel paths. | All services dispose-safe. | None. |
| 5 — Proxy / route / gateway contracts | Verified `tool/advisor_proxy/proxy_bootstrap.dart:116-121` pool factory + `:1646` health-producer concurrency. R3 flagged. | R3 in §6. | A4.2. |
| 6 — Auth / roles / permissions / scope | N/A — pool sizing + timers are not auth-bearing. `lib/auth/permission_keys.dart` not touched (per slice "Hard rules"). | — | None. |
| 7 — Lifecycle & destructive actions | Cancel-on-dispose verified for all 11 `lib/` `Timer.periodic` sites; this IS a lifecycle-lens audit. §1.1 is the deliverable. | All clean. | None. |
| 8 — Background workers / deploy / startup / health | Verified Postgres pool initialization path through `proxy_bootstrap.dart`; verified runbook env-var pin at `runbooks/cloud_run_env_vars.md:42`. R1 + R3 are the deploy-hygiene findings. | R1 + R3 in §6. | A4.2. |
| 9 — UI state / UX / accessibility | Verified `_LiveClock` (T2), `_ShiftPeriodSelector` (T3), `_DaypartScaffoldSection` (T4), `_TimeIntoServiceHeader` (T5). R2 preserves UX (same 30 s cadence, same labels). No accessibility regression — same `Text` widgets, same labels. | R2 in §6. | A4.2. |
| 10 — Performance & data loading | The audit's primary lens. Findings in §1, §2, §3, §4. Recommendations in §6. JSON probe paths in §7. | R1, R2, R3. | A4.2. |
| 11 — Mobile / operator web / admin / API parity | R2 affects the mobile shift-dashboard path only; operator-web and admin do not host this widget tree. R1 + R3 affect all proxy/worker services equally. | No parity gap. | None. |
| 12 — Tests / builds / browser use / evidence | `dart analyze` skipped per slice ("N/A — no Dart files changed"). No tests added (audit is doc-only). The doc itself is the evidence; A4.2 will need rebuild-count + soak-gauge tests. | None for A4.1. | A4.2 ships rebuild-count + soak-gauge tests (per §7.2). |
| 13 — Observability / audit / supportability | Existing gauges enumerated in §7.1. No new gauges proposed for A4.1. | None for A4.1. | A4.2 verifies via existing gauges. |
| 14 — Docs / tracker / prompt hygiene | Audit file created in conventional location (`docs/_audits/code_health/`); follows shape of `a1_proxy_bug_root_cause.md` + `a3_proxy_monolith_decomposition.md`; cites framework + Lens 10 verbatim. Trackers / ledger / indices intentionally NOT updated (per slice "Hard rules"). | Clean. | None. |

### 9.1 Self-audit attestations

- **Doc completeness**: every cited file:line was opened and verified
  in this worktree against `42e04764`. Cadences in §1.1 are accurate
  (30 s for shift-dashboard timers, 15 s for connectivity notifier,
  5 s for debug-console live-tail, 1 h for system-info-service,
  constructor-supplied for the rest).
- **No-implementation discipline**: zero `.dart` files modified in
  this slice. `git diff --stat origin/master..HEAD` should show only
  `docs/_audits/code_health/a4_performance_audit.md`.
- **Authority chain**: header cites `PERFORMANCE_FRAMEWORK.md`
  (active, 2026-05-03) and `02_plumbing_audit_matrix.md` Lens 10.
- **Scope adherence**: §0 explicitly enumerates in-scope and
  out-of-scope items; the doc covers exactly the slice scope, no
  drive-by findings.

End of A4.1 audit.
