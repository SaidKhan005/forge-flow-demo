import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/connector_config.dart';

class ConnectorConfigDao {
  final Database _db;
  const ConnectorConfigDao(this._db);

  Future<List<ConnectorConfig>> getConnectorConfigs(
      String restaurantId) async {
    final rows = await _db.query(
      'connector_configs',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'source_type ASC, updated_at DESC',
    );
    return rows.map(ConnectorConfig.fromMap).toList();
  }

  Future<ConnectorConfig?> getConnectorConfigBySourceType(
      String restaurantId, String sourceType) async {
    final rows = await _db.query(
      'connector_configs',
      where: 'restaurant_id = ? AND source_type = ?',
      whereArgs: [restaurantId, sourceType],
      orderBy: 'updated_at DESC, connector_id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ConnectorConfig.fromMap(rows.first);
  }

  Future<void> upsertConnectorConfig(ConnectorConfig config) async {
    await _db.transaction((txn) async {
      final existing = await txn.query(
        'connector_configs',
        where: 'restaurant_id = ? AND source_type = ?',
        whereArgs: [config.restaurantId, config.sourceType],
        orderBy: 'updated_at DESC, connector_id DESC',
      );

      if (existing.isNotEmpty) {
        await txn.delete(
          'connector_configs',
          where: 'restaurant_id = ? AND source_type = ?',
          whereArgs: [config.restaurantId, config.sourceType],
        );
      }

      await txn.insert(
        'connector_configs',
        config.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }
}
