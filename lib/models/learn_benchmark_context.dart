// Phase 7.55l.8a — Learn Benchmark Context
// Immutable model carrying everything Learn needs from the benchmark layer.
// Resolved by LearnBenchmarkContextService from persisted app authority.
//
// Per-Daypart Targets V1 (Slice 1) — Gap 39 model layer:
// Per-period target rows mirror the shape of ActiveTargetProfile.dayparts
// so the Learn analyzer can sharpen pattern resolution to the period
// underneath ("Friday dinner: covers down" vs "Friday: covers down").
// Decision 13 — no UX overhaul in V1; analyzer narration update is a
// follow-up after Slice 1's model layer lands.

/// Per-period target row for [LearnBenchmarkContext].
///
/// Field naming uses the `daypart` prefix (Design Rule 1) so callers
/// cannot accidentally substitute the whole-day pool scalars on the
/// parent context.
class LearnBenchmarkContextDaypart {
  final String servicePeriodId;
  final double daypartTargetCPLH;
  final double daypartTargetSPLH;
  final double daypartTargetPPA;
  final double daypartOpzFloorCPLH;
  final double daypartOpzCeilingCPLH;

  const LearnBenchmarkContextDaypart({
    required this.servicePeriodId,
    required this.daypartTargetCPLH,
    required this.daypartTargetSPLH,
    required this.daypartTargetPPA,
    required this.daypartOpzFloorCPLH,
    required this.daypartOpzCeilingCPLH,
  });
}

class LearnBenchmarkContext {
  final String benchmarkSourceLabel;
  final int selectedShiftCount;
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final String rangeQualityLabel;
  final String rangeQualityMessage;

  /// Per-period target rows. Empty when the underlying cycle wrote no
  /// per-period child rows (Gap 42 fallback). Consumers must check
  /// [daypartFor] for null before reading and fall back to the whole-day
  /// pool fields above (Design Rule 2 — never substitute `0`).
  final List<LearnBenchmarkContextDaypart> dayparts;

  const LearnBenchmarkContext({
    required this.benchmarkSourceLabel,
    required this.selectedShiftCount,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.rangeQualityLabel,
    required this.rangeQualityMessage,
    this.dayparts = const [],
  });

  LearnBenchmarkContextDaypart? daypartFor(String servicePeriodId) {
    for (final d in dayparts) {
      if (d.servicePeriodId == servicePeriodId) return d;
    }
    return null;
  }
}
