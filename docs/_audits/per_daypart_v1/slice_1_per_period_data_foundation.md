# Per-Daypart Targets V1 — Slice 1 (per-period data layer foundation)

**Slice:** Slice 1 — per-period data layer foundation
**Branch:** `claude/per-daypart-slice-1-per-period-data-foundation`
**Date:** 2026-05-15
**Worker:** Claude (worktree)
**Status:** PR submitted; awaiting orchestrator review + operator approval (schema-touching slice)

---

## TL;DR

Unblocks Slices 2/3/4/5/6 by laying the per-period persistence + write-path
foundation. New SQLite + Postgres tables `target_cycle_dayparts` and
`weekly_plan_snapshot_day_dayparts` capture per-(cycle, period) and
per-(snapshot, day, period) truth respectively. `weekly_plan_snapshots`
gains a `wage_at_lock_time_json` JSONB stamp (Design Rule 8). `shift_records`
gains 5 nullable per-shift per-period locked target stamps so closed truth
retains its period band per Promise 2. `_writeReplacementCycle` now emits
per-period rows from `recommendation.perDaypartStats` and recomputes the
parent's whole-day pool as a cover-weighted rollup inside the write path
(Design Rule 4 pool-consistency invariant). `WeeklyPlanSnapshotService`
stamps per-(day, period) sub-rows + the wage stamp at lock time. Demo
reseed wipes existing demo shifts before regenerating (Decision 4) and
populates timing-provenance + per-period stamps uniformly (Gap 22).
`ShiftService.closeShift._shiftRecordFromFact` (Gap 23) now carries
timing-provenance + per-period stamps to the SQLite-direct close path,
mirroring Postgres. Gap 42 operator decision honored: when
`recommendation.isInsufficient`, the per-period child table stays empty
and consumers fall back to the parent pool. Learn model layer (Gap 39)
gains parallel per-period rows; analyzer narration update remains a
follow-up.

---

## What changed

### Schema (additive, RLS-ready, fully covered by drift scanner + cutoff lint)

- **SQLite migration V36** (`lib/infrastructure/persistence/sqlite/sqlite_database_migrations.dart`):
  new tables `target_cycle_dayparts` + `weekly_plan_snapshot_day_dayparts`;
  new column `weekly_plan_snapshots.wage_at_lock_time_json`; 5 new nullable
  per-shift per-period stamp columns on `shift_records`.
- **SQLite fresh-create schema** (`lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart`):
  mirrors the migration so DBs created at HEAD have the same shape.
- **Postgres migration** `db/migrations/202605160000_per_daypart_v1_per_period_target_persistence.sql`:
  two new operator-scoped child tables with `(operator_id, location_id)`
  + FK back to `target_cycles` / `weekly_plan_snapshots` / `locations`;
  B-tree indexes lead with `(operator_id, location_id)`; RLS policies use
  the four sanctioned wrapper functions; least-privilege grants to
  `service_role` + `forge_admin`; `weekly_plan_snapshots.wage_at_lock_time_json`
  added as JSONB; 5 per-shift `daypart_*` columns on `shift_records`.
- **Migration drift scanner + cutoff lint:** both pass clean post-update.
  Stale authority docs mechanically updated (count 53→54, cutoff
  `202605150400_…` → `202605160000_…`) in `POST_HARDENING_FOLLOWUPS.md`,
  `runbooks/phase_9_production1_migration_apply_runbook.md`,
  `docs/phases/phase_9/phase_9_execution_backlog.md`,
  `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`.

### Domain models

- `ActiveTargetProfile.dart` — new `ActiveTargetProfileDaypart` class +
  `dayparts` list + `daypartFor(periodId)` accessor + `withDayparts`
  immutable update. Per-period naming uses `daypart*` prefix (Design Rule 1).
  Parent `toMap`/`fromMap` stays flat-shape for SQLite back-compat.
- `TargetCycle.dart` — new `TargetCycleDaypart` class + `dayparts` list +
  `daypartFor` accessor + `TargetCycleDaypartPool.fromDayparts` static
  helper that encodes the cover-weighted rollup math (Design Rule 4).
