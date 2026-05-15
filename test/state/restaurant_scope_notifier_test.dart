import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/business_scope.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/scope/business_scope_repository.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  group('RestaurantScopeNotifier.loadBusinessScopes', () {
    test(
      'rebases a revoked active location and publishes a scope change',
      () async {
        final repo = _FakeActiveScopeRepository(stored: _location('loc-1'));
        final client = _FakeBusinessScopeClient(<BusinessScope>[
          _location('loc-2', label: 'Harbour'),
        ]);
        final notifier = RestaurantScopeNotifier.fromRestaurant(
          _restaurant('loc-1'),
          availableScopes: <BusinessScope>[_location('loc-1')],
          activeScope: _location('loc-1'),
        );
        final published = <BusinessScope>[];
        final subscription = ActiveBusinessScopeChangeBus.instance.changes
            .listen(published.add);
        addTearDown(subscription.cancel);

        await notifier.loadBusinessScopes(
          userId: 'user-1',
          client: client,
          activeScopeRepository: repo,
        );
        await _drainMicrotasks();

        expect(notifier.activeScope?.stableKey, 'location:loc-2');
        expect(notifier.restaurant?.restaurantId, 'loc-2');
        expect(repo.saved?.stableKey, 'location:loc-2');
        expect(repo.clearCalls, 0);
        expect(
          published.map((scope) => scope.stableKey),
          <String>['location:loc-2'],
          reason:
              'a forced scope-list refresh that removes the active location '
              'must drive the existing wipe/resync bus',
        );
      },
    );

    test('clears the persisted active scope when no scopes remain', () async {
      final repo = _FakeActiveScopeRepository(stored: _location('loc-1'));
      final client = _FakeBusinessScopeClient(const <BusinessScope>[]);
      final notifier = RestaurantScopeNotifier.fromRestaurant(
        _restaurant('loc-1'),
        availableScopes: <BusinessScope>[_location('loc-1')],
        activeScope: _location('loc-1'),
      );

      await notifier.loadBusinessScopes(
        userId: 'user-1',
        client: client,
        activeScopeRepository: repo,
      );

      expect(notifier.availableScopes, isEmpty);
      expect(notifier.activeScope, isNull);
      expect(notifier.restaurant, isNull);
      expect(repo.saved, isNull);
      expect(repo.clearCalls, 1);
    });

    test(
      'clears the active scope when only non-location scopes remain',
      () async {
        final repo = _FakeActiveScopeRepository(stored: _location('loc-1'));
        final client = _FakeBusinessScopeClient(<BusinessScope>[_orgUnit()]);
        final notifier = RestaurantScopeNotifier.fromRestaurant(
          _restaurant('loc-1'),
          availableScopes: <BusinessScope>[_location('loc-1')],
          activeScope: _location('loc-1'),
        );

        await notifier.loadBusinessScopes(
          userId: 'user-1',
          client: client,
          activeScopeRepository: repo,
        );

        expect(notifier.availableScopes.map((scope) => scope.scopeType), [
          'org_unit',
        ]);
        expect(notifier.activeScope, isNull);
        expect(notifier.restaurant, isNull);
        expect(repo.clearCalls, 1);
      },
    );

    test(
      // Mobile-FU-business-scope-drawer-seed — demo (and any
      // no-client) bootstrap must hydrate `availableScopes` from
      // local SQLite so the drawer does not render the empty state.
      'seedAvailableScopesFromLocal hydrates availableScopes from local restaurants',
      () async {
        final repo = _FakeActiveScopeRepository();
        final notifier = RestaurantScopeNotifier.fromRestaurant(
          _restaurant('demo_restaurant_001'),
        );

        await notifier.seedAvailableScopesFromLocal(
          userId: 'user-demo',
          operatorId: 'demo-operator',
          localRestaurantsReader: () async => <RestaurantLocation>[
            RestaurantLocation(
              restaurantId: 'demo_restaurant_001',
              displayName: 'Barrio Legado',
              businessTimezone: 'America/St_Johns',
              createdAt: '2026-05-15T00:00:00Z',
              updatedAt: '2026-05-15T00:00:00Z',
            ),
          ],
          activeScopeRepository: repo,
        );

        expect(notifier.availableScopes, hasLength(1));
        final scope = notifier.availableScopes.single;
        expect(scope.scopeType, 'location');
        expect(scope.locationId, 'demo_restaurant_001');
        expect(scope.operatorId, 'demo-operator');
        expect(scope.label, 'Barrio Legado');
        expect(scope.businessTimezone, 'America/St_Johns');
        expect(notifier.activeScope?.stableKey, 'location:demo_restaurant_001');
        expect(repo.saved?.stableKey, 'location:demo_restaurant_001');
        expect(notifier.isLoading, isFalse);
      },
    );

    test(
      // Mobile-FU-business-scope-drawer-seed — when no rows are
      // seeded yet the empty state is still legitimate (matches the
      // pre-existing renderer behavior in `_buildBusinessScopeDrawer`).
      'seedAvailableScopesFromLocal leaves availableScopes empty when no restaurants exist',
      () async {
        final repo = _FakeActiveScopeRepository();
        final notifier = RestaurantScopeNotifier.fromRestaurant(
          _restaurant('demo_restaurant_001'),
        );

        await notifier.seedAvailableScopesFromLocal(
          userId: 'user-demo',
          operatorId: 'demo-operator',
          localRestaurantsReader: () async => const <RestaurantLocation>[],
          activeScopeRepository: repo,
        );

        expect(notifier.availableScopes, isEmpty);
        expect(notifier.isLoading, isFalse);
        expect(repo.saved, isNull);
        expect(repo.clearCalls, 0);
      },
    );

    test(
      // Mobile-FU-business-scope-drawer-seed — the local seed must
      // honor a previously-persisted active scope when it still
      // resolves against the local list (otherwise a re-seed could
      // silently switch the operator's view).
      'seedAvailableScopesFromLocal prefers the persisted active scope when it still resolves',
      () async {
        final repo = _FakeActiveScopeRepository(
          stored: BusinessScope(
            scopeId: 'loc-b',
            scopeType: 'location',
            operatorId: 'demo-operator',
            locationId: 'loc-b',
            label: 'Harbour',
          ),
        );
        final notifier = RestaurantScopeNotifier.fromRestaurant(
          _restaurant('loc-a'),
        );

        await notifier.seedAvailableScopesFromLocal(
          userId: 'user-demo',
          operatorId: 'demo-operator',
          localRestaurantsReader: () async => <RestaurantLocation>[
            RestaurantLocation(
              restaurantId: 'loc-a',
              displayName: 'Legado',
              businessTimezone: 'America/St_Johns',
              createdAt: '2026-05-15T00:00:00Z',
              updatedAt: '2026-05-15T00:00:00Z',
            ),
            RestaurantLocation(
              restaurantId: 'loc-b',
              displayName: 'Harbour',
              businessTimezone: 'America/St_Johns',
              createdAt: '2026-05-15T00:00:00Z',
              updatedAt: '2026-05-15T00:00:00Z',
            ),
          ],
          activeScopeRepository: repo,
        );

        expect(notifier.availableScopes, hasLength(2));
        expect(notifier.activeScope?.locationId, 'loc-b');
        expect(repo.saved?.locationId, 'loc-b');
      },
    );

    test('does not publish during a cold first scope load', () async {
      final repo = _FakeActiveScopeRepository();
      final client = _FakeBusinessScopeClient(<BusinessScope>[
        _location('loc-1'),
      ]);
      final notifier = RestaurantScopeNotifier.fromRestaurant(
        _restaurant('demo'),
      );
      final published = <BusinessScope>[];
      final subscription = ActiveBusinessScopeChangeBus.instance.changes.listen(
        published.add,
      );
      addTearDown(subscription.cancel);

      await notifier.loadBusinessScopes(
        userId: 'user-1',
        client: client,
        activeScopeRepository: repo,
      );
      await _drainMicrotasks();

      expect(notifier.activeScope?.stableKey, 'location:loc-1');
      expect(published, isEmpty);
    });
  });
}

