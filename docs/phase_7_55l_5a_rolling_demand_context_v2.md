# Phase 7.55l.5a - Rolling DemandForecastContext v2

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Implemented — v2 demand context only, no weekly-plan persistence yet

## Purpose

Upgrade `DemandForecastContext` from baseline-only v1 to explicit rolling
demand v2 with two explicit layers and one resolved output:

1. 60-day baseline weekly average covers
2. fixed 3-week recent trend weekly average covers
3. resolved rolling weekly forecast covers (blended from layers 1 + 2)

This makes demand architecture-correct without changing manager UX and
without starting weekly-plan persistence or full day-allocation migration.

## What This Slice Adds

### DemandForecastContext v2 Model

Explicit fields for both demand layers plus resolved output:

- `baselineTotalCovers` — sum of covers in the 60-day baseline window
- `baselineWeeklyAvgCovers` — `round(baselineTotalCovers / (60 / 7))`
- `baselineWeeksRepresented` — constant `60 / 7`
- `recentThreeWeekTotalCovers` — sum of covers in the 21-day recent window
- `recentThreeWeekWeeklyAvgCovers` — `round(recentThreeWeekTotalCovers / 3)`
- `recentTrendDeltaCovers` — `recentThreeWeekWeeklyAvgCovers - baselineWeeklyAvgCovers`
- `resolvedWeeklyForecastCovers` — the blended output (see smoothing rule)

Compatibility accessors (transitional, no caller migration needed):

- `historicalTotalCovers` getter → `baselineTotalCovers`
- `historicalWeeklyAvgCovers` getter → `resolvedWeeklyForecastCovers`
- `weeksRepresented` getter → `baselineWeeksRepresented`

### Smoothing Rule

The resolved weekly forecast covers uses an explicit bridge smoothing rule:

- if both windows have eligible closed shifts:
  - `recentTrendDeltaCovers = recentThreeWeekWeeklyAvgCovers - baselineWeeklyAvgCovers`
  - `resolvedWeeklyForecastCovers = max(0, baselineWeeklyAvgCovers + (recentTrendDeltaCovers / 2).round())`
- if only the baseline window has eligible closed shifts:
  - `resolvedWeeklyForecastCovers = baselineWeeklyAvgCovers`
- if the baseline window has no eligible closed shifts:
  - unavailable (genuinely no data — not merely zero covers)

This is:

- explicit — both layers visible, not blended into one opaque number
- stable — baseline anchors the forecast, trend only half-adjusts it
- not a hard switch to 3-week average
- not a complex forecast stack

### Zero-Demand Truth Semantics

Zero resolved weekly forecast covers is valid available demand when the
closed-history window exists. This truth propagates through the full stack:

- `DemandForecastContextService` — window availability is determined by the
  presence of eligible closed shifts, not by positive cover totals
- `DemandForecastContext.isAvailable` — true when `resolvedWeeklyForecastCovers`
  is non-null; zero is valid
- `ScheduleForecastDemandResolver.resolve(...)` — treats
  `historicalWeeklyAvgCovers = 0` as valid available demand, not as missing
- `ScheduleForecastDemandResolver.resolveFromContext(...)` — preserves
  zero-cover demand from the v2 context
- demo fallback only applies when demand is genuinely missing (`null`),
  not when demand is real zero

Truly unavailable means no eligible closed shifts in the relevant window —
not merely zero covers. This distinction matters because zero-cover demand
is an honest operational signal, not missing data.

### DemandForecastContextService v2 Build

The service now builds both demand layers from closed POS shifts:

- 60-day baseline window: inclusive 60 calendar days ending at anchor
- 3-week recent trend window: inclusive 21 calendar days ending at anchor
- anchor rule unchanged: mock replay date first, latest closed date fallback
- window availability: presence of eligible closed shifts, not positive cover totals
- zero-cover windows are valid demand windows
- truly unavailable means no eligible closed shifts in the baseline window

### DemandForecastContextNotifier Update

- Continues exposing `context`
- Adds `resolvedWeeklyForecastCovers` getter
- Keeps `historicalWeeklyAvgCovers` getter for compatibility

### ScheduleForecastDemandResolver Update

- `resolveFromContext(...)` now reads `context.resolvedWeeklyForecastCovers`
  instead of `context.historicalWeeklyAvgCovers`
- Both point to the same value via the compatibility getter, but the
  resolver now reads the v2 field directly for clarity
- Direct `resolve(...)` treats zero covers as valid available demand;
  only `null` means missing
- Demo fallback only activates when demand is genuinely missing (`null`),
  not when demand is real zero
- No source-label churn — outward-facing `ForecastDemandSource` values
  remain stable; source taxonomy cleanup is deferred

## Compatibility Bridge

This slice deliberately avoids broad consumer migration:

- `historicalWeeklyAvgCovers` becomes a documented transitional getter
  that returns the resolved rolling weekly forecast covers
- `historicalTotalCovers` becomes a transitional getter that returns
  the 60-day baseline total covers
- `weeksRepresented` becomes a transitional getter that returns the
  baseline weeks represented
- existing callers that read these fields continue to work without
  changes — they now receive blended v2 demand instead of raw baseline

This is transitional state. Consumer migration (7.55l.7) will move
callers to the explicit v2 field names.

## What This Slice Does Not Do

- No manager forecast adjustments or editing
- No WeeklyPlanSnapshot persistence or auto-lock logic
- No final day-allocation migration
- No broad consumer migration across Schedule / Shift / Variance / History
- No new UI states or visible source-label churn
- No UX change
- No tracker file changes

### DataAlignmentAuditPanel Update

The audit panel now shows explicit v2 demand fields instead of mixing
compatibility getters under a single baseline label:

- `BASELINE TOTAL COVERS (60-DAY)` — from `baselineTotalCovers`
- `BASELINE WEEKLY AVG (60-DAY)` — from `baselineWeeklyAvgCovers`
- `RECENT TOTAL COVERS (3-WEEK)` — from `recentThreeWeekTotalCovers`
- `RECENT WEEKLY AVG (3-WEEK)` — from `recentThreeWeekWeeklyAvgCovers`
- `TREND DELTA` — from `recentTrendDeltaCovers`
- `RESOLVED WEEKLY FORECAST` — from `resolvedWeeklyForecastCovers`
- `DEMAND SOURCE` — from `coversSource`
- `ANCHOR DATE` — from `anchorBusinessDate`

This is an audit/debug surface change, not a manager UX change.

Section header updated to `DEMAND CONTEXT (ROLLING)` in 7.55l.5f to
explicitly communicate rolling demand semantics. See
`docs/phase_7_55l_5f_demand_audit_truth_cleanup.md`.

## Cross-References

- Architecture rules: `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- DemandForecastContext model: `lib/domain/models/demand_forecast_context.dart`
- DemandForecastContextService: `lib/data/demand_forecast_context_service.dart`
- DemandForecastContextNotifier: `lib/data/demand_forecast_context_notifier.dart`
- ScheduleForecastDemandResolver: `lib/domain/services/schedule_forecast_demand_resolver.dart`
