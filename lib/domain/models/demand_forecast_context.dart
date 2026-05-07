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

  Map<String, dynamic> toMap() => <String, dynamic>{
    'restaurant_id': restaurantId,
    'anchor_business_date': anchorBusinessDate,
    'baseline_total_covers': baselineTotalCovers,
    'baseline_weekly_avg_covers': baselineWeeklyAvgCovers,
    'baseline_weeks_represented': baselineWeeksRepresented,
    'recent_three_week_total_covers': recentThreeWeekTotalCovers,
    'recent_three_week_weekly_avg_covers': recentThreeWeekWeeklyAvgCovers,
    'recent_trend_delta_covers': recentTrendDeltaCovers,
    'resolved_weekly_forecast_covers': resolvedWeeklyForecastCovers,
    'covers_source': coversSource.name,
    'built_at': builtAt,
  };

  factory DemandForecastContext.fromMap(Map<String, dynamic> map) {
    return DemandForecastContext(
      restaurantId:
          _readString(map['restaurant_id']) ??
          _readString(map['location_id']) ??
          '',
      anchorBusinessDate:
          _readDateString(map['anchor_business_date']) ??
          _readDateString(map['business_date']) ??
          _readDateString(map['week_start_date']),
      baselineTotalCovers:
          _readInt(map['baseline_total_covers']) ??
          _readInt(map['sixty_day_total_covers']) ??
          _readInt(map['historical_total_covers']),
      baselineWeeklyAvgCovers:
          _readInt(map['baseline_weekly_avg_covers']) ??
          _readInt(map['baseline_weekly_average_covers']) ??
          _readInt(map['sixty_day_weekly_average_covers']),
      baselineWeeksRepresented:
          _readDouble(map['baseline_weeks_represented']) ?? 0,
      recentThreeWeekTotalCovers:
          _readInt(map['recent_three_week_total_covers']) ??
          _readInt(map['recent_21_day_total_covers']),
      recentThreeWeekWeeklyAvgCovers:
          _readInt(map['recent_three_week_weekly_avg_covers']) ??
          _readInt(map['recent_21_day_weekly_average_covers']),
      recentTrendDeltaCovers: _readInt(map['recent_trend_delta_covers']),
      resolvedWeeklyForecastCovers:
          _readInt(map['resolved_weekly_forecast_covers']) ??
          _readInt(map['weekly_forecast_covers']) ??
          _readInt(map['forecast_covers']),
      coversSource: _readForecastDemandSource(
        map['covers_source'],
        fallback: ForecastDemandSource.appDerivedFromHistoricalAverage,
      ),
      builtAt:
          _readIsoString(map['built_at']) ??
          _readIsoString(map['generated_at']) ??
          _readIsoString(map['updated_at']) ??
          '',
    );
  }

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

ForecastDemandSource _readForecastDemandSource(
  Object? value, {
  required ForecastDemandSource fallback,
}) {
  final raw = _readString(value);
  if (raw == null) return fallback;
  for (final source in ForecastDemandSource.values) {
    if (source.name == raw) return source;
  }
  return switch (raw.toLowerCase()) {
    'historical_average' ||
    'app_derived_from_historical_average' ||
    'sixty_day_average' => ForecastDemandSource.appDerivedFromHistoricalAverage,
    'covers_and_ppa' || 'app_derived_from_covers_and_ppa' =>
      ForecastDemandSource.appDerivedFromCoversAndPpa,
    'reservation_walk_in' || 'reservation_and_walk_in' =>
      ForecastDemandSource.appDerivedFromReservationAndWalkInModel,
    'demo' || 'demo_fallback' => ForecastDemandSource.demoFallback,
    'unavailable' => ForecastDemandSource.unavailable,
    _ => fallback,
  };
}

String? _readString(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return value.toString();
}

String? _readDateString(Object? value) {
  if (value == null) return null;
  if (value is DateTime) {
    return value.toUtc().toIso8601String().substring(0, 10);
  }
  final raw = _readString(value);
  if (raw == null) return null;
  return raw.length >= 10 ? raw.substring(0, 10) : raw;
}

String? _readIsoString(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc().toIso8601String();
  return _readString(value);
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _readDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