BusinessScope _location(String id, {String? label}) {
  return BusinessScope(
    scopeId: id,
    scopeType: 'location',
    operatorId: 'op-1',
    locationId: id,
    label: label ?? id,
    businessTimezone: 'America/St_Johns',
  );
}

BusinessScope _orgUnit() {
  return const BusinessScope(
    scopeId: 'org-1',
    scopeType: 'org_unit',
    operatorId: 'op-1',
    parentScopeId: 'op-1',
    label: 'Region',
  );
}

RestaurantLocation _restaurant(String id) {
  return RestaurantLocation(
    restaurantId: id,
    displayName: id,
    businessTimezone: 'America/St_Johns',
    createdAt: '2026-05-07T00:00:00Z',
    updatedAt: '2026-05-07T00:00:00Z',
  );
}

Future<void> _drainMicrotasks() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeBusinessScopeClient implements BusinessScopeClient {
  _FakeBusinessScopeClient(this.scopes);

  final List<BusinessScope> scopes;

  @override
  Future<List<BusinessScope>> fetchAccessibleBusinessScopes({
    required String userId,
  }) async {
    return scopes;
  }
}

class _FakeActiveScopeRepository implements ActiveBusinessScopeRepository {
  _FakeActiveScopeRepository({this.stored});

  BusinessScope? stored;
  BusinessScope? saved;
  int clearCalls = 0;

  @override
  Future<void> clearActiveScope(String userId) async {
    clearCalls += 1;
    stored = null;
    saved = null;
  }

  @override
  Future<BusinessScope?> getActiveScope(String userId) async => stored;

  @override
  Future<void> saveActiveScope({
    required String userId,
    required BusinessScope scope,
  }) async {
    stored = scope;
    saved = scope;
  }
}
