# Phase 7.55p.5g - Recommended Benchmark Selection Service

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed (follow-up `7.55p.5g-review-fix` applied — explicit
restaurant-scope routing through the recommendation path now honors
the passed `restaurantId` end-to-end)

## Goal

Implement the app-owned recommended benchmark selection service defined
by the `7.55p.5f` statistics contract so the default recommended/system
benchmark cohort becomes real source truth instead of falling back to
the hardcoded seed-selected records in `BaselineData`.

## Scope

- In: `RecommendedBenchmarkSelection` model + `RecommendedBenchmarkSelectionService`
  pipeline (eligibility, daypart stratification, MAD outlier detection,
  CPLH-first top-N, trimmed-mean center, per-daypart OPZ, legacy union
  band); wiring into `BaselineManagerService.resolveRecommendedSelection`
  and `hasPersistedManagerOverride`; rerouting `TargetCycleService`
  recommended/admin-replacement paths to consume the service; pipe the
  service output into `BenchmarkSelectionSummary` persistence; concrete
  PPA / labor % diagnostic thresholds
- In: tiny seam on `SqliteDatabase.buildActiveTargetProfileFromBaseline`
  that accepts target / OPZ / source-type overrides so the default
  recommended path can skip `BaselineData.derivedTargetCPLH`
- Out: graph fallback / explainer cleanup (`7.55p.5h`)
- Out: scope-aware planned labor package (`7.55p.5i`/`5j`)
- Out: per-daypart OPZ rendering (Phase 10.5)
- Out: vendor integration work, recommendation-engine extensions

## Runtime seam

```
Benchmark 60-day closed shifts (SQLite)
   │
   v
BaselineManagerService.getCandidateShiftsForDateRange()
   │
   v
BaselineManagerService.resolveRecommendedSelection()
   │
   v
RecommendedBenchmarkSelectionService.select()
   │ (7.55p.5f pipeline)
   │  - eligibility gates
   │  - daypart stratification
   │  - MAD outlier labeling on CPLH
   │  - CPLH-first top-50% selection (min 3, max 10)
   │  - trimmed-mean (10%) / median fallback center
   │  - per-daypart OPZ bands (primary)
   │  - union band (legacy consumers only)
   v
RecommendedBenchmarkSelection
   │
   v
TargetCycleService._createRecommendedCycle / _writeReplacementCycle
   │  - hasPersistedManagerOverride(restaurantId) → route decision
   │  - no manager override → consume service output via
   │    buildActiveTargetProfileFromBaseline(…targetCPLHOverride: …)
   │  - manager override → existing BaselineData path (unchanged)
   │  - service output is ALSO used by _persistSelectionSummary
   v
TargetCycle + ActiveTargetProfile + BenchmarkSelectionSummary
```

The service never persists `baseline_selection_rows`. The manager
override table is not touched by the recommendation path.

## Routing rules

| Restaurant state | Profile / summary source | TargetCycle source label |
|---|---|---|
| Persisted manager-selected keys present | `BaselineData` (existing manager-override path) | `cycle_manager_override` (in replacement) / `cycle_recommended` on creation when override already primed |
| No manager-selected keys, `overallQuality != 'insufficient'` | Service recommendation (`pooledRecommendedTargetCPLH/SPLH/PPA`, `unionOpz*`) | `cycle_recommended` |
| No manager-selected keys, `overallQuality == 'insufficient'` | `MeridianConfig` Config Defaults via target overrides on `buildActiveTargetProfileFromBaseline` | `cycle_recommended_insufficient` |

Intentionally: the insufficient branch uses `MeridianConfig.*` hard
defaults (and a distinct source label), NOT the seed-selected
`_seedRecords` cohort. The fallback is honest — "we don't have enough
evidence, so we fall back to Config Default" — not "let's pretend these
14 hardcoded records are the recommendation."

## Concrete PPA / labor % diagnostic thresholds

`7.55p.5f` deliberately left "notably below/above" unquantified. This
slice sets the concrete rule:

- **PPA** — cohort median PPA < daypart median PPA × `(1 − 0.10)` → flag
  that daypart's cohort as `'weak'`
- **Labor %** — cohort median labor % > daypart median labor % × `(1 + 0.10)`
  → flag that daypart's cohort as `'weak'`

Both compare the CPLH-ranked cohort against the MAD-filtered daypart
pool the cohort was drawn from. `10%` is a standard "notable
difference" threshold in operations dashboards — strong enough to flag
CPLH-high-but-PPA-poor or CPLH-high-but-labor-%-poor cohorts without
firing on normal cohort-to-population variation.

Both thresholds are configurable via `RecommendedSelectionConfig`
(`notablePpaRelativeGap`, `notableLaborPctRelativeGap`).

## What this slice did to existing files

