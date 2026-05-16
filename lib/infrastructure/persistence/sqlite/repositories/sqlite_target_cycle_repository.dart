import '../../../../domain/models/target_cycle.dart';
// TargetCycleDaypart is re-exported from target_cycle.dart but the
// analyzer treats the explicit import as documentation-grade.
import '../../../../domain/repositories/target_cycle_repository.dart';
import '../dao/target_cycle_dao.dart';
import '../sqlite_database.dart';

class SqliteTargetCycleRepository implements TargetCycleRepository {
  SqliteTargetCycleRepository._();
  static final SqliteTargetCycleRepository instance =
      SqliteTargetCycleRepository._();

  TargetCycleDao? _dao;

  Future<TargetCycleDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = TargetCycleDao(db);
    return _dao!;
  }

  @override
  Future<TargetCycle?> getActiveCycle(String restaurantId) async {
    final dao = await _daoReady;
    return dao.getActiveCycle(restaurantId);
  }

  @override
  Future<TargetCycle?> getCycleById(String cycleId) async {
    final dao = await _daoReady;
    return dao.getCycleById(cycleId);
  }

  @override
  Future<void> upsertCycle(TargetCycle cycle) async {
    final dao = await _daoReady;
    return dao.upsertCycle(cycle);
  }

  @override
  Future<void> deactivateCycle(String cycleId) async {
    final dao = await _daoReady;
    return dao.deactivateCycle(cycleId);
  }

  /// Deactivates all active cycles for [restaurantId].
  ///
  /// Concrete-only method (not on the abstract contract) used by
  /// TargetCycleService to enforce one-active-per-restaurant before
  /// writing a new cycle.
  Future<void> deactivateAllForRestaurant(String restaurantId) async {
    final dao = await _daoReady;
    return dao.deactivateAllForRestaurant(restaurantId);
  }

  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    final dao = await _daoReady;
    return dao.wipeForOtherScopes(keepRestaurantId);
  }

  /// Per-Daypart V1 (Slice 1) — concrete-only accessor for per-period
  /// child rows. Used by reads that already have a cycleId in hand and
  /// want the child rows without rehydrating the parent.
  Future<List<TargetCycleDaypart>> getDaypartsForCycle(String cycleId) async {
    final dao = await _daoReady;
    return dao.getDaypartsForCycle(cycleId);
  }
}
