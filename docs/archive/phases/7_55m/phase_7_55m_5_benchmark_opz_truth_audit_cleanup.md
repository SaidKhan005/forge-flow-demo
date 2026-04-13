# Phase 7.55m.5 — Benchmark OPZ Truth Audit / Cleanup

Updated: 2026-04-12 (7.55m.5a source-set honesty tightening)
Owner: Claude implementation
Status: Implemented

## What This Slice Establishes

An explicit account of the three OPZ-related concepts in the codebase,
where they overlap, where they must stay separate, and what the
"covers the entire scale" visual concern actually is.

## Three OPZ Concepts

The codebase uses "OPZ" in three distinct ways. All three are valid,
but they serve different purposes and should not be confused.

### 1. OPZ Definition (from Benchmark Selection)

- **Source**: `BaselineData.opzFloorCPLH` / `opzCeilingCPLH`
- **What it is**: the min/max CPLH of the selected benchmark or
  star-shift records
- **Where it is set**: `BaselineData._opzSourceRecords` — selected
  records when any are selected (`_selected.isNotEmpty`), all records
  as a fallback when nothing is selected
- **Who consumes it**: Shift (via `ActiveTargetProfile`), Variance,
  Benchmark targets card, `OpzValidation`
- **What it means**: the floor and ceiling of the Optimal
  Productivity Zone. This defines the band within which current
  CPLH is considered healthy.
- **Relationship to TargetCycle**: the active `TargetCycle` locks
  OPZ bounds for 60 days. `BaselineData` is the bridge-era source;
  `ActiveTargetProfile` is the runtime projection.

### 2. Benchmark Range-Quality Assessment

- **Source**: `BaselineData.baselineRangeValidation` and
  `BaselineSelectionAnalyticsService.computeAnalytics()`
- **What it is**: an evaluation of whether the selected benchmark
  CPLH spread is too narrow, appropriate, or too wide to teach a
  repeatable standard
- **Thresholds**:
  - fewer than 2 selected → `OPZ RANGE TOO NARROW`
  - CPLH width < 0.15 → `OPZ RANGE TOO NARROW`
  - CPLH width > 1.25 → `OPZ RANGE TOO WIDE`
  - otherwise → `GOOD OPZ RANGE`
- **Who consumes it**: Benchmark screen (badge + explanation in
  `_CplhRangeBar`), Learn (via `BaselineSelectionAnalytics`)
- **What it means**: the quality of the manager's benchmark
  selection. A too-narrow selection does not give the team enough
  flex; a too-wide selection does not teach one clean standard.
- **Relationship to OPZ definition**: when records are selected,
  range-quality evaluates the same CPLH spread that defines the
  OPZ floor and ceiling. In the no-selection fallback case, they
  diverge: OPZ bounds fall back to all records while range-quality
  reports `OPZ RANGE TOO NARROW` (fewer than 2 selected). See
  the "Source-Set Fallback Split" section below.

### 3. Shift CPLH Zone Status

- **Source**: `BaselineData.opzStatusForCplh()` /
  `opzStatusLabelForCplh()` / `opzSubLabelForCplh()`
- **What it is**: a current-state check of where live CPLH sits
  relative to the OPZ floor and ceiling
- **Values**: `below` / `in` / `above`
- **Who consumes it**: `ZoneStatusCard` on the Shift screen,
  `ShiftDashboardReadModel`
- **What it means**: is the current shift running below, inside,
  or above the optimal productivity zone?
- **Relationship to the other two**: zone status uses the OPZ
  bounds (concept 1) but is independent of range quality
  (concept 2). A shift can be "IN OPZ" even when the benchmark
  selection quality is "TOO NARROW" or "TOO WIDE."

## Source-Set Fallback Split

`_opzSourceRecords` and `baselineRangeValidation` do NOT always
use the same source set:

- **Normal selected-state case**: both use the selected records.
  OPZ floor/ceiling = selected min/max. Range-quality evaluates
  the selected spread. They are aligned.
- **No-selection fallback case**: `_opzSourceRecords` falls back
  to all records (so OPZ floor/ceiling still resolve). But
  `baselineRangeValidation` sees fewer than 2 selected and
  returns `OPZ RANGE TOO NARROW`. They intentionally diverge.

This is not a bug. The fallback ensures Shift always has OPZ
bounds to render a zone gauge, even when the benchmark selection
is empty or insufficient. The range-quality assessment correctly
reports that the selection itself is too narrow to teach.

## Where They Should Match

- When records are selected, OPZ floor/ceiling and range-quality
  derive from the same selected-shift CPLH values.
