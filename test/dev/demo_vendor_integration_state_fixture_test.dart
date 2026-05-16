// Demo-data Slice E (part 1) — acceptance tests for the vendor
// integration demo-state fixture + the demo `DemoModeStateGateway`
// impl + the read-side `DemoModeStateNotifier` snapshot.
//
// Proves: (a) mixed per-(operator, location, category) states render
// for the 4 demo locations × 3 categories; (b) `hasDemoCategories` is
// true for ≥1 location and false for ≥1; (c) determinism (no RNG —
// two reads byte-identical); (d) the production read path is
// unchanged (no `kDemoMode` reader branch — the notifier returns
// whatever the proxy returns); (e) ids stay aligned with
// `DemoScope` / `kDemoTeamLocationsFixture` so drift fails loudly.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/dev/demo_vendor_integration_state_fixture.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';
import 'package:forge_and_flow/state/demo_mode_state_notifier.dart';

const String _operatorId = 'demo-operator';

void main() {
  group('DemoVendorIntegrationStateFixture — canonical state', () {
    test('Downtown: POS+Labor connected & demo, Reservation error & demo', () {
      final records = DemoVendorIntegrationStateFixture.demoModeRecords(
        operatorId: _operatorId,
        locationId: DemoScope.downtownRestaurantId,
      );
      expect(records.map((r) => r.category), <IntegrationCategory>[
        IntegrationCategory.pos,
        IntegrationCategory.labor,
        IntegrationCategory.reservation,
      ]);
      expect(records.every((r) => r.isDemo), isTrue);
      expect(records.every((r) => r.operatorId == _operatorId), isTrue);

      final pos = DemoVendorIntegrationStateFixture.stateFor(
        locationId: DemoScope.downtownRestaurantId,
        category: IntegrationCategory.pos,
      );
      final reservation = DemoVendorIntegrationStateFixture.stateFor(
        locationId: DemoScope.downtownRestaurantId,
        category: IntegrationCategory.reservation,
      );
      expect(pos.connectionStatus, ConnectionStatus.connected);
      expect(reservation.connectionStatus, ConnectionStatus.error);
      expect(reservation.lastErrorMessage, isNotNull);
    });

    test('Riverside: every category already flipped to live', () {
      final records = DemoVendorIntegrationStateFixture.demoModeRecords(
        operatorId: _operatorId,
        locationId: DemoScope.riversideRestaurantId,
      );
      expect(records.every((r) => !r.isDemo), isTrue);
      for (final r in records) {
        expect(r.flippedToLiveAt, isNotNull);
        expect(r.flippedToLiveAt!.isUtc, isTrue);
        expect(r.flippedByConnectionId, isNotNull);
      }
    });

    test('Harbour: clean demo — all disconnected & demo', () {
      for (final category in IntegrationCategory.values) {
        final s = DemoVendorIntegrationStateFixture.stateFor(
          locationId: DemoScope.harbourRestaurantId,
          category: category,
        );
        expect(s.isDemo, isTrue);
        expect(s.connectionStatus, ConnectionStatus.disconnected);
      }
    });

    test('deterministic — two reads byte-identical (no RNG)', () {
      final a = DemoVendorIntegrationStateFixture.demoModeRecords(
        operatorId: _operatorId,
        locationId: DemoScope.riversideRestaurantId,
      );
      final b = DemoVendorIntegrationStateFixture.demoModeRecords(
        operatorId: _operatorId,
        locationId: DemoScope.riversideRestaurantId,
      );
      for (var i = 0; i < a.length; i++) {
        expect(a[i].category, b[i].category);
        expect(a[i].isDemo, b[i].isDemo);
        expect(a[i].flippedToLiveAt, b[i].flippedToLiveAt);
        expect(a[i].flippedByConnectionId, b[i].flippedByConnectionId);
      }
    });

    test('mobile location ids stay aligned with DemoScope', () {
      for (final loc in DemoScope.locations) {
        expect(
          DemoVendorIntegrationStateFixture.knowsLocation(loc.restaurantId),
          isTrue,
          reason: '${loc.restaurantId} must resolve in the fixture',
        );
      }
    });

    test('operator-web location ids stay aligned with the team fixture', () {
      for (final loc in kDemoTeamLocationsFixture) {
        expect(
          DemoVendorIntegrationStateFixture.knowsLocation(loc.locationId),
          isTrue,
          reason: '${loc.locationId} must resolve in the fixture',
        );
      }
    });
  });

  group('DemoModeStateNotifier — Test 1 (mixed states render)', () {
    Future<DemoModeStateSnapshot> snapshotFor(String locationId) async {
      final notifier = DemoModeStateNotifier(
        client: _FixtureSyncProxyClient(),
        now: () => DateTime.utc(2026, 5, 15),
      );
      await notifier.setScope(
        operatorId: _operatorId,
        locationId: locationId,
      );
      return notifier.snapshot;
    }

    test('4 locations × 3 categories with the specified mixed states', () async {
      final downtown = await snapshotFor(DemoScope.downtownRestaurantId);
      final northLoop = await snapshotFor(DemoScope.northLoopRestaurantId);
      final riverside = await snapshotFor(DemoScope.riversideRestaurantId);
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

      // hasDemoCategories true for ≥1 location and false for ≥1.
      expect(downtown.hasDemoCategories, isTrue);
      expect(northLoop.hasDemoCategories, isTrue);
      expect(harbour.hasDemoCategories, isTrue);
      expect(riverside.hasDemoCategories, isFalse);

      // Mixed: Downtown demo across all 3; Riverside live across all 3.
      expect(downtown.records.every((r) => r.isDemo), isTrue);
      expect(riverside.records.every((r) => !r.isDemo), isTrue);
    });

    test('deterministic across two notifier reads', () async {
      final first = await snapshotFor(DemoScope.downtownRestaurantId);
      final second = await snapshotFor(DemoScope.downtownRestaurantId);
      expect(
        first.records.map((r) => '${r.category}:${r.isDemo}').toList(),
        second.records.map((r) => '${r.category}:${r.isDemo}').toList(),
      );
    });

    test(
      'production read path unchanged — notifier returns whatever the '
      'proxy returns (no kDemoMode reader branch)',
      () async {
        final notifier = DemoModeStateNotifier(
          client: _FixtureSyncProxyClient(
            overrideRecords: <DemoModeRecord>[
              DemoModeRecord(
                operatorId: _operatorId,
                locationId: 'prod-loc',
                category: IntegrationCategory.pos,
                isDemo: false,
              ),
            ],
          ),
          now: () => DateTime.utc(2026, 5, 15),
        );
        await notifier.setScope(
          operatorId: _operatorId,
          locationId: 'prod-loc',
        );
        // The notifier did not consult the fixture or branch on a demo
        // flag — it surfaced exactly the proxy's rows.
        expect(notifier.snapshot.records.length, 1);
        expect(notifier.snapshot.records.single.isDemo, isFalse);
        expect(notifier.snapshot.hasDemoCategories, isFalse);
      },
    );
  });

  group('DemoVendorIntegrationDemoModeStateGateway — write-side swap', () {
    const gateway =
        DemoVendorIntegrationDemoModeStateGateway(operatorId: _operatorId);

    test('readOrCreateDefault returns the fixture row', () async {
      final row = await gateway.readOrCreateDefault(
        operatorId: _operatorId,
        locationId: DemoScope.downtownRestaurantId,
        category: IntegrationCategory.reservation,
      );
      expect(row.isDemo, isTrue);
      expect(row.category, IntegrationCategory.reservation);
      expect(row.operatorId, _operatorId);
    });

    test('flipToLive flips a demo row one-way with metadata', () async {
      final flippedAt = DateTime.utc(2026, 5, 15, 9, 30);
      final flipped = await gateway.flipToLive(
        operatorId: _operatorId,
        locationId: DemoScope.downtownRestaurantId,
        category: IntegrationCategory.pos,
        connectionId: 'conn-xyz',
        flippedAt: flippedAt,
      );
      expect(flipped.isDemo, isFalse);
      expect(flipped.flippedToLiveAt, flippedAt);
      expect(flipped.flippedByConnectionId, 'conn-xyz');
    });

    test('flipToLive on an already-live row is idempotent', () async {
      final result = await gateway.flipToLive(
        operatorId: _operatorId,
        locationId: DemoScope.riversideRestaurantId,
        category: IntegrationCategory.pos,
        connectionId: 'conn-should-be-ignored',
        flippedAt: DateTime.utc(2026, 5, 15, 9, 30),
      );
      expect(result.isDemo, isFalse);
      expect(result.flippedByConnectionId, isNot('conn-should-be-ignored'));
    });
  });
}

/// Minimal proxy stub: routes only `fetchDemoModeStates` (to the
/// fixture, or a fixed override for the production-path test); every
/// other method throws via `noSuchMethod` so a regression that pulls
/// other data through here fails loudly.
class _FixtureSyncProxyClient implements SyncProxyClient {
  _FixtureSyncProxyClient({this.overrideRecords});

  final List<DemoModeRecord>? overrideRecords;

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async {
    if (overrideRecords != null) return overrideRecords!;
    return DemoVendorIntegrationStateFixture.demoModeRecords(
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'not needed in Slice E fixture tests: '
        '${invocation.memberName}',
      );
}
