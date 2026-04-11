import '../models/demand_forecast_context.dart';
import '../models/schedule_forecast_demand.dart';

/// Resolves a [ScheduleForecastDemand] from POS historical data.
///
/// Architecture:
///   POS (60-day closed shifts) → total covers → ÷ (60/7) → weekly avg covers
///   weekly avg covers × target PPA → forecasted sales
///
/// Covers always come from POS 60-day history.
/// Sales is always derived as covers × target PPA.
/// No vendor-provided forecast inputs. No manager editing.
/// Manager influence is limited to Baseline target profile override.
///
/// Waterfall:
///   1. Historical weekly average covers (POS 60-day context).
///   2. Demo fallback (only when [demoMode] is true).
///   3. Unavailable.
///
/// This resolver is pure — no database, no side effects.
class ScheduleForecastDemandResolver {
  const ScheduleForecastDemandResolver._();

  /// Resolve forecast demand from POS historical context.
  ///
  /// [targetPPA] — from the active target profile; used for sales derivation.
  /// [historicalWeeklyAvgCovers] — from POS 60-day context (total covers ÷ 8.57 weeks).
  /// [demoMode] — true enables [demoFallbackCovers] as last resort.
  /// [demoFallbackCovers] — the demo constant (default 1200).
  static ScheduleForecastDemand resolve({
    required double targetPPA,
    int? historicalWeeklyAvgCovers,
    bool demoMode = false,
    int demoFallbackCovers = 1200,
  }) {
    // ── Case 1: Historical weekly average covers from POS ────────────────
    if (historicalWeeklyAvgCovers != null && historicalWeeklyAvgCovers > 0) {
      final covers = historicalWeeklyAvgCovers;
      final sales = covers * targetPPA;
      return ScheduleForecastDemand(
        forecastSales: sales,
        forecastCovers: covers,
        salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      );
    }

    // ── Case 2: Demo fallback ────────────────────────────────────────────
    if (demoMode) {
      final covers = demoFallbackCovers;
      final sales = covers * targetPPA;
      return ScheduleForecastDemand(
        forecastSales: sales,
        forecastCovers: covers,
        salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
        coversSource: ForecastDemandSource.demoFallback,
      );
    }

    // ── Case 3: Unavailable ──────────────────────────────────────────────
    return ScheduleForecastDemand.unavailable;
  }

  /// Resolve forecast demand from a [DemandForecastContext].
  ///
  /// Delegates to [resolve] using the context's weekly average covers.
  /// Keeps the resolver pure — context building is the service's concern.
  static ScheduleForecastDemand resolveFromContext({
    required double targetPPA,
    required DemandForecastContext context,
    bool demoMode = false,
    int demoFallbackCovers = 1200,
  }) {
    return resolve(
      targetPPA: targetPPA,
      historicalWeeklyAvgCovers: context.historicalWeeklyAvgCovers,
      demoMode: demoMode,
      demoFallbackCovers: demoFallbackCovers,
    );
  }
}
