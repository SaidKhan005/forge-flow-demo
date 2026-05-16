import '../../../../domain/repositories/baseline_selection_repository.dart';
import '../dao/baseline_selection_dao.dart';
import '../sqlite_database.dart';

class SqliteBaselineSelectionRepository implements BaselineSelectionRepository {
  SqliteBaselineSelectionRepository._();
  static final SqliteBaselineSelectionRepository instance =
      SqliteBaselineSelectionRepository._();

  BaselineSelectionDao? _dao;

  Future<BaselineSelectionDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = BaselineSelectionDao(db);
    return _dao!;
  }

  @override
  Future<Set<String>> getSelectedRecordKeys(String restaurantId) async {
    final dao = await _daoReady;
    return dao.getSelectedRecordKeys(restaurantId);
  }

  @override
  Future<void> replaceSelectedRecordKeys(
    String restaurantId,
    Set<String> keys,
  ) async {
    final dao = await _daoReady;
    return dao.replaceSelectedRecordKeys(restaurantId, keys);
  }

  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    final dao = await _daoReady;
    return dao.wipeForOtherScopes(keepRestaurantId);
  }

  /// Set-preserving sibling of [wipeForOtherScopes]. Deletes every
  /// mirrored `baseline_selected_records` row whose `restaurant_id` is
  /// NOT in [keepRestaurantIds]. Used only by the demo bootstrap
  /// source-swap (`demoScopePreservingCrossTenantWipe`) so a demo
  /// location switch keeps every demo location's selections; production
  /// keeps the single-keep path byte-unchanged.
  Future<int> wipeForScopesNotIn(Set<String> keepRestaurantIds) async {
    final dao = await _daoReady;
    return dao.deleteForRestaurantsNotIn(keepRestaurantIds);
  }
}
