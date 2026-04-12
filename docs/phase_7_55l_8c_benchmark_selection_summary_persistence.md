# Phase 7.55l.8c - Benchmark Selection Summary Persistence

Updated: 2026-04-11
Owner: Codex planning / tracker truth
Status: Implemented

## Purpose

Remove the last canonical Learn benchmark bridge by persisting benchmark-
selection summary fields at target-cycle build time, so Learn no longer reads
default/system benchmark analytics from `BaselineData`.

Before this slice, Learn's canonical path still fell back to `BaselineData`
bridge analytics for non-override profiles (`system_baseline`,
`cycle_recommended`, `admin_replacement`) because no persisted benchmark-
selection summary existed for the cycle that was actually built.

## What This Slice Adds

### BenchmarkSelectionSummary Model

A small, immutable model carrying benchmark-selection analytics tied to a
specific target cycle:

- `summaryId` — unique identifier
- `restaurantId` — restaurant scope
- `targetCycleId` — the cycle this summary was captured for
- `sourceType` — profile source type at capture time (audit truth)
- `selectedShiftCount` — count of selected star shifts at build time
- `rangeQualityLabel` — user-facing range status label
- `rangeQualityMessage` — user-facing range quality message
- `createdAt` — when the summary was persisted

### BenchmarkSelectionSummary Persistence

SQLite table `benchmark_selection_summaries` with:

- one summary row per target cycle (UNIQUE on `target_cycle_id`)
- fetch by `targetCycleId`
- upsert support

Schema version bumped to 17 with migration.

### TargetCycleService Summary Persistence

Every cycle write path now also persists a `BenchmarkSelectionSummary`
that captures the benchmark-selection context at build time:

- `_createRecommendedCycle` — captures selection summary from current
  `BaselineData` state (which was freshly primed for the build)
- `_writeReplacementCycle` — captures selection summary from the same
  freshly primed `BaselineData` state used to build the replacement

The summary is computed using `BaselineSelectionAnalyticsService.computeAnalytics`
with the currently effective selected records from `BaselineData`, capturing
the exact selection truth that was in effect when the cycle was built.

### Updated Learn Benchmark-Context Reads

`LearnBenchmarkContextService` canonical profile-present path now:

- Loads active profile (unchanged)
- Loads active cycle
- Loads persisted `BenchmarkSelectionSummary` for that cycle
- If summary exists: selected-shift count + range-quality come from the
  persisted summary — no `BaselineData` reads
- If summary is unexpectedly missing (7.55l.8c1 recovery): does a one-time
  backfill — computes compatibility analytics via
  `BaselineSelectionAnalyticsService.resolve()`, materializes a
  `BenchmarkSelectionSummary`, persists it, then uses the persisted values.
  Subsequent reads use the canonical persisted path.

### 7.55l.8c1 — Missing-Summary Recovery Tightening

**Before (8c):** Missing summary → call `BaselineSelectionAnalyticsService
.resolve()` → return analytics transiently → every read bypasses persistence

**After (8c1):** Missing summary → compute compatibility analytics →
materialize a `BenchmarkSelectionSummary` → persist it → use the persisted
values → subsequent reads use the canonical persisted path

Per-repository test overrides (`testGetRestaurantId`, `testGetProfile`,
`testGetCycle`, `testGetSummary`, `testPersistSummary`) were added to
enable testing the recovery logic without SQLite. These are only used when
`testCanonicalOverride` is null.

### Updated BaselineSelectionAnalyticsService

No structural changes. The service remains available as a compatibility
fallback for cycles created before 7.55l.8c that lack a persisted summary.

## What This Slice Does Not Do

- No manager UX redesign
- No Learn screen layout changes
- No History pattern analysis changes
- No Schedule / Shift / Variance / History behavior changes
- No daypart-evidence work from `7.55k`
- No tracker file changes
- No target math or formula changes

## Remaining Bridge

`BaselineData` bridge is now limited to:

- Explicit bridge-only mode (widget tests)
- Genuine no-profile bootstrap (first launch before any cycle)
- Transitional profile without a cycle (bridge-era profile that predates
  cycle creation)

The compatibility recovery path for missing summaries is no longer a silent
bridge bypass — it is a one-time backfill that repairs the data gap and
ensures subsequent reads use the canonical persisted path. Once a backfill
runs, the recovery path is not re-entered for that cycle.

## Cross-References

- Architecture rules: `docs/phase_7_55_target_cycle_weekly_plan_rules.md`
- Implementation plan: `docs/phase_7_55l_target_cycle_weekly_plan_implementation.md`
- Compatibility bridge scope: `docs/phase_8_gate/compatibility_bridge_scope.md`
- Prior slice: `docs/phase_7_55l_8b_learn_selection_analytics_migration.md`
- BenchmarkSelectionSummary: `lib/domain/models/benchmark_selection_summary.dart`
- BenchmarkSelectionSummaryRepository: `lib/domain/repositories/benchmark_selection_summary_repository.dart`
- TargetCycleService: `lib/data/target_cycle_service.dart`
- LearnBenchmarkContextService: `lib/data/learn_benchmark_context_service.dart`
