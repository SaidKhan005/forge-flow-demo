// Phase 7.55k.3 — Aggregate daypart pattern summary.
//
// Groups closed ShiftRecords by recurring service-period bucket
// (restaurantId + dayLabel + daypart) and carries metric proof,
// dominant levers, and exemplar source shift IDs.
//
// This is NOT a per-date fact — it aggregates across multiple
// closed service-period facts. Source facts are keyed by
// ServicePeriodKey-shaped identity (restaurantId + businessDate +
// servicePeriodId); this summary aggregates over them.
//
// Current History / Learn consumers remain on HistoryPatternRecord.
// Later slices (7.55k.5, 7.55k.6) will migrate to this model.

class DaypartPatternSummary {
  /// Restaurant scope for this summary bucket.
  final String restaurantId;

  /// Day-of-week label (e.g. 'Mon', 'Sat').
  final String dayLabel;

  /// Service-period ID (e.g. 'lunch', 'dinner', 'late_night').
  final String daypart;

  // ── Counts ──────────────────────────────────────────────────────────────

  /// Total closed shifts in this bucket.
  final int closedShiftCount;

  /// Shifts with a favorable lever (benchmark evidence).
  /// Only valid known lever IDs (from LeverCards.all) are counted.
  final int benchmarkCount;

  /// Shifts with an unfavorable lever (leak evidence).
  /// Only valid known lever IDs (from LeverCards.all) are counted.
  final int leakCount;

  // ── Dominant levers ─────────────────────────────────────────────────────

  /// Most common favorable lever ID, or null if no benchmark evidence.
  final String? dominantBenchmarkLeverId;

  /// Most common unfavorable lever ID, or null if no leak evidence.
  final String? dominantLeakLeverId;

  // ── Metric averages ─────────────────────────────────────────────────────

  final double avgCovers;
  final double avgSales;
  final double avgPPA;
  final double avgCPLH;
  final double avgSPLH;
  final double avgFohHours;
  final double avgBohHours;
  final double avgLaborPct;
  final double avgVariancePts;

  // ── Exemplar references ─────────────────────────────────────────────────

  /// Up to 5 source shift IDs for traceability back to original facts.
  final List<String> exemplarSourceShiftIds;

  const DaypartPatternSummary({
    required this.restaurantId,
    required this.dayLabel,
    required this.daypart,
    required this.closedShiftCount,
    required this.benchmarkCount,
    required this.leakCount,
    this.dominantBenchmarkLeverId,
    this.dominantLeakLeverId,
    required this.avgCovers,
    required this.avgSales,
    required this.avgPPA,
    required this.avgCPLH,
    required this.avgSPLH,
    required this.avgFohHours,
    required this.avgBohHours,
    required this.avgLaborPct,
    required this.avgVariancePts,
    required this.exemplarSourceShiftIds,
  });

  /// Human-readable bucket label (e.g. "Sat Dinner").
  String get fullLabel => '$dayLabel $daypartLabel';

  /// Display label for the service period.
  String get daypartLabel {
    switch (daypart) {
      case 'lunch':
        return 'Lunch';
      case 'dinner':
        return 'Dinner';
      case 'late_night':
        return 'Late Night';
      case 'morning':
        return 'Morning';
      default:
        return daypart;
    }
  }

  /// Whether this summary meets a given minimum sample threshold.
  bool meetsThreshold(int minSample) => closedShiftCount >= minSample;
}
