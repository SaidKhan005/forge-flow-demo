# Phase 7.55l.5d - Weekly Day-Allocation Smoothing

Updated: 2026-04-11 (5e anchor-alignment correction applied)
Owner: Codex planning / tracker truth
Status: Implemented

## Purpose

Replace the old "recent 8 weekIds" day-allocation approximation with
business-date-anchored windowing that uses:

1. 60-day baseline day-of-week share
2. fixed 3-week recent trend day-of-week share
3. smoothed resolved day weights (blended from layers 1 + 2)

This aligns day allocation with the same date-window architecture used by
`DemandForecastContext` v2, eliminating the weekId approximation gap.

## What This Slice Adds

### DistributionWeightBuilder.fromDateWindowShifts()

New builder method that replaces the old `fromClosedShifts()` path for
date-anchored weight building:

- Takes two lists of closed shifts: 60-day baseline and 21-day recent
- Computes day-of-week cover shares for each window from positive-cover
  closed shifts
- Applies smoothing rule to produce resolved day weights
- Daypart subrow weights come from the 60-day baseline only (transitional)
- The old `fromClosedShifts()` method remains for backward compatibility

### Day-of-Week Smoothing Rule

For each day of the week (Mon-Sun):

- Compute `baselineShare` = day covers / total covers in 60-day window
- Compute `recentShare` = day covers / total covers in 21-day window
- When the 21-day window has positive-cover closed shifts:
  `resolvedShare = baselineShare + ((recentShare - baselineShare) / 2)`
- When the 21-day window has no positive-cover shifts:
  `resolvedShare = baselineShare`
- Convert resolved shares to integer weights via `(resolvedShare * 1000).round()`
  for downstream largest-remainder allocation

This mirrors the weekly covers smoothing rule: baseline anchors, recent
trend half-adjusts. Day distribution stays stable; recent shifts gently
nudge it toward observed patterns.

### SchedulePlanReadService.loadDistributionWeights() Update

Replaces the old 8-weekId path with business-date-anchored windows:

- Determines anchor date: mock replay date first, latest closed date fallback
- Queries 60-day baseline closed shifts (inclusive window ending at anchor)
- Queries 21-day recent closed shifts (inclusive window ending at anchor)
- Routes through `DistributionWeightBuilder.fromDateWindowShifts()`

### ScheduleDistributionWeightsNotifier.load() Update

Replaces the old weekId path with date-anchored queries:

- Anchor precedence now matches the rest of the planning stack:
  1. mock replay business date (when available)
  2. latest closed business date (fallback)
- Mock replay date is resolved via an injectable `MockReplayDateProvider`
  callback (defaults to SQLite lookup; tests inject a fake)
- Queries shifts via `getClosedShiftsInDateRange()` instead of
  `getClosedShiftsForWeeks()`
- `_weekRepo` becomes transitional/unused (kept in constructor for now)

This eliminates the anchor mismatch where demand context and day weights
could anchor to different dates during replay/demo mode (corrected in
7.55l.5e).

## What This Slice Does Not Do

- No daypart subrow smoothing (daypart weights stay 60-day baseline only)
- No consumer migration for daypart weight paths
- No changes to `SchedulePlanResolver` allocation logic
- No changes to default weight constants
- No UX changes
- No WeeklyPlanSnapshot persistence

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Rolling demand v2: `docs/archive/phases/7_55l/phase_7_55l_5a_rolling_demand_context_v2.md`
- Distribution weights model: `lib/domain/models/schedule_distribution_weights.dart`
- Weight builder: `lib/domain/services/distribution_weight_builder.dart`
- Weight notifier: `lib/data/schedule_distribution_weights_notifier.dart`
- Plan read service: `lib/data/schedule_plan_read_service.dart`
- Plan resolver: `lib/domain/services/schedule_plan_resolver.dart`
