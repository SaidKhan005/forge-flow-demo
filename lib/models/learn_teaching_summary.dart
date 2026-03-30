// Phase 7.14 — Learn Teaching Summary
// Immutable model combining History pattern analysis with active Baseline truth.

class LearnTeachingSummary {
  final int weekCount;
  final String benchmarkSourceLabel;
  final int selectedShiftCount;
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final String rangeQualityLabel;
  final String rangeQualityMessage;
  final String primaryLeakId;
  final String primaryLeakSideLabel;
  final int primaryLeakCount;
  final List<String> topLeakDayparts;
  final List<String> benchmarkDayparts;
  final String primaryFixLine;
  final String studyLine;
  final String coachToLine;
  final bool hasHistoryPatterns;
  final String primaryBenchmarkId;
  final String primaryBenchmarkSideLabel;
  final int primaryBenchmarkCount;
  final bool hasBenchmarkPatterns;

  const LearnTeachingSummary({
    required this.weekCount,
    required this.benchmarkSourceLabel,
    required this.selectedShiftCount,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.rangeQualityLabel,
    required this.rangeQualityMessage,
    required this.primaryLeakId,
    required this.primaryLeakSideLabel,
    required this.primaryLeakCount,
    required this.topLeakDayparts,
    required this.benchmarkDayparts,
    required this.primaryFixLine,
    required this.studyLine,
    required this.coachToLine,
    required this.hasHistoryPatterns,
    required this.primaryBenchmarkId,
    required this.primaryBenchmarkSideLabel,
    required this.primaryBenchmarkCount,
    required this.hasBenchmarkPatterns,
  });
}
