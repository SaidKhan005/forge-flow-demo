# Phase 7.55m.3 — Shift Time Truthfulness Cleanup

Updated: 2026-04-12
Owner: Claude implementation
Status: Implemented

## What This Slice Adds

### Fake service-elapsed text removed

The Shift header previously rendered
`readModel.timeLabel · readModel.serviceElapsedLabel`, which came from
static strings seeded on `OpenShiftSnapshot` during demo/replay mode.
That made the header look live while actually being frozen.

The `serviceElapsedLabel` display (`"3h 14m into service"`) is removed.
No replacement "time into service" indicator is added — that is Phase
10.5 work requiring real daypart-live service-period tracking.

### Real wall-clock display

The header time is now a small ticking `_LiveClock` widget that displays
the actual wall-clock time (formatted as `h:mm AM/PM`). It ticks every
30 seconds via a periodic timer.

This is a UI-only display. It does not:
- determine the current business date
- determine the current shift status
- infer the current daypart

Those remain snapshot-driven through the read model.

### Test seam

`ShiftDashboard.clockOverride` is a static `DateTime Function()?` that
tests can set to inject a deterministic time. When null (the default),
`_LiveClock` uses `DateTime.now()`.

## What This Slice Does Not Add

- No service-period timer or "time into service" replacement
- No live daypart driver teaching
- No daypart inference from wall clock
- No change to Variance / History / Learn
- No broader transport-model cleanup

## Deferred Fields

`timeLabel` and `serviceElapsedLabel` remain on `OpenShiftSnapshot` and
`ShiftDashboardReadModel` to avoid broad churn across test fixtures and
the read-model builder. They are marked with comments explaining they are
no longer the primary header time source. Future cleanup can remove them
when the snapshot/read-model shape is next revised.

## Files Changed

- `lib/screens/shift_dashboard.dart` (replaced header time, added `_LiveClock`)
- `lib/models/shift_dashboard_read_model.dart` (comment on deferred fields)
- `test/shift_visual_widget_test.dart` (updated header time test)

## Test Coverage

- Shift header no longer renders `serviceElapsedLabel` text
- Shift header renders a live clock value via the deterministic test seam
- Core Shift sections (metrics, OPZ, labor) still render normally
