import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/weekly_plan_snapshot.dart';

class WeeklyPlanSnapshotDao {
  final Database _db;
  const WeeklyPlanSnapshotDao(this._db);

  /// Returns the snapshot in force for [businessDate], or null.
  ///
  /// Finds the snapshot where weekStartDate <= businessDate <= weekEndDate.
  Future<WeeklyPlanSnapshot?> getSnapshotForBusinessDate(
    String restaurantId,
    String businessDate,
  ) async {
    final rows = await _db.query(
      'weekly_plan_snapshots',
      where: 'restaurant_id = ? AND week_start_date <= ? AND week_end_date >= ?',
      whereArgs: [restaurantId, businessDate, businessDate],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Returns the snapshot matching [weekKey], or null.
  Future<WeeklyPlanSnapshot?> getSnapshotForWeekKey(
    String restaurantId,
    String weekKey,
  ) async {
    final rows = await _db.query(
      'weekly_plan_snapshots',
      where: 'restaurant_id = ? AND week_key = ?',
      whereArgs: [restaurantId, weekKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Inserts or replaces a snapshot.
  Future<void> upsertSnapshot(WeeklyPlanSnapshot snapshot) async {
    final map = snapshot.toMap();
    final dayRows = map.remove('day_rows') as List<dynamic>;
    map['day_rows_json'] = jsonEncode(dayRows);
    await _db.insert(
      'weekly_plan_snapshots',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Converts a database row back to a [WeeklyPlanSnapshot].
  WeeklyPlanSnapshot _fromRow(Map<String, dynamic> row) {
    final map = Map<String, dynamic>.from(row);
    final dayRowsJson = map.remove('day_rows_json') as String;
    map['day_rows'] = jsonDecode(dayRowsJson) as List<dynamic>;
    return WeeklyPlanSnapshot.fromMap(map);
  }
}
