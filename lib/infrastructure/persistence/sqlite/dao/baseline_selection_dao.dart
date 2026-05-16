import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class BaselineSelectionDao {
  final Database _db;
  const BaselineSelectionDao(this._db);

  Future<Set<String>> getSelectedRecordKeys(String restaurantId) async {
    final rows = await _db.query(
      'baseline_selected_records',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
    );
    return rows.map((r) => r['record_key'] as String).toSet();
  }

  Future<void> replaceSelectedRecordKeys(
    String restaurantId,
    Set<String> keys,
  ) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'baseline_selected_records',
        where: 'restaurant_id = ?',
        whereArgs: [restaurantId],
      );
      for (final key in keys) {
        await txn.insert('baseline_selected_records', {
          'restaurant_id': restaurantId,
          'record_key': key,
        });
      }
    });
  }

  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    await _db.delete(
      'baseline_selected_records',
      where: 'restaurant_id != ?',
      whereArgs: [keepRestaurantId],
    );
  }

  /// Deletes every `baseline_selected_records` row whose `restaurant_id`
  /// is NOT in [keepRestaurantIds]. The set-preserving sibling of
  /// [wipeForOtherScopes]; the demo bootstrap source-swap
  /// (`demoScopePreservingCrossTenantWipe`) passes the demo operator's
  /// full `DemoScope.locations` set so a demo location switch keeps
  /// every demo location's selections while a genuinely-foreign tenant
  /// is still purged. Production keeps using the single-keep method
  /// byte-unchanged. No-ops on an empty keep set (NOT IN () is invalid
  /// SQL and would otherwise delete everything).
  Future<int> deleteForRestaurantsNotIn(Set<String> keepRestaurantIds) async {
    if (keepRestaurantIds.isEmpty) return 0;
    final keep = keepRestaurantIds.toList(growable: false);
    final placeholders = List.filled(keep.length, '?').join(', ');
    return _db.delete(
      'baseline_selected_records',
      where: 'restaurant_id NOT IN ($placeholders)',
      whereArgs: keep,
    );
  }
}
