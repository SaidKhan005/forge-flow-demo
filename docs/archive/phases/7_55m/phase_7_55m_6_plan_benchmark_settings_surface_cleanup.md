# Phase 7.55m.6 — Plan / Benchmark / Settings Surface Cleanup

Updated: 2026-04-12 (7.55m.6a OPZ copy alignment + real Plan widget tests)
Owner: Claude implementation
Status: Implemented

## What This Slice Delivers

A surface cleanup pass for Plan, Benchmark, and Settings now that runtime
truth (7.55m.1–5) has been audited and tightened. No runtime-truth changes,
no `7.55k` downstream semantics, no `10.5` live daypart behavior.

## Changes

### Plan Section Labels

The Plan screen (`ScheduleBuilder`) now has explicit section labels:

1. **WEEKLY PLAN SUMMARY** — before the forecast + derived summary cards
2. **COVER FORECAST BY DAY** — before the bar chart (moved from in-card
   caption to a proper section label)
3. **DAY-BY-DAY PLAN** — before the expandable day table

### Benchmark Target Grouping

The flat "TARGETS DERIVED FROM BENCHMARK" list is now grouped into four
scannable sections in the preferred product order:

1. **WAGE** — FOH Wage, BOH Wage, Blended Wage
2. **OPZ RANGE** — OPZ Floor, OPZ Ceiling, Headroom
3. **TARGET INPUTS** — CPLH, SPLH, PPA
4. **THEORETICAL OUTPUT** — Theoretical Labor %

### OPZ Helper Copy

Range-quality messages shortened for scannability:

- **Too narrow**: "Star shifts too tightly clustered. Add more for a
  teachable range."
- **Too wide**: "Star shifts too widely spread. Tighten to one clean
  standard."
- **Good**: "Target sits in a usable range with room to flex."

Thresholds unchanged. Labels unchanged. Semantics unchanged.
All three branches in `BaselineData.baselineRangeValidation` (fewer-than-2,
width < 0.15, and width > 1.25) now use the shortened copy. Both
`BaselineData.baselineRangeValidation` and
`BaselineSelectionAnalyticsService.computeAnalytics()` are fully aligned.

### Settings Organization

- "DEMO" section renamed to **MOCK REPLAY** for clarity
- Destructive "Clear All Data" moved to its own **DATA MANAGEMENT** section
- No workflow changes

## What Was Not Changed

- No runtime truth, target math, cycle math, or replay behavior
- No `7.55k` downstream semantics pulled forward
- No `10.5` live daypart behavior pulled forward
- No new manager workflow
- No tracker file updates
- Internal `Baseline` / `Schedule` code names unchanged

## Files Changed

- `docs/archive/phases/7_55m/phase_7_55m_6_plan_benchmark_settings_surface_cleanup.md` (this doc)
- `lib/screens/schedule_builder.dart` (Plan section labels + `testContent` seam)
- `lib/screens/baseline_tracker.dart` (Benchmark target grouping)
- `lib/data/legacy_fixture_data.dart` (OPZ helper copy)
- `lib/data/baseline_selection_analytics_service.dart` (OPZ helper copy alignment)
- `lib/screens/settings_screen.dart` (Settings section organization)
- `test/schedule_builder_widget_test.dart` (section label tests)
- `test/settings_screen_widget_test.dart` (section label tests)
- `test/learn_benchmark_context_service_test.dart` (message text alignment)

## Test Coverage

- Real `ScheduleBuilder` content widget renders the three section labels
  (via `ScheduleBuilder.testContent` seam that bypasses the upstream
  3-provider tree while mounting the real `_ScheduleBuilderContent`)
- Old in-card chart caption `COVER FORECAST DISTRIBUTED BY DAY` is absent
  from the real widget tree
- Settings screen section labels render after reorganization
- OPZ range-quality message alignment: all three branches in
  `BaselineData.baselineRangeValidation` assert the shortened copy
- No old long-form OPZ messages remain in active runtime code
- OPZ message alignment between BaselineData and analytics service
