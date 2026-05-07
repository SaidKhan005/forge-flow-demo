import '../../../../domain/models/weekly_plan_snapshot.dart';
import '../../../../domain/models/demand_forecast_context.dart';
import '../../../../domain/repositories/weekly_plan_snapshot_repository.dart';
import '../dao/weekly_plan_snapshot_dao.dart';
import '../sqlite_database.dart';

class SqliteWeeklyPlanSnapshotRepository
    implements WeeklyPlanSnapshotRepository {
  SqliteWeeklyPlanSnapshotRepository._();
  static final SqliteWeeklyPlanSnapshotRepository instance =
      SqliteWeeklyPlanSnapshotRepository._();

  WeeklyPlanSnapshotDao? _dao;

  Future<WeeklyPlanSnapshotDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = WeeklyPlanSnapshotDao(db);
    return _dao!;
  }

  @override
  Future<WeeklyPlanSnapshot?> getSnapshotForBusinessDate(
    String restaurantId,
    String businessDate,
  ) async {
    final dao = await _daoReady;
    return dao.getSnapshotForBusinessDate(restaurantId, businessDate);
  }

  @override
  Future<WeeklyPlanSnapshot?> getSnapshotForWeekKey(
    String restaurantId,
    String weekKey,
  ) async {
    final dao = await _daoReady;
    return dao.getSnapshotForWeekKey(restaurantId, weekKey);
  }

  @override
  Future<void> upsertSnapshot(WeeklyPlanSnapshot snapshot) async {
    final dao = await _daoReady;
    return dao.upsertSnapshot(snapshot);
  }

  @override
  Future<int> attachForecastContext({
    required String restaurantId,
    required DemandForecastContext context,
    String? forecastContextId,
    String? weekStartDate,
    String? weekEndDate,
  }) async {
    final dao = await _daoReady;
    return dao.attachForecastContext(
      restaurantId: restaurantId,
      context: context,
      forecastContextId: forecastContextId,
      weekStartDate: weekStartDate,
      weekEndDate: weekEndDate,
    );
  }

  @override
  Future<DemandForecastContext?> getForecastContextForBusinessDate(
    String restaurantId,
    String businessDate,
  ) async {
    final dao = await _daoReady;
    return dao.getForecastContextForBusinessDate(restaurantId, businessDate);
  }

  @override
  Future<DemandForecastContext?> getForecastContextForWeekKey(
    String restaurantId,
    String weekKey,
  ) async {
    final dao = await _daoReady;
    return dao.getForecastContextForWeekKey(restaurantId, weekKey);
  }

  @override
  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    final dao = await _daoReady;
    return dao.wipeForOtherScopes(keepRestaurantId);
  }
}
