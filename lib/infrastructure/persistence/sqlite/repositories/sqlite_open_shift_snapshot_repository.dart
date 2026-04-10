import '../../../../domain/models/open_shift_snapshot.dart';
import '../../../../domain/repositories/open_shift_snapshot_repository.dart';
import '../dao/open_shift_snapshot_dao.dart';
import '../sqlite_database.dart';

class SqliteOpenShiftSnapshotRepository
    implements OpenShiftSnapshotRepository {
  SqliteOpenShiftSnapshotRepository._();
  static final SqliteOpenShiftSnapshotRepository instance =
      SqliteOpenShiftSnapshotRepository._();

  OpenShiftSnapshotDao? _dao;

  Future<OpenShiftSnapshotDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = OpenShiftSnapshotDao(db);
    return _dao!;
  }

  @override
  Future<List<OpenShiftSnapshot>> getOpenShiftsForWeek(
      String restaurantId, String weekId) async {
    final dao = await _daoReady;
    return dao.getOpenShiftsForWeek(restaurantId, weekId);
  }

  @override
  Future<OpenShiftSnapshot?> getCurrentOpenShift(String restaurantId) async {
    final dao = await _daoReady;
    return dao.getCurrentOpenShift(restaurantId);
  }

  @override
  Future<String?> getCurrentBusinessDate(String restaurantId) async {
    final dao = await _daoReady;
    return dao.getCurrentBusinessDate(restaurantId);
  }

  @override
  Future<List<OpenShiftSnapshot>> getSnapshotsForDay(
      String restaurantId, String businessDate) async {
    final dao = await _daoReady;
    return dao.getSnapshotsForDay(restaurantId, businessDate);
  }

  @override
  Future<void> replaceOpenShiftSnapshot(OpenShiftSnapshot snapshot) async {
    final dao = await _daoReady;
    return dao.replaceOpenShiftSnapshot(snapshot);
  }

  @override
  Future<String?> getLatestOpenWeekId(String restaurantId) async {
    final dao = await _daoReady;
    return dao.getLatestOpenWeekId(restaurantId);
  }

  @override
  Future<void> replaceOpenShiftSnapshotsForWeek(
      String restaurantId, String weekId,
      List<OpenShiftSnapshot> snapshots) async {
    final dao = await _daoReady;
    return dao.replaceOpenShiftSnapshotsForWeek(restaurantId, weekId, snapshots);
  }
}
