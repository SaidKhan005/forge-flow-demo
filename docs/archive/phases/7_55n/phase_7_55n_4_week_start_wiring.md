# Phase 7.55n.4 â€” Week-Start Wiring

Updated: 2026-04-13
Owner: Claude implementation
Status: Complete (includes 7.55n.4a locked-WTD honesty cleanup)

## What This Slice Establishes

- Current-week snapshot identity now reads the restaurant-owned
  `weekStartDay` from `RestaurantTimingConfig`.
- Snapshot `weekStartDate`, `weekEndDate`, and `weekKey` derive from the
  configured week-start day instead of hidden Monday truth.
- Snapshot day rows are rotated to match the configured week start so
  labels and business dates stay aligned.
- Monday remains an explicit default fallback when timing config is
  unavailable â€” not hidden truth.
- Locked current-week WTD forecast accumulation in `ShiftService` now
  uses business-date comparison instead of ISO weekday-number ordering,
  so it stays honest regardless of the configured week-start day.

## Design Decisions

### One runtime seam â€” no duplication

`WeeklyPlanSnapshotService._resolveWeekStartDay()` reads the persisted
timing config via `RestaurantTimingConfigReadService` and returns the
configured `weekStartDay`, or `DateTime.monday` when config is
unavailable. This single seam feeds all `WeeklyPlanSnapshotPolicy` calls
in the service.

### Day-row rotation for configured week start

`SchedulePlan.dayPlans` is always Monâ€“Sun ordered by the resolver.
When the configured week start is not Monday, `_buildDayRows` rotates
the day plans so the first entry matches the configured week-start day.
This ensures day labels and sequentially assigned business dates align
correctly.

Rotation offset: `(weekStartDay - 1) % 7` where Monday = 1.

Examples:
- Monday start (1): offset 0, no rotation â†’ Monâ€“Sun
- Sunday start (7): offset 6, Sun comes first â†’ Sunâ€“Sat
- Wednesday start (3): offset 2, Wed comes first â†’ Wedâ€“Tue

### Locked WTD closed-shift membership (7.55n.4a)

`ShiftService._buildLockedWeekToDate()` previously loaded closed shifts
via `getShiftsForWeek(restaurantId, weekId)`. The `weekId` is an
ISO/Monday-based compatibility string, so for non-Monday restaurants the
locked WTD actuals could exclude the configured week-start day or
include the wrong trailing day.

The locked path now uses `getClosedShiftsInDateRange(restaurantId,
snapshot.weekStartDate, snapshot.weekEndDate)` so actual closed-truth
membership follows the configured snapshot week span.

The non-locked WTD path (`getWeekToDate`) and `getCurrentWeekId()` still
use `weekId`-based queries. Broad `weekId` migration has not landed.

### Locked WTD closedDayNumber (7.55n.4a)

`closedDayNumber` previously used ISO weekday numbering via
`BusinessDateAuthorityService.dayNumber(lastDayLabel)`. For a
Sunday-start restaurant, the first closed Sunday read as Day 7, not
Day 1.

The locked path now derives `closedDayNumber` from the latest closed
business date's position inside the configured snapshot week span:
```
closedDayNum = closedDt.difference(weekStartDt).inDays + 1
```

For Sunday-start, the first closed Sunday is Day 1. For Wednesday-start,
the first closed Wednesday is Day 1.

### Locked WTD business-date forecast comparison

WTD forecast cover accumulation uses business-date comparison against
the snapshot's own week-span boundaries:
```
d.businessDate >= snapshot.weekStartDate && d.businessDate <= maxClosedDate
```

This uses the snapshot's own week-span truth and works correctly
regardless of the configured week-start day.

### Monday default is explicit fallback, not hidden truth

When `RestaurantTimingConfigReadService` returns null, the service
explicitly falls back to `DateTime.monday`. The fallback is documented
in code comments and in this slice doc.

## What This Slice Does NOT Do

- Does not change business-date resolver behavior; `7.55n.2` owns that.
- Does not change service-period definition resolution; `7.55n.3` owns that.
- Does not model service-period close vs shift finalization; `7.55n.5`.
- Does not normalize metadata timestamps; `7.55n.6`.
- Does not make Shift daypart-live; `10.5`.
- Does not broadly migrate persisted `weekId` fields across
  models/tables.
- Does not change `ShiftService.getShiftsForWeek` query semantics â€” it
  still queries by ISO-format `weekId` string.
- Does not migrate the non-locked `getWeekToDate` path's day-number
  ordering.
- Does not add manager-facing settings UI.
- Does not add vendor transport or broad integration work.

## Remaining Compatibility Gaps (Documented Honestly)

### weekId-based shift queries (non-locked paths)

`ShiftService.getShiftsForWeek(restaurantId, weekId)` and
`getCurrentWeekId()` still use the ISO-format `weekId` string from
seeded/replayed shift data. This `weekId` is inherently Monday-based.

The locked WTD path (`_buildLockedWeekToDate`) now uses
`getClosedShiftsInDateRange` instead. But `getWeekToDate()` (the
non-locked path), `closeShift()`, and historical-week queries still
use `weekId`-based membership.

A full migration would require either:
- rewriting `weekId` values when week start changes, or
- switching all shift queries to business-date-range-based lookups

Neither is in scope for this slice.

### Non-locked WTD path

`ShiftService.getWeekToDate()` still uses ISO weekday-number ordering
for last-closed-day determination. This path operates on `weekId`-based
shift queries and does not consult the weekly plan snapshot, so the
week-start configuration does not affect it yet.

### Historical week-id migration

Persisted `weekId` fields on `ShiftRecord`, `WeekRecord`, and
`OpenShiftSnapshot` are not migrated. They remain ISO-week-formatted
strings from seeding/replay. A broad `weekId` migration is explicitly
out of scope per the hard constraints.

## Files Created

- `docs/archive/phases/7_55n/phase_7_55n_4_week_start_wiring.md`
- `test/week_start_wiring_test.dart`

## Files Modified

- `lib/data/weekly_plan_snapshot_service.dart`
  - Added `_resolveWeekStartDay()` runtime seam
  - `getCurrentWeekSnapshot()` now reads configured `weekStartDay` and
    passes it to all `WeeklyPlanSnapshotPolicy` calls
  - `_generateAndPersistSnapshot()` accepts and forwards `weekStartDay`
  - `_buildDayRows()` rotates day plans to match configured week start
  - Added import for `RestaurantTimingConfigReadService`
- `lib/data/shift_service.dart`
  - `_buildLockedWeekToDate()` now loads closed shifts via
    `getClosedShiftsInDateRange` using the snapshot date span instead
    of the compatibility `weekId` query (7.55n.4a)
  - `closedDayNumber` now derived from position inside the configured
    snapshot week span, not ISO weekday numbering (7.55n.4a)
  - WTD forecast accumulation uses business-date comparison
  - Added `_parseDate` helper

## Phase Ownership

- `7.55n.1` â€” persistence seam (complete)
- `7.55n.2` â€” BusinessDateResolver (complete)
- `7.55n.3` â€” ServicePeriodDefinitionResolver (complete)
- `7.55n.4` â€” this slice: week-start wiring
- `7.55n.5` â€” service-period close vs shift finalization
- `7.55n.6` â€” metadata timestamp normalization
- `10.5` â€” live Shift service-period behavior
