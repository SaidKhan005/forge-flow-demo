# Phase 7.55n.5 â€” Service-Period Close vs Shift Finalization

Updated: 2026-04-13
Owner: Claude implementation
Status: Complete

## What This Slice Establishes

- Service-period end and shift finalization are now separate runtime concepts.
- `ShiftBoundaryResolver` is a pure, deterministic domain service with
  explicit methods for:
  - `servicePeriodHasEnded()` â€” classification boundary only.
  - `isShiftFinalized()` â€” closed historical truth boundary.
  - `isEligibleForClosedTruth()` â€” downstream gate for WTD, History, Learn.
- Current live locked-WTD closed-truth membership now consults finalization
  authority via `ShiftBoundaryResolver`.
- Under `appLocalCutoffFallback`, a same-business-date closed row is no
  longer treated as finalized in the locked WTD path. The current
  operational business date must be strictly later than the row's business
  date.
- Under `vendorFinalization`, any vendor-closed row is immediately finalized.
- App-local fallback uses operational business-date progression as the
  compatibility finalization seam in this slice.
- Falls back to existing closed-row behavior when timing config or
  operational business date is unavailable.

## Design Decisions

### Pure resolver, no runtime dependencies

`ShiftBoundaryResolver` is a pure domain service with no database, clock,
or singleton dependencies. All methods are static and work from explicit
inputs. This keeps the finalization decision testable and composable.

### Service-period end is classification-only

`servicePeriodHasEnded()` answers whether a configured service period has
ended at a given restaurant-local timestamp. For same-day periods, this is
straightforward: ended when local time is at or past the end time. For
rollover periods (e.g. late_night 23:00-02:00), the active window spans
midnight and the period has ended when local time falls in the gap between
end and start.

This is classification-only. A service period ending does NOT imply the
shift is finalized or that the row is closed historical truth.

### Finalization depends on ShiftCloseAuthority

`isShiftFinalized()` consults the restaurant's configured
`ShiftCloseAuthority`:

- `vendorFinalization`: a row with status `'closed'` is immediately
  finalized. The vendor/source system owns close truth.
- `appLocalCutoffFallback`: a closed row becomes finalized only when the
  current operational business date is strictly later than the row's
  business date. A same-business-date closed row is NOT yet finalized.

The operational business date comes from open-shift snapshot authority
(what business day is it now?), not from the planning-anchor date.

### Closed-truth eligibility is the single downstream gate

`isEligibleForClosedTruth()` composes the finalization check. Downstream
consumers (WTD, History, Learn, benchmark evidence) should use this gate
instead of checking `status == 'closed'` alone.

In this slice, only the locked WTD path is wired. The non-locked WTD path,
`closeShift()`, historical-week queries, and History/Learn are not yet
migrated to finalization-aware filtering.

### Compatibility fallback in ShiftService

`_buildLockedWeekToDate()` now:

1. Loads timing config for `shiftCloseAuthority`.
2. Loads operational business date from `OpenShiftSnapshotRepository`.
3. Filters closed rows through `ShiftBoundaryResolver.isEligibleForClosedTruth`.

When timing config or operational business date is unavailable, all closed
rows are used (pre-7.55n.5 behavior). This is an explicit compatibility
fallback, not hidden truth.

### Operational business date is the runtime seam

This slice uses `OpenShiftSnapshotRepository.getCurrentBusinessDate()` as
the operational business date for finalization. This is the same authority
that ShiftService already uses for live operational reads. Full raw-local-
fallback-clock evaluation has not landed.

## What This Slice Does NOT Do

- Does not change business-date resolver behavior; `7.55n.2` owns that.
- Does not change service-period definition resolution; `7.55n.3` owns that.
- Does not change week-start wiring semantics; `7.55n.4` owns that.
- Does not migrate persisted `weekId` fields across models/tables.
- Does not remove or redesign the 14-shift week-record materialization.
- Does not change `shift_records` schema or status enum values.
- Does not rewrite mock replay seeding.
- Does not make Shift live daypart-aware; `10.5` owns that.
- Does not change History / Learn week-record consumption broadly.
- Does not add manager-facing settings UI.
- Does not broadly migrate `weekId`-based queries.
- Does not normalize metadata timestamps; `7.55n.6` owns that.
- Does not claim full raw-local-fallback-clock evaluation has landed.

## Remaining Compatibility Gaps (Documented Honestly)

### Non-locked WTD path

`ShiftService.getWeekToDate()` still uses `getShiftsForWeek(weekId)` and
does not consult `ShiftBoundaryResolver`. This path uses ISO weekday-number
ordering for last-closed-day and treats all closed rows as finalized.

### closeShift() vendor-ingest path

`ShiftService.closeShift()` does not consult finalization authority. It
writes the closed row and materializes a `WeekRecord` at 14 shifts. The
vendor-ingest semantics are unchanged.

### Historical week queries

`getWeekHistory()`, `getHistoricalClosedShifts()`, and
`getHistoryPatternRecords()` still consume `weekId`-based shift queries
and treat all closed rows as finalized truth. Broad finalization-aware
migration for History/Learn is not in scope for this slice.

### 14-shift week-record retirement

The 14-shift week-record materialization in `closeShift()` is unchanged.
Broad week-record retirement is deferred.

### Mock replay seed

Seeded/replayed closed rows for the current business date still carry
`status == 'closed'`. Under `appLocalCutoffFallback`, these same-date
rows are now excluded from the locked WTD path. The mock replay seed is
not rewritten in this slice.

## Files Created

- `lib/domain/services/shift_boundary_resolver.dart`
- `test/shift_boundary_resolver_test.dart`
- `docs/archive/phases/7_55n/phase_7_55n_5_service_period_close_vs_shift_finalization.md`

## Files Modified

- `lib/data/shift_service.dart`
  - Added imports for `ShiftBoundaryResolver`, `RestaurantTimingConfig`,
    `RestaurantTimingConfigReadService`
  - `_buildLockedWeekToDate()` now filters closed rows through
    `ShiftBoundaryResolver.isEligibleForClosedTruth` using active timing
    config and operational business date
  - Compatibility fallback preserves pre-7.55n.5 behavior when timing
    config or operational business date is unavailable
  - Updated file header comment
- `test/week_start_wiring_test.dart`
  - Updated test G `closedDayNumber` expectation to reflect finalization-
    aware behavior (Day 4 Thursday instead of Day 5 Friday, because Friday
    is the same-business-date under appLocalCutoffFallback)

## Phase Ownership

- `7.55n.1` â€” persistence seam (complete)
- `7.55n.2` â€” BusinessDateResolver (complete)
- `7.55n.3` â€” ServicePeriodDefinitionResolver (complete)
- `7.55n.4` â€” week-start wiring (complete)
- `7.55n.5` â€” this slice: service-period close vs shift finalization
- `7.55n.6` â€” metadata timestamp normalization
- `10.5` â€” live Shift service-period behavior
