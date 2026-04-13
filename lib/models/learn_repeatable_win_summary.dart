/// Compact UI-facing read model for one Learn repeatable win.
///
/// Derived from [DaypartPatternSummary] by the
/// [LearnRepeatableWinsReadService]. Carries enough evidence for a
/// compact but honest presentation in the Repeatable Wins card.
///
/// See phase_7_55k_6_learn_repeatable_wins_upgrade.md.
library;

class LearnRepeatableWinSummary {
  /// Human-readable label, e.g. "Sat Dinner".
  final String label;

  /// Most common favorable lever ID in this bucket (e.g. "ppa_up").
  final String dominantLeverId;

  /// Number of favorable-lever closed shifts in this bucket.
  final int benchmarkCount;

  /// Total closed shifts in this bucket.
  final int closedShiftCount;

  /// Average covers per hour (FOH efficiency proof).
  final double avgCPLH;

  /// Average sales per labor hour (BOH efficiency proof).
  final double avgSPLH;

  /// Average PPA (revenue quality proof).
  final double avgPPA;

  /// Up to 5 exemplar source shift IDs for traceability.
  final List<String> exemplarSourceShiftIds;

  const LearnRepeatableWinSummary({
    required this.label,
    required this.dominantLeverId,
    required this.benchmarkCount,
    required this.closedShiftCount,
    required this.avgCPLH,
    required this.avgSPLH,
    required this.avgPPA,
    required this.exemplarSourceShiftIds,
  });
}
