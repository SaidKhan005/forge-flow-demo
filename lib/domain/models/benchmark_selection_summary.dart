/// Benchmark-selection summary captured at target-cycle build time.
///
/// Persisted alongside each TargetCycle so Learn can read selection
/// analytics without touching BaselineData at runtime.
///
/// Phase 7.55l.8c: contract + persistence.
library;

class BenchmarkSelectionSummary {
  final String summaryId;
  final String restaurantId;
  final String targetCycleId;
  final String sourceType;
  final int selectedShiftCount;
  final String rangeQualityLabel;
  final String rangeQualityMessage;
  final String createdAt;

  const BenchmarkSelectionSummary({
    required this.summaryId,
    required this.restaurantId,
    required this.targetCycleId,
    required this.sourceType,
    required this.selectedShiftCount,
    required this.rangeQualityLabel,
    required this.rangeQualityMessage,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'summary_id': summaryId,
        'restaurant_id': restaurantId,
        'target_cycle_id': targetCycleId,
        'source_type': sourceType,
        'selected_shift_count': selectedShiftCount,
        'range_quality_label': rangeQualityLabel,
        'range_quality_message': rangeQualityMessage,
        'created_at': createdAt,
      };

  factory BenchmarkSelectionSummary.fromMap(Map<String, dynamic> m) =>
      BenchmarkSelectionSummary(
        summaryId: m['summary_id'] as String,
        restaurantId: m['restaurant_id'] as String,
        targetCycleId: m['target_cycle_id'] as String,
        sourceType: m['source_type'] as String,
        selectedShiftCount: m['selected_shift_count'] as int,
        rangeQualityLabel: m['range_quality_label'] as String,
        rangeQualityMessage: m['range_quality_message'] as String,
        createdAt: m['created_at'] as String,
      );
}
