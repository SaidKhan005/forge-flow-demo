import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/open_shift_snapshot.dart';

class OpenShiftSnapshotDao {
  final Database _db;
  const OpenShiftSnapshotDao(this._db);

  Future<List<OpenShiftSnapshot>> getOpenShiftsForWeek(
      String restaurantId, String weekId) async {
    final rows = await _db.query(
      'open_shift_snapshots',
      where: 'restaurant_id = ? AND week_id = ?',
      whereArgs: [restaurantId, weekId],
    );
    return rows.map(OpenShiftSnapshot.fromMap).toList();
  }

  Future<OpenShiftSnapshot?> getCurrentOpenShift(String restaurantId) async {
    final rows = await _db.query(
      'open_shift_snapshots',
      where: "restaurant_id = ? AND status = 'open'",
      whereArgs: [restaurantId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return OpenShiftSnapshot.fromMap(rows.first);
  }

  Future<String?> getCurrentBusinessDate(String restaurantId) async {
    final rows = await _db.query(
      'open_shift_snapshots',
      columns: ['business_date'],
      where: "restaurant_id = ? AND status = 'open'",
      whereArgs: [restaurantId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['business_date'] as String;
  }

  Future<List<OpenShiftSnapshot>> getSnapshotsForDay(
      String restaurantId, String businessDate) async {
    final rows = await _db.query(
      'open_shift_snapshots',
      where: 'restaurant_id = ? AND business_date = ?',
      whereArgs: [restaurantId, businessDate],
    );
    return rows.map(OpenShiftSnapshot.fromMap).toList();
  }

  Future<void> replaceOpenShiftSnapshot(OpenShiftSnapshot snapshot) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'open_shift_snapshots',
        where:
            'restaurant_id = ? AND week_id = ? AND day_label = ? AND daypart = ?',
        whereArgs: [
          snapshot.restaurantId,
          snapshot.weekId,
          snapshot.dayLabel,
          snapshot.daypart,
        ],
      );
      await txn.insert('open_shift_snapshots', snapshot.toMap());
    });
  }

  Future<String?> getLatestOpenWeekId(String restaurantId) async {
    final rows = await _db.query(
      'open_shift_snapshots',
      columns: ['week_id'],
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'updated_at DESC, week_id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['week_id'] as String;
  }

  Future<void> replaceOpenShiftSnapshotsForWeek(
      String restaurantId, String weekId,
      List<OpenShiftSnapshot> snapshots) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'open_shift_snapshots',
        where: 'restaurant_id = ? AND week_id = ?',
        whereArgs: [restaurantId, weekId],
      );
      for (final s in snapshots) {
        await txn.insert('open_shift_snapshots', s.toMap());
      }
    });
  }
}
