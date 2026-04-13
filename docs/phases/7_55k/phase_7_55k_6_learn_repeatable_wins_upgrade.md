# Phase 7.55k.6 — Learn Repeatable Wins Upgrade

Updated: 2026-04-12
Owner: Codex planning / Claude implementation
Status: Implemented

## What This Slice Delivers

Upgrades Learn Repeatable Wins from frequency-only benchmark labels to compact,
evidence-backed closed-truth summaries. The Repeatable Wins card now shows
sample depth, metric proof, and a dominant favorable lever alongside each win
daypart, using the `DaypartPatternSummary` seam from `7.55k.3`.

## Key Design Decisions

### Read model

`LearnRepeatableWinSummary` is a compact UI-facing read model carrying:

- recurring bucket label (`dayLabel + daypart`)
- dominant favorable lever ID (e.g. `ppa_up`)
- favorable evidence count (`benchmarkCount`)
- total sample depth (`closedShiftCount`)
- `avgCPLH`, `avgSPLH`, and `avgPPA` as compact metric proofs
- exemplar source shift IDs for traceability

### Read service

`LearnRepeatableWinsReadService` derives win summaries from historical closed
shifts via `DaypartPatternSummaryBuilder`. Only buckets with at least one
favorable-lever shift AND a non-null dominant benchmark lever are included.
Ranking is by `benchmarkCount` descending, then `closedShiftCount` descending,
then explicit canonical day order (Mon-Sun) and service-period order
(morning -> lunch -> dinner -> late_night). Ties are fully deterministic
without relying on sort stability. Top 3 win dayparts are returned.

### Source-truth boundary

- Only closed shifts enter the pipeline.
- Open/projected rows are excluded.
- `DaypartPatternSummaryBuilder` handles the closed-only filter.
- Favorable evidence drives win candidacy.
- Buckets without a dominant favorable lever are excluded.
- Leak evidence stays separate (still on `LearnTeachingAnalyzer` path).

### Learn tab wiring

The `_RepeatableWinsCard` now renders evidence-backed win rows instead of
frequency-only benchmark-daypart labels. Each row shows:
`Sat Dinner · 5/8 wins · 4.80 CPLH · $180 SPLH`

The `N/M wins` format surfaces both favorable evidence count and total sample
depth. Each evidence row carries a compact per-row lever chip (e.g. `PPA`,
`CPLH`) so rows with different dominant levers are visually distinguishable.

The teaching block (WHAT HELD, WHAT TO PROTECT, WHAT TO STUDY) is explicitly
scoped to the top-ranked win via a `COACHING — <label>` header. This prevents
the teaching copy from reading as though one lever card explains every listed
row.

Generic lever-card teaching remains as supporting copy alongside the evidence.

### Compatibility

- `LearnTeachingAnalyzer` still powers leak/coaching copy and benchmark-context
  fields. It is not removed or rewritten in this slice.
- `LearnTeachingSummary` is not modified. The new `repeatableWins` list is
  carried separately via `_LearnData`.
- Benchmark Set card is unchanged.
- Recurring Leak card is unchanged.
- `HistoryPatternRecord` and `HistoryPatternBuilder` remain in place.
- `HistoryTeachingAnalyzer` remains unchanged.

## What This Slice Does NOT Do

- Does not migrate the Benchmark Set card.
- Does not rewrite the Recurring Leak card broadly.
- Does not remove `HistoryPatternRecord` or `HistoryPatternBuilder`.
- Does not redesign runtime architecture broadly.
- Does not implement visibility/sample-threshold policy (`7.55k.7` owns that).
- Does not make Shift service-period or live-daypart aware.
- Does not pull Phase 10.5 behavior forward.
- Does not update tracker markdown files.

## Future Boundaries

- `7.55k.7` owns visibility rules / early-signal policy.
- `7.55k.8` owns integration implications.
- `7.55n` owns restaurant timing + service-period runtime foundation.
- `7.55o` owns engineering hygiene / file extraction.
- `10.5` owns live Shift service-period behavior and daypart-live teaching.

## Files

- `docs/phases/7_55k/phase_7_55k_6_learn_repeatable_wins_upgrade.md` (this doc)
- `lib/models/learn_repeatable_win_summary.dart`
- `lib/services/learn_repeatable_wins_read_service.dart`
- `lib/screens/variance_report.dart` (Learn tab wiring)
- `test/learn_repeatable_wins_read_service_test.dart`
- `test/learn_layer_widget_test.dart`

## Cross-References

- `docs/phases/7_55k/phase_7_55k_3_daypart_pattern_summary_model.md` — evidence seam
- `docs/phases/7_55k/phase_7_55k_5_history_benchmark_dayparts_upgrade.md` — History upgrade pattern
- `docs/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md` — parent plan