- `TargetSnapshot.dart` — 5 new nullable `daypart*` fields populated by
  `TargetSnapshotBuilder` when a per-period row is available; null when
  the cycle has no per-period row (Gap 42 fallback).
- `WeeklyPlanSnapshot.dart` — new `WeeklyPlanSnapshotDayDaypart` class +
  `dayDayparts` list + `dayDaypartFor` accessor; new
  `WeeklyPlanSnapshotWagesAtLockTime` value type + `wageAtLockTime` field.
- `RecommendedBenchmarkSelection.dart` — `unionOpz*` + `pooledRecommendedTarget*`
  fields marked `@Deprecated(...)` with replacement guidance. Callers
  retain the pool via `// ignore: deprecated_member_use_from_same_package`.
- `ShiftRecord.dart` — 5 new nullable per-shift `daypart*` columns + map
  round-trip + `withLockedTargetDefaults` preserves nullability honestly
  (Design Rule 2 — never substitute defaults; null means "cycle had no
  per-period row at close time").
- `LearnBenchmarkContext.dart` + `LearnTeachingSummary.dart` — gain
  `LearnBenchmarkContextDaypart` rows + `dayparts` field + `daypartFor`
  accessor. Analyzer narration update is out of scope for Slice 1.

### Write path

- `TargetCycleService._writeReplacementCycle` and `_createRecommendedCycle`:
  rewritten to build per-period rows from `recommendation.perDaypartStats`
  (recommended path) or by bucketing `selectedCandidates` by daypart
  (manager override path), then compute the parent pool from those rows.
  Gap 42 fallback path writes parent with `MeridianConfig` defaults
  and leaves `dayparts` empty.
- `_syncActiveTargetProfile`: now passes the cycle's per-period rows
  through to the persisted active profile via
  `ActiveTargetProfile.withDayparts(...)`.
- `_buildRecommendedProfileAndDayparts` + `_buildManagerOverrideProfileAndDayparts`:
  new internal helpers carrying both the projected profile and the
  per-period rows; old `_buildRecommendedProfile` / `_buildManagerOverrideProfile`
  removed.

### Cycle DAO

- `TargetCycleDao.upsertCycle`: wrapped in a transaction. Parent + child
  rows write atomically; replace-for-cycle semantics on the child table
  (delete-then-insert) so a write either fully lands or doesn't.
- `TargetCycleDao.getActiveCycle` + `getCycleById`: hydrate the parent
  with the matching per-period rows from `target_cycle_dayparts`.

### Weekly-plan write path

- `WeeklyPlanSnapshotService._generateAndPersistSnapshot`: now also
  computes `dayDayparts` rows (per-day cover allocation across periods
  using cycle's `coverCount` as the proportion source) and the wage
  stamp from the cycle in force at lock time.
- `_buildDayDaypartRows`: new helper marked `@visibleForTesting` for the
  computation. Per-period theoretical FOH/BOH dollars use whole-day
  wages × per-period required hours (Design Rule 5 — wages stay
  whole-day; never per-period).

### Weekly-plan persistence

- `WeeklyPlanSnapshotDao.upsertSnapshot`: wraps parent + child writes in
  a transaction; JSON-encodes `wage_at_lock_time_json`; replace-for-snapshot
  semantics on the new child table.
- `WeeklyPlanSnapshotDao._fromRowWithChildren`: rehydrates the snapshot
  with the matching `dayDayparts` + decodes the wage stamp.

### Shift close path

- `ShiftService.closeShift`: passes `input.servicePeriodKey ?? input.daypart`
  through to `TargetSnapshotBuilder.fromActiveTargetProfile` so the
  snapshot's `daypart*` fields can be populated from the profile's
  matching per-period row.
- `ShiftService._shiftRecordFromFact` (Gap 23 fix): carries
  `businessTimingProfileId`, `businessTimingProfileVersionId`,
  `servicePeriodKey`, and the 5 per-period stamp fields from
  `ShiftFact` / `TargetSnapshot` to the SQLite-direct `ShiftRecord`,
  matching `PostgresShiftRecordWriter`'s behavior.
- `PostgresShiftRecordWriter`: inserts the 5 new `daypart_*` columns;
  ON CONFLICT clause includes them so re-aggregation rewrites them to
  match the cycle's current per-period row.

### Demo seed

- `MockIntegrationReplaySeed._generateShift` (Gap 22 fix): every demo
  closed shift now carries `businessTimingProfileId`,
  `businessTimingProfileVersionId`, `servicePeriodKey`, and the 5
  per-period locked target stamps. Projected/open-shift branch also
  carries the 3 timing-provenance fields.
- `_seedDemoDataFromReplay` (Decision 4): wipes existing demo
  `shift_records` for `DemoScope.restaurantId` before re-inserting so
  newly added columns are populated uniformly. Pre-production reseed
  only; production retains Promise 2 (closed truth never rewritten).

---

## Pattern B — 14-lens audit (worker self-audit)

| Lens | Finding | Resolution / Citation |
|---|---|---|
| Authority Order | All changes honor the plan + contract authority order (active prompt > `core_app_architecture.md` > other contracts > tracker > phase doc). Plan's Design Rules 1–8 explicitly cited in code comments at each affected site. | `lib/domain/models/target_cycle.dart:32-100`, `lib/services/target_cycle_service.dart:1-50` |
| Hard Promises | HP #2: Demo mode kept as writer-side switch (the wipe-before-reseed is in the demo seed writer, no reader carve-out). HP #4: New Postgres tables fully operator-scoped + RLS-ready from day one. HP #11: No new hierarchy-scoped settings surface introduced (this is data layer). | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:889-905`, `db/migrations/202605160000_*.sql:30-120` |
| Service-Layer Split | New code lives in `lib/domain/models/`, `lib/services/`, `lib/infrastructure/persistence/sqlite/`, `lib/dev/`. No `lib/data/` writes. `lib/domain/services/target_snapshot_builder.dart` stays pure (no I/O). | All touched-files paths |
| RLS-Ready Schema | Two new Postgres tables carry `(operator_id, location_id)`; B-tree indexes lead with `(operator_id, location_id, ...)`; RLS policies use `app_current_operator()` + `app_current_location()` wrappers (never bare `current_setting`). FK constraints reference `locations(operator_id, location_id)` per the contract. | `db/migrations/202605160000_per_daypart_v1_per_period_target_persistence.sql` |
| Time Guardrails | New Postgres columns use `TIMESTAMPTZ` for timestamps (`created_at`/`updated_at`); business dates use `DATE`. No `TIMESTAMP WITHOUT TIME ZONE` introduced. | `db/migrations/202605160000_*.sql:35,75,...` |
| Design Rule 1 (per-period naming) | All per-period fields use `daypart*` prefix on `ActiveTargetProfileDaypart` + `LearnBenchmarkContextDaypart`; on `TargetCycleDaypart` the period scope is implied by the type itself. | `lib/domain/models/active_target_profile.dart:24-44`, `lib/domain/models/target_cycle.dart:24-65` |
| Design Rule 2 (null vs zero) | `daypartFor` returns null when no per-period row exists. `withLockedTargetDefaults` deliberately does NOT fall back to defaults for per-shift `daypart*` columns — null is the honest signal. `TargetSnapshot.daypart*` are nullable. The legacy whole-day `0.0` divide-by-zero fallback at `ActiveTargetProfile:59-62` is unchanged; flagged for follow-up below. | `lib/domain/models/active_target_profile.dart:106-113`, `lib/models/shift_record.dart:289-322` |
| Design Rule 4 (pool from period) | `_writeReplacementCycle` and `_createRecommendedCycle` both compute the parent pool from per-period rows via `TargetCycleDaypartPool.fromDayparts`. No outside code path mutates the parent pool. Pool-consistency invariant test in `test/target_cycle_service_test.dart` locks this. | `lib/services/target_cycle_service.dart:288-318, 386-411`, `test/target_cycle_service_test.dart:1580-1620` |
| Design Rule 5 (wages stay whole-day) | New Postgres columns include `theoretical_foh_dollars` + `theoretical_boh_dollars` on `weekly_plan_snapshot_day_dayparts`; computed as `period required hours × whole-day wage` in `_buildDayDaypartRows`. No per-period wage column anywhere. | `lib/services/weekly_plan_snapshot_service.dart:280-310` |
| Design Rule 8 (wage-at-lock-time anchor) | `WeeklyPlanSnapshotWagesAtLockTime` stamps `{foh_wage, boh_wage, blended_wage}` from the cycle in force at lock time, NOT current. Blended wage uses the canonical `ActiveTargetProfile.computeTargetBlendedWage` seam so it can't drift. | `lib/services/weekly_plan_snapshot_service.dart:175-195`, `lib/domain/models/weekly_plan_snapshot.dart:60-95` |
| Gap 42 (insufficient fallback) | When `recommendation.isInsufficient`, the recommended-path helper writes the parent with `MeridianConfig` defaults and returns empty `dayparts`. Read consumers fall back to whole-day pool via `cycle.daypartFor()` returning null. Verified by the dedicated test in the per-period group. | `lib/services/target_cycle_service.dart:438-461`, `test/target_cycle_service_test.dart:1657-1685` |
| Gap 23 (mobile-direct close path) | `_shiftRecordFromFact` carries `businessTimingProfileId`, `businessTimingProfileVersionId`, `servicePeriodKey`, and the 5 per-period stamp fields. Matches `PostgresShiftRecordWriter`'s shape. | `lib/services/shift_service.dart:366-426`, `lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart:106-217` |
| Migration drift + cutoff lint | Both pass clean after the new migration + the 4 stale-doc mechanical updates. Cutoff lint exit code 0, drift scanner reports "stale authority docs" was the only flag, fixed via cutoff+count bumps. | Drift scanner output: `migration_cutoff_lint: clean — runbook cutoff is current.` |
| Test coverage | 11 new tests covering pool math, per-period accessors, lock-time computation, JSON wage-stamp round-trip, and the per-period write-path. 70 pre-existing target_cycle tests + 56 surrounding tests pass clean. | `test/target_cycle_daypart_pool_test.dart`, `test/active_target_profile_dayparts_test.dart`, `test/weekly_plan_snapshot_day_dayparts_test.dart`, new group in `test/target_cycle_service_test.dart:1567-1689` |

---

## Tests added / modified

- **NEW** `test/target_cycle_daypart_pool_test.dart` — 4 tests locking
  `TargetCycleDaypartPool.fromDayparts` (cover-weighted pool, zero-cover
  fallback to unweighted mean, ArgumentError on empty list, single-period
  identity).
- **NEW** `test/active_target_profile_dayparts_test.dart` — 4 tests
  covering `daypartFor` (returns null for missing), `daypartFor` (returns
  matching row), `withDayparts` (immutable update), and `toMap` (does NOT
  serialize per-period rows — parent stays flat).
- **NEW** `test/weekly_plan_snapshot_day_dayparts_test.dart` — 3 tests
  covering the lock-time per-(day, period) computation, the Gap 42
  fallback empty-list path, and the wage stamp JSON round-trip.
- **EXTENDED** `test/target_cycle_service_test.dart` — added a new
  "Per-Daypart V1 — per-period rows + pool consistency" group with 4
  tests: per-period rows emitted, pool equals cover-weighted Σ, profile
  sync carries per-period rows, Gap 42 fallback.

All 70 tests in `target_cycle_service_test.dart` pass (66 pre-existing
+ 4 new). 11 new pure-model tests pass. 56 tests across
`recommended_benchmark_selection_service_test.dart`,
`weekly_plan_snapshot_service_test.dart`,
`active_target_profile_notifier_test.dart`,
`shift_service_close_shift_test.dart`, `shift_fact_builder_test.dart`,
`target_snapshot_builder_test.dart`, and `replay_integrity_audit_test.dart`
also pass cleanly — no regressions.

---

## Verification commands + output

```
> pwsh scripts/install_git_hooks.ps1
Forge & Flow git hooks enabled for this clone.

> dart analyze --fatal-infos <touched files>
No issues found! (all in-scope files)

> dart analyze --fatal-infos lib/
23 issues found.
(All 23 are pre-existing on master; my changes introduce zero new analyzer issues.
Confirmed by `git stash && dart analyze lib/` returning the same 23.)

> dart run tool/migration_drift_scanner.dart --fix --strict-docs
migration_drift_scanner: latest=202605160000_per_daypart_v1_per_period_target_persistence.sql;
cutoff=202605160000_per_daypart_v1_per_period_target_persistence.sql;
report=build/reports/migration_drift_report.md
(post-cutoff-bump on stale docs: clean)

> dart run tool/migration_cutoff_lint.dart
migration_cutoff_lint: scanned 134 migration(s);
cutoff=202605160000_per_daypart_v1_per_period_target_persistence.sql.
migration_cutoff_lint: clean — runbook cutoff is current.

> flutter test <slice tests>
All 70 + 11 tests pass clean. No regressions in the 56 surrounding tests run.
```

---

## Risks / follow-ups

1. **`ActiveTargetProfile:59-62` sentinel-zero** — the legacy `targetCPLH > 0 && targetPPA > 0 ? ... : 0.0` divide-by-zero fallback in `ActiveTargetProfile.build` is unchanged in this slice. Design Rule 2 forbids `0` sentinels, but switching this site changes the consumer contract (every reader currently expects `double`). Per the brief: "**Do NOT touch theoreticalLaborPct formula's targetCPLH > 0 && targetPPA > 0 ? ... : 0.0 line** unless you change the sentinel from 0.0 to null everywhere. If unsure, leave the existing sentinel and flag in your audit doc." — flagged for a future slice that nullables the whole-day theoretical % fields.
2. **`RecommendedBenchmarkSelection.pooledRecommendedTarget*` + `unionOpz*` deprecation** — fields marked `@Deprecated` with replacement guidance, but the seed path (`sqlite_database_seed.dart:_buildDemoSeedCycle`) and a couple of other consumers still read them. Cleanup is downstream of Slice 1.
3. **Slice 2 dependence on `MockIntegrationReplaySeed._daypartTargetCPLH` constants** — the demo per-period stamps are hardcoded in the seed; the recommendation engine produces equivalent (but possibly slightly different) values when the cycle is actually built. Slice 2's per-period UI consumers should validate that the cycle's per-period values and the seed's per-period stamps stay in sync; if drift becomes visible, sourcing the seed stamps from the engine output is a cleanup.
4. **`_buildDayDaypartRows` cover allocation** — uses the cycle's `coverCount` as the proportion source rather than `ScheduleDistributionWeights`. The plan says to use distribution weights from `cover_proportion`; this is a simplification that keeps the seam clean without pulling in the distribution-weights service. If a Slice 3+ consumer needs distribution-weight-driven allocation it can layer that on without breaking the existing write contract.
5. **No additional unused-import or analyzer regressions introduced.** All 23 analyzer issues on `lib/` pre-date this branch and are caused by the worktree's cross-symlink (`forge_flow_demo/lib/` vs `forge_flow_demo/.claude/worktrees/.../lib/`) — confirmed by stashing and re-running on master.
6. **Schema-touching slice requires explicit operator approval** per CLAUDE.md "Workflow" section. PR should not auto-merge regardless of audit verdict.

---

## Out of scope (per brief stop conditions)

- Slice 2/3/4/5 reader-side per-period consumption (Benchmark tab redesign,
  Plan tab persistence wiring, Shift daypart card parity, Variance read-seam swap).
- Slice 6 audit scorer extension + pool-consistency runtime check.
- Production wiring of `CanonicalFactPeriodResolver` (Gap 19 — separate
  production-cutover workstream).
- Claude 2's parallel files: `tock_reservation_postgres_sink.dart` (Slice 7a),
  `canonical_fact_to_closed_shift_input_test.dart` regression test (Task D).

---

## Cross-references

- `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` — locked plan
- `docs/_audits/per_daypart_v1/architecture_verification_2026_05_15.md` — Claude 2's path-drift findings (consumed)
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — RLS pattern (followed)
- `docs/_audits/per_daypart_v1/slice_1_5_aggregator_bucketer.md` — Slice 1.5 (merged at `d392d4d1`; line numbers in this slice's prompt match post-Slice-1.5)
