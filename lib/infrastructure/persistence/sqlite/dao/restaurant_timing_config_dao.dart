import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/restaurant_timing_config.dart';
import '../../../../domain/models/service_period_definition.dart';

class RestaurantTimingConfigDao {
  final Database _db;
  const RestaurantTimingConfigDao(this._db);

  Future<Map<String, dynamic>?> getRaw(String restaurantId) async {
    final rows = await _db.query(
      'restaurant_timing_configs',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<void> upsert({
    required String restaurantId,
    required String businessDayStartLocalTime,
    required int weekStartDay,
    required List<ServicePeriodDefinition> servicePeriodDefinitions,
    required ShiftCloseAuthority shiftCloseAuthority,
    String? localCloseFallback,
    required String createdAt,
    required String updatedAt,
  }) async {
    // Canonicalize order: sortOrder ascending, then id ascending for stability.
    final sorted = [...servicePeriodDefinitions]
      ..sort((a, b) {
        final cmp = a.sortOrder.compareTo(b.sortOrder);
        return cmp != 0 ? cmp : a.id.compareTo(b.id);
      });
    final defsJson = jsonEncode(
      sorted.map((d) => d.toMap()).toList(),
    );
    await _db.insert(
      'restaurant_timing_configs',
      {
        'restaurant_id': restaurantId,
        'business_day_start_local_time': businessDayStartLocalTime,
        'week_start_day': weekStartDay,
        'service_period_definitions_json': defsJson,
        'shift_close_authority': shiftCloseAuthority.value,
        'local_close_fallback': localCloseFallback,
        'created_at': createdAt,
        'updated_at': updatedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Deletes every `restaurant_timing_configs` row whose `restaurant_id`
  /// is NOT [keepRestaurantId]. Returns the number of rows deleted.
  /// Mirrors the per-tenant residue purge used by the shift_records and
  /// open_shift_snapshots DAOs.
  Future<int> deleteForOtherRestaurants(String keepRestaurantId) async {
    return _db.delete(
      'restaurant_timing_configs',
      where: 'restaurant_id != ?',
      whereArgs: [keepRestaurantId],
    );
  }
}
