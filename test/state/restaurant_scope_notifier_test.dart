import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/business_scope.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/scope/business_scope_repository.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';

import '../_test_helpers/sqlite_demo_helpers.dart';

void main() {
  setUp(setUpSqliteDemo);

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

  // Mobile-FU-drawer-seed-followup — PR #755 added the
  // [seedAvailableScopesFromLocal] fallback, but the post-merge live
  // re-drive showed the drawer still empty in demo because the
  // call-site at `_loadBusinessScopesIfNeeded` short-circuits when
  // `AuthSessionNotifier.session` is null — and the standalone demo
  // flavor builds with `requireAuth: false`, so `session` stays null
  // forever. This group exercises the session-independent boot path
  // (the default `RestaurantScopeNotifier()` constructor that drives
  // `_load`) end-to-end against the real seeded SQLite db. These
  // tests FAIL against master-as-of-PR-755 and PASS once `_load`
  // also seeds [_availableScopes] alongside [_restaurant].
  group('RestaurantScopeNotifier boot-time drawer seed (no session)', () {
    setUp(() async {
      // The notifier reads `restaurant_locations` and uses the
      // repository's singleton runtime-active id. Other groups
      // mutate both (via `_activateRestaurantForScope` inserting
      // arbitrary loc-1 / loc-a / loc-b rows). Reset to a clean demo
      // baseline so this group exercises the production boot shape:
      // a single seeded demo location, no runtime override.
      final db = await SqliteDatabase.instance.database;
      await db.delete('restaurant_locations');
      await db.delete('active_business_scopes');
      SqliteRestaurantScopeRepository.instance.clearRuntimeRestaurantOverride();
      // Re-seed the demo restaurant row that `_onCreate` originally
      // installed — `reseedDemo` only restores it when it's missing,
      // which is fine here because we just deleted it.
      await SqliteDatabase.instance.reseedDemo();
    });

    test(
      'default constructor hydrates availableScopes from the seeded '
      'restaurant_locations rows so the drawer is non-empty in demo',
      () async {
        // Construct the notifier the way the production Provider tree
        // does — no fromRestaurant() shortcut, no client, no
        // session, no operatorId injection. This is exactly what
        // happens in `main_forgeflow.dart` demo build with
        // `requireAuth: false`.
        final notifier = RestaurantScopeNotifier();

        // _load() is async; wait for it to settle.
        await _waitForLoad(notifier);

        expect(
          notifier.isLoading,
          isFalse,
          reason: '_load() should have completed and flipped the flag',
        );
        expect(
          notifier.restaurant?.restaurantId,
          'demo_restaurant_001',
          reason: 'demo bootstrap populates _restaurant on _load() — '
              'pre-existing behavior, sanity-checked here',
        );
        // The actual regression: without the fix, _availableScopes
        // is empty here because nothing on the no-session boot path
        // populated it. 2026-05-19: reseedDemo() now seeds 4 §2c
        // locations + the R6 four-period proof restaurant = 5 rows
        // in `restaurant_locations`; the boot seed must surface all of
        // them so the drawer renders every seeded location, with
        // Downtown remaining the default active scope.
        expect(
          notifier.availableScopes,
          hasLength(5),
          reason: 'drawer-seed follow-up — _load() must also seed the '
              'available-scopes list so the drawer renders every '
              'seeded location in demo (where session stays null '
              'forever)',
        );
        final downtown = notifier.availableScopes.firstWhere(
          (scope) => scope.locationId == 'demo_restaurant_001',
          orElse: () => throw StateError(
              'expected Downtown (demo_restaurant_001) in availableScopes'),
        );
        expect(downtown.scopeType, 'location');
        expect(downtown.locationId, 'demo_restaurant_001');
        expect(downtown.label, 'Barrio Legado');
        expect(downtown.businessTimezone, 'America/St_Johns');
        expect(
          notifier.activeScope?.stableKey,
          'location:demo_restaurant_001',
          reason: 'the boot seed must mark the demo restaurant as '
              'active so the drawer renders the check icon row',
        );
      },
    );

    test(
      'a subsequent seedAvailableScopesFromLocal call with a real '
      'operatorId still overwrites the boot-time placeholder',
      () async {
        // Production sign-in path: the boot seed runs first, then
        // the call-site fallback (when a session arrives but no
        // BusinessScopeClient is wired) overrides with the real
        // operator id. Verify the overwrite still works — the boot
        // seed must not durably block the production replacement.
        final notifier = RestaurantScopeNotifier();
        await _waitForLoad(notifier);
        // Boot path seeds all 5 locations from restaurant_locations
        // (4 §2c + four-period proof). The manual call below replaces
        // the list with whatever the session-scoped reader returns.
        expect(notifier.availableScopes, hasLength(5));

        // Now simulate a session arriving with a real operatorId. The
        // reader returns Downtown only — that proves the fallback path
        // overwrites the boot-time multi-location seed with whatever
        // the session-scoped reader returns (this is the production
        // shape: a real operator with a single accessible location).
        await notifier.seedAvailableScopesFromLocal(
          userId: 'real-user',
          operatorId: 'real-operator-id',
          localRestaurantsReader: () async => <RestaurantLocation>[
            RestaurantLocation(
              restaurantId: 'demo_restaurant_001',
              displayName: 'Barrio Legado',
              businessTimezone: 'America/St_Johns',
              createdAt: '2026-05-15T00:00:00Z',
              updatedAt: '2026-05-15T00:00:00Z',
            ),
          ],
          activeScopeRepository: _FakeActiveScopeRepository(),
        );

        expect(notifier.availableScopes, hasLength(1));
        expect(
          notifier.availableScopes.single.operatorId,
          'real-operator-id',
          reason: 'the session-bearing fallback path must overwrite '
              'the boot-time sentinel operatorId so production '
              'reaches operator-scoped APIs with the right id',
        );
      },
    );
  });
}

/// Polls until the notifier's `isLoading` flag flips false, which
/// signals `_load()` has resolved. Caps at ~1s so a hung test fails
/// loudly rather than spinning forever.
Future<void> _waitForLoad(RestaurantScopeNotifier notifier) async {
  for (var i = 0; i < 100; i++) {
    if (!notifier.isLoading) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  // Final drain in case isLoading flipped during the last iteration.
  await _drainMicrotasks();
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
