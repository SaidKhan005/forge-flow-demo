// Phase 7.55n.1 — Runtime read seam for restaurant timing configuration.
//
// Exposes the active restaurant's timing config to services without
// requiring widget or UI involvement. Later slices (7.55n.2–7.55n.6)
// will wire resolvers to this config; this slice only exposes the read.

import '../domain/models/restaurant_timing_config.dart';
import '../domain/repositories/restaurant_timing_config_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart';

class RestaurantTimingConfigReadService {
  RestaurantTimingConfigReadService._();
  static final RestaurantTimingConfigReadService instance =
      RestaurantTimingConfigReadService._();

  final RestaurantTimingConfigRepository _repo =
      SqliteRestaurantTimingConfigRepository.instance;

  /// Returns the timing config for the active restaurant, or null if
  /// no timing config has been persisted yet.
  Future<RestaurantTimingConfig?> getActiveTimingConfig() async {
    final restaurantId =
        await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();
    return _repo.getTimingConfig(restaurantId);
  }

  /// Returns the timing config for a specific [restaurantId], or null
  /// if none exists.
  Future<RestaurantTimingConfig?> getTimingConfig(String restaurantId) async {
    return _repo.getTimingConfig(restaurantId);
  }
}