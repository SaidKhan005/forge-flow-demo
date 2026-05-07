// Phase 8.0 / 8.operator-self-service — In-memory gateway tests.
//
// Pins the demo-mode behavior of `connectWithApiKey`: writing the
// api-key bundle should mutate the seeded connections bundle the
// same way `startConnect` does today, so the demo walkthrough keeps
// rendering a connected card immediately after the operator pastes a
// key.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';

void main() {
  group('InMemoryVendorConnectionsGateway.connectWithApiKey', () {
    test('mutates the bundle so a connected row appears', () async {
      final gateway = InMemoryVendorConnectionsGateway();

      final before = await gateway.loadBundle(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      expect(before.posConnection, isNull,
          reason: 'Empty seed must start without any connection rows.');

      final result = await gateway.connectWithApiKey(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'toast',
        apiKey: 'auth-token',
        apiSecret: 'restaurant-guid',
      );

      expect(result.connectionId, isNotEmpty);
      expect(result.firstBackfillStarted, isTrue);

      final after = await gateway.loadBundle(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      expect(after.posConnection, isNotNull);
      expect(after.posConnection!.vendorId, 'toast');
      expect(after.posConnection!.status, VendorConnectionStatus.connected);
      expect(after.posConnection!.metadata['username'], 'restaurant-guid');
    });

    test('routes labor api-key vendors into the labor slot', () async {
      final gateway = InMemoryVendorConnectionsGateway();

      await gateway.connectWithApiKey(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'agendrix',
        apiKey: 'agendrix-key',
      );

      final after = await gateway.loadBundle(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      expect(after.laborConnection, isNotNull);
      expect(after.laborConnection!.vendorId, 'agendrix');
      expect(after.posConnection, isNull);
      expect(after.reservationConnection, isNull);
    });

    test('rejects an empty api key', () async {
      final gateway = InMemoryVendorConnectionsGateway();

      await expectLater(
        gateway.connectWithApiKey(
          operatorId: 'op-1',
          locationId: 'loc-1',
          vendorId: 'toast',
          apiKey: '   ',
        ),
        throwsA(isA<VendorConnectionsGatewayError>()),
      );
    });

    test('rejects an unknown vendor id', () async {
      final gateway = InMemoryVendorConnectionsGateway();

      await expectLater(
        gateway.connectWithApiKey(
          operatorId: 'op-1',
          locationId: 'loc-1',
          vendorId: 'not_a_real_vendor',
          apiKey: 'anything',
        ),
        throwsA(isA<VendorConnectionsGatewayError>()),
      );
    });
  });

  group('InMemoryVendorConnectionsGateway.vendorCatalog', () {
    test('11 api-key vendors carry vendor-specific labels and help text', () {
      const expectedKeyPasteVendors = <String>{
        'toast',
        'lightspeed_lsk',
        'aloha_ncr_voyix',
        'oracle_micros_simphony',
        'revel',
        'adp',
        'tock',
        'push_operations',
        'agendrix',
        'sevenrooms',
        'opentable',
      };
      for (final vendorId in expectedKeyPasteVendors) {
        final entry = InMemoryVendorConnectionsGateway.vendorCatalog
            .firstWhere((candidate) => candidate.vendorId == vendorId);
        expect(
          entry.authMode,
          anyOf(VendorAuthMode.keyPaste, VendorAuthMode.oauthOrKeyPaste),
          reason: '$vendorId must be a key-paste vendor.',
        );
        expect(
          entry.apiKeyFieldLabel,
          isNotNull,
          reason: '$vendorId must declare an api-key label.',
        );
        expect(
          entry.credentialsHelpText,
          isNotNull,
          reason: '$vendorId must declare credentials help text.',
        );
      }
    });
  });
}
