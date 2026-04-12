import 'schedule_forecast_demand.dart';

/// Repository-backed demand forecast context (v2).
///
/// v1 carried only the 60-day historical weekly average.
/// v2 makes the demand stack explicit:
///
///   level 1 = 60-day baseline weekly average covers
///   level 2 = fixed 3-week recent trend weekly average covers
///   output  = resolved rolling weekly forecast covers (smoothed blend)
///
/// Smoothing rule:
///   if both layers available:
///     recentTrendDelta = recentThreeWeekWeeklyAvg - baselineWeeklyAvg
///     resolved = max(0, baselineWeeklyAvg + (recentTrendDelta / 2).round())
///   if only baseline:
///     resolved = baselineWeeklyAvg
///   if neither:
///     unavailable
///
/// This is demand context, not standards. Standards live in [ActiveTargetProfile].
class DemandForecastContext {
  final String restaurantId;

  /// The business date used as the end of both demand windows.
  final String? anchorBusinessDate;

  // ── 60-day baseline layer ─────────────────────────────────────────────

  /// Sum of covers from all eligible closed shifts in the 60-day window.
  final int? baselineTotalCovers;

  /// Weekly average covers from the 60-day window:
  /// `round(baselineTotalCovers / (60 / 7))`.
  final int? baselineWeeklyAvgCovers;

  /// Number of weeks the 60-day window represents (always 60 / 7 ≈ 8.571).
  final double baselineWeeksRepresented;

  // ── Fixed 3-week recent trend layer ───────────────────────────────────

  /// Sum of covers from all eligible closed shifts in the 21-day window.
  final int? recentThreeWeekTotalCovers;

  /// Weekly average covers from the 21-day window:
  /// `round(recentThreeWeekTotalCovers / 3)`.
  final int? recentThreeWeekWeeklyAvgCovers;

  // ── Explicit trend math ───────────────────────────────────────────────

  /// Delta between recent 3-week weekly avg and 60-day baseline weekly avg.
  /// Positive = trending up. Negative = trending down.
  final int? recentTrendDeltaCovers;

  // ── Resolved rolling weekly forecast covers ───────────────────────────

  /// The final blended weekly forecast covers used by downstream consumers.
  /// Computed via the smoothing rule documented in the class header.
  final int? resolvedWeeklyForecastCovers;

  // ── Provenance ────────────────────────────────────────────────────────

  /// Provenance of the covers value.
  final ForecastDemandSource coversSource;

  /// ISO timestamp when this context was built.
  final String builtAt;

  const DemandForecastContext({
    required this.restaurantId,
    required this.anchorBusinessDate,
    required this.baselineTotalCovers,
    required this.baselineWeeklyAvgCovers,
    required this.baselineWeeksRepresented,
    this.recentThreeWeekTotalCovers,
    this.recentThreeWeekWeeklyAvgCovers,
    this.recentTrendDeltaCovers,
    this.resolvedWeeklyForecastCovers,
    required this.coversSource,
    required this.builtAt,
  });

  // ── Compatibility accessors (transitional — 7.55l.5a) ────────────────
  //
  // These let existing callers continue to compile without broad migration.
  // Consumer migration (7.55l.7) will move callers to the explicit v2 names.

  /// Transitional alias: returns [baselineTotalCovers].
  int? get historicalTotalCovers => baselineTotalCovers;

  /// Transitional alias: returns [resolvedWeeklyForecastCovers].
  ///
  /// In v1 this was the raw 60-day baseline average. In v2 it returns the
  /// resolved rolling weekly forecast that blends baseline + 3-week trend.
  /// Existing callers that read this field now receive the blended demand.
  int? get historicalWeeklyAvgCovers => resolvedWeeklyForecastCovers;

  /// Transitional alias: returns [baselineWeeksRepresented].
  double get weeksRepresented => baselineWeeksRepresented;

  /// Whether this context has usable demand data.
  ///
  /// Available means the resolved weekly forecast covers is non-null.
  /// Zero is valid available demand (real closed-history window with zero
  /// covers). Unavailable means no eligible closed shifts existed.
  bool get isAvailable => resolvedWeeklyForecastCovers != null;

  /// Unavailable sentinel.
  static const unavailable = DemandForecastContext(
    restaurantId: '',
    anchorBusinessDate: null,
    baselineTotalCovers: null,
    baselineWeeklyAvgCovers: null,
    baselineWeeksRepresented: 0,
    coversSource: ForecastDemandSource.unavailable,
    builtAt: '',
  );
}
