import 'package:flutter/foundation.dart';
import '../domain/models/restaurant_location.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';

class RestaurantScopeNotifier extends ChangeNotifier {
  RestaurantLocation? _restaurant;
  bool _isLoading = true;

  RestaurantLocation? get restaurant => _restaurant;
  bool get isLoading => _isLoading;

  RestaurantScopeNotifier() {
    _load();
  }

  /// Test-only constructor for synchronous setup.
  RestaurantScopeNotifier.fromRestaurant(RestaurantLocation restaurant)
      : _restaurant = restaurant,
        _isLoading = false;

  Future<void> refresh() async {
    await _load();
  }

  Future<void> _load() async {
    _restaurant = await SqliteRestaurantScopeRepository.instance
        .getOrCreateActiveRestaurant();
    _isLoading = false;
    notifyListeners();
  }
}
