// Demo-data Slice E (part 1) — Test 2: the operator-web Vendor
// Connections demo gateway returns connection states CONSISTENT with
// the `demo_mode_state` fixture for the same logical locations. Same
// logical state, both surfaces (spec §2f, prompt requirement).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/dev/demo_vendor_integration_state_fixture.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_vendor_connections_resolver.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

VendorCategory _vendorCat(IntegrationCategory c) {
  switch (c) {
    case IntegrationCategory.pos:
      return VendorCategory.pos;
    case IntegrationCategory.labor:
      return VendorCategory.labor;
    case IntegrationCategory.reservation:
      return VendorCategory.reservation;
  }
}

VendorConnectionRow? _rowFor(
  VendorConnectionsBundle bundle,
  IntegrationCategory category,
) {
  switch (category) {
    case IntegrationCategory.pos:
      return bundle.posConnection;
    case IntegrationCategory.labor:
      return bundle.laborConnection;
    case IntegrationCategory.reservation:
      return bundle.reservationConnection;
  }
}

void main() {
  group('OperatorWebDemoVendorConnectionsFixture', () {
    test('resolver.demoFallback() yields a seeded in-memory gateway', () {
      const resolver = OperatorWebVendorConnectionsResolver();
      final fallback = resolver.demoFallback();
      expect(fallback, isA<InMemoryVendorConnectionsGateway>());
    });

    test(
      'every demo location: demoFlags + connection status match the '
      'demo_mode_state fixture (same logical state both surfaces)',
      () async {
        const resolver = OperatorWebVendorConnectionsResolver();
        final gateway = resolver.demoFallback();

        for (final loc in kDemoTeamLocationsFixture) {
          final bundle = await gateway.loadBundle(
            operatorId: kDemoOperatorIdFixture,
            locationId: loc.locationId,
          );
          final records = DemoVendorIntegrationStateFixture.demoModeRecords(
            operatorId: kDemoOperatorIdFixture,
            locationId: loc.locationId,
          );

          for (final record in records) {
            final category = record.category;
            // 1. demoFlags is the SAME per-category is_demo.
            expect(
              bundle.demoFlags[_vendorCat(category)],
              record.isDemo,
              reason: '${loc.locationId}/$category demoFlag mismatch',
            );

            // 2. Connection presence/status agrees with the fixture's
            //    logical state for that (location, category).
            final state = DemoVendorIntegrationStateFixture.stateFor(
              locationId: loc.locationId,
              category: category,
            );
            final row = _rowFor(bundle, category);
            switch (state.connectionStatus) {
              case ConnectionStatus.connected:
                expect(row, isNotNull,
                    reason: '${loc.locationId}/$category should be connected');
                expect(row!.status, VendorConnectionStatus.connected);
                break;
              case ConnectionStatus.error:
                expect(row, isNotNull,
                    reason: '${loc.locationId}/$category should be error');
                expect(row!.status, VendorConnectionStatus.error);
                expect(row.lastErrorMessage, isNotNull);
                break;
              case ConnectionStatus.disconnected:
                expect(row, isNull,
                    reason: '${loc.locationId}/$category should be clean');
                break;
            }
          }
        }
      },
    );

    test('mixed states across locations are present', () async {
      const resolver = OperatorWebVendorConnectionsResolver();
      final gateway = resolver.demoFallback();

      final downtown = await gateway.loadBundle(
        operatorId: kDemoOperatorIdFixture,
        locationId: 'demo-loc-downtown',
      );
      final riverside = await gateway.loadBundle(
        operatorId: kDemoOperatorIdFixture,
        locationId: 'demo-loc-riverside',
      );
      final harbour = await gateway.loadBundle(
        operatorId: kDemoOperatorIdFixture,
        locationId: 'demo-loc-harbour',
      );

      // Downtown: a connected POS AND an error reservation (mixed).
      expect(downtown.posConnection?.status,
          VendorConnectionStatus.connected);
      expect(downtown.reservationConnection?.status,
          VendorConnectionStatus.error);
      expect(downtown.demoFlags.values.every((v) => v), isTrue);

      // Riverside: already flipped to live — every demoFlag false.
      expect(riverside.demoFlags.values.any((v) => v), isFalse);
      expect(riverside.posConnection?.status,
          VendorConnectionStatus.connected);

      // Harbour: clean demo — no connected vendors, all demo flags true.
      expect(harbour.posConnection, isNull);
      expect(harbour.laborConnection, isNull);
      expect(harbour.reservationConnection, isNull);
      expect(harbour.demoFlags.values.every((v) => v), isTrue);
    });
  });
}
