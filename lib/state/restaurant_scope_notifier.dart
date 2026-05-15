import 'package:flutter/foundation.dart';
import '../domain/models/business_scope.dart';
import '../domain/models/restaurant_location.dart';
import '../domain/services/utc_metadata_timestamp.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_active_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../services/scope/business_scope_repository.dart';

/// Lazy reader that returns the locally-seeded
/// [RestaurantLocation] rows. Injected by tests; defaults to the
/// shared [SqliteRestaurantScopeRepository] singleton.
typedef LocalRestaurantsReader = Future<List<RestaurantLocation>> Function();

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
    final previous = _activeScope ?? persisted;
    final persistedSelection = _findMatchingScope(scopes, persisted);
    final selected =
        (persistedSelection != null && persistedSelection.isLocationScope
            ? persistedSelection
            : null) ??
        scopes.where((scope) => scope.isLocationScope).firstOrNull;
    _availableScopes = scopes;
    _activeScope = selected;
    if (selected != null) {
      await repo.saveActiveScope(userId: userId, scope: selected);
      await _activateRestaurantForScope(selected);
      if (previous != null && previous.stableKey != selected.stableKey) {
        ActiveBusinessScopeChangeBus.instance.publish(selected);
      }
    } else {
      await repo.clearActiveScope(userId);
      SqliteRestaurantScopeRepository.instance.clearRuntimeRestaurantOverride();
      _restaurant = null;
    }
    _isLoading = false;
    notifyListeners();
  }

  /// Populates [availableScopes] from the locally-seeded
  /// `restaurant_locations` rows when no [BusinessScopeClient] is
  /// wired (demo bootstrap, offline first boot, or the brief window
  /// before the proxy fetch resolves).
  ///
  /// Mirrors the shape [loadBusinessScopes] would produce had a
  /// network client been available: one location-scoped
  /// [BusinessScope] per row, tagged with the active session's
  /// [operatorId]. Picks the previously-persisted active scope when
  /// it still resolves; otherwise falls back to the first location.
  ///
  /// Architectural notes:
  /// - HP #2 (demo is a writer-side switch): this is NOT a `kDemoMode`
  ///   reader carve-out. The demo writer side already seeds
  ///   `restaurant_locations` with `restaurant_id =
  ///   'demo_restaurant_001'`; production receives the same rows
  ///   either via the proxy fetch or via local cache hydration. Both
  ///   paths feed the same drawer renderer.
  /// - The networked [loadBusinessScopes] still wins when a
  ///   [BusinessScopeClient] is wired — that call overwrites
  ///   [_availableScopes] with the proxy-authoritative list.
  Future<void> seedAvailableScopesFromLocal({
    required String userId,
    required String operatorId,
    LocalRestaurantsReader? localRestaurantsReader,
    ActiveBusinessScopeRepository? activeScopeRepository,
  }) async {
    final reader =
        localRestaurantsReader ??
        SqliteRestaurantScopeRepository.instance.listRestaurants;
    final activeRepo =
        activeScopeRepository ?? SqliteActiveScopeRepository.instance;
    final restaurants = await reader();
    if (restaurants.isEmpty) {
      // Nothing to surface — fall through with empty list. The
      // drawer's pre-existing "Your available locations will appear
      // here." empty-state still renders for this branch.
      _availableScopes = const <BusinessScope>[];
      _isLoading = false;
      notifyListeners();
      return;
    }
    final scopes = <BusinessScope>[
      for (final r in restaurants)
        BusinessScope(
          scopeId: r.restaurantId,
          scopeType: 'location',
          operatorId: operatorId,
          locationId: r.restaurantId,
          label: r.displayName,
          businessTimezone: r.businessTimezone.isEmpty
              ? null
              : r.businessTimezone,
        ),
    ];
    final persisted = await activeRepo.getActiveScope(userId);
    final persistedMatch = _findMatchingScope(scopes, persisted);
    final activeRestaurantId = _restaurant?.restaurantId;
    final activeMatch = activeRestaurantId == null
        ? null
        : scopes
              .where(
                (s) =>
                    s.isLocationScope && s.locationId == activeRestaurantId,
              )
              .firstOrNull;
    final selected = persistedMatch ?? activeMatch ?? scopes.first;
    _availableScopes = scopes;
    _activeScope = selected;
    if (selected.isLocationScope) {
      await activeRepo.saveActiveScope(userId: userId, scope: selected);
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
