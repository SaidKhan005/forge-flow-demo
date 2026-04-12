import '../models/demand_forecast_context.dart';
import '../models/schedule_forecast_demand.dart';

/// Resolves a [ScheduleForecastDemand] from demand context.
///
/// Architecture (v2):
///   POS closed shifts → 60-day baseline + 3-week recent trend
///   → smoothed resolved weekly forecast covers
///   → covers × target PPA → forecasted sales
///
/// Covers come from the rolling v2 demand context.
/// Sales is always derived as covers × target PPA.
/// No vendor-provided forecast inputs. No manager editing.
/// Manager influence is limited to Baseline target profile override.
///
/// Waterfall:
///   1. Resolved rolling weekly forecast covers (v2 demand context).
///   2. Historical weekly average covers (direct input, compatibility).
///   3. Demo fallback (only when [demoMode] is true).
///   4. Unavailable.
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
    // Zero is valid available demand (real closed-history with zero covers).
    // Only null means missing data.
    if (historicalWeeklyAvgCovers != null) {
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
  /// Uses the context's resolved rolling weekly forecast covers (v2).
  /// Keeps the resolver pure — context building is the service's concern.
  static ScheduleForecastDemand resolveFromContext({
    required double targetPPA,
    required DemandForecastContext context,
    bool demoMode = false,
    int demoFallbackCovers = 1200,
  }) {
    return resolve(
      targetPPA: targetPPA,
      historicalWeeklyAvgCovers: context.resolvedWeeklyForecastCovers,
      demoMode: demoMode,
      demoFallbackCovers: demoFallbackCovers,
    );
  }
}
