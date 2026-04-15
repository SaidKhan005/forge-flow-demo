# Phase 7.55p.5h - Benchmark Graph Fallback and Explanation Cleanup

Updated: 2026-04-14
Owner: Claude implementation
Status: Landed (follow-up `7.55p.5h-review-fix` applied — graph
geometry now comes from the persisted cycle when recommendation
signals are active, and honesty is rehydrated on bootstrap so it
survives fresh launches)

## Goal

Make the Benchmark graph and explainer honest when the
`RecommendedBenchmarkSelectionService` (7.55p.5g) concludes the 60-day
cohort is insufficient, weak, or has a union band too wide to teach at
cross-daypart scope. Do not change selection math.

## Scope

- In: graph-model / `_CplhRangeBar` honest-fallback surface; tiny
  compatibility seam on `BaselineData` so the graph model can branch on
  recommendation-quality truth; honest copy for the degenerate states;
  narrow `TargetCycleService` seam that forwards signals the summary
  already computed
- Out: recommendation math changes (7.55p.5f owns the contract, 7.55p.5g
  owns the service)
- Out: per-daypart OPZ rendering (Phase 10.5)
- Out: planned-labor-package lane (7.55p.5i / 7.55p.5j)
- Out: full Benchmark screen redesign

## Graph honesty question

> When the recommendation is weak or insufficient — or when the legacy
> union band is so wide that the collapsed graph stops teaching — can
> the Benchmark surface still look confident? And if it can, what copy
> should it show?

## Answer

**The graph should say plainly that it is not teachable right now,
not pretend to have a benchmark band when the recommendation service
has explicitly flagged the cohort as degenerate.**

## What was misleading before

| State | Pre-fix behaviour | Honest behaviour |
|---|---|---|
| `overallQuality == 'insufficient'` (no 60-day evidence) | Graph still draws a confident inner box; badge reads `GOOD OPZ RANGE` or a stale `OPZ RANGE TOO NARROW` message scolding the manager for not picking enough "star shifts" — even though the manager didn't select anything, the recommendation service did not have enough evidence | Badge reads `RANGE UNCONFIRMED`; inner box dims; copy explains the system fell back to Config Default as a placeholder |
| `overallQuality == 'weak'` + union band > 1.25 CPLH | Badge reads `OPZ RANGE TOO WIDE`; copy reads "Star shifts too widely spread. Tighten to one clean standard." — wrong coach for the recommendation path because the manager didn't spread anything | Badge reads `RANGE TOO WIDE TO TEACH`; copy explains dayparts have structurally different CPLH levels and per-daypart benchmarks are coming |
| `overallQuality == 'weak'` (narrower but low-quality) | Same "Star shifts too tightly clustered..." copy fires for incomplete-evidence cohorts | Badge reads `RANGE UNCERTAIN`; copy says cohort did not meet the quality bar yet |
| `overallQuality == 'strong' / 'adequate'` | Works fine | Unchanged |
| Manager override active | Works fine | Unchanged — existing `baselineRangeValidation` still drives the `STAR SHIFT RANGE` / "star shifts" copy for the explicit manager-selected cohort |

## Runtime seam

```
RecommendedBenchmarkSelectionService.select()
   │
   v
TargetCycleService._persistSelectionSummary()
   │
   ├── writes BenchmarkSelectionSummary row (unchanged)
   │
   └── applies BaselineRecommendationSignals onto BaselineData
       (new 7.55p.5h bridge seam, only for recommendation-backed writes;
        manager-override writes clear the signals so the existing
        `baselineRangeValidation` copy stays authoritative there)
           │
           v
BaselineData.rangeGraphModel (graph read model)
   │
   ├── qualityTier: normalized tier
   ├── isDegenerate: widget cue to dim the inner box
   ├── statusBadgeLabel: honest badge label
   ├── recommendedExplanation: honest primary copy
   └── degenerateFallbackMessage: optional secondary line when degenerate
           │
           v
baseline_tracker._CplhRangeBar (widget)
   - uses isDegenerate to dim the inner box colour and switch the badge
     colour to warning
   - renders degenerateFallbackMessage beneath the primary explainer
     when present
```

## Three-way branch on graph honesty

