import '../../../../domain/models/restaurant_location.dart';
import '../../../../domain/repositories/restaurant_scope_repository.dart';
import '../dao/restaurant_scope_dao.dart';
import '../sqlite_database.dart';

class SqliteRestaurantScopeRepository implements RestaurantScopeRepository {
  SqliteRestaurantScopeRepository._();
  static final SqliteRestaurantScopeRepository instance =
      SqliteRestaurantScopeRepository._();

  RestaurantScopeDao? _dao;

  Future<RestaurantScopeDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = RestaurantScopeDao(db);
    return _dao!;
  }

  @override
  Future<RestaurantLocation> getOrCreateActiveRestaurant() async {
    final dao = await _daoReady;
    final existing = await dao.getRestaurant(DemoScope.restaurantId);
    if (existing != null) {
      if (existing.displayName == 'Forge & Flow Demo') {
        final normalized = RestaurantLocation(
          restaurantId: existing.restaurantId,
          displayName: DemoScope.displayName,
          businessTimezone: existing.businessTimezone,
          createdAt: existing.createdAt,
          updatedAt: DateTime.now().toIso8601String(),
        );
        await dao.updateRestaurant(normalized);
        return normalized;
      }
      return existing;
    }

    final now = DateTime.now().toIso8601String();
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

  @override
  Future<String> getActiveRestaurantId() async {
    final restaurant = await getOrCreateActiveRestaurant();
    return restaurant.restaurantId;
  }
}
