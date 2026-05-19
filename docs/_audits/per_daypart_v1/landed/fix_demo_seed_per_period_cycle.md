# Fix — Demo seed writes differentiated per-period cycle rows

**Branch:** `claude/per-daypart-fix-demo-seed-per-period-cycle`
**Base:** `master`
**Slice tag:** per-daypart-targets-v1 demo-fidelity fix (Slice 1 + Gap 42 + Decision 4)
**Owner:** worker agent (Claude lane)
**Verdict:** approve-for-merge (pending orchestrator independent audit)

---

## TL;DR

The per-daypart V1 engine is correct and tested, but the **demo showed
one identical target for every daypart** because the demo seed never
persisted the cycle's per-period rows. `_buildDemoSeedCycle` built the
demo `TargetCycle` with whole-day scalars only (via the now-`@Deprecated`
`recommendation.pooledRecommendedTarget*` / `unionOpz*` accessors) and
`_ensureDemoSeedCycle` persisted it with a raw single-table
`db.insert('target_cycles', …)` that never touched
`target_cycle_dayparts`. Net: `cycle.dayparts` was always empty → every
per-period read hit the Gap-42 whole-day fallback → one pooled number
everywhere.

Fix: `_buildDemoSeedCycle` now builds a `List<TargetCycleDaypart>` for
the three demo service periods (`lunch` / `dinner` / `late_night`),
preferring each period's `recommendation.perDaypartStats[periodId]` and
falling back to the deterministic demo band (the same constants already
stamped onto demo closed shifts, exposed via a new public
`MockIntegrationReplaySeed.demoDaypartTargetBand` accessor so the demo
*always* shows differentiated targets). The parent whole-day scalars are
computed via the canonical `TargetCycleDaypartPool.fromDayparts(...)`
rollup (Design Rule 4) — the deprecated pooled/union accessors are gone.
`_ensureDemoSeedCycle` now persists through Slice 1's canonical write
path `TargetCycleDao(db).upsertCycle(cycle)`, which writes the parent
row + `target_cycle_dayparts` child rows in one transaction. No
hand-rolled second child-table writer.

Demo-mode only. No `kDemoMode` reader branch, no `demo_*` table, no
schema change (Slice 1 created the tables). The whole-day half is
untouched.

---

## Files changed

| File | LoC | Note |
|---|---|---|
| `lib/dev/mock_integration_replay_seed.dart` | +49 −0 | New top-level `DemoDaypartTargetBand` value type. New public `demoServicePeriodIds` list + `demoDaypartTargetBand(periodId)` accessor exposing the existing private `_daypartTarget*` / `_daypartOpz*` maps (returns `null` for unknown id — Design Rule 2, never a `0` sentinel). No behaviour change to existing seed generation. |
| `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` | +66 −26 | `_buildDemoSeedCycle` rewritten: computes per-period candidate cover totals over the same calibration-window closed-shift cohort the recommendation engine consumed, builds differentiated `TargetCycleDaypart` rows (per-period rec stats → demo-band fallback), passes `dayparts:` to the cycle, and sets the parent whole-day scalars from `TargetCycleDaypartPool.fromDayparts(...)`. Deprecated `pooledRecommendedTarget*` / `unionOpz*` accessors removed. `_ensureDemoSeedCycle` now persists via `TargetCycleDao(db).upsertCycle(cycle)` (parent + child, one txn) instead of raw `db.insert('target_cycles', …)`. |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | +1 −0 | Added `import 'dao/target_cycle_dao.dart';` so the part-file seed can reach the canonical cycle DAO. No cycle (the DAO imports only `target_cycle.dart` + sqflite). |
| `test/per_daypart_v1_demo_seed_per_period_cycle_test.dart` | +134 (new) | 3 regression tests: (1) demo active cycle hydrates differentiated `lunch`/`dinner`/`late_night` rows from `target_cycle_dayparts`; (2) parent whole-day scalars equal `TargetCycleDaypartPool.fromDayparts(cycle.dayparts)` (Design Rule 4, no deprecated accessor); (3) the projected `ActiveTargetProfile` differentiates `daypartFor()` across periods. |

Total: **+116 / −26** across 3 lib files + **+134** new test.

---

