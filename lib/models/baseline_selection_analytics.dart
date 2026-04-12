// Phase 7.55l.8b — Baseline Selection Analytics
// Immutable model carrying selection-analytics fields for Learn.
// Resolved by BaselineSelectionAnalyticsService from persisted state.

class BaselineSelectionAnalytics {
  final int selectedShiftCount;
  final String rangeQualityLabel;
  final String rangeQualityMessage;

  const BaselineSelectionAnalytics({
    required this.selectedShiftCount,
    required this.rangeQualityLabel,
    required this.rangeQualityMessage,
  });
}
