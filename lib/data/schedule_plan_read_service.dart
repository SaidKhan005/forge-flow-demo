// Phase 7.55i.2 + 7.55l.5d + 7.55l.7a — Shared SchedulePlan read service.
//
// Centralizes SchedulePlan resolution so Schedule, Shift, Audit, and
// Manager Override preview consume one authority path instead of
// independently calling SchedulePlanResolver.
//
// Two read paths:
//   - getCurrentWeeklyPlan(): live-resolved from demand + profile + weights
//     (used by generation bridge and Schedule Builder preview)
//   - getCurrentLockedWeeklyPlan(): projected from the locked
//     WeeklyPlanSnapshot (used by Shift, Audit, and other downstream
//     readers that should consume locked weekly truth)
//
// Formulas remain in SchedulePlanResolver. This service only centralizes
// the input tuple.
//
// 7.55l.5d: loadDistributionWeights now uses business-date-anchored windows
// (60-day baseline + 21-day recent) with day-of-week smoothing instead of
// the old 8-weekId approximation.
//
// 7.55l.7a: added getCurrentLockedWeeklyPlan() for downstream consumers
// that should read from the locked weekly snapshot instead of live-resolving.
//
// 7.55m.1: Planning-anchor resolution in loadDistributionWeights now
// delegates to BusinessDateAuthorityService.

import '../domain/models/active_target_profile.dart';
import '../domain/models/schedule_distribution_weights.dart';
import '../domain/models/schedule_plan.dart';
import '../domain/services/distribution_weight_builder.dart';
import '../domain/services/schedule_forecast_demand_resolver.dart';
import '../domain/services/schedule_plan_resolver.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../domain/services/weekly_plan_snapshot_schedule_plan_projector.dart';
import 'business_date_authority_service.dart';
import 'demand_forecast_context_service.dart';
import 'wage_standard_context_service.dart';
import 'weekly_plan_snapshot_service.dart';

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

  /// Returns the current-week [SchedulePlan] projected from the locked
  /// [WeeklyPlanSnapshot].
  ///
  /// Uses [WeeklyPlanSnapshotService] to load (or auto-generate) the
  /// current-week snapshot, then projects it to [SchedulePlan] shape.
  ///
  /// Returns null when no current-week snapshot can be determined.
  ///
  /// This path is for downstream readers (Shift, Audit) that should
  /// consume locked weekly truth. It does NOT create a recursion path:
  /// [WeeklyPlanSnapshotService] auto-generates from [getCurrentWeeklyPlan]
  /// (the live path), which never calls back here.
  Future<SchedulePlan?> getCurrentLockedWeeklyPlan() async {
    final snapshot =
        await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
    if (snapshot == null) return null;
    return WeeklyPlanSnapshotSchedulePlanProjector.project(snapshot);
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

  /// Loads data-driven distribution weights using business-date-anchored
  /// windows with day-of-week smoothing.
  ///
  /// Planning-anchor resolution delegates to [BusinessDateAuthorityService].
  /// Windows: 60-day baseline + 21-day recent trend.
  ///
  /// Returns null when no anchor date or no closed shift history exists.
  static Future<ScheduleDistributionWeights?> loadDistributionWeights(
    String restaurantId,
  ) async {
    try {
      final anchorDate = await BusinessDateAuthorityService.instance
          .resolvePlanningAnchorDate(restaurantId);

      if (anchorDate == null) return null;

      // 60-day baseline window (inclusive).
      final baselineStart = DemandForecastContextService.subtractDays(
          anchorDate, 59);
      final baselineShifts = await SqliteShiftRecordRepository.instance
          .getClosedShiftsInDateRange(
              restaurantId, baselineStart, anchorDate);

      // 21-day recent window (inclusive).
      final recentStart = DemandForecastContextService.subtractDays(
          anchorDate, 20);
      final recentShifts = await SqliteShiftRecordRepository.instance
          .getClosedShiftsInDateRange(
              restaurantId, recentStart, anchorDate);

      return DistributionWeightBuilder.fromDateWindowShifts(
        baselineShifts: baselineShifts,
        recentShifts: recentShifts,
      );
    } catch (_) {
      return null;
    }
  }
}
