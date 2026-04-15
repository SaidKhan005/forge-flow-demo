import '../models/restaurant_timing_config.dart';

abstract class RestaurantTimingConfigRepository {
  /// Returns the timing config for [restaurantId], or null if none exists.
  Future<RestaurantTimingConfig?> getTimingConfig(String restaurantId);

  /// Persists a timing config row (insert or replace).
  Future<void> saveTimingConfig(RestaurantTimingConfig config);
}
