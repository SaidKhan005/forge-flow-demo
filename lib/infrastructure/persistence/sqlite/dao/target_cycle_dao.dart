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
    final parent = TargetCycle.fromMap(rows.first);
    return _hydrateWithDayparts(parent);
  }

  Future<TargetCycle?> getCycleById(String cycleId) async {
    final rows = await _db.query(
      'target_cycles',
      where: 'cycle_id = ?',
      whereArgs: [cycleId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final parent = TargetCycle.fromMap(rows.first);
    return _hydrateWithDayparts(parent);
  }

  Future<void> upsertCycle(TargetCycle cycle) async {
    // Per-Daypart V1 (Slice 1): the cycle write path persists both the
    // parent `target_cycles` row (whose whole-day scalar fields are the
    // cover-weighted rollup cache) AND the child `target_cycle_dayparts`
    // rows. Wrapped in a transaction so a write either fully lands or
    // doesn't — partial state would let consumers read a parent pool
    // without matching period rows, violating Design Rule 4.
    await _db.transaction((txn) async {
      await txn.insert(
        'target_cycles',
        cycle.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      // Replace-for-cycle semantics: legacy child rows for the same
      // cycle are deleted before the new ones land.
      await txn.delete(
        'target_cycle_dayparts',
        where: 'cycle_id = ?',
        whereArgs: [cycle.cycleId],
      );
      if (cycle.dayparts.isEmpty) return;
      final nowIso = DateTime.now().toUtc().toIso8601String();
      for (final dp in cycle.dayparts) {
        await txn.insert('target_cycle_dayparts', {
          'cycle_id': cycle.cycleId,
          ...dp.toMap(),
          'created_at': nowIso,
        });
      }
    });
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

  /// Returns the persisted per-period rows for [cycleId], or an empty
  /// list when the child table has no rows for the cycle (Gap 42
  /// fallback path).
  Future<List<TargetCycleDaypart>> getDaypartsForCycle(String cycleId) async {
    final rows = await _db.query(
      'target_cycle_dayparts',
      where: 'cycle_id = ?',
      whereArgs: [cycleId],
      orderBy: 'service_period_id ASC',
    );
    return rows.map((r) => TargetCycleDaypart.fromMap(r)).toList();
  }

  Future<TargetCycle> _hydrateWithDayparts(TargetCycle parent) async {
    final dayparts = await getDaypartsForCycle(parent.cycleId);
    if (dayparts.isEmpty) return parent;
    return parent.copyWith(dayparts: dayparts);
  }
}
