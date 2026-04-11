// Phase 7.55i.2 — Shared SchedulePlan read service.
//
// Centralizes SchedulePlan resolution so Schedule, Shift, Audit, and
// Manager Override preview consume one authority path instead of
// independently calling SchedulePlanResolver.
//
// Inputs:
//   - DemandForecastContext (canonical demand)
//   - ActiveTargetProfile (standards)
//   - ScheduleDistributionWeights (day-level allocation)
//
// Output:
//   - SchedulePlan (immutable weekly plan)
//
// Formulas remain in SchedulePlanResolver. This service only centralizes
// the input tuple.

import '../domain/models/active_target_profile.dart';
import '../domain/models/schedule_distribution_weights.dart';
import '../domain/models/schedule_plan.dart';
import '../domain/services/distribution_weight_builder.dart';
import '../domain/services/schedule_forecast_demand_resolver.dart';
import '../domain/services/schedule_plan_resolver.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_week_record_repository.dart';
import 'demand_forecast_context_service.dart';
import 'wage_standard_context_service.dart';

class SchedulePlanReadService {
  SchedulePlanReadService._();
  static final SchedulePlanReadService instance = SchedulePlanReadService._();

  /// Resolves the current weekly [SchedulePlan] from canonical demand,
  /// active target profile, and data-driven distribution weights.
  ///
  /// Returns null when demand is unavailable or no target profile exists.
  Future<SchedulePlan?> getCurrentWeeklyPlan() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();

    final profile = await _loadProfile(restaurantId);
    final demandCtx =
        await DemandForecastContextService.instance.getCurrentContext();
    final demand = ScheduleForecastDemandResolver.resolveFromContext(
      targetPPA: profile.targetPPA,
      context: demandCtx,
    );

    final weights = await loadDistributionWeights(restaurantId);

    return SchedulePlanResolver.resolve(
      demand: demand,
      profile: profile,
      distributionWeights: weights,
    );
  }

  /// Resolves a preview [SchedulePlan] from explicit target values and the
  /// current canonical demand context.
  ///
  /// Used by Manager Override to show downstream plan impact from draft targets
  /// without committing. Does not include distribution weights — preview is
  /// for weekly-level impact comparison only.
  Future<SchedulePlan?> getPreviewPlanFromTargetValues({
    required double targetCPLH,
    required double targetPPA,
    required double targetSPLH,
    required double fohWage,
    required double bohWage,
  }) async {
    final demandCtx =
        await DemandForecastContextService.instance.getCurrentContext();
    final demand = ScheduleForecastDemandResolver.resolveFromContext(
      targetPPA: targetPPA,
      context: demandCtx,
    );

    if (!demand.isAvailable || demand.forecastCovers == null) return null;

    return SchedulePlanResolver.resolveFromValues(
      forecastCovers: demand.forecastCovers!,
      targetPPA: targetPPA,
      targetCPLH: targetCPLH,
      targetSPLH: targetSPLH,
      fohWage: fohWage,
      bohWage: bohWage,
      coversSource: demand.coversSource,
      salesSource: demand.salesSource,
    );
  }

  /// Resolves a [SchedulePlan] from explicit input values.
  ///
  /// Used by reactive notifiers and synchronous preview paths that already
  /// have target, demand, and weight inputs in scope. Routes through the
  /// same resolver pipeline as [getCurrentWeeklyPlan] without async
  /// repository reads.
  ///
  /// Returns null when demand is unavailable.
  static SchedulePlan? resolveFromInputs({
    required double targetCPLH,
    required double targetPPA,
    required double targetSPLH,
    required double fohWage,
    required double bohWage,
    required int? historicalWeeklyAvgCovers,
    ScheduleDistributionWeights? distributionWeights,
  }) {
    final demand = ScheduleForecastDemandResolver.resolve(
      targetPPA: targetPPA,
      historicalWeeklyAvgCovers: historicalWeeklyAvgCovers,
    );

    if (!demand.isAvailable || demand.forecastCovers == null) return null;

    return SchedulePlanResolver.resolveFromValues(
      forecastCovers: demand.forecastCovers!,
      targetPPA: targetPPA,
      targetCPLH: targetCPLH,
      targetSPLH: targetSPLH,
      fohWage: fohWage,
      bohWage: bohWage,
      coversSource: demand.coversSource,
      salesSource: demand.salesSource,
      distributionWeights: distributionWeights,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Loads the active target profile, bootstrapping with wage authority
  /// if no persisted profile exists.
  Future<ActiveTargetProfile> _loadProfile(String restaurantId) async {
    return WageStandardContextService.instance
        .loadOrBootstrapProfile(restaurantId);
  }

  /// Loads data-driven distribution weights from the most recent 8 completed
  /// weeks of closed shifts. Returns null when no history is available.
  ///
  /// Extracted from [ScheduleDistributionWeightsNotifier.load] so both the
  /// reactive notifier and this service use the same weight-loading logic.
  static Future<ScheduleDistributionWeights?> loadDistributionWeights(
    String restaurantId,
  ) async {
    try {
      final weekHistory = await SqliteWeekRecordRepository.instance
          .getWeekHistory(restaurantId);

      if (weekHistory.isEmpty) return null;

      final recentWeekIds =
          weekHistory.take(8).map((w) => w.weekId).toList();
      final closedShifts = await SqliteShiftRecordRepository.instance
          .getClosedShiftsForWeeks(restaurantId, recentWeekIds);

      return DistributionWeightBuilder.fromClosedShifts(closedShifts);
    } catch (_) {
      return null;
    }
  }
}
