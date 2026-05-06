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

  /// Returns closed shifts whose business_date falls within [startDate, endDate].
  /// Rows with null business_date are excluded naturally by the WHERE clause.
  /// Results ordered by business_date DESC.
  Future<List<ShiftRecord>> getClosedShiftsInDateRange(
      String restaurantId, String startDate, String endDate) async {
    final rows = await _db.rawQuery(
      'SELECT * FROM shift_records '
      "WHERE restaurant_id = ? AND status = 'closed' "
      'AND business_date >= ? AND business_date <= ? '
      'ORDER BY business_date DESC',
      [restaurantId, startDate, endDate],
    );
    return rows.map(ShiftRecord.fromMap).toList();
  }

  /// Returns the latest non-null business_date among closed shifts for this
  /// restaurant, or null if no closed shifts have a business_date.
  Future<String?> getLatestClosedBusinessDate(String restaurantId) async {
    final rows = await _db.rawQuery(
      'SELECT MAX(business_date) AS latest_date FROM shift_records '
      "WHERE restaurant_id = ? AND status = 'closed' "
      'AND business_date IS NOT NULL',
      [restaurantId],
    );
    if (rows.isEmpty) return null;
    return rows.first['latest_date'] as String?;
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

  /// Deletes every `shift_records` row whose `restaurant_id` is NOT
  /// [keepRestaurantId]. Returns the number of rows deleted. Used by
  /// the mobile operational sync runtime when the active operator or
  /// location flips on a shared device, so the prior tenant's mirrored
  /// rows cannot leak through DAO reads that don't filter by scope.
  Future<int> deleteForOtherRestaurants(String keepRestaurantId) async {
    return _db.delete(
      'shift_records',
      where: 'restaurant_id != ?',
      whereArgs: [keepRestaurantId],
    );
  }
}
