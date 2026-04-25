// Phase 7.55l.5a — DemandForecastContext v2 builder.
//
//
// Builds rolling demand context from two explicit layers:
//   level 1 = 60-day baseline (inclusive anchor window)
//   level 2 = fixed 3-week recent trend (21-day inclusive anchor window)
//   output  = resolved rolling weekly forecast covers (smoothed blend)
//
// Smoothing rule for resolved weekly forecast covers:
//   if both windows have eligible closed shifts:
//     recentTrendDelta = recentThreeWeekWeeklyAvg - baselineWeeklyAvg
//     resolved = max(0, baselineWeeklyAvg + (recentTrendDelta / 2).round())
//   if only the baseline window has eligible closed shifts:
//     resolved = baselineWeeklyAvg
//   if the baseline window has no eligible closed shifts:
//     unavailable (genuinely no data — not merely zero covers)
//
// Window availability is determined by the presence of eligible closed shifts,
// not by whether cover totals are positive. A window with real closed shifts
// that happen to have zero covers is valid demand data, not missing data.
//
// Phase 7.55m.1: Planning-anchor resolution now delegates to
// BusinessDateAuthorityService. Date arithmetic uses the shared helper.

import 'dart:math' show max;

import '../domain/models/demand_forecast_context.dart';
import '../domain/models/schedule_forecast_demand.dart';
import '../domain/repositories/restaurant_scope_repository.dart';
import '../domain/repositories/shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'business_date_authority_service.dart';

/// Repository-backed service that builds [DemandForecastContext] v2 from
/// eligible closed shifts.
///
/// Anchor precedence:
///   1. Mock replay current business date (when available)
///   2. Latest closed business date (fallback)
///
/// Uses the same anchor rule as [BaselineManagerService].
class DemandForecastContextService {
  DemandForecastContextService._();
  static final DemandForecastContextService instance =
      DemandForecastContextService._();

  final RestaurantScopeRepository _scopeRepo =
      SqliteRestaurantScopeRepository.instance;
  final ShiftRecordRepository _shiftRepo =
      SqliteShiftRecordRepository.instance;

  /// The weeks-represented constant for the 60-day window: 60 / 7 ≈ 8.571.
  static const double _weeksIn60DayWindow = 60 / 7;

  /// The weeks-represented constant for the 21-day window: 3.
  static const double _weeksIn21DayWindow = 3;

  /// Builds the current demand context for the active restaurant.
  ///
  /// Planning-anchor resolution delegates to [BusinessDateAuthorityService].
  Future<DemandForecastContext> getCurrentContext() async {
    final restaurantId = await _scopeRepo.getActiveRestaurantId();

    final anchorDate = await BusinessDateAuthorityService.instance
        .resolvePlanningAnchorDate(restaurantId);

    if (anchorDate == null) {
      return DemandForecastContext(
        restaurantId: restaurantId,
        anchorBusinessDate: null,
        baselineTotalCovers: null,
        baselineWeeklyAvgCovers: null,
        baselineWeeksRepresented: 0,
        coversSource: ForecastDemandSource.unavailable,
        builtAt: DateTime.now().toIso8601String(),
      );
    }

    return getContextForAnchorDate(restaurantId, anchorDate);
  }

  /// Builds demand context for an explicit anchor date and restaurant.
  Future<DemandForecastContext> getContextForAnchorDate(
    String restaurantId,
    String anchorDate,
  ) async {
    // ── Level 1: 60-day baseline ──────────────────────────────────────────
    final baselineStart = subtractDays(anchorDate, 59);
    final closedShifts60 = await _shiftRepo.getClosedShiftsInDateRange(
      restaurantId,
      baselineStart,
      anchorDate,
    );

    // No eligible closed shifts in the 60-day window → truly unavailable.
    // This is genuinely missing data, not merely zero covers.
    if (closedShifts60.isEmpty) {
      return DemandForecastContext(
        restaurantId: restaurantId,
        anchorBusinessDate: anchorDate,
        baselineTotalCovers: null,
        baselineWeeklyAvgCovers: null,
        baselineWeeksRepresented: 0,
        coversSource: ForecastDemandSource.unavailable,
        builtAt: DateTime.now().toIso8601String(),
      );
    }

    final baselineTotal =
        closedShifts60.fold<int>(0, (sum, shift) => sum + shift.covers);
    final baselineWeeklyAvg =
        (baselineTotal / _weeksIn60DayWindow).round();

    // ── Level 2: fixed 3-week recent trend ────────────────────────────────
    final recentStart = subtractDays(anchorDate, 20);
    final closedShifts21 = await _shiftRepo.getClosedShiftsInDateRange(
      restaurantId,
      recentStart,
      anchorDate,
    );

    final recentTotal =
        closedShifts21.fold<int>(0, (sum, shift) => sum + shift.covers);
    final recentWeeklyAvg =
        (recentTotal / _weeksIn21DayWindow).round();

    // ── Resolve rolling weekly forecast covers ────────────────────────────
    int resolvedWeekly;
    int? trendDelta;

    if (closedShifts21.isNotEmpty) {
      // Both windows have eligible closed shifts — apply smoothing rule.
      trendDelta = recentWeeklyAvg - baselineWeeklyAvg;
      resolvedWeekly =
          max(0, baselineWeeklyAvg + (trendDelta / 2).round());
    } else {
      // Only baseline window has eligible closed shifts — use baseline directly.
      resolvedWeekly = baselineWeeklyAvg;
    }

    return DemandForecastContext(
      restaurantId: restaurantId,
      anchorBusinessDate: anchorDate,
      baselineTotalCovers: baselineTotal,
      baselineWeeklyAvgCovers: baselineWeeklyAvg,
      baselineWeeksRepresented: _weeksIn60DayWindow,
      recentThreeWeekTotalCovers:
          closedShifts21.isNotEmpty ? recentTotal : null,
      recentThreeWeekWeeklyAvgCovers:
          closedShifts21.isNotEmpty ? recentWeeklyAvg : null,
      recentTrendDeltaCovers: trendDelta,
      resolvedWeeklyForecastCovers: resolvedWeekly,
      coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      builtAt: DateTime.now().toIso8601String(),
    );
  }

  /// Subtracts [days] from an ISO date string.
  ///
  /// Delegates to [BusinessDateAuthorityService.subtractDays] — the canonical
  /// date-arithmetic helper. Kept as a pass-through so existing callers
  /// (e.g. SchedulePlanReadService) do not need a simultaneous migration.
  static String subtractDays(String isoDate, int days) =>
      BusinessDateAuthorityService.subtractDays(isoDate, days);
}