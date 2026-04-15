# Phase 7.55p.5f - Recommended Benchmark Selection Statistics Contract

Updated: 2026-04-13
Owner: Claude contract
Status: Landed (contract/doc only — no code changes)

## Goal

Define the statistics contract for the app-owned recommended benchmark
selector so the default recommendation produces a robust, explainable
cohort instead of degenerating toward the full historical range.

## Scope

- In: selection statistics contract, eligibility gates, robust-center
  derivation, output shape, degenerate-prevention rules
- Out: implementation of the selector service (7.55p.5g), graph fallback
  cleanup (7.55p.5h), scope-aware planned package (7.55p.5i/5j)

## Contract Question

> How should the recommended benchmark selector choose which closed
> shifts to include, so the result is a stable, teachable cohort that
> does not visually or analytically degenerate?

## The Problem

The current default selection can visually degenerate:

1. The demo data pre-selects 14 records across lunch, dinner, and late
   night with CPLH ranging from 4.2 to 5.0
2. The 60-day historical pool ranges from 3.4 to 5.0
3. The selected set spans 43% of the historical range (7.55p.5b)
4. The graph inner highlight fills nearly half the bar
5. A manager seeing this may not trust the "benchmark" because it reads
   as "almost everything"

The OPZ width itself is correct (7.55p.5b confirmed this). The problem
is upstream: **the recommended set is too broad because it does not
distinguish high-performance shifts from merely acceptable ones.**

## Contract

### Phase 1: Input — Eligibility Gates

Before any statistics run, the candidate pool must be filtered:

| Gate | Rule | Rationale |
|---|---|---|
| Status | `status == 'closed'` only | Only finalized truth counts |
| Minimum covers | `covers >= 20` (configurable) | Shifts with trivially low volume produce degenerate CPLH |
| Minimum hours | `fohHours + bohHours >= 2` | Below this, rate metrics are noise |
| Completeness | `covers > 0 && actualSales > 0 && fohHours > 0` | All three must be present for CPLH/SPLH/PPA to be meaningful |
| Window | Last 60 business days | Matches the TargetCycle window |

**Output:** An eligible candidate list. The service should also return
the count of records excluded by each gate for transparency.

### Phase 2: Stratification — Daypart-First Cohorts

Run the selection logic per daypart, not across the full pool:

| Rule | Rationale |
|---|---|
| Group by `daypart` | Lunch, dinner, and late-night have structurally different CPLH levels. Mixing them inflates the spread. |
| Minimum cohort size per daypart: 3 | Below 3, the daypart does not have enough evidence for a robust selection. |
| If a daypart has < 3 eligible records, exclude it from recommendation | Do not fill thin evidence with noise |

