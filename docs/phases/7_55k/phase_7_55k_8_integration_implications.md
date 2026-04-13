# Phase 7.55k.8 — Integration Implications

Updated: 2026-04-12
Owner: Codex planning / Claude implementation
Status: Implemented

## What This Slice Delivers

Documents the concrete downstream integration requirements that `7.55k.4`
through `7.55k.7a` proved, and feeds them back into the `7.55j` integration
planning lane so `7.55j.3` (vendor checklist) and `7.55j.4` (gap report)
inherit the right requirements instead of stale generic assumptions.

This is a documentation / handoff slice. No runtime code changes.

## What 7.55k Proved

### 7.55k.4 — Variance Full Week Projection Semantics

Every Full Week row now carries an explicit `RowStatus` (closed, open,
projected, mixed). This proves that downstream integrations must provide:

- **Close/finalization semantics**: the app must know when a business day is
  finalized so closed rows carry locked truth and open/projected rows are
  clearly non-final.
- **Business-date-safe closed truth**: closed actuals must arrive tagged to
  the correct business date, not just a calendar date.
- **Explicit provenance between closed truth, open live context, and projected
  plan context**: integrations must not conflate live in-progress data with
  finalized actuals.

### 7.55k.5 — History Benchmark Dayparts Upgrade

History benchmark dayparts are now evidence-backed closed-truth summaries
(sample count, metric proofs, exemplar IDs), not frequency-only labels.
This proves that integrations must support:

- **Enough timestamp detail for app-owned service-period mapping**: the app
  maps POS/labor facts into service periods itself. If the vendor only provides
  full-day rolled-up aggregates with no usable timestamps, daypart evidence
  must degrade or stay hidden.
- **Source IDs for exemplar tracing and deduplication**: benchmark daypart
  records carry exemplar source shift IDs so evidence rows can be traced back
  to their originating closed facts.
- **Enough labor granularity for daypart evidence**: actual FOH/BOH hours must
  be mappable to service periods by time range, not just full-day totals.
- **Correction/update feeds after close**: if POS or labor facts change after
  initial close (refunds, punch edits, late adjustments), the benchmark
  evidence pipeline should be aware so history does not go stale.

### 7.55k.6 — Learn Repeatable Wins Upgrade

Learn Repeatable Wins are now evidence-backed closed-truth summaries with
dominant favorable levers, sample depth, and metric proofs. This proves:

- **Favorable lever detection depends on closed actuals vs locked targets**:
  integrations must provide closed covers, sales, and hours at enough
  granularity for the app to compute PPA, CPLH, SPLH, and determine which
  lever was dominant.
- **Evidence maturity depends on integration depth**: a vendor that provides
  only weekly rolled-up aggregates cannot produce the per-shift, per-daypart
  evidence that Repeatable Wins requires.
- **Source IDs matter for win stability**: if the same closed shift can appear
  in multiple sync batches, deduplication by source ID is required to avoid
  inflating win counts.

### 7.55k.7 / 7.55k.7a — Interim Visibility Rules

The app now has explicit sample-depth and repeatability thresholds:

- **Strong benchmark**: 3+ closed shifts in a recurring bucket.
- **Early signal**: fewer than 3 closed shifts.
- **Repeatable win**: 2+ favorable shifts in a recurring bucket.
- **Hidden**: not enough evidence to surface.

This proves:

- **Thin-sample visibility is app-owned policy, but integrations must provide
  enough closed-shift depth for evidence to mature**: a vendor that only
  provides a few weeks of backfill will leave most daypart buckets in
  early-signal or hidden tiers.
- **The 60-day backfill window is the minimum**: integrations must support at
  least a 60-day historical backfill to give the app enough closed facts for
  benchmark and win evidence to cross the strong threshold.
- **Incremental sync after backfill is important**: without ongoing daily-close
  sync, closed-shift depth cannot grow and evidence tiers stay thin.

## Concrete Integration Requirements Proven by 7.55k

### For closed-truth evidence (History / Learn / Benchmark)

These are **required** for evidence-backed coaching:

| Requirement | Why | Source |
|---|---|---|
| Business-date-tagged closed actuals | Evidence is bucketed by business date + daypart | POS + Labor |
| Timestamped source facts (opened/closed times) | App maps facts into service periods; without timestamps, daypart depth is unavailable | POS + Labor |
| Close/finalization signal per business date | App must distinguish finalized days from still-open days | POS |
| Source IDs (check/order/shift/punch) | Exemplar tracing, deduplication, correction tracking | POS + Labor |
| Correction/update feeds after close | Benchmark and win evidence must not go stale after refunds, punch edits, or late adjustments | POS + Labor |
| FOH/BOH hours by time range (not just daily total) | Daypart-level CPLH/SPLH requires hours mapped to service periods | Labor |
| At least 60-day backfill window | Evidence tiers require enough closed-shift depth to cross strong/repeatable thresholds | POS + Labor |
| Incremental daily-close sync | Without ongoing sync, evidence depth cannot grow past the backfill | POS + Labor |

