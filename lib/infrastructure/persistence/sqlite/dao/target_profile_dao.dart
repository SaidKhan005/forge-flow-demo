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
    return ActiveTargetProfile.fromMap(rows.first);
  }

  Future<void> upsertActiveTargetProfile(ActiveTargetProfile profile) async {
    await _db.insert(
      'active_target_profiles',
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertTargetProfileVersion(TargetProfileVersion version) async {
    await _db.insert(
      'target_profile_versions',
      version.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
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
}
