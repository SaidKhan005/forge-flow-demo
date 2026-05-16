# Per-Daypart Targets V1 — Slice 3 demo-seed fix audit: populate weekly-plan snapshot `dayDayparts` + `wageAtLockTime`

> Branch: `claude/fix-slice3-demo-seed-snapshot`
> Base: `master`

## Slice intent (from prompt + plan Slice 3 + Design Rules 4/8 + CLAUDE.md HP #2)

`_seedWeeklyPlanSnapshotFromReplay` built the demo locked
`WeeklyPlanSnapshot` omitting `dayDayparts:` and `wageAtLockTime:`, so
the demo-seeded snapshot was structurally a pre-Slice-1 "legacy"
snapshot. `schedule_forecast_notifier.dart:519-520` then saw
`snapshot.dayDayparts.isEmpty == true` and silently fell back to the
read-time `DaypartPlanAllocator` — Slice 3's persistence read-swap was
dead in demo and the Gap-12 1:1 allocator trap was never actually
closed for the shipped demo.

Fix: mirror the runtime lock path
(`WeeklyPlanSnapshotService._generateAndPersistSnapshot` +
`_buildDayDaypartRows`, ~lines 188-231 / 372-437) inside the demo seed
so the seeded snapshot carries per-(business_date, service_period)
sub-rows + the Design-Rule-8 wage stamp, persisted to the same
`weekly_plan_snapshot_day_dayparts` table + `wage_at_lock_time_json`
column the runtime writer uses.

## Scope (files modified)

- `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` —
  edited ONLY `_seedWeeklyPlanSnapshotFromReplay` + added one adjacent
  private helper `_buildSeedDayDaypartRows` (pure replica of the
  runtime `WeeklyPlanSnapshotService._buildDayDaypartRows`, the same
  inlined-replica pattern the file already uses for
  `_resolveSeedDemandWeeklyCovers` / `_buildSeedDistributionWeights`).
  Changes: (a) hydrate the seeded cycle's per-period `dayparts` from
  `target_cycle_dayparts` (mirrors `TargetCycleDao._hydrateWithDayparts`);
  (b) build + pass `dayDayparts:` and `wageAtLockTime:` to the
  `WeeklyPlanSnapshot(...)` constructor; (c) persist the child rows to
  `weekly_plan_snapshot_day_dayparts` with delete-then-insert
  replace-for-snapshot semantics mirroring
  `WeeklyPlanSnapshotDao.upsertSnapshot`.
- `test/per_daypart_v1_slice3_demo_seed_snapshot_test.dart` — NEW, 5
  tests.

No other files touched. `weekly_plan_snapshot_service.dart` read
read-only for the helper/wage-stamp shape (not modified).

## Verification (CI dark — local commands + results)

- `flutter pub get` — `Got dependencies!`
- `dart analyze lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart test/per_daypart_v1_slice3_demo_seed_snapshot_test.dart` — **No issues found!**
- `flutter test test/per_daypart_v1_slice3_demo_seed_snapshot_test.dart test/per_daypart_v1_demo_seed_per_period_cycle_test.dart test/per_daypart_v1_slice_3_plan_persistence_test.dart` — **+14 All tests passed!** (5 new + 3 demo-cycle + 6 slice-3 plan-persistence)
- `flutter test test/weekly_plan_snapshot_service_test.dart test/weekly_plan_snapshot_day_dayparts_test.dart test/weekly_plan_snapshot_policy_test.dart` — **+61 All tests passed!** (no regression in the snapshot service/DAO/policy suites; "test D — snapshot matches generated SchedulePlan" still green — day rows unchanged)

## Pattern B audit table (worker self-audit + executor independent audit)

