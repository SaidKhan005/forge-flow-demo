# Phase 7.55l.5f - Demand Audit Truth Cleanup

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Implemented

## Purpose

Fix the Data Alignment Audit panel so its demand section uses honest
rolling-demand v2 terminology instead of labeling that might imply every
displayed value is 60-day baseline context only.

This is an audit/debug surface change, not a manager UX change.

## What This Slice Fixes

### Section Header

The demand section header was `DEMAND FORECAST CONTEXT`. This is now
`DEMAND CONTEXT (ROLLING)` to explicitly communicate that the displayed
context is rolling demand, not a static or locked baseline-only snapshot.

Both the loaded-state and empty/null-state paths now use the same
`DEMAND CONTEXT (ROLLING)` label (empty-state aligned in 7.55l.5g).

### Explicit v2 Field Usage

The demand section reads explicit v2 field names directly from
`DemandForecastContext` rather than compatibility aliases:

- `BASELINE TOTAL COVERS (60-DAY)` — from `baselineTotalCovers`
- `BASELINE WEEKLY AVG (60-DAY)` — from `baselineWeeklyAvgCovers`
- `RECENT TOTAL COVERS (3-WEEK)` — from `recentThreeWeekTotalCovers`
- `RECENT WEEKLY AVG (3-WEEK)` — from `recentThreeWeekWeeklyAvgCovers`
- `TREND DELTA` — from `recentTrendDeltaCovers`
- `RESOLVED WEEKLY FORECAST` — from `resolvedWeeklyForecastCovers`
- `DEMAND SOURCE` — from `coversSource`
- `ANCHOR DATE` — from `anchorBusinessDate`

No compatibility aliases (`historicalTotalCovers`,
`historicalWeeklyAvgCovers`, `weeksRepresented`) are used in the panel.

## What This Slice Does Not Do

- No demand math changes
- No changes to `DemandForecastContext` model
- No changes to `DemandForecastContextService`
- No changes to `DemandForecastContextNotifier`
- No manager UX changes
- No WeeklyPlanSnapshot persistence
- No consumer migration

## Cross-References

- Rolling demand v2 model: `docs/archive/phases/7_55l/phase_7_55l_5a_rolling_demand_context_v2.md`
- DemandForecastContext model: `lib/domain/models/demand_forecast_context.dart`
- Audit panel: `lib/widgets/data_alignment_audit_panel.dart`
