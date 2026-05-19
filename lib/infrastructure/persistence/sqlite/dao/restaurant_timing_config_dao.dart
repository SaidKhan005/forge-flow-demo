import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
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

  /// Per-Daypart V1 Slice 1.5 — `shift_close_authority` +
  /// `local_close_fallback` were dropped from the row. Close-authority
  /// is auto-derived per shift from
  /// `lib/services/integration/close_authority_capability.dart`.
  Future<void> upsert({
    required String restaurantId,
    required String businessDayStartLocalTime,
    required int weekStartDay,
    required List<ServicePeriodDefinition> servicePeriodDefinitions,
    required String createdAt,
    required String updatedAt,
    String? selectedScopeType,
    String? selectedScopeId,
    String? sourceScopeType,
    String? sourceScopeId,
    String? sourceScopeLabel,
    bool? inheritedFromAncestor,
  }) async {
    // Canonicalize order: sortOrder ascending, then id ascending for stability.
    final sorted = [...servicePeriodDefinitions]
      ..sort((a, b) {
        final cmp = a.sortOrder.compareTo(b.sortOrder);
        return cmp != 0 ? cmp : a.id.compareTo(b.id);
      });
    final defsJson = jsonEncode(sorted.map((d) => d.toMap()).toList());
    await _db.insert('restaurant_timing_configs', {
      'restaurant_id': restaurantId,
      'business_day_start_local_time': businessDayStartLocalTime,
      'week_start_day': weekStartDay,
      'service_period_definitions_json': defsJson,
      'selected_scope_type': selectedScopeType,
      'selected_scope_id': selectedScopeId,
      'source_scope_type': sourceScopeType,
      'source_scope_id': sourceScopeId,
      'source_scope_label': sourceScopeLabel,
      'inherited_from_ancestor': inheritedFromAncestor == null
          ? null
          : (inheritedFromAncestor ? 1 : 0),
      'created_at': createdAt,
      'updated_at': updatedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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

  /// Deletes every `restaurant_timing_configs` row whose `restaurant_id`
  /// is NOT in [keepRestaurantIds]. The set-preserving sibling of
  /// [deleteForOtherRestaurants]; the demo bootstrap source-swap
  /// (`demoScopePreservingCrossTenantWipe`) passes the demo operator's
  /// full `DemoScope.locations` set so a demo location switch keeps
  /// every demo location's timing config while a genuinely-foreign
  /// tenant is still purged. Production keeps using the single-keep
  /// method byte-unchanged. No-ops on an empty keep set (NOT IN () is
  /// invalid SQL and would otherwise delete everything).
  Future<int> deleteForRestaurantsNotIn(Set<String> keepRestaurantIds) async {
    if (keepRestaurantIds.isEmpty) return 0;
    final keep = keepRestaurantIds.toList(growable: false);
    final placeholders = List.filled(keep.length, '?').join(', ');
    return _db.delete(
      'restaurant_timing_configs',
      where: 'restaurant_id NOT IN ($placeholders)',
      whereArgs: keep,
    );
  }
}
