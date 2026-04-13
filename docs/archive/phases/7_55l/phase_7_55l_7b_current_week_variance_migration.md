# Phase 7.55l.7b - Current-Week Variance / WeekData Migration

Updated: 2026-04-11 (7.55l.7b1 forecast completion)
Owner: Codex planning / tracker truth
Status: Implemented (7.55l.7b + 7.55l.7b1)

## Purpose

Move current-week Variance / WTD state onto the locked cycle/week
architecture so the app's current-week `WeekData` reads from:

- the locked `WeeklyPlanSnapshot` for weekly forecast truth
- the snapshot-linked `TargetCycle` for target standards

instead of deriving current-week comparison truth from the live
profile/forecast state.

## What This Slice Adds

### Cycle Lookup by ID

A narrow `getCycleById(cycleId)` read seam added to:

- `TargetCycleRepository` (abstract contract)
- `TargetCycleDao` (SQLite implementation)
- `SqliteTargetCycleRepository` (repository implementation)

This lets current-week WTD load the cycle referenced by
`WeeklyPlanSnapshot.targetCycleId` without depending on the
current live active cycle.

No broad historical query interface. No schema changes.
No new write behavior.

### Current-Week WeekData Migration

`ShiftService.getLiveWeekToDate()` now:

1. Loads the locked `WeeklyPlanSnapshot` for the current week
2. If available, loads the snapshot-linked `TargetCycle` by ID
3. Projects the cycle to `ActiveTargetProfile` for theoretical
   labor % derivation
4. Builds `WeekData` with:
   - `totalWeekForecastCovers` from the locked snapshot weekly total
   - `wtdForecastCovers` from the locked snapshot day rows summed
     through the last closed business day (not from per-shift
     `ShiftRecord.forecastCovers`)
   - target standards (CPLH, SPLH, PPA, wages) from the locked cycle
   - theoretical labor percentages from the cycle projection
   - actual closed-shift aggregation unchanged
5. Falls back to existing live behavior when no snapshot or cycle
   is available

Both weekly total forecast and WTD forecast comparison truth come
from the locked snapshot for the current week. Actual closed-shift
aggregation (covers, sales, hours, labor dollars) still comes from
shift records.

### Historical-Week Behavior Preserved

`getWeekToDate(weekId, weekLabel)` is unchanged. Historical-week
queries continue on their existing path. This slice is strictly
current-week only.

### Variance Wording Honesty

`variance_report.dart` section label updated from:

- "WEEK-TO-DATE vs BASELINE" → "WEEK-TO-DATE vs LOCKED PLAN"

This honestly reflects the architecture truth: current-week WTD
now compares actuals against the locked weekly plan, not a generic
baseline.

## What This Slice Does Not Do

- No historical-week migration
- No History / Learn migration
- No Schedule Builder migration
- No daypart snapshot projection
- No SchedulePlan math changes
- No labor formula changes
- No demand math changes
- No WeeklyPlanSnapshot persistence redesign
- No tracker file changes

## Locked vs Live Behavior

### Current week (snapshot exists)

```text
WeeklyPlanSnapshot
  → totalWeekForecastCovers (locked weekly forecast total)
  → wtdForecastCovers (locked day-row sum through last closed day)
  → targetCycleId
    → TargetCycle
      → ActiveTargetProfile projection
        → target CPLH, SPLH, PPA, wages
        → theoretical labor percentages
Closed shift_records
  → actual covers, sales, hours, labor dollars
```

### Current week (no snapshot — fallback)

Same as pre-7.55l.7b behavior: live profile + shift-summed forecast.

### Historical weeks

Unchanged. `getWeekToDate(weekId, weekLabel)` uses the live active
profile and shift-summed forecast covers.

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- First consumer migration: `docs/archive/phases/7_55l/phase_7_55l_7a_first_consumer_migration_slice.md`
- Snapshot contract: `docs/archive/phases/7_55l/phase_7_55l_6a_weekly_plan_snapshot_contract.md`
- Snapshot persistence: `docs/archive/phases/7_55l/phase_7_55l_6b_weekly_plan_snapshot_persistence_autolock.md`
- TargetCycle model: `lib/domain/models/target_cycle.dart`
- TargetCycle repository: `lib/domain/repositories/target_cycle_repository.dart`
- WeeklyPlanSnapshot model: `lib/domain/models/weekly_plan_snapshot.dart`
- WeeklyPlanSnapshotService: `lib/data/weekly_plan_snapshot_service.dart`
- ShiftService: `lib/data/shift_service.dart`
- WeekData: `lib/models/week_data.dart`
- Variance report: `lib/screens/variance_report.dart`
