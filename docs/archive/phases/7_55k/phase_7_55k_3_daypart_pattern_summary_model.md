# Phase 7.55k.3 â€” Daypart Pattern Summary Model

Updated: 2026-04-12
Owner: Codex planning / Claude implementation
Status: Implemented

## What This Slice Delivers

A richer aggregate `DaypartPatternSummary` model and a
`DaypartPatternSummaryBuilder` that derives summaries from closed
`ShiftRecord`s. This gives downstream History and Learn upgrades an
evidence-carrying read seam to build on.

Current History / Learn consumers remain on `HistoryPatternRecord` for
now. This slice does not migrate them.

## Key Design Decisions

### Identity shape

`DaypartPatternSummary` is an **aggregate summary grouped by recurring
service-period bucket** (e.g., "Saturday Dinner"), not a per-date fact.

Source facts feeding the summary are keyed by `ServicePeriodKey`-shaped
identity (`restaurantId + businessDate + servicePeriodId`). The summary
itself aggregates across those facts â€” its identity is
`restaurantId + dayLabel + daypart`.

### Relationship to existing models

- `HistoryPatternRecord` â€” lightweight per-shift signal (lever + boolean).
  Remains in place; not removed or migrated in this slice.
- `HistoryPatternBuilder` â€” existing builder. Remains in place as the
  active path for `HistoryTeachingAnalyzer` and `LearnTeachingAnalyzer`.
- `DaypartPatternSummary` â€” new aggregate carrying counts, averages,
  dominant levers, and exemplar source shift IDs.
- `DaypartPatternSummaryBuilder` â€” new builder producing summaries from
  closed `ShiftRecord`s.

### Sample threshold

The builder accepts a `minSampleThreshold` parameter. Summaries with
fewer closed shifts than the threshold are excluded from the output.
This keeps the contract explicit and testable without pulling `7.55k.7`
visibility-rule policy forward.

### Ordering

Output is sorted by canonical day order (Monâ€“Sun via `CanonicalDayOrder`)
then by a deterministic service-period order (`morning`, `lunch`,
`dinner`, `late_night`; unknown IDs sort last alphabetically). This
avoids building the full `ServicePeriodDefinitionResolver` for this
slice while keeping output stable.

### Lever evidence

- Only valid known lever IDs (from `LeverCards.all`) participate in benchmark
  and leak counting. Unknown or unmapped lever IDs are excluded from lever
  evidence but still contribute to `closedShiftCount` and metric averages.
  This aligns with `HistoryPatternBuilder`, which also validates lever IDs
  against `LeverCards.all`.
- `ON_MODEL` shifts are excluded from lever counting and dominant lever
  detection. They still count toward `closedShiftCount` and metric averages
  because they represent real closed operational facts.
- Benchmark vs leak classification uses `LaborModel.isFavorableLever()`.
- Dominant levers use the same deterministic tie-breaking as
  `HistoryTeachingAnalyzer`.

### Exemplar IDs

`exemplarSourceShiftIds` collects `sourceShiftId` from source shifts when
present, falling back to a deterministic synthetic key
(`weekId:dayLabel:daypart:businessDate`, or `weekId:dayLabel:daypart:weekId`
when `businessDate` is absent) when no persisted ID exists. Candidate shifts
are sorted deterministically (by `weekId`, then `businessDate`, then
`covers`) before exemplar extraction, so the same input facts always produce
the same exemplar list regardless of input ordering. Limited to 5 entries per
summary for tractability.

## What This Slice Does NOT Do

- Does not migrate `HistoryTeachingAnalyzer` or `LearnTeachingAnalyzer`
  to the new summary.
- Does not change Variance, History, or Learn screens.
- Does not introduce `ServicePeriodDefinitionResolver`.
- Does not change the Shift dashboard.
- Does not update tracker markdown files.

## Downstream Consumers (future slices)

- `7.55k.5` â€” History benchmark dayparts upgrade: will consume
  `DaypartPatternSummary` for evidence-backed benchmark daypart labels.
- `7.55k.6` â€” Learn repeatable wins upgrade: will consume
  `DaypartPatternSummary` for metric-grounded coaching copy.
- `7.55k.7` â€” Interim visibility rules: will use `closedShiftCount`
  against the sample threshold for gating and early-signal labels.

## Files

- `docs/archive/phases/7_55k/phase_7_55k_3_daypart_pattern_summary_model.md` (this doc)
- `lib/models/daypart_pattern_summary.dart`
- `lib/services/daypart_pattern_summary_builder.dart`
- `test/daypart_pattern_summary_builder_test.dart`

## Cross-References

- `docs/archive/phases/7_55k/phase_7_55k_1_daypart_scope_audit.md` â€” overstatement gaps
- `docs/archive/phases/7_55k/phase_7_55k_2_service_period_decoupling_plan.md` â€” identity shapes
- `docs/archive/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md` â€” parent plan
