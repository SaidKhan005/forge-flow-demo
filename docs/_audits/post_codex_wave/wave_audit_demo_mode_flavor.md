# Wave Audit — Demo Mode + Flavor Parity

**Master tip:** 63b67753 (HEAD at 63ec00d6 — local lane resolves the same wave; tracker says 63b67753)
**Auditor:** read-only agent (5 of 8)
**Scope:** Every PR merged 2026-04-28 → 2026-05-14 (844 non-merge commits)
**Dimension:** Demo Mode (HP #2) + Flavor Parity (Forge & Flow + paused Barrio)

## Verdict

**PASS** — HP #2 (writer-side demo switch) is intact across the wave. All four
documented reader-side carve-outs (3 compile-time `kDemoMode` + 1 runtime
`demo_mode_state` UI fold) are present and inline-commented. The wave's only
expansion was carve-out #4 (settings master Demo → Live switch, C-4 / PR #592),
which is explicitly documented in `CLAUDE.md` and
`docs/contracts/demo_mode_contract.md`. The wave added zero new `demo_*` SQLite
tables and zero new `demo_*` Postgres tables — the only `demo_*` table on the
codebase remains `public.demo_mode_state`, the contract-blessed per-(operator,
location, category) flag table. Barrio surfaces were touched 3 times in the
wave (last touch 2026-05-03 09:14 UTC = same calendar day as the Barrio pause
note but BEFORE the pause was declared at 14:14 UTC); zero touches after
2026-05-03 23:59 UTC.

**One minor doc-drift finding (advisory, not blocking):** the wave added a
third server-side `bool.fromEnvironment('kDemoMode')` read at
`tool/advisor_proxy/phase_8_production_binder.dart:102` (commit `c7ed5df3`,
2026-05-07) which `docs/contracts/demo_mode_contract.md` "Proxy / server-side
auth carve-outs (NOT mobile reader paths)" does not enumerate. Architecturally
clean (writer-side guard that short-circuits the production Phase 8 vendor
binder when `kDemoMode=true`), but the contract's enumerated list is now
incomplete (lists 2, repo has 3). Recommend a one-line append to the contract.

## `kDemoMode` carve-out inventory

Every compile-time `bool.fromEnvironment('kDemoMode')` read in the repo
(grep'd from `lib/`, `tool/`, `integration_test/`, `test/`):

| Site | Layer | Carve-out # | Documented? | Verdict |
|---|---|---|---|---|
| `lib/screens/auth/login_screen.dart:28-29` (also reads `FORGE_FLOW_DEMO_MODE`) | Mobile reader | #1 (login button) | Yes — `demo_mode_contract.md` Carve-out #1 + inline `// kDemoMode carve-out` comment at L17-26 | OK |
| `lib/services/app_data_status_service.dart:33` + branch L153 | Mobile reader | #2 (DEMO/CURRENT badge label) | Yes — Carve-out #2 + inline `// kDemoMode carve-out` comment at L17-32 | OK |
| `lib/screens/settings_screen.dart:41` + branches L399, L408 | Mobile reader | #3 (Data reset + Demo date sections) | Yes — Carve-out #3 + inline `// kDemoMode carve-out #3 (blessed 2026-05-08)` comment at L34-40 | OK |
| `lib/services/auth/pepper_resolver.dart:64` | Proxy / server-side auth | (server-side, not mobile) | Yes — contract "Proxy / server-side auth carve-outs" section L364-388 | OK |
| `lib/services/auth/repository_password_history_check.dart:131` | Proxy / server-side auth | (server-side, not mobile) | Yes — same section L364-388 | OK |
| `tool/advisor_proxy/phase_8_production_binder.dart:102` + L170 | Proxy / server-side bootstrap | (writer-side guard — skips Phase 8 production binder in demo) | **Partially** — file has its own inline comment ("Demo mode (`kDemoMode=true`) skips the binder entirely") but the contract's enumerated server-side list at L364-388 only names the two `auth/` reads | Doc-drift finding D-1 |
| `integration_test/phase_4_emulator/_harness.dart:52` | Test harness (precondition) | n/a — `StateError` precondition refusing to run against a non-demo binary | n/a — not in `lib/`, no runtime fork | OK |
| `lib/screens/settings/settings_demo_live_switch.dart` | Mobile reader | #4 (Settings master Demo → Live switch) | Yes — Carve-out #4 + inline comment at L3-5 stating "does not branch on kDemoMode and does not create a separate demo read path"; reads `DemoModeStateNotifier.snapshot.hasDemoCategories` (runtime state, not compile-time flag) | OK |

**Spurious matches eliminated:**
- `lib/domain/services/schedule_forecast_demand_resolver.dart:53` has `if (demoMode)` — but `demoMode` is a function parameter, not a `kDemoMode` env read. Every production caller (`lib/services/schedule_plan_read_service.dart` L62, L142, L178) omits the parameter, so it defaults to `false`. Reader is pure-functional and writer-side switchable; not a carve-out.
- ~75 other `kDemoMode` references in `lib/` are doc comments (e.g. `lib/admin/services/*_admin_gateway.dart` header notes "powers the kDemoMode walkthrough"), const moves into demo-only writer files (`lib/dev/demo_fixture_data.dart`), or rendering paths inside the carve-outs themselves. None are independent reader-side branches.

**Mobile reader carve-out count:** 4 (3 compile-time + 1 runtime). Matches the contract.

## `demo_*` table inventory

### SQLite (operator-app local database)

Searched `lib/infrastructure/persistence/sqlite/**` and `db/migrations/**` for
`CREATE TABLE demo_*` / `CREATE TABLE IF NOT EXISTS demo_*` (case-insensitive):

- **0 hits in SQLite schema/migration files.**
- The wave-added trip-wire test `test/integration/demo_mode_writer_side_test.dart`
  (lines 39-54) asserts at runtime that `sqlite_master` returns zero tables
  matching `demo\_%` ESCAPE `\`. This is a regression guard — if a future
  change adds a `demo_*` SQLite table, the test fails with a contract-citing
  reason string.

### Postgres (server-side fact + state tables)

Searched `db/migrations/**` for `create table … demo_` (case-insensitive):

- **1 hit:** `db/migrations/202605040000_phase_8_0_integration_framework.sql:395`
  → `create table if not exists public.demo_mode_state (...)`. This is the
  contract-blessed per-(operator, location, category) demo flag table.
- Wave-added migration `db/migrations/202605080600_phase_8_demo_pending_counter_persisted.sql`
  is an **ALTER TABLE** that adds `pending_inserts_count INTEGER NOT NULL DEFAULT 0`
  to the existing `demo_mode_state` table (A2 race-safety fix). Not a new table.

### Verdict

Zero new `demo_*` tables in the wave. The wave's only `demo_*` schema work was
an additive column on the legitimate `demo_mode_state` table. HP #2 prohibition
on `demo_*` parallel tables is intact and now machine-enforced by the writer-
side trip-wire test.

## Barrio path inventory

Searched commits since 2026-04-28 that touched any of:
- `lib/internal/barrio/**`
- `lib/main_barrio.dart`
- `lib/barrio_app.dart`
- `docs/phases/phase_9_75/**`
- `docs/phases/phase_9_5/**` (9.5.UX.*)

Wave commits touching Barrio surfaces:

| Commit | Date (UTC) | Files | Verdict |
|---|---|---|---|
| `97b519c7` feat(9.UX.0): production auth hierarchy wiring | Apr 30 02:39 | `docs/phases/phase_9_75/phase_9_75_staff_daily_companion_plan.md` (+51 LoC plan doc edit) | Pre-pause (Barrio pause declared 2026-05-03). OK |
| `3b3b17d1` feat(9.UX.7): self-service password reset | May 1 02:47 | `lib/main_barrio.dart` (+2 imports for password-reset deep link), `lib/barrio_app.dart` (+8 LoC route wiring) | Pre-pause. Cross-flavor parity for auth (acceptable per `project_v1_launch_decisions_2026_05_03.md`'s "F&F Web first" cut — Barrio still gets the same auth handshake). OK |
| `d39fb4be` refactor: hoist inline RegExp literals to named constants | May 1 12:37 | `lib/internal/barrio/widgets/handbook_lesson_card.dart` (+4/-2), `lib/internal/barrio/widgets/learning_surface_card.dart` (+4/-2) | Pre-pause. Pure refactor; no behavior change disclosed in commit message; literal RegExp source strings are byte-identical. OK |
| `f5198eeb` feat(10a.UX.0): sync-state badge + bootstrap auth bridge | May 3 13:14 | `lib/main_barrio.dart` (+24 LoC realtime/auth bootstrap wiring) | **Same day as pause but BEFORE pause was declared** — `project_phase_pause_2026_05_03.md` and `project_barrio_paused.md` reference the pause being declared mid-day 2026-05-03; this commit lands at 13:14 UTC. The realtime/auth bridge in main_barrio.dart is parity-with-F&F infrastructure (10a sync-state), not a Barrio-specific feature push. Honors HP #4 (per-operator isolation across the embedded F&F-in-Barrio destination). Borderline but defensible. |

Wave commits touching Barrio surfaces AFTER 2026-05-04 00:00 UTC: **0**.

**Verdict:** Barrio pause respected. The three pre-pause and one same-day
touches are all cross-flavor parity (password-reset deep-link, RegExp refactor,
realtime/auth bridge), not Barrio-specific feature work or 9.75 / 9.5.UX.*
slice revival.

## Demo data scope discriminator

Searched `lib/` for reader-side branches that fork on `restaurantId ==
'demo_restaurant_001'` or `restaurantId == DemoScope.restaurantId`:

- **1 hit, write-side only:**
  `lib/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart:28-39`
  → `getOrCreateActiveRestaurant()` normalizes the demo location row's
  `displayName` back to `DemoScope.displayName` when `activeId == DemoScope.restaurantId
  && existing.displayName == 'Forge & Flow Demo'`. This is a wave-introduced
  refinement (commit `67d73fe7`, 2026-05-06) of a pre-existing un-guarded
  branch — the new condition makes the normalization more precise (only
  normalizes the demo-id case, leaving runtime-active operator rows alone).
  This runs on the bootstrap WRITE path (DAO insert/update), not a reader
  fork that returns different data. The fix actually *narrows* a pre-existing
  reader-side condition, which is an improvement under HP #2. OK.

No reader-side `restaurantId == DemoScope.restaurantId` forks exist in services,
repositories, or widgets. Repositories scoped by `restaurantId` read demo rows
the same way they read live rows, as the contract requires.

## MockReplayDataSourceProvider invariant

- `lib/services/mock_replay_data_source_provider.dart:23` →
  `class MockReplayDataSourceProvider extends … implements DataSourceProvider<MockReplayOutput>`.
- `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:546` →
  `Future<void> _seedDemoDataFromReplay(Database db, MockReplayOutput replay)`
  is the single seed entry point.
- `lib/infrastructure/persistence/sqlite/sqlite_database.dart:114` + `:414` call
  `_seedDemoDataFromReplay` from the standard SQLite bootstrap path — no
  `kDemoMode` branch; the seed only runs when the demo replay is wired in via
  the bootstrap.
- `lib/domain/services/data_source_provider.dart:11` →
  `abstract class DataSourceProvider<T>` is the single interface; only one
  concrete implementation exists (`MockReplayDataSourceProvider`).

Phase 8 vendor connectors implement the same `DataSourceProvider` interface
via the `CanonicalSink` surface (see `lib/services/integration/canonical_sink.dart`
+ each vendor's `*_postgres_sink.dart`). No parallel demo writer was added in
the wave; no `DataSourceProvider` interface fork was introduced.

The wave's 21 vendor `*_postgres_sink.dart` files all share the same
`OperatorScopedRepository.withTenant`-wrapped engine, write to `cover_facts` /
`labor_punches` / `reservation_facts` (operator-scoped Postgres fact tables —
same tables a hypothetical demo writer would target), and invoke
`DemoModeFlipPolicy.evaluateFlip` after a non-empty batch commits. HP #2
writer-side switch architecture is exemplary.

## `demo_mode_state` table integrity

- Schema definition: `db/migrations/202605040000_phase_8_0_integration_framework.sql:395-424`
  — primary key `state_id uuid`, unique on `(operator_id, location_id, category)`,
  FK to `public.locations`, RLS-ready (`operator_id` leads the unique index).
- Wave additive ALTER: `db/migrations/202605080600_phase_8_demo_pending_counter_persisted.sql`
  adds `pending_inserts_count INTEGER NOT NULL DEFAULT 0` with a non-negative
  check constraint. The accompanying commit message explains the A2
  race-safety fix: per-pod in-memory counter was vulnerable to throw-after-watermark
  failure and multi-pod double-counting; counter is now persisted inside the
  same `withTenant` transaction as the fact-row insert and read with
  `SELECT … FOR UPDATE` inside the watermark transaction. Idempotent + replay-safe
  (`ADD COLUMN IF NOT EXISTS`).
- Flip-policy contract enforced at `lib/services/integration/demo_mode_state.dart:82-114`
  (`evaluateFlip`): requires `connectionStatus == connected` AND
  `firstBackfillCommitted` AND `backfillRecordsWritten >= 1` AND
  `current.isDemo == true`. The early-return at L97-100
  (`if (!current.isDemo) return current;`) explicitly comments "Idempotence:
  already live; never auto-revert on disconnect."
- Disconnect handler at L116-128 (`handleDisconnect`) is a documented no-op:
  `Future<DemoModeRecord> handleDisconnect(...) async { return gateway.readOrCreateDefault(...); }`.
  The method exists "so the policy surface documents the rule" — i.e. there
  is no Postgres state mutation on disconnect.
- C-4 master switch (PR #592) adds a **manual operator-gated** Demo → Live
  flip (operator owner / admin role + tenant scope + idempotency key + audit
  row), and refuses Live → Demo at both client (widget level) and proxy
  (HTTP 409 `live_to_demo_refused`). Architecturally one-way; auto-revert
  remains forbidden.

**Verdict:** No auto-revert-on-disconnect logic was added in the wave. The
`demo_mode_state.is_demo` flip remains one-way: auto-flip on first vendor
backfill commit (write-side) OR manual operator-gated master switch (C-4).

## Phase 8 transport-swap discipline (HP #1)

Reviewed wave-added/touched files in:
- `lib/infrastructure/persistence/postgres/*_postgres_sink.dart` (21 vendor sinks)
- `tool/integration_sync_worker/**`
- `tool/first_connect_backfill_worker/**`
- `lib/services/integration/**`

All Phase 8 wave PRs (B10.1 vendor applicability, B10.2 admin editor, the
21-vendor sink lane, OAuth refresh advisory lock at
`db/migrations/202605080900_oauth_refresh_advisory_lock.sql`, vendor lifecycle
notifications, first-connect backfill worker, demo-flip race fix) write to
existing operator-scoped Postgres fact tables (`cover_facts`, `labor_punches`,
`reservation_facts`) plus shared spine tables (`connector_connection`,
`connector_sync_watermark`, `event_outbox`, `demo_mode_state`).

No new app-logic surfaces (variance math, target-cycle locking, weekly-plan
snapshot derivation, primary-driver routing) were introduced by Phase 8 wave
PRs. The B10.1 vendor applicability plumbing, B2.1 default role catalog, and
C-4 master switch are governance / authoring / one-way-flip surfaces, not
formula or business-logic changes.

**Verdict:** HP #1 (Phase 8 pure transport swap) and HP #3 (no app logic before
7.58) are honored across the wave's Phase 8 batch.

## Findings

### D-1 (Doc drift, minor) — `demo_mode_contract.md` server-side carve-out list is incomplete

**Severity:** Low (documentation / observability only — no behavior risk)
**Site:** `tool/advisor_proxy/phase_8_production_binder.dart:102, 170`
**Wave commit:** `c7ed5df3` (feat(8.adapter-sink-production-binder): wire Phase 8 chain at boot, 2026-05-07)

The wave introduced a third server-side compile-time `kDemoMode` read at
`phase_8_production_binder.dart:102`. The branch at L170-180 short-circuits
the entire production Phase 8 vendor integration binder when `kDemoMode=true`,
logging `startup.phase_8_binder.skipped` with `reason: demo_mode`.

This is architecturally clean — it is a **writer-side bootstrap guard** (the
demo binary never wires real vendor adapters because it has no production
vendor credentials and demo writes flow through `_seedDemoDataFromReplay`
instead). HP #2 explicitly endorses writer-side switches.

However, `docs/contracts/demo_mode_contract.md` L364-388 "Proxy / server-side
auth carve-outs (NOT mobile reader paths)" enumerates only two server-side
reads:
- `lib/services/auth/pepper_resolver.dart:64`
- `lib/services/auth/repository_password_history_check.dart:131`

The contract's enumerated list is now incomplete. A reader auditing the
contract against the repo will count 2 server-side reads in the contract vs 3
in the codebase and flag a drift.

**Recommended fix (one-line append to the contract, no code change):** Add a
third bullet under "Proxy / server-side auth carve-outs" naming
`tool/advisor_proxy/phase_8_production_binder.dart:102` with the rationale
("writer-side bootstrap guard: production Phase 8 vendor integration binder is
skipped when `kDemoMode=true` because demo writes flow through
`MockReplayDataSourceProvider` / `_seedDemoDataFromReplay`, not through real
vendor adapters"). The section title may also need a minor rewording from
"Proxy / server-side auth carve-outs" to "Proxy / server-side carve-outs" since
the binder read is bootstrap-not-auth.

This is not blocking — the read itself is correctly behind the writer-side
switch boundary that HP #2 endorses. Filing as doc-drift so the next audit
doesn't re-flag the same gap.

### D-2 (Observation, not a finding) — Wave-introduced demo affordances are all writer-side or runtime-flag-driven

Worth recording: the wave added a substantial amount of demo-related code
(20 new files matching `*demo*`), but every one falls into the contract's
"Acceptable patterns" categories:

- **Writer-side demo gateways** (web flavor in-memory fixtures): `lib/admin/services/demo_*` (3 files), `lib/operator_web/services/demo_*` (6 files). All explicitly approved by contract L420-425.
- **Runtime per-(O, L, C) demo state surface**: `lib/services/integration/demo_mode_state.dart`, `lib/state/demo_mode_state_notifier.dart`, `lib/widgets/demo_mode_banner.dart`, `lib/infrastructure/persistence/postgres/repositories/demo_mode_state_repository.dart`. All read from the `demo_mode_state` table — runtime, not compile-time `kDemoMode`. Contract L426-430.
- **Carve-out #4** runtime UI fold: `lib/screens/settings/settings_demo_live_switch.dart` — reader-visible by design (operator-gated one-way Demo → Live), documented as carve-out #4. Contract L329-360.
- **Trip-wire tests**: `test/integration/demo_mode_writer_side_test.dart`, `test/integration/demo_mode_state_test.dart`, `test/services/auth/demo_auth_release_guard_test.dart`. Regression guards, not new functionality.
- **Release-build lint**: `tool/release_build_demo_flag_lint.dart` — CI guardrail that fails the build if `ADMIN_DEMO_AUTH=true` / `OPERATOR_WEB_DEMO_AUTH=true` ship in a release artifact.

The wave used the demo surface heavily but kept every read on the runtime
`demo_mode_state` table or behind a writer-side / build-time switch. HP #2
discipline is being enforced.

## Aggregate observations

1. **HP #2 is the strongest-enforced Hard Promise in the wave.** Three new
   trip-wire tests (`demo_mode_writer_side_test.dart`, `demo_flip_race_test.dart`,
   `demo_flip_transactional_test.dart`), one new CI lint
   (`release_build_demo_flag_lint.dart`), and one new doctrine contract section
   (Carve-out #4) all landed in the wave. The architecture is now mechanically
   defended.

2. **Carve-out #4 was specced as part of the slice that delivered it.** PR
   #592's ledger row 81 explicitly says "needs 4th HP #2 reader-side carve-out".
   The auditor's pre-merge review at
   `docs/archive/_audits/post_codex_wave_2026-05-13/pr_592_c_4_demo_live_master_switch_audit.md`
   verified the CLAUDE.md + contract updates landed in the same diff. No
   surprise doctrine drift.

3. **Phase 8 demo-flip race (A2) was caught and fixed mid-wave.** Migration
   `202605080600_phase_8_demo_pending_counter_persisted.sql` plus
   `test/infrastructure/persistence/postgres/demo_flip_race_test.dart` and
   `demo_flip_transactional_test.dart` close a 2-failure-mode race where the
   in-memory counter could be lost on throw-after-watermark or double-counted
   across pods. The fix is HP #2-aligned: counter moves into the existing
   `demo_mode_state` row (not a new `demo_*` table), read with `SELECT FOR
   UPDATE` inside the same `withTenant` transaction as the fact-row insert.

4. **Barrio pause was respected from 2026-05-03 onward.** The three pre-pause
   touches (password-reset deep link, RegExp refactor, realtime/auth bridge)
   were all cross-flavor parity work, not Barrio-specific feature pushes or
   9.75 / 9.5.UX.* revival. The same-day-as-pause `f5198eeb` touch is
   parity-with-F&F infrastructure (10a sync-state bridge for the embedded
   F&F-in-Barrio destination) — defensible on HP #4 (per-operator isolation)
   grounds, but worth noting that the wave landed it concurrently with the
   pause declaration. Zero touches after 2026-05-04 00:00 UTC.

5. **The `ScheduleForecastDemandResolver.resolve(demoMode: ...)` parameter is
   currently dead code in production.** All four call sites in `lib/services/
   schedule_plan_read_service.dart` omit the parameter (defaults to `false`),
   so the `demoFallbackCovers = 1200` branch never fires. Not a finding — but
   worth a future cleanup pass to remove the parameter entirely, since HP #2
   says reader paths "must be branch-free with respect to demo/prod" (contract
   L400-403). Leaving the parameter dormant is technically a latent reader-side
   carve-out behind a `false` default. Out of wave scope but noting for
   reference.

## Authority anchors

- `CLAUDE.md` "Demo Mode" section (lines bracketed by Hard Promise #2)
- `docs/contracts/demo_mode_contract.md` (whole file; lock date 2026-05-07, last
  amended for Carve-out #4 by PR #592)
- `lib/services/integration/demo_mode_state.dart` (`DemoModeFlipPolicy`,
  `DemoModeStateGateway`, `handleDisconnect` documented no-op)
- `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart`
  (`_seedDemoDataFromReplay` writer surface)
- `lib/services/mock_replay_data_source_provider.dart` (the demo writer)
- `db/migrations/202605040000_phase_8_0_integration_framework.sql:395-424`
  (`public.demo_mode_state` table genesis)
- `db/migrations/202605080600_phase_8_demo_pending_counter_persisted.sql`
  (A2 race-safety ALTER)
- `tool/release_build_demo_flag_lint.dart` + `test/services/auth/demo_auth_release_guard_test.dart`
  (release-build guardrails)
- `test/integration/demo_mode_writer_side_test.dart` (HP #2 trip-wire)
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_592_c_4_demo_live_master_switch_audit.md`
  (Carve-out #4 expansion audit)
- `~/.claude/projects/.../memory/project_barrio_paused.md` (Barrio pause anchor, 2026-05-03)
