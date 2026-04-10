/// Forecast demand source provenance.
///
/// Tracks where forecast covers originated. Sales is always derived
/// from covers × target PPA — it is never an independent source.
enum ForecastDemandSource {
  /// App derived from POS 60-day historical weekly average covers.
  /// This is the primary and expected production source.
  appDerivedFromHistoricalAverage,

  /// App derived: covers existed, sales = covers * targetPPA.
  appDerivedFromCoversAndPpa,

  /// App derived: reservation book + walk-in model (Phase 8R).
  appDerivedFromReservationAndWalkInModel,

  /// Demo fallback — hardcoded constant used only when no other source exists
  /// and demoMode is true.
  demoFallback,

  /// No forecast source available.
  unavailable,
}

/// Resolved forecast demand for the Schedule screen.
///
/// Immutable value object carrying resolved weekly forecast sales and covers
/// along with provenance for each. The resolver produces this; the Schedule
/// notifier consumes it.
///
/// Architecture:
///   POS (60-day closed shifts) → total covers → ÷ (60/7) → weekly avg covers
///   weekly avg covers × target PPA → forecasted sales (always derived)
class ScheduleForecastDemand {
  final double? forecastSales;
  final int? forecastCovers;
  final ForecastDemandSource salesSource;
  final ForecastDemandSource coversSource;

  /// True when at least one of forecastSales or forecastCovers is available.
  bool get isAvailable =>
      salesSource != ForecastDemandSource.unavailable ||
      coversSource != ForecastDemandSource.unavailable;

  const ScheduleForecastDemand({
    required this.forecastSales,
    required this.forecastCovers,
    required this.salesSource,
    required this.coversSource,
  });

  /// Unavailable sentinel.
  static const unavailable = ScheduleForecastDemand(
    forecastSales: null,
    forecastCovers: null,
    salesSource: ForecastDemandSource.unavailable,
    coversSource: ForecastDemandSource.unavailable,
  );

  /// Human-readable label for the primary covers source.
  String get coversSourceLabel {
    switch (coversSource) {
      case ForecastDemandSource.appDerivedFromHistoricalAverage:
        return '60-day weekly average';
      case ForecastDemandSource.appDerivedFromCoversAndPpa:
        return 'Derived from covers';
      case ForecastDemandSource.appDerivedFromReservationAndWalkInModel:
        return 'Reservation + walk-in model';
      case ForecastDemandSource.demoFallback:
        return 'Demo fallback';
      case ForecastDemandSource.unavailable:
        return 'Unavailable';
    }
  }
}
