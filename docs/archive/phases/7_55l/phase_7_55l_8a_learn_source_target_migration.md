# Phase 7.55l.8a - Learn Source + Target Migration Off Production BaselineData

Updated: 2026-04-11 (7.55l.8a1 fallback tightening)
Owner: Codex planning / tracker truth
Status: Implemented (fallback tightened in 7.55l.8a1)

## Purpose

Move Learn's benchmark source label and target metrics off direct production
`BaselineData` reads and onto repository-backed cycle/profile authority.

Before this slice, `LearnTeachingAnalyzer` read directly from the mutable
in-memory `BaselineData` singleton for:

- `selectedRecordCount`
- `derivedTargetCPLH`
- `derivedTargetSPLH`
- `derivedTargetPPA`
- `baselineRangeValidation`
- `hasManagerOverride`

That was the biggest remaining production `BaselineData` dependency in the
cycle/week architecture.

## What This Slice Adds

### LearnBenchmarkContext Model

A small, immutable model carrying everything Learn needs from the benchmark
layer without importing `BaselineData`:

- `benchmarkSourceLabel` — product-facing source label
- `selectedShiftCount` — star shift count
- `targetCPLH` / `targetSPLH` / `targetPPA` — locked target standards
- `rangeQualityLabel` / `rangeQualityMessage` — selection quality

### LearnBenchmarkContextService

A dedicated service that resolves `LearnBenchmarkContext` from persisted
app authority:

- **Source label**: derived from the persisted `ActiveTargetProfile.sourceType`,
  not from `BaselineData.hasManagerOverride`. Handles both legacy and cycle-era
  source type strings.
- **Target CPLH / SPLH / PPA**: from the persisted `ActiveTargetProfile`,
  not from `BaselineData.derivedTarget*`.
- **Selected count / range quality**: temporary bridge from `BaselineData`,
  isolated inside this service. `LearnTeachingAnalyzer` itself no longer
  touches `BaselineData`.

Source-label mapping:

| Profile sourceType | Product label |
|---|---|
| `system_baseline` / `cycle_recommended` | `SYSTEM BENCHMARK SET` |
| `manager_override` / `cycle_manager_override` | `MANAGER STAR SHIFTS` |
| `admin_replacement` / `cycle_admin_replacement` | `ADMIN REPLACEMENT` |
| null / unknown | `SYSTEM BENCHMARK SET` |

Fallback semantics (tightened in 7.55l.8a1):

- **Explicit bridge-only mode**: `enableBridgeOnly()` bypasses repository
  access entirely and returns bridge truth. Used in widget tests where
  SQLite is not initialized.
- **Genuine no-profile bootstrap**: when the repository read succeeds but
  returns `null` (first launch before any cycle has been created), the
  service falls back to `BaselineData` for all fields.
- **Unexpected repository failures**: any exception from the repository
  layer propagates — it is not silently converted into bridge truth.

This ensures that a broken repository path is surfaced immediately rather
than silently reverting Learn to bridge-era source labels and targets.

### Refactored LearnTeachingAnalyzer

- Now accepts `LearnBenchmarkContext` as a required parameter instead of
  reading `BaselineData` directly.
- No longer imports `legacy_fixture_data.dart`.
- History-pattern analysis behavior unchanged.
- Summary output shape unchanged.

### Updated Learn Load Path

`variance_report.dart` `_LearnTab` now:

1. Loads benchmark context via `LearnBenchmarkContextService.instance.resolve()`
2. Passes that context into `LearnTeachingAnalyzer.summarize()`
3. Screen layout and existing sections remain intact.

## What This Slice Does Not Do

- No manager UX redesign
- No Learn screen layout changes
- No History pattern analysis changes
- No Schedule / Shift / Variance / History behavior changes
- No SQLite schema additions
- No daypart-evidence work from `7.55k`
- No tracker file changes

## Remaining Bridge

Selected-count and range-quality fields inside `LearnBenchmarkContextService`
still read from `BaselineData`. This bridge is:

- Isolated inside the service, not inside the analyzer
- Documented as temporary
- Scheduled for retirement in `7.55l.8` when baseline-selection analytics
  move to a persisted query model

## Cross-References

- Architecture rules: `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Compatibility bridge scope: `docs/phases/phase_8_gate/compatibility_bridge_scope.md`
- LearnBenchmarkContext: `lib/models/learn_benchmark_context.dart`
- LearnBenchmarkContextService: `lib/data/learn_benchmark_context_service.dart`
- LearnTeachingAnalyzer: `lib/services/learn_teaching_analyzer.dart`
- VarianceReport Learn tab: `lib/screens/variance_report.dart`
