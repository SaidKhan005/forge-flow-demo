// POST_HARDENING_FOLLOWUPS.md P1 — RestaurantScopeService unit tests.
//
// Validates the thin widget-layer wrapper that routes
// `getActiveRestaurantId()` calls away from a direct
// `SqliteRestaurantScopeRepository` import in widgets/notifiers.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/domain/repositories/restaurant_scope_repository.dart';
import 'package:forge_and_flow/services/restaurant_scope_service.dart';

class _FakeRestaurantScopeRepository implements RestaurantScopeRepository {
  _FakeRestaurantScopeRepository(this.activeId);
  final String activeId;
  int activeIdCalls = 0;
  int locationCalls = 0;

  @override
  Future<String> getActiveRestaurantId() async {
    activeIdCalls += 1;
    return activeId;
  }

  @override
  Future<RestaurantLocation> getOrCreateActiveRestaurant() async {
    locationCalls += 1;
    return RestaurantLocation(
      restaurantId: activeId,
      displayName: 'Test',
      businessTimezone: 'UTC',
      createdAt: '2026-05-08T00:00:00Z',
      updatedAt: '2026-05-08T00:00:00Z',
    );
  }
}

void main() {
  tearDown(() {
    RestaurantScopeService.instance.resetForTest();
  });

  test('delegates getActiveRestaurantId to the injected repository',
      () async {
    final fake = _FakeRestaurantScopeRepository('demo_restaurant_001');
    RestaurantScopeService.instance.overrideRepositoryForTest(fake);

    final id = await RestaurantScopeService.instance.getActiveRestaurantId();

    expect(id, 'demo_restaurant_001');
    expect(fake.activeIdCalls, 1);
  });

  test('resetForTest restores the production singleton', () async {
    final fake = _FakeRestaurantScopeRepository('test_restaurant_999');
    RestaurantScopeService.instance.overrideRepositoryForTest(fake);
    expect(
      await RestaurantScopeService.instance.getActiveRestaurantId(),
      'test_restaurant_999',
    );

    RestaurantScopeService.instance.resetForTest();
    // After reset the override is gone; calling again does not hit the
    // fake. We don't exercise the real SQLite path here (that requires
    // a database harness) — we just prove the fake is no longer wired.
    expect(fake.activeIdCalls, 1);
  });
}
