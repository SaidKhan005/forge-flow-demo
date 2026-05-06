import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/target_cycle.dart';

class TargetCycleDao {
  final Database _db;
  const TargetCycleDao(this._db);

  Future<TargetCycle?> getActiveCycle(String restaurantId) async {
    final rows = await _db.query(
      'target_cycles',
      where: 'restaurant_id = ? AND deactivated_at IS NULL',
      whereArgs: [restaurantId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TargetCycle.fromMap(rows.first);
  }

  Future<TargetCycle?> getCycleById(String cycleId) async {
    final rows = await _db.query(
      'target_cycles',
      where: 'cycle_id = ?',
      whereArgs: [cycleId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TargetCycle.fromMap(rows.first);
  }

  Future<void> upsertCycle(TargetCycle cycle) async {
    await _db.insert(
      'target_cycles',
      cycle.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deactivateCycle(String cycleId) async {
    await _db.update(
      'target_cycles',
      {'deactivated_at': DateTime.now().toUtc().toIso8601String()},
      where: 'cycle_id = ?',
      whereArgs: [cycleId],
    );
  }

  /// Deactivates all active cycles for [restaurantId].
  ///
  /// Called before creating a new cycle to enforce one-active-per-restaurant.
  Future<void> deactivateAllForRestaurant(String restaurantId) async {
    await _db.update(
      'target_cycles',
      {'deactivated_at': DateTime.now().toUtc().toIso8601String()},
      where: 'restaurant_id = ? AND deactivated_at IS NULL',
      whereArgs: [restaurantId],
    );
  }

  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    await _db.delete(
      'target_cycles',
      where: 'restaurant_id != ?',
      whereArgs: [keepRestaurantId],
    );
  }
}
