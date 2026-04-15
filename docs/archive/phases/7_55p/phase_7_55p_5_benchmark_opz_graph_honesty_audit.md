# Phase 7.55p.5 - Benchmark OPZ and Graph Honesty Audit

Updated: 2026-04-13
Owner: Claude implementation
Status: Landed

## Goal

Audit and tighten the Benchmark surface so OPZ range, graph meaning, and
theoretical output are honest and consistent with the persisted runtime
target authority used by Shift and downstream surfaces.

## Scope

- In: Benchmark target-source migration to `ActiveTargetProfile`,
  FOH/BOH/total theoretical output, graph title clarity, test alignment
- Out: OPZ threshold retune, benchmark selection redesign, blended wage
  formula redesign, Shift/Variance visual polish, new selection algorithm

## Audit Findings

### 1. OPZ width is true data, not a math error

The `7.55m.5` audit already established:
- The graph outer line = 60-day historical CPLH range
- The inner highlight = selected benchmark/star-shift CPLH range
- Position normalization is bounded [0,1] and proportionally correct
- When the inner highlight fills most of the bar, it is because the
  selected shifts span most of the historical range — true data

The range-quality assessment (`GOOD OPZ RANGE` / `TOO NARROW` /
`TOO WIDE`) correctly evaluates the selection spread. No fake tightening
is needed or warranted.

### 2. Target card was reading from wrong authority

`_BaselineTargetsCard` was reading OPZ bounds, target CPLH/SPLH/PPA,
and theoretical output from `BaselineData` (the bridge-era in-memory
source). Meanwhile Shift reads these values from `ActiveTargetProfile`
(the persisted runtime target authority). This split meant:

- Benchmark could show slightly different target values than Shift
- The 20.3% vs 20.5% discrepancy was caused by reading from different
  sources that derive the same formula but from potentially different
  input snapshots

**Fix**: `_BaselineTargetsCard` now reads all target-authority fields
from `ActiveTargetProfile` with `BaselineData` fallback only when the
profile is unavailable. Wages were already migrated (7.55h); this slice
migrates OPZ bounds, target inputs, and theoretical output.

### 3. Theoretical output was incomplete

The card showed only total theoretical labor %. The manager wants to see
the FOH/BOH breakdown to understand where labor cost pressure lives.

**Fix**: The THEORETICAL OUTPUT group now shows three rows:
- FOH LABOR % (from `profile.theoreticalFohLaborPct`)
- BOH LABOR % (from `profile.theoreticalBohLaborPct`)
- TOTAL LABOR % (from `profile.theoreticalLaborPct`)

All three read from `ActiveTargetProfile`, which already computes them
in `buildActiveTargetProfileFromBaseline()`.

### 4. Graph title was ambiguous

"CPLH TARGET" as the graph title could suggest the inner highlight box
is the "target" rather than the whole graph showing context around the
target. The tick mark that labels the actual CPLH target position was
also called "CPLH TARGET", creating visual redundancy.

**Fix**: Graph title changed from "CPLH TARGET" to "CPLH RANGE & TARGET".
The tick mark label remains "CPLH TARGET" (it labels a specific position).

## What Is Graph/Selection-Context Truth

These elements properly belong to `BaselineData` because they represent
the benchmark selection context — what the manager chose, and the full
60-day history it sits within:

- `rangeGraphModel` — historical range, active/selected range, positions
- `baselineRangeValidation` — selection-quality assessment
- `historicalContextRecords` — the 60-day pool
- Range-quality labels (GOOD/NARROW/WIDE)

## What Is Runtime Target-Authority Truth

These elements now read from `ActiveTargetProfile` because they represent
the locked runtime target used by Shift, Variance, and downstream:

- Target CPLH, SPLH, PPA
- OPZ floor / ceiling (and derived headroom)
- FOH theoretical labor %
- BOH theoretical labor %
- Total theoretical labor %
- FOH wage, BOH wage (already migrated in 7.55h)

## Touched Seams

| File | What changed |
|---|---|
| `lib/screens/baseline_tracker.dart` | `_BaselineTargetsCard` now reads all target-authority fields (wages, OPZ, targets, theoretical output) from `ActiveTargetProfile` with `BaselineData` fallback. `_targetBlendedWage()` now accepts explicit target inputs instead of hardcoded `BaselineData` reads. THEORETICAL OUTPUT labels renamed to `FOH/BOH/TOTAL THEORETICAL %` to distinguish from Shift's plan-based `Target x.x%`. |
| `lib/data/legacy_fixture_data.dart` | Graph title changed from "CPLH TARGET" to "CPLH RANGE & TARGET" |
| `test/baseline_range_logic_test.dart` | Updated 3 title assertions for new graph title |
| `test/target_consistency_opz_test.dart` | Updated graph title assertions, added THEORETICAL % label assertions, added Group G with profile-precedence widget tests (profile-present and fallback-absent paths) |

## Benchmark vs Shift Target Labor — Final Ownership

Benchmark and Shift show different labor % numbers because they answer
different questions:

| Surface | Label | Formula | What it answers |
|---|---|---|---|
| Benchmark | `TOTAL THEORETICAL %` | `fohWage / (CPLH × PPA) + bohWage / SPLH` | "Given these targets, what is the mathematical labor % at perfect efficiency?" |
| Shift | `Target x.x%` | `(planFohHours × fohWage + planBohHours × bohWage) / forecastSales` | "Given this week's locked plan hours and forecast, what is the planned labor %?" |

Both now read wages and targets from `ActiveTargetProfile`. The numbers
can still differ slightly because the Shift formula uses integer plan
hours (which round from the model-hour formula), while the Benchmark
formula is pure continuous math.

The `7.55p.5a` fix makes this distinction explicit by labeling the
Benchmark number "THEORETICAL" instead of a bare "LABOR %" or
"TOTAL LABOR %" that could be mistaken for Shift's planned target.

## Pre-Existing Test Issue

`target_consistency_opz_test.dart` Group B ("ScheduleForecastNotifier uses
injected active-target values") has a pre-existing failure: the `isNot(0)`
assertion fails because `modelFohHours(weeklyCovers, 4.75)` and
`modelFohHours(weeklyCovers, 4.5)` both round to the same integer value.
This is a test-data coincidence, not a logic error. Confirmed pre-existing
by running against the committed baseline with all working-tree changes
stashed. Not introduced by this slice.

## Remaining Gaps

- **Blended wage formula refinement**: The current blended wage uses
  model-hour-weighted average of FOH/BOH wages. The formula itself is
  not redesigned in this slice — only the input authority was aligned.
- **`BaselineData.historicalWeeklyAvgCovers` still used for blended wage
  demand context**: The blended wage formula needs a demand-volume input
  to compute model hours. `historicalWeeklyAvgCovers` is the honest
  60-day average from the full historical pool. This is reasonable
  because it is demand context, not target authority. If a future
  slice provides a profile-level demand input, the formula can migrate.
- **Pre-existing Group B test data issue**: documented above.