### For live/open context (Variance Full Week open/projected rows)

These are **required for context** but not for evidence:

| Requirement | Why | Source |
|---|---|---|
| Intraday covers/sales for the open business day | Open rows show live in-progress context | POS |
| Current clocked-in labor | Open rows show live labor context | Labor |
| Business-date identification for the open day | App must know which day is currently in progress | POS or App clock |

### For projected/plan context (Variance Full Week projected rows)

These are **app-owned** and do not require integration:

| Requirement | Why | Source |
|---|---|---|
| Projected rows from WeeklyPlanSnapshot | Projected context comes from the locked weekly plan | App-owned |
| Plan hours and forecast covers | From SchedulePlan resolution | App-owned |

### Optional explanatory context

| Requirement | Why | Source |
|---|---|---|
| Reservation party size, time, status | Explains demand patterns in History; powers "In the books" on Shift | Reservation |
| Revenue center or service mode | May improve daypart assignment quality | POS |
| Vendor-native service period field | Optional shortcut; app prefers timestamp bucketing | POS |

## What Degrades Without Timestamps

If a POS or labor vendor provides only full-day rolled-up aggregates with no
usable timestamps:

- **Whole-day Shift still works** — Shift is whole-day until Phase 10.5.
- **Schedule still works** — day allocation uses weekly totals.
- **Variance WTD still works** — WTD compares day-level aggregates.
- **Daypart evidence degrades or stays hidden**: History benchmark dayparts,
  Learn Repeatable Wins, and Variance Full Week daypart detail rows cannot
  produce honest closed-daypart truth from math alone. The app's interim
  visibility rules will correctly hide or downgrade these surfaces.

This is an acceptable degradation path, not a blocker. The app should document
per-vendor whether daypart depth is available or limited.

## What Does NOT Change

- **Vendor-native daypart support is optional**: the app prefers to own
  service-period definitions and map timestamped facts itself.
- **App owns visibility policy**: sample-depth and repeatability thresholds
  are app-side decisions, not vendor requirements. Integrations provide the
  raw closed facts; the app decides what evidence is strong enough to surface.
- **Shift stays whole-day until Phase 10.5**: `7.55k` does not require live
  daypart Shift transport.
- **Reservation remains optional explanatory context** for History/Learn
  unless a future product decision promotes it into demand forecasting.
- **Forecast demand remains app-owned**: POS history is the baseline evidence;
  the app derives the rolling demand forecast.

## Phase Ownership

| Phase | Owns |
|---|---|
| `7.55k.8` | This documentation / handoff slice |
| `7.55j.3` | Vendor endpoint checklist template (uses these requirements) |
| `7.55j.4` | Final gap report (uses these requirements) |
| `7.55n` | Restaurant timing + service-period runtime foundation |
| `7.55o` | File extraction / engineering hygiene |
| `10.5` | Live Shift service-period behavior |
| Phase 8 | Live POS + Labor connector implementation |
| Phase 8R | Live Reservation connector implementation |

## What This Slice Does NOT Do

- Does not change runtime code.
- Does not change tests.
- Does not implement vendor connectors.
- Does not invent vendor-specific endpoint names.
- Does not revive `7.55j.3` or `7.55j.4` implementation.
- Does not start `7.55n` timing work.
- Does not update tracker markdown files.

## Files

- `docs/phases/7_55k/phase_7_55k_8_integration_implications.md` (this doc)
- `docs/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md` (updated)
- `docs/phases/7_55j/phase_7_55j_2_required_capability_matrix.md` (updated)

## Cross-References

- `docs/phases/7_55k/phase_7_55k_4_variance_full_week_projection_semantics.md`
- `docs/phases/7_55k/phase_7_55k_5_history_benchmark_dayparts_upgrade.md`
- `docs/phases/7_55k/phase_7_55k_6_learn_repeatable_wins_upgrade.md`
- `docs/phases/7_55k/phase_7_55k_7_interim_visibility_rules.md`
- `docs/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md` — parent plan
- `docs/contracts/phase_7_55_architecture_contract.md` — system contract
