// Phase 8 Wave B — `8.spine-bridge.0` — POS adapter registry tests.
//
// Verifies the registry binds all 7 Wave B POS adapters by vendorId
// and that lookup short-circuits on unknown vendors. No live HTTP, no
// Postgres, no fixtures from `test/integrations/**` — those tests
// remain owned by the Wave B per-vendor lanes and stay untouched.
//
// Method bodies on the stub deps types use `noSuchMethod` so the
// abstract surface area of each vendor's gateway / API client does not
// need to be re-spelled here. The dispatch lane only has to confirm
// each builder constructs a real adapter instance — the spine bridge
// does not call any adapter method at this stage; lanes `.1.*` cover
// the wired behavior.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/lightspeed_lsk_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/revel_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/square_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/toast_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/toast_webhook_signature_verifier.dart'
    show kToastVendorId;
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';

import '../../../tool/advisor_proxy/pos_adapter_registry.dart';

void main() {
  group('kPosAdapters registry', () {
    test('exposes exactly the 7 Wave B POS vendor ids', () {
      expect(
        registeredPosVendorIds.toSet(),
        <String>{
          kAlohaNcrVoyixVendorId,
          'clover',
          kLightspeedLskVendorId,
          oracleMicrosSimphonyVendorId,
          kRevelVendorId,
          kSquareVendorId,
          kToastVendorId,
        },
      );
      expect(registeredPosVendorIds, hasLength(7));
    });

    test('lookupPosAdapter returns null on unknown vendor', () {
      final result = lookupPosAdapter(
        'unknown_vendor',
        deps: AlohaNcrVoyixPosAdapterDeps(
          transport: _StubAlohaTransport(),
          factSink: _StubAlohaFactSink(),
        ),
      );
      expect(result, isNull);
    });

    test('lookupPosAdapter throws ArgumentError on deps/vendorId mismatch', () {
      expect(
        () => lookupPosAdapter(
          kSquareVendorId,
          deps: AlohaNcrVoyixPosAdapterDeps(
            transport: _StubAlohaTransport(),
            factSink: _StubAlohaFactSink(),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('every registered adapter implements PosAdapter', () {
      final cases = <String, PosAdapter>{
        kAlohaNcrVoyixVendorId: lookupPosAdapter(
          kAlohaNcrVoyixVendorId,
          deps: AlohaNcrVoyixPosAdapterDeps(
            transport: _StubAlohaTransport(),
            factSink: _StubAlohaFactSink(),
          ),
        )!,
        'clover': lookupPosAdapter(
          'clover',
          deps: CloverPosAdapterDeps(
            api: _StubCloverApi(),
            factWriter: _StubCloverFactWriter(),
            watermarkStore: _StubCloverWatermarkStore(),
            webhookRegistry: _StubCloverWebhookRegistry(),
            credentials: _StubCloverCredentialStore(),
          ),
        )!,
        kLightspeedLskVendorId: lookupPosAdapter(
          kLightspeedLskVendorId,
          deps: LightspeedLskPosAdapterDeps(
            gateway: _StubLightspeedLskGateway(),
            oauthClient: _StubLightspeedLskOAuthClient(),
            webhookClient: _StubLightspeedLskWebhookClient(),
            ordersClient: _StubLightspeedLskOrdersClient(),
            restaurantTimezone: 'America/Toronto',
            businessDayRolloverHour: 4,
            webhookUrl: 'https://example.test/v1/webhooks/lightspeed_lsk',
          ),
        )!,
        oracleMicrosSimphonyVendorId: lookupPosAdapter(
          oracleMicrosSimphonyVendorId,
          deps: OracleMicrosSimphonyPosAdapterDeps(
            apiClient: _StubSimphonyApiClient(),
            canonicalSink: _StubSimphonyCanonicalSink(),
          ),
        )!,
        kRevelVendorId: lookupPosAdapter(
          kRevelVendorId,
          deps: RevelPosAdapterDeps(
            transport: _StubRevelTransport(),
            gateway: _StubRevelGateway(),
          ),
        )!,
        kSquareVendorId: lookupPosAdapter(
          kSquareVendorId,
          deps: SquarePosAdapterDeps(
            apiClient: _StubSquareApiClient(),
            factWriter: _StubSquareFactWriter(),
            watermarkStore: _StubSquareWatermarkStore(),
            notificationUrlForConnection: ({
              required String operatorId,
              required String locationId,
            }) async => 'https://example.test/v1/webhooks/square',
          ),
        )!,
        kToastVendorId: lookupPosAdapter(
          kToastVendorId,
          deps: ToastPosAdapterDeps(
            transport: _StubToastTransport(),
            factSink: _StubToastFactSink(),
          ),
        )!,
      };

      expect(cases, hasLength(7));
      cases.forEach((vendorId, adapter) {
        expect(adapter, isA<PosAdapter>(),
            reason: '$vendorId must implement PosAdapter');
        expect(adapter.vendorId, vendorId,
            reason: '$vendorId adapter.vendorId must match registry key');
      });
    });

    test(
        'lookupPosCapability returns the VendorCapabilityProfile for every '
        'registered vendor and null for unknown vendors', () {
      // Unknown vendor short-circuits.
      expect(lookupPosCapability('unknown_vendor'), isNull);

      // Every registered vendor returns a non-null profile keyed to the
      // same vendorId.
      for (final vendorId in registeredPosVendorIds) {
        final profile = lookupPosCapability(vendorId);
        expect(profile, isNotNull,
            reason: 'lookupPosCapability($vendorId) must not be null');
        expect(profile!.vendorId, vendorId,
            reason: 'profile.vendorId must match registry key');
        expect(profile.category, IntegrationCategory.pos,
            reason: 'profile.category must be pos');
      }

      expect(kPosCapabilityProfiles.keys.toSet(),
          registeredPosVendorIds.toSet(),
          reason: 'capability mirror keys must match adapter registry keys');
    });

    test(
        'capability mirror does not drift from each adapter\'s runtime '
        'capabilityProfile', () {
      // Build each adapter once and assert the registry mirror equals
      // the runtime profile. Dart canonicalises identical const
      // VendorCapabilityProfile expressions to the same instance, so
      // identity-equality (the default `==`) suffices.
      final adapters = <String, PosAdapter>{
        kAlohaNcrVoyixVendorId: lookupPosAdapter(
          kAlohaNcrVoyixVendorId,
          deps: AlohaNcrVoyixPosAdapterDeps(
            transport: _StubAlohaTransport(),
            factSink: _StubAlohaFactSink(),
          ),
        )!,
        'clover': lookupPosAdapter(
          'clover',
          deps: CloverPosAdapterDeps(
            api: _StubCloverApi(),
            factWriter: _StubCloverFactWriter(),
            watermarkStore: _StubCloverWatermarkStore(),
            webhookRegistry: _StubCloverWebhookRegistry(),
            credentials: _StubCloverCredentialStore(),
          ),
        )!,
        kLightspeedLskVendorId: lookupPosAdapter(
          kLightspeedLskVendorId,
          deps: LightspeedLskPosAdapterDeps(
            gateway: _StubLightspeedLskGateway(),
            oauthClient: _StubLightspeedLskOAuthClient(),
            webhookClient: _StubLightspeedLskWebhookClient(),
            ordersClient: _StubLightspeedLskOrdersClient(),
            restaurantTimezone: 'America/Toronto',
            businessDayRolloverHour: 4,
            webhookUrl: 'https://example.test/v1/webhooks/lightspeed_lsk',
          ),
        )!,
        oracleMicrosSimphonyVendorId: lookupPosAdapter(
          oracleMicrosSimphonyVendorId,
          deps: OracleMicrosSimphonyPosAdapterDeps(
            apiClient: _StubSimphonyApiClient(),
            canonicalSink: _StubSimphonyCanonicalSink(),
          ),
        )!,
        kRevelVendorId: lookupPosAdapter(
          kRevelVendorId,
          deps: RevelPosAdapterDeps(
            transport: _StubRevelTransport(),
            gateway: _StubRevelGateway(),
          ),
        )!,
        kSquareVendorId: lookupPosAdapter(
          kSquareVendorId,
          deps: SquarePosAdapterDeps(
            apiClient: _StubSquareApiClient(),
            factWriter: _StubSquareFactWriter(),
            watermarkStore: _StubSquareWatermarkStore(),
            notificationUrlForConnection: ({
              required String operatorId,
              required String locationId,
            }) async => 'https://example.test/v1/webhooks/square',
          ),
        )!,
        kToastVendorId: lookupPosAdapter(
          kToastVendorId,
          deps: ToastPosAdapterDeps(
            transport: _StubToastTransport(),
            factSink: _StubToastFactSink(),
          ),
        )!,
      };

      adapters.forEach((vendorId, adapter) {
        final mirror = kPosCapabilityProfiles[vendorId];
        expect(mirror, isNotNull, reason: '$vendorId mirror missing');
        expect(identical(adapter.capabilityProfile, mirror), isTrue,
            reason:
                '$vendorId capability mirror drifted from adapter '
                'capabilityProfile (const canonicalisation broke — registry '
                'mirror fields differ from the adapter\'s declaration)');
      });
    });
  });
}

// ─── Stubs (noSuchMethod-based; no behavior wired) ──────────────────

class _StubAlohaTransport implements AlohaNcrVoyixApiClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubAlohaFactSink implements AlohaNcrVoyixFactSink {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubCloverApi implements CloverApiClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubCloverFactWriter implements CloverTenantFactWriter {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubCloverWatermarkStore implements CloverWatermarkStore {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubCloverWebhookRegistry implements CloverWebhookRegistry {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubCloverCredentialStore implements CloverCredentialStore {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubLightspeedLskGateway implements LightspeedLskGateway {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubLightspeedLskOAuthClient implements LightspeedLskOAuthClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubLightspeedLskWebhookClient implements LightspeedLskWebhookClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubLightspeedLskOrdersClient implements LightspeedLskOrdersClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSimphonyApiClient implements OracleMicrosSimphonyApiClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSimphonyCanonicalSink implements OracleMicrosSimphonyCanonicalSink {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubRevelTransport implements RevelTransport {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubRevelGateway implements RevelGateway {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSquareApiClient implements SquareApiClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSquareFactWriter implements SquarePosFactWriter {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSquareWatermarkStore implements SquareWatermarkStore {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubToastTransport implements ToastApiClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubToastFactSink implements ToastFactSink {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}
