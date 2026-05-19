import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../../domain/models/data_accuracy_service_period_setting.dart';
import '../../../../domain/models/data_accuracy_settings.dart';

/// Theme H#7 — persistent SQLite mirror of the proxy's
/// `data_accuracy_service_period_settings` keyed rows.
///
/// Previously the proxy's per-period DAS rows lived only in volatile
/// in-memory state on `PostgresShiftRecordToMobileSync`. This DAO writes
/// each pull into `data_accuracy_service_period_settings_cache` so app
/// start can rehydrate the most recent server pull before the first
/// sweep completes.
///
/// Composite key matches the proxy emit shape:
///   (restaurant_id, service_period_key, effective_at_business_date)
class DataAccuracyServicePeriodSettingsCacheDao {
  DataAccuracyServicePeriodSettingsCacheDao(this._db);

  final Database _db;

  static const String _table = 'data_accuracy_service_period_settings_cache';

  /// Read every cached row for [restaurantId], ordered by service period
  /// then by effective date descending so the most recent row at-or-before
  /// any business date is the first match for a given service period.
  Future<List<DataAccuracyServicePeriodSetting>> getRows(
    String restaurantId,
  ) async {
    final rows = await _db.query(
      _table,
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'service_period_key ASC, effective_at_business_date DESC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Replace the cached rows for [restaurantId] with [rows] in a single
  /// transaction. Returns true if any row was inserted or removed.
  Future<bool> replaceAll(
    String restaurantId,
    List<DataAccuracyServicePeriodSetting> rows,
  ) async {
    return _db.transaction<bool>((txn) async {
      final deleted = await txn.delete(
        _table,
        where: 'restaurant_id = ?',
        whereArgs: [restaurantId],
      );
      final cachedAt = DateTime.now().toUtc().toIso8601String();
      var changed = deleted > 0;
      for (final row in rows) {
        await txn.insert(
          _table,
          _toRow(restaurantId: restaurantId, row: row, cachedAt: cachedAt),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        changed = true;
      }
      return changed;
    });
  }

  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    await _db.delete(
      _table,
      where: 'restaurant_id <> ?',
      whereArgs: [keepRestaurantId],
    );
  }

  static Map<String, Object?> _toRow({
    required String restaurantId,
    required DataAccuracyServicePeriodSetting row,
    required String cachedAt,
  }) {
    return <String, Object?>{
      'restaurant_id': restaurantId,
      'service_period_key': row.servicePeriodKey,
      'effective_at_business_date': row.effectiveAtBusinessDate,
      'id': row.id,
      'operator_id': row.operatorId,
      'location_id': row.locationId,
      'covers_source': row.coversSource.wire,
      'covers_source_scope_type': row.coversSourceSource?.scopeType,
      'covers_source_source_kind': row.coversSourceSource?.sourceKind,
      'covers_source_scope_id': row.coversSourceSource?.scopeId,
      'covers_source_setting_id': row.coversSourceSource?.settingId,
      'covers_source_override_id': row.coversSourceSource?.overrideId,
      'wage_source': row.wageSource.wire,
      'created_at': row.createdAt.toUtc().toIso8601String(),
      'updated_at': row.updatedAt.toUtc().toIso8601String(),
      'updated_by': row.updatedBy,
      'cached_at': cachedAt,
    };
  }

  static DataAccuracyServicePeriodSetting _fromRow(Map<String, Object?> row) {
    return DataAccuracyServicePeriodSetting(
      id: row['id']! as String,
      operatorId: row['operator_id']! as String,
      locationId: row['location_id']! as String,
      servicePeriodKey: row['service_period_key']! as String,
      coversSource: ServicePeriodCoversSourceWire.fromWire(
        row['covers_source']! as String,
      ),
      coversSourceSource: DataAccuracySettingSource.fromMap(<String, Object?>{
        'scope_type': row['covers_source_scope_type'],
        'source_kind': row['covers_source_source_kind'],
        'scope_id': row['covers_source_scope_id'],
        'setting_id': row['covers_source_setting_id'],
        'override_id': row['covers_source_override_id'],
      }),
      wageSource: ServicePeriodWageSourceWire.fromWire(
        row['wage_source']! as String,
      ),
      effectiveAtBusinessDate: row['effective_at_business_date']! as String,
      createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
      updatedAt: DateTime.parse(row['updated_at']! as String).toUtc(),
      updatedBy: row['updated_by'] as String?,
    );
  }
}
