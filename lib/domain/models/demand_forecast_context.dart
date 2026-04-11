import 'schedule_forecast_demand.dart';

/// Repository-backed demand forecast context.
///
/// Replaces direct reads from `BaselineData.historicalWeeklyAvgCovers` with a
/// canonical authority built from eligible closed shifts in the rolling 60-day
/// window.
///
/// Architecture:
///   closed ShiftRecords in 60-day window → total covers → ÷ (60/7) → weekly avg
///
/// This is demand context, not standards. Standards live in [ActiveTargetProfile].
class DemandForecastContext {
  final String restaurantId;

  /// The business date used as the end of the 60-day window.
  final String? anchorBusinessDate;

  /// Sum of covers from all eligible closed shifts in the window.
  final int? historicalTotalCovers;

  /// Weekly average covers: `(totalCovers / weeksRepresented).round()`.
  final int? historicalWeeklyAvgCovers;

  /// Number of weeks the 60-day window represents (always 60 / 7 ≈ 8.57).
  final double weeksRepresented;

  /// Provenance of the covers value.
  final ForecastDemandSource coversSource;

  /// ISO timestamp when this context was built.
  final String builtAt;

  const DemandForecastContext({
    required this.restaurantId,
    required this.anchorBusinessDate,
    required this.historicalTotalCovers,
    required this.historicalWeeklyAvgCovers,
    required this.weeksRepresented,
    required this.coversSource,
    required this.builtAt,
  });

  /// Whether this context has usable demand data.
  bool get isAvailable =>
      historicalWeeklyAvgCovers != null && historicalWeeklyAvgCovers! > 0;

  /// Unavailable sentinel.
  static const unavailable = DemandForecastContext(
    restaurantId: '',
    anchorBusinessDate: null,
    historicalTotalCovers: null,
    historicalWeeklyAvgCovers: null,
    weeksRepresented: 0,
    coversSource: ForecastDemandSource.unavailable,
    builtAt: '',
  );
}
