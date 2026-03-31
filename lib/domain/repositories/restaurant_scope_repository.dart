import '../models/restaurant_location.dart';

abstract class RestaurantScopeRepository {
  Future<RestaurantLocation> getOrCreateActiveRestaurant();
  Future<String> getActiveRestaurantId();
}
