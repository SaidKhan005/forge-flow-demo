import '../models/benchmark_selection_summary.dart';

/// Contract for BenchmarkSelectionSummary persistence.
///
/// Phase 7.55l.8c: one summary per target cycle.
abstract class BenchmarkSelectionSummaryRepository {
  Future<BenchmarkSelectionSummary?> getByTargetCycleId(
      String targetCycleId);
  Future<void> upsert(BenchmarkSelectionSummary summary);
}
