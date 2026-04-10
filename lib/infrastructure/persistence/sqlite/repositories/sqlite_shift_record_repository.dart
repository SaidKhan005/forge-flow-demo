import '../../../../domain/repositories/shift_record_repository.dart';
import '../../../../models/shift_record.dart';
import '../dao/shift_record_dao.dart';
import '../sqlite_database.dart';

class SqliteShiftRecordRepository implements ShiftRecordRepository {
  SqliteShiftRecordRepository._();
  static final SqliteShiftRecordRepository instance =
      SqliteShiftRecordRepository._();

  ShiftRecordDao? _dao;

  Future<ShiftRecordDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = ShiftRecordDao(db);
    return _dao!;
  }

  @override
  Future<List<ShiftRecord>> getShiftsForWeek(
      String restaurantId, String weekId) async {
    final dao = await _daoReady;
    return dao.getShiftsForWeek(restaurantId, weekId);
  }

  @override
  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
      String restaurantId, List<String> weekIds) async {
    final dao = await _daoReady;
    return dao.getClosedShiftsForWeeks(restaurantId, weekIds);
  }

  @override
  Future<List<ShiftRecord>> getClosedShiftsInDateRange(
      String restaurantId, String startDate, String endDate) async {
    final dao = await _daoReady;
    return dao.getClosedShiftsInDateRange(restaurantId, startDate, endDate);
  }

  @override
  Future<String?> getLatestClosedBusinessDate(String restaurantId) async {
    final dao = await _daoReady;
    return dao.getLatestClosedBusinessDate(restaurantId);
  }

  @override
  Future<int> replaceShiftForSlot(ShiftRecord record) async {
    final dao = await _daoReady;
    return dao.replaceShiftForSlot(record);
  }
}
