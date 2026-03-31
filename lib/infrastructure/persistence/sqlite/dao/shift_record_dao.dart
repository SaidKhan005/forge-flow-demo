import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../models/shift_record.dart';

class ShiftRecordDao {
  final Database _db;
  const ShiftRecordDao(this._db);

  Future<List<ShiftRecord>> getShiftsForWeek(
      String restaurantId, String weekId) async {
    final rows = await _db.query(
      'shift_records',
      where: 'restaurant_id = ? AND week_id = ?',
      whereArgs: [restaurantId, weekId],
    );
    return rows.map(ShiftRecord.fromMap).toList();
  }

  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
      String restaurantId, List<String> weekIds) async {
    if (weekIds.isEmpty) return [];
    final placeholders = weekIds.map((_) => '?').join(', ');
    final rows = await _db.rawQuery(
      'SELECT * FROM shift_records '
      "WHERE restaurant_id = ? AND status = 'closed' "
      'AND week_id IN ($placeholders) '
      'ORDER BY week_id DESC',
      [restaurantId, ...weekIds],
    );
    return rows.map(ShiftRecord.fromMap).toList();
  }

  Future<int> replaceShiftForSlot(ShiftRecord record) async {
    return _db.transaction<int>((txn) async {
      await txn.delete(
        'shift_records',
        where:
            'restaurant_id = ? AND week_id = ? AND day_label = ? AND daypart = ?',
        whereArgs: [
          record.restaurantId,
          record.weekId,
          record.dayLabel,
          record.daypart,
        ],
      );
      return txn.insert('shift_records', record.toMap()..remove('id'));
    });
  }
}
