import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/restaurant_location.dart';

class RestaurantScopeDao {
  final Database _db;
  const RestaurantScopeDao(this._db);

  Future<RestaurantLocation?> getRestaurant(String restaurantId) async {
    final rows = await _db.query(
      'restaurant_locations',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
    );
    if (rows.isEmpty) return null;
    return RestaurantLocation.fromMap(rows.first);
  }

  Future<void> insertRestaurant(RestaurantLocation location) async {
    await _db.insert(
      'restaurant_locations',
      location.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> updateRestaurant(RestaurantLocation location) async {
    await _db.update(
      'restaurant_locations',
      location.toMap(),
      where: 'restaurant_id = ?',
      whereArgs: [location.restaurantId],
    );
  }

  Future<List<RestaurantLocation>> getAllRestaurants() async {
    final rows = await _db.query('restaurant_locations');
    return rows.map(RestaurantLocation.fromMap).toList();
  }
}
