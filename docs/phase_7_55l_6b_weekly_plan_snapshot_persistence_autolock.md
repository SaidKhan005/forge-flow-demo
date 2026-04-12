# Phase 7.55l.6b - WeeklyPlanSnapshot Persistence + Auto-Lock Spine

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Implemented (6b/6b1/6b2/6b3)

## Purpose

Add the first persistence-backed WeeklyPlanSnapshot runtime spine:

- SQLite `weekly_plan_snapshots` table
- DAO and repository implementation of the existing contract
- a narrow service that can read the snapshot in force for the current
  business week
- auto-generate and auto-lock the current week's snapshot when it does
  not exist

This makes WeeklyPlanSnapshot real in persistence without yet migrating
runtime consumers onto it.

## What This Slice Adds

### SQLite Persistence

One `weekly_plan_snapshots` table with:

- `snapshot_id` (PK)
- `restaurant_id`
- `week_key` (derived, stored for index/lookup)
- `week_start_date`, `week_end_date`
- `target_cycle_id`
- weekly totals: `forecast_covers`, `forecast_sales`,
  `required_foh_hours`, `required_boh_hours`,
  `theoretical_foh_labor_dollars`, `theoretical_boh_labor_dollars`,
  `theoretical_labor_pct`, `target_blended_wage`
- `covers_source`, `sales_source`
- `generated_at`, `locked_at`
- `day_rows_json` (serialized day-level rows as JSON text)

Guardrail: one snapshot per restaurant per week key
(`UNIQUE(restaurant_id, week_key)`).

No daypart snapshot tables in this slice.

### DAO + Repository Implementation

Implements the `WeeklyPlanSnapshotRepository` contract from 7.55l.6a:

- `getSnapshotForBusinessDate` — finds the snapshot where the business
  date falls within `[weekStartDate, weekEndDate]`
- `getSnapshotForWeekKey` — direct lookup by restaurant + week key
- `upsertSnapshot` — insert or replace

### WeeklyPlanSnapshotService

Narrow runtime seam for current-week snapshot access:

- determines the current business date using mock replay business date
  first, latest closed business date fallback (same anchor precedence
  as the planning stack)
- derives the current business-week span via `WeeklyPlanSnapshotPolicy`
- reads an existing current-week snapshot if present
- if missing, generates and persists a locked snapshot for the current
  week using `TargetCycleService` + `SchedulePlanReadService`
- returns the existing locked snapshot unchanged on subsequent reads

### Generation Bridge

In this slice, generation maps from:

- `TargetCycleService.getOrCreateActiveCycle()` for the active cycle id
- `SchedulePlanReadService.getCurrentWeeklyPlan()` for the resolved
  weekly plan
- `SchedulePlan.dayPlans` mapped to `WeeklyPlanSnapshotDay` with
  business dates derived from the week span

This is a current-week auto-lock spine only. No arbitrary historical-
week regeneration. No rewrite of an existing current-week snapshot.

## Contract Rules Preserved

- One locked snapshot per restaurant per week (Rule 1)
- Auto-generate at week start (Rule 2)
- Missing snapshot recovery from current cycle + demand (Rule 3)
- Midweek cycle refresh does not rewrite the locked week (Rule 4)
- No draft/publish workflow (Rule 5)
- No manager forecast adjustments (Rule 6)
- No intended UX change (Rule 7)

### Mock Replay Weekly-Lock Preservation (7.55l.6b1)

Mock replay reseed (`reseedMockReplayForBusinessDate`) preserves the
locked `weekly_plan_snapshots` table. Advancing mock replay by one day
within the same business week does not wipe or regenerate the locked
snapshot.

- `reseedMockReplayForBusinessDate` intentionally skips
  `weekly_plan_snapshots` cleanup — locked weekly truth survives
  same-week replay advance
- `reseedDemo` (full demo reset) and `clearAllData` still clear all
  snapshots for clean-slate test and reset paths
- replay advance into a new business week can still generate a new
  snapshot for that new week normally

### Target-Cycle Linkage Preservation (7.55l.6b2)

Same-week replay reseed preserves both the locked weekly snapshot and
its referenced `target_cycles` row. The locked snapshot's
`targetCycleId` always resolves to an existing cycle row after
same-week replay advance — no dangling references.

- `reseedMockReplayForBusinessDate` intentionally skips
  `target_cycles` cleanup — the locked snapshot's cycle linkage must
  remain valid across same-week replay advance
- `reseedDemo` (full demo reset) and `clearAllData` still clear all
  target cycles for clean-slate test and reset paths
- replay advance into a new business week can still generate a new
  target cycle and weekly snapshot normally

### Active-Profile Projection Preservation (7.55l.6b3)

Same-week replay reseed preserves the cycle-projected
`ActiveTargetProfile` alongside the locked weekly snapshot and its
referenced target cycle. Replay advance does not leave runtime
planning truth internally split.

- `reseedMockReplayForBusinessDate` skips `_seedDemoActiveTargetProfile`
  when a preserved active cycle already exists — the cycle's projected
  profile must not be overwritten with baseline-seeded truth
- `reseedDemo` (full demo reset) clears `target_cycles` first, so the
  cycle check finds no preserved cycle and seeds normally from baseline
- `clearAllData` still clears `active_target_profiles` for clean-slate
  reset paths
- after same-week replay advance, the locked weekly snapshot, preserved
  target cycle, and active profile all remain internally consistent
- this preserves the 7.55l.4a architecture rule: persisted
  `ActiveTargetProfile` is the projection of the current active
  `TargetCycle`

## What This Slice Does Not Do

- No consumer migration (Schedule, Shift, Variance, History, Audit, Learn)
- No daypart snapshot persistence
- No historical backfill job
- No restaurant-configurable week start (Monday default for now)
- No SchedulePlan math changes
- No labor formula changes
- No demand math changes
- No manager UX changes
- No tracker file changes

## Deferred Follow-Ups

- Restaurant-configurable week-start day (from settings)
- Consumer migration onto the locked snapshot (7.55l.7)
- Daypart-level snapshot persistence (7.55k or later)
- Historical backfill for past weeks

## Cross-References

- Contract: `docs/phase_7_55l_6a_weekly_plan_snapshot_contract.md`
- Architecture rules: `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- WeeklyPlanSnapshot model: `lib/domain/models/weekly_plan_snapshot.dart`
- WeeklyPlanSnapshotRepository: `lib/domain/repositories/weekly_plan_snapshot_repository.dart`
- WeeklyPlanSnapshotPolicy: `lib/domain/services/weekly_plan_snapshot_policy.dart`
- WeeklyPlanSnapshotDao: `lib/infrastructure/persistence/sqlite/dao/weekly_plan_snapshot_dao.dart`
- SqliteWeeklyPlanSnapshotRepository: `lib/infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart`
- WeeklyPlanSnapshotService: `lib/data/weekly_plan_snapshot_service.dart`
