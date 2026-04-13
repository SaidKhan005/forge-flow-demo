/// Compact UI-facing read model for one History benchmark daypart.
///
/// Derived from [DaypartPatternSummary] by the
/// [HistoryBenchmarkDaypartReadService]. Carries enough evidence for
/// a compact but honest presentation in the History teaching card.
///
/// See phase_7_55k_5_history_benchmark_dayparts_upgrade.md.
library;

class HistoryBenchmarkDaypartSummary {
  /// Human-readable label, e.g. "Sat Dinner".
  final String label;

  /// Number of favorable-lever closed shifts in this bucket.
  final int benchmarkCount;

  /// Total closed shifts in this bucket.
  final int closedShiftCount;

  /// Average covers per hour (FOH efficiency proof).
  final double avgCPLH;

  /// Average sales per labor hour (BOH efficiency proof).
  final double avgSPLH;

  /// Up to 5 exemplar source shift IDs for traceability.
  final List<String> exemplarSourceShiftIds;

  const HistoryBenchmarkDaypartSummary({
    required this.label,
    required this.benchmarkCount,
    required this.closedShiftCount,
    required this.avgCPLH,
    required this.avgSPLH,
    required this.exemplarSourceShiftIds,
  });
}
