import '../../../../domain/models/restaurant_location.dart';
import '../../../../domain/repositories/restaurant_scope_repository.dart';
import '../../../../domain/services/utc_metadata_timestamp.dart';
import '../dao/restaurant_scope_dao.dart';
import '../sqlite_database.dart';

class SqliteRestaurantScopeRepository implements RestaurantScopeRepository {
  SqliteRestaurantScopeRepository._();
  static final SqliteRestaurantScopeRepository instance =
      SqliteRestaurantScopeRepository._();

  RestaurantScopeDao? _dao;
  String? _runtimeActiveRestaurantId;

  Future<RestaurantScopeDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = RestaurantScopeDao(db);
    return _dao!;
  }

  @override
  Future<RestaurantLocation> getOrCreateActiveRestaurant() async {
    final dao = await _daoReady;
    final activeId = _runtimeActiveRestaurantId ?? DemoScope.restaurantId;
    final existing = await dao.getRestaurant(activeId);
    if (existing != null) {
      if (activeId == DemoScope.restaurantId &&
          existing.displayName == 'Forge & Flow Demo') {
        final normalized = RestaurantLocation(
          restaurantId: existing.restaurantId,
          displayName: DemoScope.displayName,
          businessTimezone: existing.businessTimezone,
          createdAt: existing.createdAt,
          updatedAt: nowIsoUtc(),
        );
        await dao.updateRestaurant(normalized);
        return normalized;
      }
      return existing;
    }

    final now = nowIsoUtc();
    final location = RestaurantLocation(
      restaurantId: DemoScope.restaurantId,
      displayName: DemoScope.displayName,
      businessTimezone: DemoScope.businessTimezone,
      createdAt: now,
      updatedAt: now,
    );
    await dao.insertRestaurant(location);
    return location;
  }

  Future<void> activateRuntimeRestaurant(RestaurantLocation location) async {
    final dao = await _daoReady;
    final existing = await dao.getRestaurant(location.restaurantId);
    if (existing == null) {
      await dao.insertRestaurant(location);
    } else {
      await dao.updateRestaurant(location);
    }
    _runtimeActiveRestaurantId = location.restaurantId;
  }

  void clearRuntimeRestaurantOverride() {
    _runtimeActiveRestaurantId = null;
  }

  @override
  Future<String> getActiveRestaurantId() async {
    final restaurant = await getOrCreateActiveRestaurant();
    return restaurant.restaurantId;
  }
}
