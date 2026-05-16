import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/wage_role_row.dart';

class WageRoleRowDao {
  final Database _db;
  const WageRoleRowDao(this._db);

  Future<List<WageRoleRow>> getRows(String restaurantId) async {
    final rows = await _db.query(
      'wage_role_rows',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'labor_bucket, role_name',
    );
    return rows.map(WageRoleRow.fromMap).toList();
  }

  /// Upsert a single row. When [WageRoleRow.serverId] is set the upsert
  /// resolves on the `(restaurant_id, server_id)` UNIQUE index so a
  /// vendor-driven server row keeps its identity even if the
  /// (restaurant_id, role_name) pair shifts (e.g., role rename). When
  /// [WageRoleRow.serverId] is null the legacy
  /// `(restaurant_id, role_name)` UNIQUE constraint applies.
  Future<void> upsertRow(WageRoleRow row) async {
    if (row.serverId != null) {
      // Match the row by server_id first; fall back to insert.
      final existing = await _db.query(
        'wage_role_rows',
        where: 'restaurant_id = ? AND server_id = ?',
        whereArgs: [row.restaurantId, row.serverId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final id = existing.first['id'] as int;
        final map = row.toMap()..remove('id');
        await _db.update(
          'wage_role_rows',
          map,
          where: 'id = ?',
          whereArgs: [id],
        );
        return;
      }
    }
    await _db.insert(
      'wage_role_rows',
      row.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> replaceAll(String restaurantId, List<WageRoleRow> rows) async {
    return _db.transaction<bool>((txn) async {
      final deleted = await txn.delete(
        'wage_role_rows',
        where: 'restaurant_id = ?',
        whereArgs: [restaurantId],
      );
      var changed = deleted > 0;
      for (final row in rows) {
        final map = row.toMap()
          ..remove('id')
          ..['restaurant_id'] = restaurantId;
        await txn.insert(
          'wage_role_rows',
          map,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        changed = true;
      }
      return changed;
    });
  }

  Future<void> deleteRow(int id) async {
    await _db.delete('wage_role_rows', where: 'id = ?', whereArgs: [id]);
  }

  /// Soft-delete by `server_id`; only used when the proxy emits a row
  /// with `is_active=false`. Returns the number of rows updated.
  Future<int> markInactiveByServerId({
    required String restaurantId,
    required String serverId,
  }) async {
    return _db.update(
      'wage_role_rows',
      <String, Object?>{'is_active': 0},
      where: 'restaurant_id = ? AND server_id = ?',
      whereArgs: [restaurantId, serverId],
    );
  }

  Future<void> deleteAll(String restaurantId) async {
    await _db.delete(
      'wage_role_rows',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
    );
  }

  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    await _db.delete(
      'wage_role_rows',
      where: 'restaurant_id <> ?',
      whereArgs: [keepRestaurantId],
    );
  }

  /// Deletes every `wage_role_rows` row whose `restaurant_id` is NOT in
  /// [keepRestaurantIds]. The set-preserving sibling of
  /// [wipeForOtherScopes]; the demo bootstrap source-swap
  /// (`demoScopePreservingCrossTenantWipe`) passes the demo operator's
  /// full `DemoScope.locations` set so a demo location switch keeps
  /// every demo location's wage rows while a genuinely-foreign tenant
  /// is still purged. Production keeps using the single-keep method
  /// byte-unchanged. No-ops on an empty keep set (NOT IN () is invalid
  /// SQL and would otherwise delete everything).
  Future<int> deleteForRestaurantsNotIn(Set<String> keepRestaurantIds) async {
    if (keepRestaurantIds.isEmpty) return 0;
    final keep = keepRestaurantIds.toList(growable: false);
    final placeholders = List.filled(keep.length, '?').join(', ');
    return _db.delete(
      'wage_role_rows',
      where: 'restaurant_id NOT IN ($placeholders)',
      whereArgs: keep,
    );
  }
}
