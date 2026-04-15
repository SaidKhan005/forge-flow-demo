# Phase 7.55p.2 — Variance WTD / Full Week Alignment
Status: Landed

## Goal
Align Variance WTD table and Full Week projection table to the architecture
contract so target-side values come from locked Plan truth plus
Benchmark-owned standards, not from actual-volume model-hour leakage.

## Scope
- In: WTD target hours, WTD blended wage, driver carry-forward, row copy,
  Full Week open/projected target package, snapshot blended wage preservation,
  mixed-status summary removal
- Out: Full Week shift-level target hours (stays model-hours per Ch10),
  Dollar Impact accumulation (7.55p.3), projection recalculation

## What Changed

### WTD target alignment
`WeekData` gains optional `planFohHoursWtd` / `planBohHoursWtd` fields
populated from locked `WeeklyPlanSnapshotDay.requiredFohHours` /
`requiredBohHours` in `_buildLockedWeekToDate()`. New getters
`targetFohHoursWtd` / `targetBohHoursWtd` return plan hours when
available, model hours as fallback (compatibility path).

### WTD blended wage
`theoreticalBlendedWage` now weights target wages by plan-aligned target
hours instead of actual-volume model hours.

### Driver carry-forward
`VarianceWeekProjectionReadService._driverLabel()` carries forward the
most recent closed lever from the same daypart for open/projected rows.
Falls back to "Not yet available" when no prior closed shift exists for
that daypart.

### Full Week open/projected target package (7.55p.2a)
`ShiftRecord` gains `snapshotBlendedWage` — an explicit target-side field
populated from `OpenShiftSnapshot.blendedWage` via
`CurrentWeekState.shiftRecordFromSnapshot`. This preserves the
snapshot/plan blended wage instead of discarding it and falling back to
generic config wage math.

`_ProjectedShiftDetail` now renders the full plan target package for
open/projected rows:
- Covers (plan/forecast)
- FOH Hours (plan/scheduled)
- BOH Hours (plan/scheduled)
- Blended Wage (snapshot truth)
- Labor % (theoretical/benchmark context)

### Mixed-status summary removal (7.55p.2a)
Collapsed day rows no longer render the count summary text (e.g.,
"1 Closed, 1 Projected"). The daypart status chips (`L✓ D→`) already
carry status composition visually. The read model still computes
`statusSummary` internally for any downstream consumer that needs it.

### Copy cleanup
- Full Week day-row covers: removed `cvr` suffix
- Projected total label: `target` -> `Target`

## Touched Writers

| File | What changed |
|---|---|
| `lib/models/week_data.dart` | Added `planFohHoursWtd`, `planBohHoursWtd`, `targetFohHoursWtd`, `targetBohHoursWtd` getters; updated `theoreticalBlendedWage` |
| `lib/data/shift_service.dart` | `_buildLockedWeekToDate()` sums plan hours from snapshot day rows |
| `lib/models/shift_record.dart` | Added `snapshotBlendedWage` field (7.55p.2a) |
| `lib/models/current_week_state.dart` | `shiftRecordFromSnapshot` preserves snapshot blended wage (7.55p.2a) |
| `lib/services/variance_week_projection_read_service.dart` | Driver carry-forward logic; capitalized status summary |
| `lib/screens/variance_report.dart` | WTD uses `targetFohHoursWtd`/`targetBohHoursWtd`; projected detail renders FOH/BOH hours + blended wage; removed status summary text from collapsed day rows; copy fixes |
| `test/wtd_variance_logic_test.dart` | 4 plan-alignment tests (group "WeekData plan-aligned target hours") |
| `test/variance_week_projection_read_service_test.dart` | 6 carry-forward tests (group I), 1 capitalization test (group J), 3 snapshot blended wage tests (group K); updated group E assertion |
| `test/variance_visual_widget_test.dart` | Updated mixed-status test (group H); added plan target package tests (group I) |

## Follow-up Gaps
- Full Week expanded-shift target hours remain model-hours per Ch10
  execution variance semantics. If plan-hours comparison is wanted at
  shift level, it needs daypart-level plan rows (not currently modeled).
- `getWeekToDate()` (compatibility path) does not populate plan hours —
  plan fields are null, fallback to model hours is correct.
- Dollar Impact accumulation model deferred to 7.55p.3.
