# Phase 7.55m.4 — Driver Parity Audit / Cleanup

Updated: 2026-04-12 (7.55m.4a honesty tightening)
Owner: Claude implementation
Status: Implemented

## What This Slice Establishes

An explicit account of how primary-driver detection works across Shift
and Variance today, why the outputs can legitimately differ, and what
remains deferred.

## Shared Engine

All real driver computation goes through one function:

```text
LaborModel.determineLever(...)
```

This function accepts actual and target values for covers, PPA, CPLH,
SPLH, wages, and hours, then returns the lever id with the largest
deviation from target. It is stateless and pure — the same inputs always
produce the same output.

No parallel driver formula exists anywhere in the codebase.

## Surface Scopes

### Shift (whole-day current-state)

- **Caller**: `ShiftDashboardReadModel.buildWholeDay()`
- **Scope**: all closed + open snapshots for the current business day,
  aggregated as a whole-day summary
- **Actuals**: covers and sales from closed + open snapshots (not
  projected)
- **Hours**: actual-to-date hours from closed + open, full-day scheduled
  hours for model comparison
- **Forecast**: day-row forecast covers from the locked SchedulePlan
- **Visible UI**: metric card DRIVER badge (hero card indicator)
- **Hidden UI**: the full PRIMARY DRIVER teaching section is commented
  out — deferred until daypart-aware Shift in Phase 10.5

### Variance WTD (week-to-date)

- **Callers**: `ShiftService.getWeekToDate()` and
  `ShiftService._buildLockedWeekToDate()`
- **Scope**: all closed shifts in the current week, aggregated as a
  WTD summary
- **Actuals**: WTD covers, sales, hours from closed shifts only
- **Hours**: WTD scheduled hours vs WTD model hours from target profile
- **Forecast**: WTD forecast covers (closed shifts' forecast values, or
  locked snapshot day rows through the last closed day)
- **Visible UI**: full PRIMARY DRIVER section with `LeverCardWidget`
  showing the lever name, direction, and teaching copy

### Historical Weekly (full-week rollup)

- **Caller**: `ShiftService._buildWeekRecord()`
- **Scope**: all 14 closed shifts for a completed week
- **Uses**: locked shift-level targets for weighted averages
- **Visible UI**: week detail view lever badge in History

### Full Week Open/Projected Rows (placeholder)

- **Caller**: `CurrentWeekState.shiftRecordFromSnapshot()`
- **Value**: hardcoded `'ON_MODEL'`
- **This is a placeholder.** Open and projected rows do not compute a
  real lever because they lack the closed-shift actual-vs-target
  comparison that drives meaningful lever detection. `ON_MODEL` is the
  neutral default.
- **Visible UI**: lever badge on expanded Full Week row detail
- **Honest status**: `ON_MODEL` is a neutral placeholder, not a claim
  about the row's actual-vs-target position.
  - **Projected rows** have no live actuals yet, so there is nothing
    to compare against target. The placeholder is factually inert.
  - **Open rows** may already carry live partial actuals (covers, PPA,
    CPLH, etc.) that could deviate from target. The placeholder is
    still assigned because row-scope driver detection is not yet
    modeled — not because the row is genuinely neutral.
  - Future `7.55k` work should define an honest row-scope driver
    contract that distinguishes "no data yet" from "has data but
    no driver contract."

## Why Shift and Variance Outputs Can Differ

The engine is shared, but the inputs differ:

| Dimension | Shift | Variance WTD |
|---|---|---|
| Time window | Current business day | All closed days this week |
| Covers source | Closed + open snapshots | Closed shifts only |
| Hours scope | Actual-to-date + full-day scheduled | WTD actual + WTD model |
| Forecast baseline | Day-row forecast from plan | WTD closed-shift forecast |
| Wage inputs | Not passed (omitted) | WTD blended wages |

Because the inputs differ, the largest-deviation lever can legitimately
differ. For example:
- Shift might show `covers_down` because today's covers are light
  relative to today's forecast
- Variance might show `cplh_down` because across the full WTD window,
  FOH productivity is the dominant deviation

This is not a bug. It is correct behavior from different scopes.

## What Remains Deferred

### Shift PRIMARY DRIVER teaching section (Phase 10.5)

The full teaching takeaway on the Shift screen is commented out. The
current comment says it needs "whole-day actuals vs daypart targets
alignment." More precisely: the Shift lever is computed from a whole-day
aggregate, but in Phase 10.5 the Shift screen will become
daypart-live and the driver should reflect the current service period's
actual-vs-target comparison. Showing a whole-day aggregate lever as
if it is a current-service-period teaching signal would be misleading.

The DRIVER badge on the Shift metric cards is still visible. This is
acceptable — it highlights which metric is driving variance without
making a service-period claim.

### Full Week row-scope semantics (7.55k)

Future `7.55k` work should:
- define an honest row-scope driver contract that distinguishes
  "no data yet" (projected) from "has data but no driver contract" (open)
- add richer closed-row driver detail with daypart evidence
- stop using a single neutral placeholder for rows with meaningfully
  different data states

### Daypart-live driver (10.5)

Phase 10.5 owns:
- live service-period Shift with real driver teaching
- current-daypart primary lever based on service-period actuals
- real "time into service" display

## Files Changed

- `lib/screens/shift_dashboard.dart` (tightened hidden-section comment)
- `lib/models/shift_dashboard_read_model.dart` (scope comment on lever call)
- `lib/models/current_week_state.dart` (honest comment on ON_MODEL placeholder)
- `test/variance_visual_widget_test.dart` (driver parity tests)

## Test Coverage

- `LaborModel.determineLever` can yield different results from different
  scopes (same engine, different inputs)
- Variance PRIMARY DRIVER section renders
- Full Week open/projected rows use `ON_MODEL` placeholder
- Shift DRIVER badge still renders on hero card
- Shift PRIMARY DRIVER teaching section remains hidden
