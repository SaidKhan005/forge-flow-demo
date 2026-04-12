import '../../../../domain/models/weekly_plan_snapshot.dart';
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
}
