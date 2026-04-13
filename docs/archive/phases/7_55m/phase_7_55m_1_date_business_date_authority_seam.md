# Phase 7.55m.1 — Date / Business-Date Authority Seam

Updated: 2026-04-12
Owner: Claude implementation
Status: Implemented (7.55m.1a day-order unification completed)

## What This Slice Adds

### Shared planning-anchor date seam

A small `BusinessDateAuthorityService` centralizes the planning-anchor
precedence that was previously duplicated across four services:

```text
1. Mock replay current business date (when available)
2. Latest closed business date (fallback)
```

Previously duplicated in:
- `BaselineManagerService.getCandidateShifts()`
- `DemandForecastContextService.getCurrentContext()`
- `SchedulePlanReadService.loadDistributionWeights()`
- `WeeklyPlanSnapshotService._resolveCurrentBusinessDate()`

Now all four delegate to
`BusinessDateAuthorityService.resolvePlanningAnchorDate(restaurantId)`.

### Explicit planning vs operational authority split

The codebase now has an explicit boundary between:

- **Planning-anchor authority** (`BusinessDateAuthorityService`):
  used by Baseline, Demand, Schedule Plan, and Weekly Plan Snapshot
  services to determine the reference date for 60-day windows,
  forecast anchoring, and week identification.

- **Operational current-shift authority** (`ShiftService` +
  `OpenShiftSnapshotRepository`): used by Shift dashboard, Variance
  Full Week, and current-week state to determine what business day
  is operationally "now" from the perspective of open/live shifts.

These are intentionally separate seams. The planning anchor resolves
from mock replay state and closed shift history. The operational
authority resolves from open-shift snapshot state.

### Canonical day ordering

A single `CanonicalDayOrder` class in `lib/domain/canonical_day_order.dart`
provides the Mon–Sun ordering truth. It lives in the domain layer so both
domain models and data-layer services can reference it cleanly.

Both `BusinessDateAuthorityService` and `ScheduleDistributionWeights`
delegate their day-order constants to this shared source. No parallel
canonical Mon–Sun ordering constants remain in active runtime code.

Display-layer 1-based numbering is derived from the canonical 0-based
order where needed, rather than maintaining a separate ordering constant.

## What This Slice Does Not Add

- No real live Shift clock or daypart-live behavior (Phase 10.5)
- No restaurant-configurable week start (deferred — documented below)
- No `7.55k` row-scope or daypart semantics work
- No `10.5` live daypart primary driver
- No manager UX changes

## Deferred: Restaurant-Configurable Week Start

The current week-start default is Monday (`DateTime.monday`). Restaurant
settings should eventually control this. That remains deferred to a
future slice because:

- `WeeklyPlanSnapshotPolicy` already accepts `weekStartDay` as a
  parameter, so the plumbing is partially ready
- The Settings screen does not yet expose week-start configuration
- The planning-anchor and snapshot services would need to read the
  restaurant's configured week start at resolution time

This is documented honestly as a known gap, not hidden.

## Files Changed

- `lib/domain/canonical_day_order.dart` (new — 7.55m.1a shared day-order source)
- `lib/data/business_date_authority_service.dart` (new — 7.55m.1a delegates day-order to shared source)
- `lib/data/baseline_manager_service.dart` (migrated anchor resolution)
- `lib/data/demand_forecast_context_service.dart` (migrated anchor resolution)
- `lib/data/schedule_plan_read_service.dart` (migrated anchor resolution)
- `lib/data/weekly_plan_snapshot_service.dart` (migrated anchor resolution)
- `lib/data/shift_service.dart` (clarifying comments, canonical day-order reuse)
- `lib/domain/models/schedule_distribution_weights.dart` (7.55m.1a delegates day-order to shared source)
- `test/business_date_authority_service_test.dart` (new)

## Test Coverage

- Shared authority returns mock replay business date when present
- Shared authority falls back to latest closed business date when mock
  replay date is absent
- Shared authority returns null when neither source is available
- Migrated planning services still resolve anchor dates correctly
- Canonical day ordering is consistent and reusable
- Day ordering is truly shared from one source (`CanonicalDayOrder`)
- No parallel canonical day-order constants remain in active runtime code
- Operational Shift/open-snapshot authority is not collapsed into the
  planning-anchor seam
