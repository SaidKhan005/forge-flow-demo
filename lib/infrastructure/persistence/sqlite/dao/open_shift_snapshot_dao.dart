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

  /// Returns the most recent `business_date` (ISO `YYYY-MM-DD`, so
  /// lexicographic ordering is chronological) that has ANY snapshot row
  /// for [restaurantId], regardless of `status`. Used by the
  /// closed-state Shift dashboard to bind the last completed business
  /// day's already-persisted final values when no `status='open'` shift
  /// exists. Read-only — no recompute, no write. Null when the operator
  /// has no shift history at all (brand-new operator → simple empty
  /// state).
  Future<String?> getMostRecentBusinessDate(String restaurantId) async {
    final rows = await _db.query(
      'open_shift_snapshots',
      columns: ['business_date'],
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'business_date DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['business_date'] as String;
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

  /// Deletes every `open_shift_snapshots` row whose `restaurant_id` is
  /// NOT [keepRestaurantId]. Returns the number of rows deleted. Used
  /// by the mobile operational sync runtime when the active operator
  /// or location flips on a shared device, so the prior tenant's
  /// mirrored snapshots cannot leak through DAO reads that don't
  /// filter by scope.
  Future<int> deleteForOtherRestaurants(String keepRestaurantId) async {
    return _db.delete(
      'open_shift_snapshots',
      where: 'restaurant_id != ?',
      whereArgs: [keepRestaurantId],
    );
  }

  /// Deletes every `open_shift_snapshots` row whose `restaurant_id` is
  /// NOT in [keepRestaurantIds]. The set-preserving sibling of
  /// [deleteForOtherRestaurants]; the demo bootstrap source-swap
  /// (`demoScopePreservingCrossTenantWipe`) passes the demo operator's
  /// full `DemoScope.locations` set so a demo location switch keeps
  /// every demo location's snapshots while a genuinely-foreign tenant
  /// is still purged. Production keeps using the single-keep method
  /// byte-unchanged. No-ops on an empty keep set (NOT IN () is invalid
  /// SQL and would otherwise delete everything).
  Future<int> deleteForRestaurantsNotIn(Set<String> keepRestaurantIds) async {
    if (keepRestaurantIds.isEmpty) return 0;
    final keep = keepRestaurantIds.toList(growable: false);
    final placeholders = List.filled(keep.length, '?').join(', ');
    return _db.delete(
      'open_shift_snapshots',
      where: 'restaurant_id NOT IN ($placeholders)',
      whereArgs: keep,
    );
  }
}
