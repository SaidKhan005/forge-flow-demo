// Phase 7.55l.8a — Learn Benchmark Context
// Immutable model carrying everything Learn needs from the benchmark layer.
// Resolved by LearnBenchmarkContextService from persisted app authority.

class LearnBenchmarkContext {
  final String benchmarkSourceLabel;
  final int selectedShiftCount;
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final String rangeQualityLabel;
  final String rangeQualityMessage;

  const LearnBenchmarkContext({
    required this.benchmarkSourceLabel,
    required this.selectedShiftCount,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.rangeQualityLabel,
    required this.rangeQualityMessage,
  });
}
