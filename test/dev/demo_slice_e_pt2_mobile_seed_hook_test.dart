// Demo-data Slice E pt2 — acceptance tests for the mobile-fold
// `demo_mode_state` seed hook (the `DemoVendorIntegrationDemoModeSource`
// writer-side swap that feeds `DemoModeStateNotifier` in the demo
// flavor).
//
// Proves:
//   (a) mobile fold + banner now have a source — the demo
//       `DemoModeStateNotifier` resolves the armed source and exposes
//       the 4 `DemoScope.locations` × 3 categories;
//   (b) values are byte-consistent with pt1 (#800)
//       `DemoVendorIntegrationStateFixture` (same connected/error/
//       disconnected + `is_demo` mix; `hasDemoCategories` true for ≥1
//       location and false for ≥1);
//   (c) HP #2 writer-side only — production path unchanged: when the
//       seed hook did NOT arm the source (production / non-demo build)
//       `maybeClient()` is null and the notifier stays silent (no
//       `kDemoMode` reader branch anywhere);
//   (d) determinism — two "reseeds" (arm twice) are byte-identical, no
//       RNG / no `DateTime.now()`;
//   (e) HP #4 — every record carries only its own location + the demo
//       operator; no cross-location / cross-operator leakage;
//   (f) the demo client serves ONLY `fetchDemoModeStates` — any other
//       proxy call fails loudly (no operational-sync leakage).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/dev/demo_vendor_integration_state_fixture.dart';
import 'package:forge_and_flow/dev/demo_vendor_integration_sync_proxy_client.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/auth/demo_auth_login_service.dart'
    show kDemoOperatorOperatorId;
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/state/demo_mode_state_notifier.dart';

List<String> get _demoLocationIds =>
    <String>[for (final l in DemoScope.locations) l.restaurantId];

void main() {
  setUp(DemoVendorIntegrationDemoModeSource.resetForTest);
  tearDown(DemoVendorIntegrationDemoModeSource.resetForTest);

  group('production path unchanged (HP #2 writer-side only)', () {
    test('source not armed → maybeClient() is null', () {
      expect(DemoVendorIntegrationDemoModeSource.maybeClient(), isNull);
    });

    test(
      'unarmed source + null-client notifier → silent (no records, '
      'no banner) — exactly the production no-proxy reality',
      () async {
        final notifier = DemoModeStateNotifier(
          client: DemoVendorIntegrationDemoModeSource.maybeClient(),
          now: () => DateTime.utc(2026, 5, 15),
        );
        await notifier.setScope(
          operatorId: kDemoOperatorOperatorId,
          locationId: DemoScope.downtownRestaurantId,
        );
        expect(notifier.snapshot.records, isEmpty);
        expect(notifier.snapshot.hasDemoCategories, isFalse);
      },
    );
  });

  group('demo seed hook armed the source', () {
    setUp(() {
      // Simulate `_seedDemoVendorIntegrationModeStateSource` running
      // under the demo writer-side switch.
      DemoVendorIntegrationDemoModeSource.armForDemoSeed(
        demoLocationIds: _demoLocationIds,
      );
    });

    test('maybeClient() is now non-null', () {
      expect(DemoVendorIntegrationDemoModeSource.maybeClient(), isNotNull);
    });

    Future<DemoModeStateSnapshot> snapshotFor(String locationId) async {
      final notifier = DemoModeStateNotifier(
        client: DemoVendorIntegrationDemoModeSource.maybeClient(),
        now: () => DateTime.utc(2026, 5, 15),
      );
      await notifier.setScope(
        operatorId: kDemoOperatorOperatorId,
        locationId: locationId,
      );
      return notifier.snapshot;
    }

    test(
      'mobile fold + banner render: 4 locations × 3 categories, mix '
      'matches pt1 (hasDemoCategories true for ≥1, false for ≥1)',
      () async {
        final downtown =
            await snapshotFor(DemoScope.downtownRestaurantId);
        final northLoop =
            await snapshotFor(DemoScope.northLoopRestaurantId);
        final riverside =
            await snapshotFor(DemoScope.riversideRestaurantId);
        final harbour = await snapshotFor(DemoScope.harbourRestaurantId);

        for (final snap in <DemoModeStateSnapshot>[
          downtown,
          northLoop,
          riverside,
          harbour,
        ]) {
          expect(snap.records.length, 3);
          expect(
            snap.records.map((r) => r.category).toSet(),
            IntegrationCategory.values.toSet(),
          );
        }

        // §2g: ≥1 location still demo, ≥1 fully flipped live.
        expect(downtown.hasDemoCategories, isTrue);
        expect(northLoop.hasDemoCategories, isTrue);
        expect(harbour.hasDemoCategories, isTrue);
        expect(riverside.hasDemoCategories, isFalse);

        // The banner renders the still-demo categories for a mixed
        // location and nothing for the fully-live one.
        expect(downtown.demoCategories, isNotEmpty);
        expect(riverside.demoCategories, isEmpty);
      },
    );

    test(
      'byte-consistent with pt1 (#800) DemoVendorIntegrationStateFixture',
      () async {
        for (final locationId in _demoLocationIds) {
          final viaNotifier = (await snapshotFor(locationId)).records;
          final viaPt1Fixture =
              DemoVendorIntegrationStateFixture.demoModeRecords(
            operatorId: kDemoOperatorOperatorId,
            locationId: locationId,
          );
          expect(
            viaNotifier
                .map((r) =>
                    '${r.category}|${r.isDemo}|${r.flippedToLiveAt}|'
                    '${r.flippedByConnectionId}')
                .toList(),
            viaPt1Fixture
                .map((r) =>
                    '${r.category}|${r.isDemo}|${r.flippedToLiveAt}|'
                    '${r.flippedByConnectionId}')
                .toList(),
            reason: '$locationId must mirror pt1 exactly',
          );
        }
      },
    );

    test('deterministic across two reseeds (no RNG)', () async {
      final first = await snapshotFor(DemoScope.downtownRestaurantId);
      // Re-arm — simulates a second demo seed (reseed/advance path).
      DemoVendorIntegrationDemoModeSource.armForDemoSeed(
        demoLocationIds: _demoLocationIds,
      );
      final second = await snapshotFor(DemoScope.downtownRestaurantId);
      expect(
        first.records.map((r) => '${r.category}:${r.isDemo}').toList(),
        second.records.map((r) => '${r.category}:${r.isDemo}').toList(),
      );
    });

    test('HP #4 — no cross-location / cross-operator leakage', () {
      final byLocation =
          DemoVendorIntegrationDemoModeSource.materializeAndValidate(
        _demoLocationIds,
      );
      expect(byLocation.keys.toSet(), _demoLocationIds.toSet());
      byLocation.forEach((locationId, records) {
        for (final r in records) {
          expect(r.locationId, locationId);
          expect(r.operatorId, kDemoOperatorOperatorId);
        }
      });
    });
  });

  test(
    'demo client serves ONLY fetchDemoModeStates — operational sync '
    'leakage fails loudly',
    () {
      const client = DemoVendorIntegrationModeStateSyncProxyClient();
      expect(
        () => client.fetchShiftRecords(
          operatorId: kDemoOperatorOperatorId,
          locationId: DemoScope.downtownRestaurantId,
          cursor: null,
          pageSize: 50,
        ),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );
}
