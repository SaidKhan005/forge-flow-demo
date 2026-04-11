import '../domain/models/demand_forecast_context.dart';
import '../domain/models/schedule_forecast_demand.dart';
import '../domain/repositories/restaurant_scope_repository.dart';
import '../domain/repositories/shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';

/// Repository-backed service that builds [DemandForecastContext] from eligible
/// closed shifts in the rolling 60-calendar-day window.
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

  /// The weeks-represented constant: 60 / 7 ≈ 8.571.
  static const double _weeksInWindow = 60 / 7;

  /// Builds the current demand context for the active restaurant.
  Future<DemandForecastContext> getCurrentContext() async {
    final restaurantId = await _scopeRepo.getActiveRestaurantId();

    // Anchor preference: mock replay date → latest closed date
    final mockDate = await SqliteDatabase.instance
        .getMockReplayBusinessDate(restaurantId);
    final anchorDate =
        mockDate ?? await _shiftRepo.getLatestClosedBusinessDate(restaurantId);

    if (anchorDate == null) {
      return DemandForecastContext(
        restaurantId: restaurantId,
        anchorBusinessDate: null,
        historicalTotalCovers: null,
        historicalWeeklyAvgCovers: null,
        weeksRepresented: 0,
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
    final startDate = _subtractDays(anchorDate, 59);
    final endDate = anchorDate;

    final closedShifts = await _shiftRepo.getClosedShiftsInDateRange(
      restaurantId,
      startDate,
      endDate,
    );

    if (closedShifts.isEmpty) {
      return DemandForecastContext(
        restaurantId: restaurantId,
        anchorBusinessDate: anchorDate,
        historicalTotalCovers: 0,
        historicalWeeklyAvgCovers: 0,
        weeksRepresented: _weeksInWindow,
        coversSource: ForecastDemandSource.unavailable,
        builtAt: DateTime.now().toIso8601String(),
      );
    }

    final totalCovers =
        closedShifts.fold<int>(0, (sum, shift) => sum + shift.covers);
    final weeklyAvg = (totalCovers / _weeksInWindow).round();

    return DemandForecastContext(
      restaurantId: restaurantId,
      anchorBusinessDate: anchorDate,
      historicalTotalCovers: totalCovers,
      historicalWeeklyAvgCovers: weeklyAvg,
      weeksRepresented: _weeksInWindow,
      coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      builtAt: DateTime.now().toIso8601String(),
    );
  }

  /// Subtracts [days] from an ISO date string.
  static String _subtractDays(String isoDate, int days) {
    final parts = isoDate.split('-');
    final dt = DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    final result = dt.subtract(Duration(days: days));
    return '${result.year}-${result.month.toString().padLeft(2, '0')}'
        '-${result.day.toString().padLeft(2, '0')}';
  }
}