- `BaselineData.baselineRangeValidation` and
  `BaselineSelectionAnalyticsService.computeAnalytics()` use
  identical thresholds and wording. This alignment is verified
  by existing tests.
- Learn range-quality labels come from either the persisted
  `BenchmarkSelectionSummary` or the analytics service fallback.
  Both paths produce the same three labels.

## Where They Should Not Match

- Shift zone status (`below`/`in`/`above`) is about current
  live CPLH position. It is independent of whether the benchmark
  selection quality is good or bad.
- Benchmark range-quality is about the spread of the selection.
  It does not tell you where current CPLH sits.
- The Benchmark graph outer line is the 60-day historical context.
  It is not the OPZ range and not the selection quality.

## The "Entire Scale" Concern

### What the Graph Shows

The Benchmark CPLH range graph has three layers:

1. **Outer line** (full horizontal bar): 60-day historical CPLH
   range, labeled "LOWEST CPLH LAST 60 DAYS" to "HIGHEST CPLH
   LAST 60 DAYS"
2. **Inner highlight** (green-bordered box): selected benchmark
   or star-shift CPLH range, labeled "BENCHMARK RANGE" or
   "STAR SHIFT RANGE"
3. **Target tick**: the recommended/overridden CPLH target

### Why the Inner Highlight Can Appear Large

If the selected shifts span most of the historical range, the
inner highlight fills most of the bar. This is not a distortion.
It happens when:

- The restaurant operates consistently and historical outliers
  are rare — the full 60-day range is not much wider than the
  selected set
- The manager selected shifts across a broad performance range
  — in which case the quality badge should show `OPZ RANGE
  TOO WIDE` if the spread exceeds 1.25

### Audit Verdict

The graph is working as designed. Position normalization is
correct: `activeRangeStartPosition` and `activeRangeEndPosition`
are computed against the historical scale, so the inner highlight
is always proportionally accurate relative to the outer line.

No visual distortion was found. The "covers the entire scale"
impression comes from true data relationships, not from a
read-model or normalization bug.

### What Could Be Improved Later

- `7.55m.6` could tighten the graph explanation copy so it
  explicitly names the relationship between the outer historical
  range and the inner selected range
- `7.55k` could add richer daypart evidence to the benchmark
  selection so the manager understands *which* shifts contribute
  to the range

## Threshold and Wording Alignment Audit

| Source | < 2 selected | width < 0.15 | 0.15 ≤ width ≤ 1.25 | width > 1.25 |
|--------|-------------|-------------|---------------------|-------------|
| `BaselineData.baselineRangeValidation` | TOO NARROW | TOO NARROW | GOOD | TOO WIDE |
| `BaselineSelectionAnalyticsService.computeAnalytics()` | TOO NARROW | TOO NARROW | GOOD | TOO WIDE |
| Label text | `OPZ RANGE TOO NARROW` | `OPZ RANGE TOO NARROW` | `GOOD OPZ RANGE` | `OPZ RANGE TOO WIDE` |

**Status: Fully aligned.** Both sources use identical thresholds,
labels, and message wording.

## `OpzValidation` vs `BaselineRangeValidation`

These are two different validation models that should not be
confused:

- `OpzValidation` evaluates where the **target** sits relative to
  the OPZ floor/ceiling: `in_zone`, `near_ceiling`, `above_ceiling`,
  `below_floor`. This is about target positioning.
- `BaselineRangeValidation` evaluates whether the **selection spread**
  is usable: `healthy`, `too_narrow`, `too_wide`. This is about
  selection quality.

Both are valid and serve different coaching purposes.

## What Remains Deferred

### `7.55m.6` — Presentation Copy

- Tighten the Benchmark graph explanation so the relationship
  between outer historical range and inner selected range is
  immediately clear from the copy alone
- Shorten OPZ range helper wording for easier scanning

### `7.55k` — Downstream Semantics

- Richer daypart evidence in benchmark selection
- History/Learn daypart benchmark improvements
- Full Week row-scope semantics

### `10.5` — Live Daypart Shift

- Real-time service-period OPZ zone checking
- Daypart-aware Shift primary driver

## Files Changed

- `docs/archive/phases/7_55m/phase_7_55m_5_benchmark_opz_truth_audit_cleanup.md` (this doc)
- `lib/data/legacy_fixture_data.dart` (tightened OPZ concept comments)
- `test/baseline_range_logic_test.dart` (graph/zone-status audit tests)

## Test Coverage

- Graph active range always sits within historical context range
- Graph position normalization is bounded [0, 1]
- Shift OPZ zone status is independent of benchmark selection quality
- Existing narrow / good / wide threshold tests remain passing
