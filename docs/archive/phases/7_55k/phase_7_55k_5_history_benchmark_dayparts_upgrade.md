# Phase 7.55k.5 â€” History Benchmark Dayparts Upgrade

Updated: 2026-04-12
Owner: Codex planning / Claude implementation
Status: Implemented

## What This Slice Delivers

Upgrades History benchmark dayparts from frequency-only labels to compact,
evidence-backed closed-truth summaries. The History teaching card now shows
sample count and metric proof alongside each benchmark daypart, using the
`DaypartPatternSummary` seam from `7.55k.3`.

## Key Design Decisions

### Read model

`HistoryBenchmarkDaypartSummary` is a compact UI-facing read model carrying:

- recurring bucket label (`dayLabel + daypart`)
- favorable evidence count (`benchmarkCount`)
- total sample depth (`closedShiftCount`)
- `avgCPLH` and `avgSPLH` as compact metric proofs
- exemplar source shift IDs for traceability

The compact UI renders both favorable and total counts (`5/8 wins`) so evidence
depth is never overstated.

### Read service

`HistoryBenchmarkDaypartReadService` derives benchmark summaries from
historical closed shifts via `DaypartPatternSummaryBuilder`. Ranking is by
`benchmarkCount` descending, then `closedShiftCount` descending, then
explicit canonical day order (Monâ€“Sun) and service-period order
(morning â†’ lunch â†’ dinner â†’ late_night). Ties are fully deterministic
without relying on sort stability. Top 3 benchmark dayparts are returned.

### Source-truth boundary

- Only closed shifts enter the pipeline.
- Open/projected rows are excluded.
- `DaypartPatternSummaryBuilder` handles the closed-only filter.
- Favorable evidence drives benchmark candidacy.
- Leak evidence stays separate.

### History tab wiring

The `_TeachingSummaryCard` now renders evidence-backed benchmark rows
instead of joined frequency labels. Each row shows:
`Sat Dinner Â· 5/8 wins Â· 4.80 CPLH Â· $180 SPLH`

The `N/M wins` format surfaces both favorable evidence count and total sample
depth so a bucket with 5 wins out of 10 reads differently from 5 out of 5.

The leak teaching sections remain powered by `HistoryTeachingAnalyzer` on
the `HistoryPatternRecord` path â€” that is unchanged in this slice.

### Compatibility

- `HistoryPatternRecord` and `HistoryPatternBuilder` remain in place.
- `HistoryTeachingAnalyzer` still powers the leak-side teaching.
- Learn remains unchanged â€” `7.55k.6` owns Learn migration.

## What This Slice Does NOT Do

- Does not migrate Learn.
- Does not remove `HistoryPatternRecord` or `HistoryPatternBuilder`.
- Does not redesign runtime architecture broadly.
- Does not make Shift service-period or live-daypart aware.
- Does not pull Phase 10.5 behavior forward.
- Does not update tracker markdown files.

## Future Boundaries

- `7.55k.6` owns Learn repeatable wins upgrade.
- `7.55k.7` owns visibility rules / early-signal policy.
- `7.55n` owns restaurant timing + service-period runtime foundation.
- `10.5` owns live Shift service-period behavior and daypart-live teaching.

## Files

- `docs/archive/phases/7_55k/phase_7_55k_5_history_benchmark_dayparts_upgrade.md` (this doc)
- `lib/models/history_benchmark_daypart_summary.dart`
- `lib/services/history_benchmark_daypart_read_service.dart`
- `lib/data/shift_data_source.dart` (added `getHistoricalClosedShifts`)
- `lib/screens/variance_report.dart` (History tab wiring)
- `test/history_benchmark_daypart_read_service_test.dart`
- `test/variance_history_widget_test.dart`

## Cross-References

- `docs/archive/phases/7_55k/phase_7_55k_3_daypart_pattern_summary_model.md` â€” evidence seam
- `docs/archive/phases/7_55k/phase_7_55k_1_daypart_scope_audit.md` â€” overstatement gaps
- `docs/archive/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md` â€” parent plan
