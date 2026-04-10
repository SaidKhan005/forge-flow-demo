import '../../services/labor_model.dart';
import '../models/active_target_profile.dart';
import '../models/schedule_distribution_weights.dart';
import '../models/schedule_forecast_demand.dart';
import '../models/schedule_plan.dart';

/// Builds a [SchedulePlan] from [ScheduleForecastDemand] and [ActiveTargetProfile].
///
/// This is the single place where demand forecast and target standards are
/// combined into planning math. Schedule, Shift, and Manager Override preview
/// should all consume the result rather than recalculating locally.
///
/// Pure — no database, no side effects.
class SchedulePlanResolver {
  const SchedulePlanResolver._();

  /// Default day-of-week cover distribution weights.
  /// Proportional covers per day — used to split weekly forecast into daily.
  static const _defaultDayWeights = [
    ('Mon', 140),
    ('Tue', 150),
    ('Wed', 160),
    ('Thu', 190),
    ('Fri', 220),
    ('Sat', 230),
    ('Sun', 110),
  ];

  /// Build a weekly [SchedulePlan] from resolved demand and active targets.
  ///
  /// Returns null when demand is unavailable.
  ///
  /// Forecast sales are always computed as `demand.forecastCovers * profile.targetPPA`
  /// to prevent stale sales when target PPA changes (e.g. Manager Override).
  static SchedulePlan? resolve({
    required ScheduleForecastDemand demand,
    required ActiveTargetProfile profile,
    ScheduleDistributionWeights? distributionWeights,
  }) {
    if (!demand.isAvailable || demand.forecastCovers == null) {
      return null;
    }

    final covers = demand.forecastCovers!;
    return resolveFromValues(
      forecastCovers: covers,
      targetPPA: profile.targetPPA,
      targetCPLH: profile.targetCPLH,
      targetSPLH: profile.targetSPLH,
      fohWage: profile.fohWage,
      bohWage: profile.bohWage,
      coversSource: demand.coversSource,
      salesSource: demand.salesSource,
      distributionWeights: distributionWeights,
    );
  }

  /// Convenience entry point when full domain objects are not available.
  ///
  /// Constructs the intermediate [ScheduleForecastDemand] internally.
  /// Sales is always derived as [forecastCovers] * [targetPPA].
  static SchedulePlan resolveFromValues({
    required int forecastCovers,
    required double targetPPA,
    required double targetCPLH,
    required double targetSPLH,
    required double fohWage,
    required double bohWage,
    required ForecastDemandSource coversSource,
    ForecastDemandSource salesSource =
        ForecastDemandSource.appDerivedFromCoversAndPpa,
    ScheduleDistributionWeights? distributionWeights,
  }) {
    final sales = forecastCovers * targetPPA;
    final fohHours = LaborModel.modelFohHours(forecastCovers, targetCPLH);
    final bohHours = LaborModel.modelBohHoursFromSales(sales, targetSPLH);
    final fohDollars = fohHours * fohWage;
    final bohDollars = bohHours * bohWage;
    final totalDollars = fohDollars + bohDollars;
    final totalHours = fohHours + bohHours;
    final laborPct = sales > 0 ? totalDollars / sales * 100 : 0.0;
    final blendedWage = totalHours > 0 ? totalDollars / totalHours : 0.0;

    return SchedulePlan(
      forecastCovers: forecastCovers,
      forecastSales: sales,
      requiredFohHours: fohHours,
      requiredBohHours: bohHours,
      theoreticalFohLaborDollars: fohDollars,
      theoreticalBohLaborDollars: bohDollars,
      theoreticalLaborPct: laborPct,
      targetBlendedWage: blendedWage,
      coversSource: coversSource,
      salesSource: salesSource,
      dayPlans: _buildDayPlans(
        forecastCovers, targetPPA, fohHours, bohHours,
        distributionWeights,
      ),
    );
  }

  /// Resolves the day-of-week weight list to use for allocation.
  ///
  /// Uses data-driven [distributionWeights] when available and containing at
  /// least one positive weight. Falls back to [_defaultDayWeights] otherwise.
  static List<(String, int)> _resolveDayWeights(
    ScheduleDistributionWeights? distributionWeights,
  ) {
    if (distributionWeights != null && distributionWeights.isAvailable) {
      final ordered = distributionWeights.orderedDayWeights;
      final hasPositive = ordered.any((e) => e.$2 > 0);
      if (hasPositive) return ordered;
    }
    return _defaultDayWeights;
  }

  /// Distributes weekly covers, FOH hours, and BOH hours across days using
  /// data-driven or default day-of-week weights and largest-remainder allocation.
  ///
  /// Guarantees:
  ///   sum(dayPlans.forecastCovers)    == weeklyCovers
  ///   sum(dayPlans.requiredFohHours)  == weeklyFohHours
  ///   sum(dayPlans.requiredBohHours)  == weeklyBohHours
  static List<ScheduleDayPlan> _buildDayPlans(
    int weeklyCovers,
    double targetPPA,
    int weeklyFohHours,
    int weeklyBohHours,
    ScheduleDistributionWeights? distributionWeights,
  ) {
    final dayWeights = _resolveDayWeights(distributionWeights);
    final totalWeight = dayWeights.fold<int>(0, (s, e) => s + e.$2);
    final weights = dayWeights.map((e) => e.$2).toList();

    // Allocate covers by day weight.
    final dayCovers = _allocate(weeklyCovers, weights, totalWeight);

    // Day sales = day covers × targetPPA (exact per day, not allocated).
    final daySales = dayCovers.map((c) => c * targetPPA).toList();

    // Allocate FOH hours proportional to day covers.
    final dayFoh = _allocate(weeklyFohHours, dayCovers,
        dayCovers.fold<int>(0, (s, v) => s + v));

    // Allocate BOH hours proportional to day sales.
    final dayBoh = _allocateByDouble(weeklyBohHours, daySales);

    return List.unmodifiable(List.generate(dayWeights.length, (i) {
      return ScheduleDayPlan(
        day: dayWeights[i].$1,
        forecastCovers: dayCovers[i],
        forecastSales: daySales[i],
        requiredFohHours: dayFoh[i],
        requiredBohHours: dayBoh[i],
      );
    }));
  }

  /// Largest-remainder allocation of [total] across integer [weights].
  static List<int> _allocate(int total, List<int> weights, int weightSum) {
    if (weightSum == 0) return List.filled(weights.length, 0);
    final fractional = weights.map((w) => total * w / weightSum).toList();
    return _largestRemainder(total, fractional);
  }

  /// Largest-remainder allocation of [total] across double [shares].
  /// Shares are used as proportional weights (not required to sum to total).
  static List<int> _allocateByDouble(int total, List<double> shares) {
    final shareSum = shares.fold<double>(0, (s, v) => s + v);
    if (shareSum == 0) return List.filled(shares.length, 0);
    final fractional = shares.map((s) => total * s / shareSum).toList();
    return _largestRemainder(total, fractional);
  }

  /// Core largest-remainder: floor each fractional value, then distribute
  /// the remaining units to the slots with the largest fractional parts.
  static List<int> _largestRemainder(int total, List<double> fractional) {
    final floors = fractional.map((f) => f.floor()).toList();
    var remainder = total - floors.fold<int>(0, (s, v) => s + v);
    final remainders = List.generate(
        fractional.length, (i) => (i, fractional[i] - floors[i]));
    remainders.sort((a, b) => b.$2.compareTo(a.$2));
    for (final entry in remainders) {
      if (remainder <= 0) break;
      floors[entry.$1] += 1;
      remainder -= 1;
    }
    return floors;
  }
}