**Why daypart-first:** Jim Taylor's framework tracks CPLH per daypart
(Ch. 9: "Daily covers, FOH hours, CPLH per shift by daypart — 60 days.
OPZ band highlighted."). The app should follow this principle. Combining
lunch 4.8 CPLH with dinner 4.2 CPLH inflates the range without teaching
anything about either daypart.

### Phase 3: Outlier Detection — Median + MAD

Within each daypart cohort, label outliers using the Median Absolute
Deviation (MAD) method:

```
median = median(CPLH values)
MAD = median(|x_i - median|)
adjusted_MAD = MAD × 1.4826  (consistency constant for normal distribution)
```

A record is an **outlier** if:

```
|CPLH - median| > k × adjusted_MAD
```

where `k = 3.0` (configurable; conservative default).

**Why MAD, not standard deviation:**
The [median absolute deviation](https://en.wikipedia.org/wiki/Median_absolute_deviation)
is a robust statistic — it is not inflated by the very outliers it is
trying to detect. Standard deviation squares deviations, which means a
single extreme CPLH shift can pull the threshold wide enough to hide
itself. MAD avoids this.
([Statistical reference](https://eurekastatistics.com/using-the-median-absolute-deviation-to-find-outliers/))

**Why k = 3.0:** This is the standard robust threshold. At k = 3 with
the 1.4826 consistency constant, it approximates a ±3σ gate under
normality, but remains robust when the data is not normal.

**IQR as a reported statistic (not a threshold):** After MAD outlier
removal, the interquartile range should be computed and reported in
`DaypartCohortStats.iqrCPLH`:

```
IQR = Q3 - Q1
```

This contract does **not** set an IQR threshold. The existing repo
`1.25` threshold in `baselineRangeValidation` measures full max–min
selected-range width, not IQR — those are different concepts (IQR
captures the middle 50%, not the tails). Reusing the same magic number
for both would quietly change the meaning of the existing quality
assessment.

Spread quality checks in this contract use full-width selected-range
(consistent with the existing repo semantics). See the
Degenerate-Prevention Rules section below. IQR is exposed so future
slices can make an evidence-backed decision about adding an IQR
threshold, but the contract does not prescribe one.

### Phase 4: Performance Scoring — Select High-Performance Cluster

After outlier removal, select the top-performing shifts within each
daypart cohort.

**Selection rule (CPLH-first):** Within each daypart (after outlier
removal), rank by CPLH descending and select the top 50% (minimum 3,
maximum 10).

If fewer than 3 remain after outlier removal, the daypart does not
produce a recommendation.

**Why CPLH-first, not a composite score:** CPLH is the one metric that
directly expresses labor efficiency — the productivity reading the OPZ
band is actually defined on (Jim Taylor Ch. 4, Ch. 11). A composite
score that weights PPA and labor % would require magic weights this
contract does not yet have evidence to set. CPLH-first keeps the
selection rule explicit and testable.

**Why top 50%, not top quartile:** Jim Taylor's OPZ is a range, not a
single elite point. Selecting the top quartile would produce a range
too narrow for coaching (the `TOO NARROW` threshold is 0.15 CPLH width).
Top 50% of a robust cohort typically produces a teachable spread.

### PPA and Labor % — Diagnostic, Not Inclusion

PPA and labor % do **not** participate in inclusion. They are reported
as diagnostic signals on the selected cohort:

| Signal | Direction | Role |
|---|---|---|
| PPA | Higher is better | Diagnostic — confirms upsell/guest attention context on the selected CPLH-high shifts |
| Labor % | Lower is better | Diagnostic — confirms the selected shifts also had healthy outcome labor % |

If the CPLH-ranked selection produces a cohort with median PPA notably
lower than the daypart median, or median labor % notably higher, the
quality tier should drop to `'weak'` (see Degenerate-Prevention Rules).
This is a sanity flag, not a second selection pass.

Future empirical work in `7.55p.5g` or beyond may layer in a composite
score if real data shows CPLH-only selection misses teachable shifts.
This contract does not mandate that work.

### Phase 5: Robust Center — Target Derivation

Derive the recommended targets from the selected cohort using the
10% trimmed mean:

```
recommended CPLH = trimmedMean(selected CPLH values, trim = 0.10)
recommended SPLH = trimmedMean(selected SPLH values, trim = 0.10)
recommended PPA  = trimmedMean(selected PPA values,  trim = 0.10)
```

**Why trimmed mean, not raw mean:**
The [10% trimmed mean](https://www.itl.nist.gov/div898/software/dataplot/refman1/auxillar/trimmecl.htm)
drops the top and bottom 10% of values before averaging. This prevents
a single extreme shift from pulling the target while preserving more
information than the median alone.
([NIST reference](https://www.itl.nist.gov/div898/handbook/))

**Fallback when sample is too small for trimming:** If the cohort has
fewer than 5 records (where 10% trim would remove less than 1 record),
use the median instead.

### Phase 6: OPZ After Selection

**Per-daypart OPZ bands are the primary output** of this contract.
Because Phase 2 stratifies selection by daypart, the teachable OPZ
also lives at the daypart level:

```
per-daypart OPZ floor[d]   = min(selected CPLH values for daypart d)
per-daypart OPZ ceiling[d] = max(selected CPLH values for daypart d)
```

These are the bands a per-daypart Shift/Variance surface should consume
when daypart-aware OPZ rendering lands (Phase 10.5).

**Cross-daypart union band (legacy consumers):** The current repo still
renders a single cross-daypart OPZ on the Benchmark graph. For that
consumer, the service should also expose a union band:

```
union OPZ floor   = min(per-daypart OPZ floors)
union OPZ ceiling = max(per-daypart OPZ ceilings)
```

This union band is mathematically the same as the pooled min/max of all
selected CPLH values. It is an **honest legacy output**, not a
recommendation — the contract explicitly acknowledges that the union
band can be wider than any individual daypart band. Surfaces consuming
the union band must accept that width is the cost of collapsing
daypart structure into one reading.

The Phase-2 daypart-first discipline protects the union band from the
pre-contract degenerate case (mixing thin/poor-CPLH dayparts) because
each daypart's contribution is already a robust cohort. But daypart-first
selection does NOT guarantee a tight union band — consumers that need a
tight band must use the per-daypart bands directly.

## Recommendation Output Shape

The selector service should return:

```
RecommendedBenchmarkSelection
├── selectedRecordIds: Set<String>       — included records (all dayparts)
├── excludedOutlierIds: Set<String>      — MAD-flagged outliers
├── excludedByGateIds: Set<String>       — eligibility failures
├── perDaypartStats: Map<String, DaypartCohortStats>   ← primary output
│   ├── eligibleCount: int
│   ├── outlierCount: int
│   ├── selectedCount: int
│   ├── medianCPLH: double
│   ├── madCPLH: double
│   ├── iqrCPLH: double                  — reported statistic, not a threshold
│   ├── medianPPA: double                — diagnostic
│   ├── medianLaborPct: double           — diagnostic
│   ├── opzFloorCPLH: double             — per-daypart band (primary)
│   ├── opzCeilingCPLH: double           — per-daypart band (primary)
│   ├── recommendedTargetCPLH: double    — trimmed mean, per-daypart
│   ├── recommendedTargetSPLH: double    — trimmed mean, per-daypart
│   ├── recommendedTargetPPA: double     — trimmed mean, per-daypart
│   └── cohortQuality: 'strong' | 'adequate' | 'weak' | 'insufficient'
├── unionOpzFloorCPLH: double            — legacy consumers only; see Phase 6
├── unionOpzCeilingCPLH: double          — legacy consumers only; see Phase 6
├── pooledRecommendedTargetCPLH: double  — weighted across dayparts, legacy
├── pooledRecommendedTargetSPLH: double  — weighted across dayparts, legacy
├── pooledRecommendedTargetPPA: double   — weighted across dayparts, legacy
├── overallQuality: 'strong' | 'adequate' | 'weak' | 'insufficient'
└── explanationMetadata: String          — human-readable summary
```

**Primary vs legacy outputs:**
- **Per-daypart `perDaypartStats`** is the primary output. It carries
  the teachable OPZ bands and recommended targets at the granularity
  the contract was designed for.
- **Pooled / union fields** exist only for the current cross-daypart
  Benchmark graph consumer. They are explicitly less precise and
  should not be used by new surfaces.

The pooled recommended targets are cover-weighted means across
dayparts (not raw averages), so they honestly reflect the volume mix
rather than pretending all dayparts contribute equally.

## Degenerate-Prevention Rules

Spread quality uses **full-width (max − min) selected-range** to stay
consistent with the existing repo `baselineRangeValidation` semantics.
IQR is reported but not thresholded here.

| Condition | Scope | Behavior |
|---|---|---|
| No dayparts with ≥ 3 eligible records | — | `overallQuality = 'insufficient'`; no recommendation |
| All records survive MAD (no outliers) | Per daypart | Fine — the data is internally consistent |
| Per-daypart selected CPLH range > 1.25 | Per daypart | Flag that daypart as `'weak'` (matches existing `TOO WIDE` full-width rule) |
| Per-daypart selected CPLH range < 0.15 | Per daypart | Flag that daypart as `'weak'` (matches existing `TOO NARROW` full-width rule) |
| Cohort median PPA notably below daypart median PPA | Per daypart | Flag that daypart as `'weak'` — CPLH-high but PPA-poor may indicate rushed service, not teachable performance |
| Cohort median labor % notably above daypart median labor % | Per daypart | Flag that daypart as `'weak'` — CPLH-high but labor-%-high may indicate expensive mix, not efficient staffing |
| Union (pooled) selected CPLH range > 1.25 | Cross-daypart | Flag `overallQuality` as at most `'adequate'`; the union band should not be the primary consumer |
| Total selected < 5 | Overall | `overallQuality = 'weak'` |
| Total selected ≥ 8 across ≥ 2 dayparts with all daypart cohorts `'strong'` or `'adequate'` | Overall | `overallQuality = 'strong'` |

"Notably below/above" for the PPA and labor % diagnostic flags is
deliberately left unquantified here — `7.55p.5g` should pick a concrete
threshold (e.g., 10% relative gap) backed by evidence from the actual
data, not a guess from this contract.

## Configurable Thresholds

These should be configurable, not hardcoded:

| Threshold | Default | Purpose |
|---|---|---|
| Minimum covers per shift | 20 | Eligibility gate |
| Minimum hours per shift | 2 | Eligibility gate |
| MAD multiplier `k` | 3.0 | Outlier sensitivity |
| Minimum cohort size per daypart | 3 | Stratification gate |
| Top-N selection fraction | 0.50 | Cohort size from ranked eligible |
| Top-N minimum | 3 | Floor on selected cohort size |
| Top-N maximum | 10 | Ceiling on selected cohort size |
| Trimmed mean fraction | 0.10 | Robustness of center derivation |
| Per-daypart full-width TOO WIDE | 1.25 | Matches existing `baselineRangeValidation` semantics |
| Per-daypart full-width TOO NARROW | 0.15 | Matches existing `baselineRangeValidation` semantics |
| Union full-width adequate cap | 1.25 | Quality-tier cap on pooled band (same width threshold, applied to the union span) |

All width thresholds in this table refer to **full max–min selected
range**, not IQR. IQR is reported for observability but is not
thresholded by this contract.

## Jim Taylor Authority

From the deep-dive (Ch. 9, lines 766):
> "Daily covers, FOH hours, CPLH per shift by daypart — 60 days. OPZ
> band highlighted. Target line at 4.5."

From Ch. 11 (lines 1069-1131):
> "Find and defend your OPZ — from your 60 days of CPLH data, identify
> the range where labor % declines and service holds."

From Ch. 12 (lines 1148):
> "Track for 60 days — identify your sustainable range. Look for when
> CPLH, SPLH, and PPA are all high together."

The recommendation contract follows these principles:
1. Track by daypart (Ch. 9)
2. 60-day window (Ch. 9, 12)
3. Use CPLH as the primary selection signal (Ch. 4, Ch. 11 — OPZ is
   defined on CPLH). PPA and labor % act as diagnostic checks on the
   CPLH-ranked cohort (Ch. 12 — shifts where all three are healthy
   together are the teachable set). `7.55p.5g` may layer composite
   scoring later if evidence supports it.
4. The result defines the OPZ range per daypart (Ch. 11), with a
   union band available for legacy cross-daypart consumers

## Why No Code Changes In This Slice

The contract defines inputs, statistics, outputs, and quality rules.
Implementation belongs to 7.55p.5g. Adding a model type here would be
premature — the service that populates it does not exist yet.

## What This Sets Up

| Slice | What it receives from this contract |
|---|---|
| `7.55p.5g` | Service implementation: eligibility gates, daypart stratification, MAD outlier detection, CPLH-first top-N selection, PPA/labor-% diagnostic flags, trimmed-mean targets per daypart, per-daypart OPZ bands, pooled union band, output shape |
| `7.55p.5h` | Graph degenerate-state: when `overallQuality` is `'insufficient'` or `'weak'`, or when the union band is flagged, the graph should show an honest fallback instead of a misleading full-range highlight |
| `7.55p.5i` | Scope-aware planned package: can consume per-daypart cohort stats for daypart-scoped planned labor % |
| Phase 10.5 | Per-daypart OPZ rendering: this contract's per-daypart bands are ready to be consumed by a daypart-aware Shift/Variance surface |

## Remaining Gaps

- **Service implementation** (7.55p.5g) — the actual Dart service
- **Graph degenerate fallback** (7.55p.5h) — what the graph shows when
  the recommendation quality is insufficient or the union band is wide
- **Per-daypart OPZ rendering** (Phase 10.5) — this contract produces
  per-daypart bands as the primary output; rendering them is a
  downstream UI slice
- **Empirical PPA / labor % diagnostic thresholds** — the "notably
  below/above" language is intentionally left for `7.55p.5g` to set
  against real data, not a contract-side guess
- **Composite scoring** — CPLH-first is the contract default;
  `7.55p.5g` or later may add a composite score if evidence shows it
  materially improves cohort quality

## Research Sources

- [Median Absolute Deviation — Wikipedia](https://en.wikipedia.org/wiki/Median_absolute_deviation) — MAD definition, consistency constant 1.4826, robustness properties
- [Using MAD to Find Outliers — Eureka Statistics](https://eurekastatistics.com/using-the-median-absolute-deviation-to-find-outliers/) — practical implementation, k multiplier guidance
- [NIST/SEMATECH e-Handbook of Statistical Methods](https://www.itl.nist.gov/div898/handbook/) — trimmed mean, robust estimators
- [NIST Trimmed Mean Confidence Limits](https://www.itl.nist.gov/div898/software/dataplot/refman1/auxillar/trimmecl.htm) — 10% trim properties
- Jim Taylor deep-dive Ch. 9, 11, 12 (`docs/internal/barrio/jim_taylor_labor_model_deep_dive.html`) — daypart tracking, OPZ definition, 60-day discipline
