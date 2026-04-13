# Phase 7.55k.7 — Interim Visibility Rules

Updated: 2026-04-12
Owner: Codex planning / Claude implementation
Status: Implemented (`7.55k.7a` honesty cleanup landed)

## What This Slice Delivers

Adds explicit interim visibility and confidence rules so History and Learn
do not overstate thin closed-daypart evidence. This is an app-side interim
policy, not final live-integration behavior.

## Key Design Decisions

### Policy seam

`DaypartEvidenceVisibilityPolicy` is a dedicated policy service that owns
sample-depth and repeatability decisions. Visibility rules do not live in
widget conditionals alone.

### Evidence tiers

Three tiers classify closed-daypart evidence:

- `strong`: enough closed-shift depth to trust the pattern.
- `earlySignal`: favorable evidence exists but sample depth is thin.
- `hidden`: not enough evidence to surface.

### History benchmark dayparts

- Buckets with `closedShiftCount >= 3` render as `BENCHMARK DAYPARTS` (strong).
- Buckets with fewer closed shifts render as `EARLY SIGNALS` in warning color.
- Strong evidence is prioritized ahead of early signals when display slots are
  limited. Tier classification happens before truncation so a thin 2/2
  early-signal bucket cannot displace a 1/3 strong benchmark. (`7.55k.7a`)
- Empty benchmark evidence still renders a dash.

### Learn Repeatable Wins

- Only buckets with `benchmarkCount >= 2` pass the visibility filter.
- A single favorable closed shift is not a repeatable pattern.
- When all win buckets are filtered out, the card shows an intentional empty
  state ("No repeatable wins yet") instead of pretending evidence exists.
- The empty state does not fall back to legacy frequency-only benchmark-daypart
  labels. (`7.55k.7a`)
- There is no early-signal tier for Repeatable Wins: either the win repeats
  or it does not belong in the card.

### Intentional empty/partial states

Empty and partial states are intentional product states, not missing UI:

- History with no strong evidence shows `EARLY SIGNALS` instead of benchmarks.
- History with no evidence at all shows a dash.
- Learn with no repeated wins shows the existing empty state with study line.

### Source-truth boundary

Unchanged from `7.55k.5` / `7.55k.6`:

- Only closed shifts enter the evidence pipeline.
- Open/projected rows are excluded.
- Favorable evidence drives benchmark/win candidacy.

## Explicit Interim Thresholds

| Rule | Value | Surface |
|------|-------|---------|
| Strong benchmark min sample | 3 closed shifts | History |
| Repeatable win min favorable | 2 favorable shifts | Learn |

These are interim values. They may change when live-integration transport
provides richer closed-shift volume.

## What This Slice Does NOT Do

- Does not redesign runtime architecture broadly.
- Does not change target math, cycle math, replay behavior, or labor formulas.
- Does not migrate Benchmark Set.
- Does not rewrite Recurring Leak broadly.
- Does not make Shift service-period or live-daypart aware.
- Does not pull Phase 10.5 behavior forward.
- Does not update tracker markdown files.

## Future Boundaries

- `7.55k.8` owns integration implications.
- `7.55n` owns restaurant timing + service-period runtime foundation.
- `7.55o` owns engineering hygiene / file extraction.
- `10.5` owns live Shift service-period behavior and daypart-live teaching.

## Files

- `docs/phases/7_55k/phase_7_55k_7_interim_visibility_rules.md` (this doc)
- `lib/services/daypart_evidence_visibility_policy.dart`
- `lib/screens/variance_report.dart` (History + Learn policy wiring)
- `test/variance_history_widget_test.dart`
- `test/learn_layer_widget_test.dart`

## Cross-References

- `docs/phases/7_55k/phase_7_55k_5_history_benchmark_dayparts_upgrade.md` — History evidence
- `docs/phases/7_55k/phase_7_55k_6_learn_repeatable_wins_upgrade.md` — Learn evidence
- `docs/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md` — parent plan
