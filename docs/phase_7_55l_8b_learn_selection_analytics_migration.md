# Phase 7.55l.8b - Learn Selection-Analytics Migration Off Production BaselineData

Updated: 2026-04-11 (7.55l.8b1 source-aware analytics fix)
Owner: Codex planning / tracker truth
Status: Implemented (source-aware analytics corrected in 7.55l.8b1)

## Purpose

Move Learn's selected-shift count and range-quality analytics off direct
production `BaselineData` reads and onto persisted baseline-selection state.

Before this slice, `LearnBenchmarkContextService` still read directly from
`BaselineData` in the canonical profile-present path for:

- `BaselineData.selectedRecordCount`
- `BaselineData.baselineRangeValidation.statusLabel`
- `BaselineData.baselineRangeValidation.message`

That was the last remaining production `BaselineData` dependency inside
Learn's normal runtime path.

## What This Slice Adds

### BaselineSelectionAnalytics Model

A small, immutable model carrying selection-analytics fields:

- `selectedShiftCount` — count of selected star shifts
- `rangeQualityLabel` — user-facing range status label
- `rangeQualityMessage` — user-facing range quality message

### BaselineSelectionAnalyticsService

A dedicated service that computes selection analytics from persisted
baseline-selection state, not from `BaselineData`.

Resolution path (source-aware as of 7.55l.8b1):

- For override-driven profiles (`manager_override`, `cycle_manager_override`):
  1. Load candidate shifts via `BaselineManagerService.getCandidateShifts()`
     (reuses the existing anchor rule: mock replay business date first,
     latest closed business date fallback, true rolling 60-day window)
  2. Count selected candidates from persisted selection keys
  3. Compute range quality from selected CPLH values

- For default recommended/system profiles (`system_baseline`,
  `cycle_recommended`, or any non-override source type):
  - Use bridge analytics from `BaselineData` because there is no persisted
    system-benchmark selection summary contract yet
  - An empty manager-override selection table is not misread as "0 selected
    star shifts" for default benchmark truth

Range quality mapping (identical to bridge-era `BaselineData` logic):

| Condition | Label | Warning |
|---|---|---|
| fewer than 2 selected shifts | `OPZ RANGE TOO NARROW` | yes |
| CPLH width < 0.15 | `OPZ RANGE TOO NARROW` | yes |
| CPLH width > 1.25 | `OPZ RANGE TOO WIDE` | yes |
| otherwise | `GOOD OPZ RANGE` | no |

Bridge-only mode: `enableBridgeOnly()` bypasses repository access and
returns analytics from `BaselineData` directly (for widget tests without
SQLite).

Test injection seam: `testAnalyticsOverride` allows unit tests to inject
analytics without touching repositories.

### Updated LearnBenchmarkContextService

Canonical profile-present path now:

- Source label + targets: from persisted `ActiveTargetProfile` (unchanged)
- Selected count + range quality: from `BaselineSelectionAnalyticsService`
  with source type passed through (7.55l.8b1)
- Override-driven profiles: persisted selection-key analytics
- Default recommended/system profiles: bridge analytics from `BaselineData`
  (honest — does not misrepresent empty override table as zero-selected
  benchmark truth)

Explicit bridge-only mode and genuine no-profile bootstrap fallback remain
allowed and still use full `BaselineData` bridge.

## What This Slice Does Not Do

- No manager UX redesign
- No Learn screen layout changes
- No History pattern analysis changes
- No Schedule / Shift / Variance / History behavior changes
- No SQLite schema additions
- No daypart-evidence work from `7.55k`
- No tracker file changes

## Remaining Bridge

`BaselineData` bridge is now used for:

- Explicit bridge-only mode (widget tests)
- Genuine no-profile bootstrap (first launch before any cycle)
- Default recommended/system benchmark analytics (source-aware, 7.55l.8b1)
  — because there is no persisted system-benchmark selection summary yet

Override-driven profiles (`manager_override`, `cycle_manager_override`) use
persisted selection-key analytics and do not read `BaselineData`.

Full persisted system-benchmark analytics remain deferred to a future slice
when a persisted benchmark-build or system-selection summary contract exists.

## Cross-References

- Architecture rules: `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Compatibility bridge scope: `docs/phase_8_gate/compatibility_bridge_scope.md`
- Prior slice: `docs/phase_7_55l_8a_learn_source_target_migration.md`
- BaselineSelectionAnalytics: `lib/models/baseline_selection_analytics.dart`
- BaselineSelectionAnalyticsService: `lib/data/baseline_selection_analytics_service.dart`
- LearnBenchmarkContextService: `lib/data/learn_benchmark_context_service.dart`