The `BaselineData._resolveGraphHonesty()` helper routes the graph
model's honest-explainer state:

1. **Manager override active** → defer to
   `BaselineData.baselineRangeValidation` exactly as before. Existing
   manager-override behaviour is bit-for-bit preserved; the "STAR SHIFT
   RANGE" / "star shifts too tightly clustered" copy still applies to
   the explicit manager-selected cohort.
2. **Recommendation signals present** → quality/width come from the
   recommendation service. Insufficient / weak / wide-union cases
   produce the honest-fallback copy above; strong/adequate cases use
   the standard `GOOD OPZ RANGE` badge.
3. **Neither signals nor manager override** (tests / legacy / pre-cycle
   bootstrap) → fall back to `baselineRangeValidation` unchanged so
   every existing test keeps passing without edits.

## Fallback copy

| Tier / trigger | Badge | Primary explainer | Secondary fallback |
|---|---|---|---|
| `insufficient` | `RANGE UNCONFIRMED` | "Not enough recent 60-day evidence to recommend a benchmark range yet. Close more shifts before treating this as a target." | "The graph is showing the Config Default range as a placeholder, not a recommendation." |
| `weak` + union band > 1.25 CPLH | `RANGE TOO WIDE TO TEACH` | "Dayparts (lunch, dinner, late night) have very different CPLH levels. The combined cross-daypart range is too wide to teach one standard." | "Per-daypart benchmarks are coming. Until then, treat this union band as context only." |
| `weak` (not wide) | `RANGE UNCERTAIN` | "Recent cohorts did not meet the quality bar. Target may not be teachable yet." | "Give the 60-day window more closed shifts — the recommendation improves as evidence builds." |
| `strong` / `adequate` | `GOOD OPZ RANGE` | "Target sits in a usable range with room to flex." | — |
| Manager override (any tier) | Existing `baselineRangeValidation.statusLabel` | Existing `baselineRangeValidation.message` | — |

The `1.25 CPLH` threshold matches the existing
`baselineRangeValidation` TOO WIDE rule and the
`RecommendedSelectionConfig.unionAdequateCap` from 7.55p.5g, so the
graph cue stays consistent with the recommendation-service threshold.

## Minimal bridge seam

Added to `lib/data/legacy_fixture_data.dart`:

- `class BaselineRecommendationSignals` — simple value carrier (source
  type, overall quality, union band width, selected count)
- `BaselineData.recommendationSignals` (read-only getter)
- `BaselineData.applyRecommendationSignals(…)` / `.clearRecommendationSignals()`

Added to `BaselineRangeGraphModel`:

- `qualityTier: String`
- `isDegenerate: bool`
- `degenerateFallbackMessage: String?`
- `statusBadgeLabel: String`

No new persistence, no schema changes, no widening of
`BenchmarkSelectionSummary`. The signals live in memory only; the
`BenchmarkSelectionSummary` row still carries the durable record.

## 7.55p.5h-review-fix: geometry + bootstrap hydration

The original `7.55p.5h` landing had two honest gaps that the review
surfaced:

1. **Geometry didn't match the claim.** The badge and explainer
   branched on recommendation-quality truth, but the drawn inner band
   + target still came from
   `BaselineData.records.where((r) => r.isSelected)` /
   `derivedTargetCPLH` — i.e. the legacy seed-selected path. So the
   copy could say "Config Default range as a placeholder" while the
   graph drew seed-selected CPLH 4.2–4.8 and a ~4.58 target.
2. **Honesty only survived the writing process.**
   `_persistSelectionSummary` set in-memory signals at cycle-write
   time, but a fresh process launch saw no signals until the next
   cycle write — which could be 60 days away. The graph fell back to
   `baselineRangeValidation` on the seed-selected records and
   presented a confident band.

The follow-up `7.55p.5h-review-fix` fixes both:

### Geometry source truth

`BaselineRecommendationSignals` now carries `rangeFloorCPLH`,
`rangeCeilingCPLH`, and `targetCPLH` — the persisted cycle's actual
geometry. `TargetCycleService._persistSelectionSummary` populates
these from the freshly-written `cycle.opzFloorCPLH /
opzCeilingCPLH / targetCPLH` (which themselves come from the
recommendation for `cycle_recommended` or `MeridianConfig` for
`cycle_recommended_insufficient`). When recommendation signals are
present and no manager override is active, `BaselineData.rangeGraphModel`
draws `activeMin = signals.rangeFloorCPLH`,
`activeMax = signals.rangeCeilingCPLH`, and
`target = signals.targetCPLH` instead of the legacy seed-selected
derivation. So:

