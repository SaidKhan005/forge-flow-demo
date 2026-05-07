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
}
