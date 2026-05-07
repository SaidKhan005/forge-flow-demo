import 'package:flutter/foundation.dart';
import '../domain/models/business_scope.dart';
import '../domain/models/restaurant_location.dart';
import '../domain/services/utc_metadata_timestamp.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_active_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../services/scope/business_scope_repository.dart';

class RestaurantScopeNotifier extends ChangeNotifier {
  RestaurantLocation? _restaurant;
  BusinessScope? _activeScope;
  List<BusinessScope> _availableScopes = const <BusinessScope>[];
  bool _isLoading = true;

  RestaurantLocation? get restaurant => _restaurant;
  BusinessScope? get activeScope => _activeScope;
  List<BusinessScope> get availableScopes =>
      List<BusinessScope>.unmodifiable(_availableScopes);
  bool get isLoading => _isLoading;
  String? get activeLocationId =>
      _activeScope?.locationId ?? restaurant?.restaurantId;

  RestaurantScopeNotifier() {
    _load();
  }

  /// Test-only constructor for synchronous setup.
  RestaurantScopeNotifier.fromRestaurant(
    RestaurantLocation restaurant, {
    List<BusinessScope> availableScopes = const <BusinessScope>[],
    BusinessScope? activeScope,
  }) : _restaurant = restaurant,
       _availableScopes = availableScopes,
       _activeScope = activeScope,
       _isLoading = false;

  Future<void> refresh() async {
    await _load();
  }

  Future<void> loadBusinessScopes({
    required String userId,
    required BusinessScopeClient client,
    ActiveBusinessScopeRepository? activeScopeRepository,
  }) async {
    final repo = activeScopeRepository ?? SqliteActiveScopeRepository.instance;
    final scopes = await client.fetchAccessibleBusinessScopes(userId: userId);
    final persisted = await repo.getActiveScope(userId);
    final selected =
        _findMatchingScope(scopes, persisted) ??
        scopes.where((scope) => scope.isLocationScope).firstOrNull ??
        (scopes.isEmpty ? null : scopes.first);
    _availableScopes = scopes;
    _activeScope = selected;
    if (selected != null) {
      await repo.saveActiveScope(userId: userId, scope: selected);
      await _activateRestaurantForScope(selected);
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> activateBusinessScope(
    BusinessScope scope, {
    required String userId,
    ActiveBusinessScopeRepository? activeScopeRepository,
  }) async {
    final repo = activeScopeRepository ?? SqliteActiveScopeRepository.instance;
    await repo.saveActiveScope(userId: userId, scope: scope);
    _activeScope = scope;
    await _activateRestaurantForScope(scope);
    notifyListeners();
    ActiveBusinessScopeChangeBus.instance.publish(scope);
  }

  Future<void> _load() async {
    _restaurant = await SqliteRestaurantScopeRepository.instance
        .getOrCreateActiveRestaurant();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> _activateRestaurantForScope(BusinessScope scope) async {
    if (!scope.isLocationScope) return;
    final now = nowIsoUtc();
    final location = scope.toRestaurantLocation(createdAt: now, updatedAt: now);
    await SqliteRestaurantScopeRepository.instance.activateRuntimeRestaurant(
      location,
    );
    _restaurant = location;
  }

  static BusinessScope? _findMatchingScope(
    List<BusinessScope> scopes,
    BusinessScope? persisted,
  ) {
    if (persisted == null) return null;
    for (final scope in scopes) {
      if (scope.stableKey == persisted.stableKey) return scope;
    }
    return null;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
