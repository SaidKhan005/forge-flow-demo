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
}
