# Phase 7.56b - Benchmark Summary Replay Stability

Updated: 2026-04-24
Owner: Codex planning / tracker truth
Status: Complete - 7.56b.1 landed + review-fix verified (2026-04-24)

## Closeout Verification (2026-04-24)

`7.56b.1` repaired the pre-existing
`benchmark_selection_summaries survive replay advance` failure. The accepted
fix adds missing-summary recovery to
`TargetCycleService.getOrCreateActiveCycle(...)` for already-existing active
cycles. Existing summaries remain untouched.

The review-fix tightened recovery routing so it mirrors
`_writeReplacementCycle`: recommended cycles use recommendation evidence,
manager-override cycles use the persisted manager-selected cohort, and
admin-replacement cycles route through override evidence only when persisted
override keys exist.

Reported verification:

- `dart analyze` — clean.
- `flutter test test/target_cycle_service_test.dart --name "benchmark selection summary"` — 10 / 10 passed.
- `flutter test test/mock_replay_scenario_test.dart --name "benchmark_selection_summaries survive replay advance"` — passed.

Full-repo test failures in `labor_model_boh_sales_test.dart` and
`notification_entrypoint_test.dart` were confirmed pre-existing on clean HEAD
`613b682` and are outside this slice.

## Goal

Close the pre-existing `mock_replay_scenario_test.dart` failure discovered
during 7.56a closeout:

```text
E - replay-stable locked artifacts survive replay advance /
benchmark_selection_summaries survive replay advance
```

The expected behavior is simple: the active target cycle must have exactly
one `BenchmarkSelectionSummary`, and that summary must survive mock replay
advance unchanged.

## Scope

- Fix the missing-summary path for an already-existing active
  `TargetCycle`.
- Preserve the existing summary when one already exists.
- Keep replay reseed behavior stable: replay advance must not clear
  `benchmark_selection_summaries`.
- Keep cycle standards, weekly plan values, demand math, and reservation
  behavior unchanged.

## Touched Runtime Seams

- `TargetCycleService.getOrCreateActiveCycle(...)` returning an existing
  active cycle.
- `TargetCycleService` summary persistence / missing-summary recovery helper.
- Optional seed-path inspection around `_ensureDemoSeedCycle(...)` only if
  needed to understand why the summary is missing.

## Current Failure Shape

`WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot()` resolves the
active cycle. If a seeded active cycle already exists without a
`benchmark_selection_summaries` row, `getOrCreateActiveCycle(...)` returns the
cycle unchanged and the summary remains absent. The replay-stability test then
fails before replay advance because `summariesBefore` is empty.

## Acceptance

- Existing active cycles with missing summaries repair to exactly one
  summary.
- Existing active cycles with summaries do not rewrite or duplicate them.
- Replay advance keeps the summary row and key fields unchanged.
- No reservation-book production code changes.
- Focused target-cycle / mock-replay tests pass.
