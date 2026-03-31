import '../../../../domain/repositories/week_record_repository.dart';
import '../../../../models/week_record.dart';
import '../dao/week_record_dao.dart';
import '../sqlite_database.dart';

class SqliteWeekRecordRepository implements WeekRecordRepository {
  SqliteWeekRecordRepository._();
  static final SqliteWeekRecordRepository instance =
      SqliteWeekRecordRepository._();

  WeekRecordDao? _dao;

  Future<WeekRecordDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = WeekRecordDao(db);
    return _dao!;
  }

  @override
  Future<List<WeekRecord>> getWeekHistory(String restaurantId) async {
    final dao = await _daoReady;
    return dao.getWeekHistory(restaurantId);
  }

  @override
  Future<int> upsertWeekRecord(WeekRecord record) async {
    final dao = await _daoReady;
    return dao.upsertWeekRecord(record);
  }
}