| File | Change |
|---|---|
| `lib/domain/models/recommended_benchmark_selection.dart` | **New** model with `DaypartCohortStats`, `RecommendedBenchmarkSelection`, insufficient factory |
| `lib/data/recommended_benchmark_selection_service.dart` | **New** pure service implementing the 7.55p.5f pipeline + configurable thresholds |
| `lib/data/baseline_manager_service.dart` | Added `hasPersistedManagerOverride(restaurantId)` and `resolveRecommendedSelection(restaurantId, businessDate)` |
| `lib/data/target_cycle_service.dart` | `_createRecommendedCycle` and `_writeReplacementCycle` now route between manager-override (BaselineData) and app-owned recommendation (service). `_persistSelectionSummary` accepts the recommendation and derives the summary from it. Added `ActiveTargetProfileBuildResult` internal helper. |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | `buildActiveTargetProfileFromBaseline` gained additive optional overrides: `targetCPLHOverride`, `targetSPLHOverride`, `targetPPAOverride`, `opzFloorOverride`, `opzCeilingOverride`, `sourceTypeOverride`. Existing callers continue to work unchanged. |

No changes to `BaselineData` storage shape, no new persistence
schemas, no widget-level edits, no tracker files touched.

## 7.55p.5g-review-fix: explicit restaurant-scope routing

The original `7.55p.5g` landing had a narrow bug: the
`resolveRecommendedSelection(restaurantId, businessDate)` entry passed
the explicit id down but the inner `getCandidateShiftsForDateRange`
helper silently resolved the **active-scope** restaurant instead.
That meant a caller could hand in restaurant B's id and still receive
restaurant A's recommendation whenever A was the UI-active scope.

The follow-up `7.55p.5g-review-fix` added an optional `restaurantId`
parameter to `getCandidateShiftsForDateRange` that is threaded through
by both `resolveRecommendedSelection` and `primeBaselineContextForDate`.
When omitted, the active scope is still used — so
`getCandidateShifts()` and every active-scope convenience caller
continue to behave exactly as before. Selected-key lookup inside the
loader is scoped to the same id.

The regression is proved by two tests in
`test/target_cycle_service_test.dart` group `O`:

1. Direct: `resolveRecommendedSelection('ghost_restaurant', date)`
   against an empty-history restaurant must return
   `overallQuality == 'insufficient'` while a demo-scoped call on the
   same database returns a usable recommendation. Before the fix both
   calls would have returned identical non-insufficient results.
2. End-to-end: `TargetCycleService.getOrCreateActiveCycle('ghost_restaurant', date)`
   persists a benchmark-selection summary with zero selected shifts
   and the `cycle_recommended_insufficient` source label, proving the
   explicit id reaches all the way through the pipeline.

## Intentional bridge behavior that remains

- `primeBaselineContextForDate` is still called at the top of
  `_createRecommendedCycle` / `_writeReplacementCycle` because
  `BaselineData.historicalContextRecords` is still consumed by
  `BaselineData.rangeGraphModel` and other compat surfaces. The
  recommended path no longer reads `BaselineData.derivedTargetCPLH` for
  its cohort truth, but the historical-context priming still happens.
- `_persistSelectionSummary` falls back to `BaselineData`-based
  counting when no recommendation is available (manager-override
  branch). That preserves the existing manager-override summary shape.

These are the "tiny bridge seams" the slice prompt explicitly allowed.

## Quality tiers in the output

- `'strong'` — total selected ≥ 8 across ≥ 2 qualifying dayparts, no
  per-daypart `'weak'` flags, union width ≤ 1.25
- `'adequate'` — union width > 1.25 OR selected < 8 OR selected < 2
  dayparts (but still ≥ some teachable evidence)
- `'weak'` — any daypart cohort flagged weak (wide/narrow CPLH range,
  PPA notably below, labor % notably above) or total selected < 5
- `'insufficient'` — no daypart had ≥ 3 eligible records after gates
  and outlier removal

`7.55p.5h` (graph fallback/explainer cleanup) will consume these tiers
to decide what the Benchmark graph shows in degenerate states.

## Remaining gaps

- **Graph degenerate-state UI** (`7.55p.5h`) — when `overallQuality`
  is `'insufficient'` or `'weak'`, or the union band is flagged, the
  graph should tell the honest story instead of showing a misleading
  full-range highlight.
- **Per-daypart OPZ rendering** (Phase 10.5) — `perDaypartStats`
  already carries the bands; the rendering UI is a downstream slice.
- **Scope-aware planned package** (`7.55p.5i` / `5j`) — the per-daypart
  cohort stats are a natural input to per-daypart planned labor %,
  but building that package is a separate lane.
- **Composite scoring beyond CPLH-first** — the contract keeps
  CPLH-first as the default selection signal with PPA/labor % as
  diagnostics; empirical evidence from real data may later justify a
  weighted composite, but nothing in this slice depends on it.
- **Manager-override summary** — still derived from `BaselineData`. A
  future slice could migrate the manager-override summary to the same
  service pipeline with the override cohort as the input pool, if the
  Learn surface warrants that consistency.
