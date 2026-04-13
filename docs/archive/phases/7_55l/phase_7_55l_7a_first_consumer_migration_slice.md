# Phase 7.55l.7a - First Consumer Migration Slice

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Implemented

## Purpose

Start consumer migration onto the locked cycle/week architecture by
adding a first-class locked-week read seam and moving a narrow first
set of current-week runtime readers onto it.

This is the first migration slice only. Schedule Builder preview/edit
flows, History, Learn, and broader consumer migration are deferred.

## What This Slice Adds

### WeeklyPlanSnapshot to SchedulePlan Projector

A pure static projector that converts a locked `WeeklyPlanSnapshot`
back to `SchedulePlan` shape for downstream consumers:

- Maps weekly totals directly: forecast covers, forecast sales,
  required FOH/BOH hours, theoretical FOH/BOH labor dollars,
  theoretical labor pct, target blended wage, covers source, sales
  source
- Maps day rows from `WeeklyPlanSnapshotDay` to `ScheduleDayPlan`
- No daypart rows in this projection (matches whole-day SchedulePlan)
- No persistence, no side effects — pure projection only

### Locked Current-Week Read Seam

`SchedulePlanReadService.getCurrentLockedWeeklyPlan()`:

- Loads the current `WeeklyPlanSnapshot` via
  `WeeklyPlanSnapshotService.getCurrentWeekSnapshot()` (which
  auto-generates and auto-locks if missing)
- Projects it to `SchedulePlan` shape via the projector
- Returns null cleanly when the current business date cannot be
  determined

No recursion path: `WeeklyPlanSnapshotService` uses the existing
live-resolved `getCurrentWeeklyPlan()` for generation. The locked
read path calls `WeeklyPlanSnapshotService` which may call the live
path, but the live path never calls back — no circular call chain.

The existing live-resolved path (`getCurrentWeeklyPlan`) is preserved
unchanged for generation bridge use and Schedule Builder preview.

### Migrated Consumers

Three consumers now use the locked weekly plan when available:

1. **`ShiftService.getShiftDashboard()`** — reads the locked current-
   week day plan for forecast covers, sales, and required hours.
   Falls back to live resolution gracefully if no snapshot exists.

2. **`ShiftDashboardNotifier._load()`** — same locked-first read path
   with live fallback for the shift dashboard reactive layer.

3. **`DataAlignmentAuditPanel`** — reads the locked current-week plan
   for its Schedule Forecast and Schedule Plan display sections.
   Labels are updated to indicate whether the plan is snapshot-backed
   ("LOCKED WEEKLY") or live-resolved ("LIVE RESOLVED").

### Audit Label Honesty

`DataAlignmentAuditPanel` now tracks whether the displayed plan came
from the locked weekly snapshot or from live resolution. Section
titles reflect the actual source:

- "SCHEDULE FORECAST (LOCKED WEEKLY)" when snapshot-backed
- "SCHEDULE PLAN (LOCKED WEEKLY)" when snapshot-backed
- "SCHEDULE FORECAST (LIVE RESOLVED)" when falling back to live
- "SCHEDULE PLAN (LIVE RESOLVED)" when falling back to live

## What This Slice Does Not Do

- No Schedule Builder preview/edit migration
- No History / Variance consumer migration
- No Learn consumer migration
- No daypart snapshot projection
- No SchedulePlan math changes
- No labor formula changes
- No demand math changes
- No manager UX changes
- No tracker file changes

## Seam Constraint Preserved

`WeeklyPlanSnapshotService` generates snapshots using
`SchedulePlanReadService.getCurrentWeeklyPlan()` (the live path).

The new `getCurrentLockedWeeklyPlan()` does NOT create a circular
dependency with snapshot generation:

- `getCurrentLockedWeeklyPlan()` calls
  `WeeklyPlanSnapshotService.getCurrentWeekSnapshot()`
- If a snapshot exists, it is returned directly (no generation)
- If missing, `WeeklyPlanSnapshotService` generates via
  `getCurrentWeeklyPlan()` (the live path)
- The live path never calls `getCurrentLockedWeeklyPlan()` or
  `WeeklyPlanSnapshotService`

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Snapshot contract: `docs/archive/phases/7_55l/phase_7_55l_6a_weekly_plan_snapshot_contract.md`
- Snapshot persistence: `docs/archive/phases/7_55l/phase_7_55l_6b_weekly_plan_snapshot_persistence_autolock.md`
- Projector: `lib/domain/services/weekly_plan_snapshot_schedule_plan_projector.dart`
- Locked read seam: `lib/data/schedule_plan_read_service.dart`
- WeeklyPlanSnapshotService: `lib/data/weekly_plan_snapshot_service.dart`