## Pattern B audit — 14 lenses

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Fix prompt #1 → `core_app_architecture.md` #2 → plan Slice 1/Gap 42/Decision 4 #3 → `CLAUDE.md` #4. Implements exactly the prompt's required fix: differentiated per-period rows via the canonical write path; parent pool = cover-weighted rollup; deprecated accessors removed; demo-mode only. No conflict with Layer 9 (whole-day authoritative; per-period adjacent). | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:795–873`; plan doc Slice 1 + Gap 42 | None |
| 2 | **Hard Promises** | HP #2 honored — same SQLite tables (`target_cycles` + Slice-1 `target_cycle_dayparts`), no `kDemoMode` branch, no `demo_*` table; the writer change is purely which write path the demo seeder calls. HP #3 (no app logic before 7.58) — this only changes *seed data fidelity*; no decision/formula path changed. HP #4 — `TargetCycleDao.upsertCycle` writes are scoped by `cycle.restaurantId` (= `DemoScope.restaurantId`); no new scope surface. | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:786–800`; `CLAUDE.md` "Demo Mode" | None |
| 3 | **Service-layer split** | Demo seed lives in `lib/infrastructure/persistence/sqlite/` (bootstrap). Persistence routed through the existing canonical `TargetCycleDao` (the established seam — `SqliteTargetCycleRepository` wraps the same DAO but binds the singleton DB, unusable mid-bootstrap). Demo target constants stay in `lib/dev/` and are exposed via an accessor, not duplicated. No `lib/data/` touch, no Postgres import, no `lib/auth/` touch. | `lib/infrastructure/persistence/sqlite/dao/target_cycle_dao.dart:33–63`; `lib/dev/mock_integration_replay_seed.dart` accessor | None |
| 4 | **Architecture guardrails** | `TargetCycle` / `TargetCycleDaypart` / `TargetCycleDaypartPool` / `LaborModel` models untouched (Slice-1 domain models are out of scope per concurrency note). Parent pool is the rollup of per-period rows via the canonical helper — no widget/seed owns source-truth bucketing. Whole-day scalars remain the legacy cache, now correctly derived. | `lib/domain/models/target_cycle.dart:102–148` (consumed, unchanged) | None |
| 5 | **Time guardrails** | No timestamp logic added. Calibration window still derived from `businessDate` via the existing `_addIsoDays`; cover totals are summed over the same calibration-window closed-shift candidate cohort the recommendation engine already uses (`_seedRecommendationCandidates`). No `TIMESTAMP WITHOUT TIME ZONE`, no schema change. | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:838–870` (cohort source, unchanged) | None |
| 6 | **RLS-ready schema** | No schema change — `target_cycle_dayparts` was created by Slice 1; this fix only *writes* it via the existing DAO (parent + child in one txn, replace-for-cycle semantics). No new table/column/index. Operator scope carried by `restaurant_id` on the parent + `cycle_id` FK on the child, unchanged. | `lib/infrastructure/persistence/sqlite/dao/target_cycle_dao.dart:40–62` (consumed) | None |
| 7 | **Proxy & API conventions** | No proxy route, idempotency key, version path, service principal, or Postgres extension. Entirely client-side SQLite seed write. | n/a | None |
| 8 | **Testing seam** | Smallest set proving the seam: (1) end-to-end `reseedDemo()` → read active cycle via `SqliteTargetCycleRepository` → assert 3 differentiated per-period rows actually round-trip the child table (would be empty under the old bug); (2) Design Rule 4 pool-consistency — parent scalars `closeTo` `TargetCycleDaypartPool.fromDayparts`; (3) projected `ActiveTargetProfile.daypartFor()` differentiates (mirrors the runtime `_syncActiveTargetProfile` mapping). Nearest existing suites (`target_cycle_service_test`, `target_cycle_daypart_pool_test`, `mock_integration_replay_seed_test`) re-run green. | `test/per_daypart_v1_demo_seed_per_period_cycle_test.dart:38–133` | None |
| 9 | **Operator-facing copy / UX writing standard** | No operator-facing copy added (seed-data fix). The downstream effect is the operator now sees *different* lunch/dinner/late-night targets in the demo instead of one repeated number — correcting a misleading display. No "roadmap" word. | n/a | None |
| 10 | **Demo mode contract** | No `kDemoMode` reader branch. Demo and prod still read the same tables via the same DAO. The only change is the demo *writer* now uses the canonical cycle write path (the same one `TargetCycleService` uses in prod) instead of a raw single-table insert — strictly more HP-#2-compliant than before. No `demo_*` table. `CLAUDE.md` Demo Mode carve-outs §1–4 untouched. | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:786–800`; `CLAUDE.md` "Demo Mode" | None |
| 11 | **Migration / drift** | No `db/migrations/*.sql` change — tables pre-exist from Slice 1. Migration drift scanner / cutoff lint not applicable. | n/a | None |
| 12 | **Concurrency / parallel-worker isolation** | Did NOT touch `shift_dashboard.dart`, `shift_service_period_notifier.dart`, or any Slice-1 domain model / migration (the parallel worker's surface). Stayed inside the demo-seed path (`sqlite_database_seed.dart`, `mock_integration_replay_seed.dart`, `sqlite_database.dart` import line) + the new test file. The `target_cycle_dao.dart` import is read-only consumption of an existing seam. | `git diff --stat` (3 lib files + 1 new test, no shift/notifier/model files) | None |
| 13 | **Transaction safety** | `TargetCycleDao.upsertCycle` opens `db.transaction(...)`. Both demo-seed call paths are safe: the reseed/advance path (`reseedMockReplayForBusinessDate`) is a plain `Database` sequence (first transaction — fine); the cold-boot `_onCreate` path runs under sqflite's implicit open-time transaction, where sqflite's reentrant `transaction()` executes the action within the existing transaction (the established, documented sqflite pattern). All targeted + integration suites that exercise both paths pass. | `lib/infrastructure/persistence/sqlite/sqlite_database.dart:95–140` (`_onCreate`); `:382–443` (reseed path) | None |
| 14 | **Regression baseline** | New file analyzes clean; all 3 new tests pass. `target_cycle_service_test` / `target_cycle_daypart_pool_test` / `mock_integration_replay_seed_test` / `demo_mode_writer_side_test` all green. `test/current_state_alignment_test.dart` shows one failure (`B — getShiftDashboard returns null when no locked weekly plan exists`) — verified **pre-existing on `HEAD` (master)** by reverting all lib changes and re-running: the same test fails identically without this PR. **Not introduced by this change.** | baseline snapshot below | None (pre-existing, not this PR) |

---

## Verification commands + results (CI is dark — local runs)

- `flutter pub get` → ok (fresh worktree).
- `dart analyze lib/dev/mock_integration_replay_seed.dart lib/infrastructure/persistence/sqlite/sqlite_database.dart lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart lib/infrastructure/persistence/sqlite/dao/target_cycle_dao.dart test/per_daypart_v1_demo_seed_per_period_cycle_test.dart` → **No issues found!**
- `flutter test test/per_daypart_v1_demo_seed_per_period_cycle_test.dart` → **+3 All tests passed!**
- `flutter test test/per_daypart_v1_demo_seed_per_period_cycle_test.dart test/target_cycle_service_test.dart test/target_cycle_daypart_pool_test.dart test/mock_integration_replay_seed_test.dart` → **+90 All tests passed!**
- `flutter test test/integration/demo_mode_writer_side_test.dart` → green (run alongside the new test).
- `flutter test test/current_state_alignment_test.dart` → one failure: `B — getShiftDashboard returns null when no locked weekly plan exists` (Expected `null`, Actual `ShiftDashboardReadModel`).

### Pre-existing-failure baseline proof

Reverted all three lib changes to `HEAD` (`git checkout -- <3 files>`),
re-ran `flutter test test/current_state_alignment_test.dart --plain-name
"getShiftDashboard returns null when no locked weekly plan exists"` →
**same failure, `+0 -1`, identical Expected/Actual.** Restored changes
(re-analyze clean, new tests still green). The failure is latent on
master and independent of this PR; it is not in
`docs/KNOWN_FAILING_TESTS.md` and should be tracked separately by the
orchestrator.

---

## Out of scope / notes for orchestrator

- The runtime `ActiveTargetProfile` per-period read seam
  (`TargetCycleService._syncActiveTargetProfile` →
  `_profileRepo.upsertActiveTargetProfile`) and the SQLite profile
  DAO's flat `toMap`/`fromMap` (no daypart hydration) are unchanged and
  out of scope — consumers reattach per-period rows from the cycle DAO.
  This fix only makes the demo cycle carry the rows; the existing
  runtime read path (proven by the 345-test engine suite) lights up.
- Pre-existing `current_state_alignment_test.dart` failure (lens 14) is
  a master-latent issue surfaced incidentally; flagged for separate
  triage, not addressed here (scope discipline).