| # | Lens | Status | Evidence (file:line) |
|---|------|--------|----------------------|
| 1 | Scope match | PASS | `git status --porcelain`: only `M sqlite_database_seed.dart` + `?? test/per_daypart_v1_slice3_demo_seed_snapshot_test.dart` (+ this audit doc). `git diff --stat`: 1 lib file, +170/-7. No `mock_integration_replay_seed.dart`, no shift/benchmark/scorer/auth files, no other seed functions. |
| 2 | Single-function localization | PASS | All seed edits are inside `_seedWeeklyPlanSnapshotFromReplay` (cycle hydration, snapshot ctor args, child persistence) + the one adjacent new private helper `_buildSeedDayDaypartRows`. No other seed function (`_seedDemoRestaurant`, `_ensureDemoSeedCycle`, `_seedDemoWageRoleRows`, `_seedOpenShiftSnapshotsFromReplay`, etc.) touched — concurrency-safe for the parallel Slice C/E/F workers on this same file. |
| 3 | Authority order | PASS | Prompt > plan Slice 3 + Design Rule 4/8 > CLAUDE.md HP #2. Runtime parity is the binding directive ("Mirror the runtime path"); `_buildSeedDayDaypartRows` is a verbatim formula replica of `WeeklyPlanSnapshotService._buildDayDaypartRows` invoked with no `applicablePeriodIdsByWeekday` map exactly as `_buildDayDaypartRowsForLock` does (`weekly_plan_snapshot_service.dart:365-370`). |
| 4 | Hard Promise #2 (demo writer-side only) | PASS | Same tables: `weekly_plan_snapshots` + `weekly_plan_snapshot_day_dayparts` + `wage_at_lock_time_json` column — the exact tables/column the runtime writer uses (`weekly_plan_snapshot_dao.dart:122-141`). No `demo_*` table created. No `kDemoMode` branch added. No reader fork — `schedule_forecast_notifier.adjustedDayViews` is unchanged and reads whatever the scope's tables hold. This is a pure writer-side bootstrap, identical demo/prod read math. |
| 5 | HP #3 (no app-logic change before 7.58) | PASS | No formula/decision change. The per-period values are computed by the same formula the runtime auto-generator already runs; this only makes the demo *persist* what runtime would have produced, so the demo exercises the already-shipped Slice 3 read path instead of the legacy allocator fallback. |
| 6 | Design Rule 4 (pool-consistency / canonical pool path) | PASS | Per-period sub-rows derive from the seeded cycle's `target_cycle_dayparts` (hydrated via `TargetCycleDao.getDaypartsForCycle`), whose parent whole-day scalars are already the cover-weighted `TargetCycleDaypartPool.fromDayparts` rollup written by `_ensureDemoSeedCycle` (`sqlite_database_seed.dart` `_buildDemoSeedCycle` → `TargetCycleDaypartPool.fromDayparts`). No hand-rolled pool. Test "pool-consistency" asserts `cycle.targetCPLH/SPLH/PPA == pool` exactly and Σ(period covers) reconciles to the day pooled figure within per-period rounding. |
| 7 | Design Rule 8 (wage-at-lock-time stamp) | PASS | `WeeklyPlanSnapshotWagesAtLockTime(fohWage: cycle.fohWage, bohWage: cycle.bohWage, blendedWage: ActiveTargetProfile.computeTargetBlendedWage(...))` — byte-identical construction to `weekly_plan_snapshot_service.dart:199-209`. Test asserts the stamp equals the cycle-in-force wages + canonical blended formula (`closeTo 1e-9`). |
| 8 | Design Rule 5 (wages stay whole-day) | PASS | `_buildSeedDayDaypartRows` computes `periodFohDollars = periodReqFohHours * cycle.fohWage` / `periodBohDollars = periodReqBohHours * cycle.bohWage` — per-period hours × whole-day wage, no per-period wage column. Mirrors runtime exactly. |
| 9 | Closed-truth immutability | PASS | The `existing.isNotEmpty` no-op guard (`sqlite_database_seed.dart` ~line 347) returns *before* any parent/child write when a snapshot already covers the in-force week, so a same-week replay advance (`reseedMockReplayForBusinessDate`, where `weekly_plan_snapshots` is replay-stable / NOT cleared) never reaches the new child delete/insert — already-locked rows are never rewritten. `reseedDemo` is an explicit full reset (clears `weekly_plan_snapshots`); no closed-truth preservation contract applies there. |
| 10 | Determinism / idempotency | PASS | No RNG. Per-period rows derive from the already-deterministic seeded cycle + the deterministic `SchedulePlanResolver` day rows. `reseedDemo` clears the parent but NOT `weekly_plan_snapshot_day_dayparts`; the deterministic snapshot_id would collide on the child PK, so the new code does `db.delete(... where snapshot_id=?)` before insert (replace-for-snapshot). Test "determinism / HP #2" reseeds twice and asserts byte-identical child rows + wage stamp + stable snapshot_id. |
| 11 | Reader-consumption (Gap-12 actually closed in demo) | PASS | Test "Plan-tab reader consumes the locked persisted sub-rows" loads the seeded snapshot via the production repository path (`SqliteWeeklyPlanSnapshotRepository.getSnapshotForWeekKey` → DAO `_fromRowWithChildren` hydrates child rows), feeds it into `ScheduleForecastNotifier.lockedAuthority` + `setLockedSnapshotForTest`, and asserts `adjustedDayViews` renders one sub-row per persisted period with covers == the persisted (cover-weighted) set — which the fixed-weight allocator could not produce. The exact gate `snapshot.dayDayparts.isNotEmpty` (notifier:519-520) is asserted true. |
| 12 | Persistence-shape parity with DAO | PASS | Child insert mirrors `WeeklyPlanSnapshotDao.upsertSnapshot` (`weekly_plan_snapshot_dao.dart:128-140`): same delete-by-snapshot_id, same `dp['snapshot_id']` + `dp['created_at']` injection, same `WeeklyPlanSnapshotDayDaypart.toMap()` column shape; columns match `weekly_plan_snapshot_day_dayparts` schema (`sqlite_database_schema.dart:418-430`). Parent map still strips `day_dayparts` (not a parent column) and JSON-encodes `wage_at_lock_time_json` (existing handling, now exercised because `wageAtLockTime != null`). |
| 13 | No-op / DAO-reentrancy safety | PASS | Used `TargetCycleDao(db)` (constructor takes the in-flight `Database` directly, no singleton re-entry) — the same pattern `_ensureDemoSeedCycle` already uses at `TargetCycleDao(db).upsertCycle(cycle)`. Child persistence uses bare `db.delete` + `db.batch()` (no nested `db.transaction`), consistent with the existing bare parent `db.insert` in this function — safe inside `_onCreate`. |
| 14 | Analyzer / tests green; no `@visibleForTesting` misuse in prod | PASS | `dart analyze` clean on both touched files. Did NOT call `WeeklyPlanSnapshotService.debugBuildDayDaypartRows` (it is `@visibleForTesting`; calling from production seed code would be `invalid_use_of_visible_for_testing_member`) — replicated the pure formula instead, matching the file's established inlined-replica convention. 14 targeted + 61 snapshot-suite tests pass. |

## Residual notes / honest limitations

- `Σ(period covers)` reconciles to the day pooled figure only within
  per-period plain-rounding tolerance (≤ period count). This is
  **intentional and faithful** — the runtime lock path
  (`_buildDayDaypartRows`) uses the same per-period `.round()` with no
  largest-remainder reconciliation. Adding reconciliation here would
  make the seeded shape diverge from the live auto-generator, which the
  prompt forbids ("byte-equivalent to what the runtime auto-generator
  would have produced"). The exact Design-Rule-4 invariant
  (`cycle pool == cover-weighted Σ period`) holds exactly at the cycle
  level via `TargetCycleDaypartPool` and is asserted in the test.
- The orchestrator will rebase at merge per the prompt's concurrency
  note; the hunk is intentionally localized to one function + one
  adjacent helper to minimize conflict with the parallel Slice C/E/F
  workers on this same file.