- **Insufficient** → graph geometry = `MeridianConfig` placeholder
  (3.5 / 5.8 / 4.5) — matches "Config Default range as a placeholder"
- **Weak+wide** → graph geometry = the actual union band — matches
  "the combined cross-daypart range is too wide"
- **Weak+narrow** → graph geometry = the actual pooled band — matches
  "target may not be teachable yet"
- **Strong/adequate** → graph geometry = the pooled recommendation —
  matches `GOOD OPZ RANGE`

Manager-override geometry is untouched: the `!hasManagerOverride`
guard keeps the seed-selected derivation authoritative for the
manager-selected cohort.

### Bootstrap hydration

Added `TargetCycleService.hydrateBenchmarkHonestyFromActiveCycle(restaurantId)`,
called from `bootstrapAndRunApp` after `primeManagerOverride`. It:

1. Reads the active cycle from the repository.
2. If no cycle exists → clears signals.
3. If manager-override cycle (or persisted manager-selected keys) →
   clears signals so the existing override branch keeps driving copy.
4. Otherwise → re-runs `resolveRecommendedSelection` against
   `cycle.calibrationWindowEnd` (the cycle's own build-time window)
   so the hydrated tier matches what the cycle was built from, and
   applies signals with the cycle's persisted geometry.

This guarantees the graph's `RANGE UNCONFIRMED` / `RANGE UNCERTAIN` /
`RANGE TOO WIDE TO TEACH` / `GOOD OPZ RANGE` state is coherent across
restarts without touching persistence schema.

## What stayed unchanged

- `RecommendedBenchmarkSelectionService` — pure, untouched, still
  authoritative for the math
- `BaselineManagerService` — untouched in this slice
- `BaselineData.baselineRangeValidation` — untouched; manager-override
  and legacy/test code paths still consume it directly
- `BaselineData.opzFloorCPLH` / `opzCeilingCPLH` / `derivedTargetCPLH` —
  unchanged; the OPZ math is correct per 7.55p.5b and remains the
  authority for Shift's zone status
- Graph layout, tick positions, target rendering — unchanged. Only the
  inner box colour/alpha and the explainer copy change in degenerate
  states.

## What this slice did NOT do (intentional)

- **Per-daypart OPZ rendering** — deferred to Phase 10.5. The
  `RANGE TOO WIDE TO TEACH` copy explicitly points forward to that work.
- **Manager-override copy refresh** — the existing "star shifts"
  vocabulary still makes sense for the manager-override flow, so it
  was left alone. If the manager-override experience warrants its own
  copy pass later, that is a separate slice.
- **Durable persistence of recommendation tier on `BenchmarkSelectionSummary`**
   — the current summary already carries `rangeQualityLabel` and
  `rangeQualityMessage` which cover durable Learn-surface needs. Adding
  a dedicated `overallQuality` column would be premature; the in-memory
  signal is sufficient for the graph-model honesty seam and avoids
  schema churn in a slice whose prompt explicitly says "avoid broad
  schema churn unless clearly justified."

## Remaining gaps

- **Per-daypart OPZ rendering** (Phase 10.5) — the per-daypart bands
  already live on `RecommendedBenchmarkSelection.perDaypartStats`; a
  future slice can surface them directly and retire the
  `RANGE TOO WIDE TO TEACH` fallback for cross-daypart views.
- **Manager-override copy modernization** — still uses "star shifts"
  language. Not blocking.
- **Persisted recommendation tier** — if Learn ever needs to query
  historical recommendation quality durably, the summary table is the
  place to add a tier column.
- **Bootstrap honesty** — before the first cycle write completes after
  app start, `BaselineData.recommendationSignals` is null and the graph
  falls back to `baselineRangeValidation`. That is acceptable for the
  seed demo but could show momentary non-honest copy on a cold-launch
  real deployment. Not blocking for this slice.
