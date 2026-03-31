import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../models/week_record.dart';

class WeekRecordDao {
  final Database _db;
  const WeekRecordDao(this._db);

  Future<List<WeekRecord>> getWeekHistory(String restaurantId) async {
    final rows = await _db.query(
      'week_records',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'week_id DESC',
    );
    return rows.map(WeekRecord.fromMap).toList();
  }

  Future<int> upsertWeekRecord(WeekRecord record) async {
    return _db.insert(
      'week_records',
      record.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
