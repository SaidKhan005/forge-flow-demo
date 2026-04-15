# Temporary Planning Context: Post-7.55p.5 Canonical Live Facts Contract

## Why this note exists

This is a temporary parking note so we can let Claude run `7.55p.5` first, do
the normal prompt/review loop there, and then come back to plan the canonical
live-facts contract with the latest accepted repo truth.

## Current accepted repo state

Accepted through:

- `7.55n.7` - shared current-state freshness model
- `7.55n.8` - Shift freshness UI + pull-to-refresh + `Updated x min ago`
- `7.55n.9` / `7.55n.9a` - app resume / foreground refresh
- `7.55n.10` - automatic boundary invalidation / refresh
- `7.55n.11` - explicit runtime write + import completion propagation seam
- `7.55n.12` / `7.55n.12a` - vendor live-data capability audit + signoff honesty cleanup
- `7.55n.13` - SQLite replay-proof blocker cleanup (`snapshot_blended_wage`), proof reruns restored

Notes:

- The old `app_resume_refresh_test.dart` review finding is stale/resolved.
- The old Phase 8 signoff overclaim finding is stale/resolved after `7.55n.12a`
  and `7.55n.13`.
- The freshness/live-data lane is in a good place architecturally, but true
  vendor-fed "live" behavior still depends on actual integrations.

## Important sequencing decision

Do **not** lock the canonical live-facts contract yet.

`7.55p.5` is now accepted through `7.55p.5a`, but the full follow-up lane is
not done yet.

Run these first:

- `7.55p.5b` - research whether the OPZ / benchmark range should actually be tighter
- `7.55p.5c` - decide the shared target-labor package across Benchmark / Shift / Variance
- `7.55p.5d` - wire the chosen FOH / BOH / total package into Variance
- `7.55p.5e` - refine and test blended wage

Then come back and draft the canonical live-facts contract based on the
post-`7.55p.5*` repo state.

## Why the full `7.55p.5*` follow-up lane should land first

`7.55p.5` and its follow-ups tighten the truth model around:

- which displayed Benchmark values should come from `ActiveTargetProfile`
- which values still belong to bridge-era graph/selection context
- how theoretical labor is represented, labeled, and eventually shared with Variance
- whether the OPZ width concern is true data, presentation ambiguity, or real debt
- whether Shift / Benchmark / Variance should share one planned labor target package, one theoretical package, or both
- how blended wage should be computed, sourced, and tested

The canonical live-facts contract should inherit those ownership decisions
instead of guessing ahead of them.

## Intended follow-up slice

Proposed next planning target after the full `7.55p.5*` follow-up lane:

- `7.55o.1` - Canonical Live Facts Contract

## What that future contract should define

### 1. Canonical live facts for Shift

Universal app-owned facts, regardless of vendor:

- sales
- covers / guest count
- order/check count
- scheduled hours
- worked hours
- approved/finalized hours
- labor dollars
- open-shift/current-floor facts
- target labor %

### 2. Canonical timestamps

- `observedAt`
- `sourceUpdatedAt`
- `importedAt`
- `businessDate`
- `closedAt` / `finalizedAt` where applicable

### 3. Source metadata

- `sourceSystem`
- `sourceEntityType`
- `sourceRecordId`
- `restaurantId`

### 4. Quality / degradation states

- `authoritative`
- `derived`
- `unavailable`
- `stale`

### 5. Freshness semantics

The future contract should define:

- what timestamp drives `Live` vs `Updated x min ago`
- what happens if POS is fresh but labor is stale
- which source wins when multiple systems can speak to the same fact

### 6. Adapter contract

The contract should make clear:

- connectors map vendor payloads into canonical facts
- connectors do not invent product semantics
- missing vendor capability must degrade explicitly, not silently

## Integration truth to carry forward

Canonical facts should be universal.

What is **not** universal:

- how each vendor supplies those facts
- webhook vs polling support
- timestamp depth/quality
- guest-count availability
- approved/finalized labor semantics
- close/finalization signal quality

So the universal internal model stays app-owned, while vendor/pair capability
and degradation behavior remain adapter-specific.

## New parked issue: recommended benchmark range degeneracy

Observed after the `7.55p.5a` / `7.55p.5b` work:

- the Benchmark graph can still show the inner "BENCHMARK RANGE" effectively
  covering the full graph in the default recommended state
- this is not the old "no selection" fallback misunderstanding
- it points to a likely recommendation/data-selection problem, not a graph
  rendering bug

Working interpretation:

- the current recommended benchmark set can be broad enough that its min/max
  CPLH nearly matches the historical min/max CPLH
