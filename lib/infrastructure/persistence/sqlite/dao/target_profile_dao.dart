import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/active_target_profile.dart';
import '../../../../domain/models/target_profile_version.dart';

class TargetProfileDao {
  final Database _db;
  const TargetProfileDao(this._db);

  Future<ActiveTargetProfile?> getActiveTargetProfile(
    String restaurantId,
  ) async {
    final rows = await _db.query(
      'active_target_profiles',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
    );
    if (rows.isEmpty) return null;
    return _hydrateWithActiveCycleDayparts(
      ActiveTargetProfile.fromMap(rows.first),
    );
  }

  Future<void> upsertActiveTargetProfile(ActiveTargetProfile profile) async {
    await _db.insert(
      'active_target_profiles',
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertTargetProfileVersion(TargetProfileVersion version) async {
    final map = await _targetProfileVersionMapForSchema(version);
    await _db.insert(
      'target_profile_versions',
      map,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (map.containsKey('target_cycle_id') &&
        version.targetCycleId != null &&
        version.targetCycleId!.trim().isNotEmpty) {
      await _db.update(
        'target_profile_versions',
        <String, Object?>{'target_cycle_id': version.targetCycleId},
        where:
            'restaurant_id = ? AND target_profile_version_id = ? '
            'AND (target_cycle_id IS NULL OR target_cycle_id = ?)',
        whereArgs: <Object?>[
          version.restaurantId,
          version.targetProfileVersionId,
          '',
        ],
      );
    }
  }

  Future<TargetProfileVersion?> getTargetProfileVersion(
    String restaurantId,
    String versionId,
  ) async {
    final rows = await _db.query(
      'target_profile_versions',
      where: 'restaurant_id = ? AND target_profile_version_id = ?',
      whereArgs: [restaurantId, versionId],
    );
    if (rows.isEmpty) return null;
    return TargetProfileVersion.fromMap(rows.first);
  }

  Future<TargetProfileVersion?> getTargetProfileVersionForCycle(
    String restaurantId,
    String targetCycleId,
  ) async {
    if (!await _columnExists('target_profile_versions', 'target_cycle_id')) {
      return null;
    }
    final rows = await _db.query(
      'target_profile_versions',
      where: 'restaurant_id = ? AND target_cycle_id = ?',
      whereArgs: <Object?>[restaurantId, targetCycleId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TargetProfileVersion.fromMap(rows.first);
  }

  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    await _db.delete(
      'active_target_profiles',
      where: 'restaurant_id != ?',
      whereArgs: [keepRestaurantId],
    );
    await _db.delete(
      'target_profile_versions',
      where: 'restaurant_id != ?',
      whereArgs: [keepRestaurantId],
    );
  }

  /// Deletes every `active_target_profiles` + `target_profile_versions`
  /// row whose `restaurant_id` is NOT in [keepRestaurantIds]. The
  /// set-preserving sibling of [wipeForOtherScopes]; the demo bootstrap
  /// source-swap (`demoScopePreservingCrossTenantWipe`) passes the demo
  /// operator's full `DemoScope.locations` set so a demo location
  /// switch keeps every demo location's profiles while a
  /// genuinely-foreign tenant is still purged. Production keeps using
  /// the single-keep method byte-unchanged. No-ops on an empty keep set
  /// (NOT IN () is invalid SQL and would otherwise delete everything).
  Future<int> deleteForRestaurantsNotIn(Set<String> keepRestaurantIds) async {
    if (keepRestaurantIds.isEmpty) return 0;
    final keep = keepRestaurantIds.toList(growable: false);
    final placeholders = List.filled(keep.length, '?').join(', ');
    final profiles = await _db.delete(
      'active_target_profiles',
      where: 'restaurant_id NOT IN ($placeholders)',
      whereArgs: keep,
    );
    final versions = await _db.delete(
      'target_profile_versions',
      where: 'restaurant_id NOT IN ($placeholders)',
      whereArgs: keep,
    );
    return profiles + versions;
  }

  Future<ActiveTargetProfile> _hydrateWithActiveCycleDayparts(
    ActiveTargetProfile parent,
  ) async {
    final pinnedCycleId = parent.targetCycleId?.trim();
    if (pinnedCycleId != null && pinnedCycleId.isNotEmpty) {
      return _hydrateWithCycleDayparts(parent, pinnedCycleId);
    }
    final cycles = await _db.query(
      'target_cycles',
      columns: const <String>['cycle_id'],
      where: 'restaurant_id = ? AND deactivated_at IS NULL',
      whereArgs: <Object?>[parent.restaurantId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (cycles.isEmpty) return parent;
    final cycleId = cycles.single['cycle_id'] as String?;
    if (cycleId == null || cycleId.isEmpty) return parent;
    return _hydrateWithCycleDayparts(parent, cycleId);
  }

  Future<ActiveTargetProfile> _hydrateWithCycleDayparts(
    ActiveTargetProfile parent,
    String cycleId,
  ) async {
    final rows = await _db.query(
      'target_cycle_dayparts',
      where: 'cycle_id = ?',
      whereArgs: <Object?>[cycleId],
      orderBy: 'service_period_id ASC',
    );
    if (rows.isEmpty) return parent;
    return parent.withDayparts(<ActiveTargetProfileDaypart>[
      for (final row in rows)
        ActiveTargetProfileDaypart(
          servicePeriodId: row['service_period_id']! as String,
          daypartTargetCPLH: (row['target_cplh']! as num).toDouble(),
          daypartTargetSPLH: (row['target_splh']! as num).toDouble(),
          daypartTargetPPA: (row['target_ppa']! as num).toDouble(),
          daypartOpzFloorCPLH: (row['opz_floor_cplh']! as num).toDouble(),
          daypartOpzCeilingCPLH: (row['opz_ceiling_cplh']! as num).toDouble(),
          verdict: row['verdict'] as String?,
          verdictReason: row['verdict_reason'] as String?,
        ),
    ]);
  }

  Future<Map<String, dynamic>> _targetProfileVersionMapForSchema(
    TargetProfileVersion version,
  ) async {
    final map = Map<String, dynamic>.from(version.toMap());
    if (!await _columnExists('target_profile_versions', 'target_cycle_id')) {
      map.remove('target_cycle_id');
    }
    return map;
  }

  Future<bool> _columnExists(String table, String column) async {
    final rows = await _db.rawQuery('PRAGMA table_info($table)');
    return rows.any((row) => row['name'] == column);
  }
}