- when that happens, the graph becomes visually degenerate even if the drawing
  math is correct
- this should be treated as a benchmark recommendation-engine issue before it
  is treated as a graph-only issue

## Research parked for later planning

High-level research conclusion:

- the right fix is not "make the graph look tighter"
- the right fix is to improve how the recommended benchmark set is chosen
- this should be an app/domain recommendation service, not widget logic

Recommended statistical direction:

1. Eligibility gates first
   - closed/finalized records only
   - minimum quality thresholds
   - exclude obviously incomplete/bad records

2. Stratify before scoring
   - at minimum by daypart
   - ideally add weekday/weekend or similar only if sample size supports it

3. Robust outlier labeling
   - median + MAD for outlier labeling
   - IQR for spread sanity checks
   - do not silently delete everything flagged; use explicit exclusion rules

4. Select a stable high-performance cluster, not raw winners
   - high CPLH
   - healthy PPA
   - low labor %
   - tight enough spread to teach a repeatable standard

5. Use robust center for recommended targets
   - trimmed mean or median for recommended CPLH / PPA / SPLH
   - not raw extremes

6. Keep OPZ simple after selection
   - once the recommended set is coherent, OPZ can still be derived from
     selected min/max
   - the likely problem is which records got selected, not the OPZ formula

Practical recommendation to revisit later:

- median + MAD for outlier labeling
- IQR for spread / cluster compactness
- 10% trimmed mean for final recommended targets
- minimum sample-size rules so weak evidence does not masquerade as a strong
  recommendation

## Sequencing note

`7.55p.5c` has now been verified, and this thread is integrated into the
current roadmap.

Planned sequence after the currently queued trust slices:

- `7.55p.5d` - Variance theoretical-package wiring
- `7.55p.5e` - blended wage refinement/testing
- `7.55p.5f1` - wage-mix setup UX + wage-authority trickle verification
- `7.55p.5g` - benchmark recommendation statistics contract
- `7.55p.5h` - recommended benchmark selection service / source-truth seam
- `7.55p.5i` - degenerate benchmark-range fallback + explanation cleanup
- `7.55p.5j` - scope-aware planned labor package contract
- `7.55p.5k` - planned labor package read-model + projection wiring
- then resume canonical live-facts planning

Why this sequence:

- `7.55p.5d` and `7.55p.5e` are already in flight and remain valid
- the Settings wage input UX now needs its own deliberate slice before more
  benchmark recommendation work
- that slice should improve usability without introducing a second wage
  authority path
- after that, the recommendation-engine thread and planned-package thread can
  continue cleanly
- the recommendation-engine work should be informed by the cleaned-up package
  ownership and blended-wage decisions
- the scope-aware planned package should be informed by:
  - the cleaned-up blended wage decision
  - the recommendation/benchmark target source-truth work
  - the explicit distinction between theoretical and planned packages
- the canonical live-facts contract should inherit both the labor-package
  decisions and the benchmark recommendation/source-truth decisions

## New parked issue: scope-aware planned labor package

User intent captured:

- if a day-by-day plan table compares current or planned labor % to that day's
  forecast sales, it should be able to show **planned labor % for today**
- that same idea should scale honestly to:
  - dayparts
  - days
  - full-week planning/projection

Working architecture conclusion:

- this is not a third truth package that replaces the existing two-package
  contract
- it is a **scope-aware planned-package metric** derived from the existing
  planned-package ingredients at a given scope

Core rule to preserve:

- planned labor % at any scope =
  planned labor dollars at that scope / forecast sales at that scope

That means:

- daypart planned labor % =
  daypart planned labor dollars / daypart forecast sales
- day planned labor % =
  summed planned labor dollars for the day / summed forecast sales for the day
- week planned labor % =
  summed planned labor dollars for the week / summed forecast sales for the week

Important guardrail:

- do **not** average percentages across child rows
- always aggregate dollars and sales first, then recompute %

Intended surface ownership:

- Shift can keep using the planned package for current-state comparison
- planning/day tables can use planned labor % by day or by daypart
- full-week planning/projection can use planned labor % at week scope
- Variance should remain theoretical-package-based unless a future explicit
  second comparison mode is introduced

## Where to resume after `7.55p.5`

When `7.55p.5` is accepted, come back to this note and plan `7.55o.1` using:

- the final accepted `7.55p.5` repo truth
- the vendor capability evidence from `7.55n.12`
- the freshness contract/freshness UI work already landed in `7.55n.*`

The key principle: build the canonical live-facts contract from actual accepted
ownership truth, not from assumptions.
