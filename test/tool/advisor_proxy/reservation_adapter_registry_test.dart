// Phase 8 Wave B — `8.spine-bridge.0` — reservation adapter registry
// tests.
//
// Verifies the registry binds all 4 Wave B reservation adapters by
// vendorId and that lookup short-circuits on unknown vendors. No live
// HTTP, no Postgres. Stubs use `noSuchMethod` so the per-vendor
// abstract surface area is not re-spelled here.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/reservation/libro_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/tock_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/tock_webhook_signature_verifier.dart'
    show kTockVendorId;
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/reservation_adapter.dart';

import '../../../tool/advisor_proxy/reservation_adapter_registry.dart';

void main() {
  group('kReservationAdapters registry', () {
    test('exposes exactly the 4 Wave B reservation vendor ids', () {
      expect(
        registeredReservationVendorIds.toSet(),
        <String>{
          kLibroVendorId,
          kOpenTableVendorId,
          kSevenRoomsVendorId,
          kTockVendorId,
        },
      );
      expect(registeredReservationVendorIds, hasLength(4));
    });

    test('lookupReservationAdapter returns null on unknown vendor', () {
      final result = lookupReservationAdapter(
        'unknown_reservation_vendor',
        deps: TockReservationAdapterDeps(
          transport: _StubTockTransport(),
          factSink: _StubTockFactSink(),
        ),
      );
      expect(result, isNull);
    });

    test(
        'lookupReservationAdapter throws ArgumentError on deps/vendorId '
        'mismatch', () {
      expect(
        () => lookupReservationAdapter(
          kOpenTableVendorId,
          deps: TockReservationAdapterDeps(
            transport: _StubTockTransport(),
            factSink: _StubTockFactSink(),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('every registered adapter implements ReservationAdapter', () {
      final cases = <String, ReservationAdapter>{
        kLibroVendorId: lookupReservationAdapter(
          kLibroVendorId,
          deps: LibroReservationAdapterDeps(
            gateway: _StubLibroGateway(),
            httpClient: _StubLibroHttpClient(),
            timezoneConverter: _StubLibroTimezoneConverter(),
          ),
        )!,
        kOpenTableVendorId: lookupReservationAdapter(
          kOpenTableVendorId,
          deps: OpenTableReservationAdapterDeps(
            transport: _StubOpenTableTransport(),
            gateway: _StubOpenTableGateway(),
          ),
        )!,
        kSevenRoomsVendorId: lookupReservationAdapter(
          kSevenRoomsVendorId,
          deps: SevenRoomsReservationAdapterDeps(
            gateway: _StubSevenRoomsGateway(),
            authClient: _StubSevenRoomsAuthClient(),
            webhookClient: _StubSevenRoomsWebhookClient(),
            reservationsClient: _StubSevenRoomsReservationsClient(),
            restaurantTimezone: 'America/Toronto',
            businessDayRolloverHour: 4,
            webhookUrl: 'https://example.test/v1/webhooks/sevenrooms',
          ),
        )!,
        kTockVendorId: lookupReservationAdapter(
          kTockVendorId,
          deps: TockReservationAdapterDeps(
            transport: _StubTockTransport(),
            factSink: _StubTockFactSink(),
          ),
        )!,
      };

      expect(cases, hasLength(4));
      cases.forEach((vendorId, adapter) {
        expect(adapter, isA<ReservationAdapter>(),
            reason: '$vendorId must implement ReservationAdapter');
        expect(adapter.vendorId, vendorId,
            reason: '$vendorId adapter.vendorId must match registry key');
      });
    });

    test(
        'lookupReservationCapability returns the VendorCapabilityProfile for '
        'every registered vendor and null for unknown vendors', () {
      expect(lookupReservationCapability('unknown_reservation_vendor'), isNull);

      for (final vendorId in registeredReservationVendorIds) {
        final profile = lookupReservationCapability(vendorId);
        expect(profile, isNotNull,
            reason: 'lookupReservationCapability($vendorId) must not be null');
        expect(profile!.vendorId, vendorId);
        expect(profile.category, IntegrationCategory.reservation);
      }

      expect(kReservationCapabilityProfiles.keys.toSet(),
          registeredReservationVendorIds.toSet());
    });

    test(
        'capability mirror does not drift from each adapter\'s runtime '
        'capabilityProfile', () {
      final adapters = <String, ReservationAdapter>{
        kLibroVendorId: lookupReservationAdapter(
          kLibroVendorId,
          deps: LibroReservationAdapterDeps(
            gateway: _StubLibroGateway(),
            httpClient: _StubLibroHttpClient(),
            timezoneConverter: _StubLibroTimezoneConverter(),
          ),
        )!,
        kOpenTableVendorId: lookupReservationAdapter(
          kOpenTableVendorId,
          deps: OpenTableReservationAdapterDeps(
            transport: _StubOpenTableTransport(),
            gateway: _StubOpenTableGateway(),
          ),
        )!,
        kSevenRoomsVendorId: lookupReservationAdapter(
          kSevenRoomsVendorId,
          deps: SevenRoomsReservationAdapterDeps(
            gateway: _StubSevenRoomsGateway(),
            authClient: _StubSevenRoomsAuthClient(),
            webhookClient: _StubSevenRoomsWebhookClient(),
            reservationsClient: _StubSevenRoomsReservationsClient(),
            restaurantTimezone: 'America/Toronto',
            businessDayRolloverHour: 4,
            webhookUrl: 'https://example.test/v1/webhooks/sevenrooms',
          ),
        )!,
        kTockVendorId: lookupReservationAdapter(
          kTockVendorId,
          deps: TockReservationAdapterDeps(
            transport: _StubTockTransport(),
            factSink: _StubTockFactSink(),
          ),
        )!,
      };

      adapters.forEach((vendorId, adapter) {
        final mirror = kReservationCapabilityProfiles[vendorId];
        expect(mirror, isNotNull, reason: '$vendorId mirror missing');
        expect(identical(adapter.capabilityProfile, mirror), isTrue,
            reason:
                '$vendorId capability mirror drifted from adapter '
                'capabilityProfile (registry mirror fields differ from the '
                'adapter\'s declaration)');
      });
    });
  });
}

// ─── Stubs (noSuchMethod-based; no behavior wired) ──────────────────

class _StubLibroGateway implements LibroReservationGateway {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubLibroHttpClient implements LibroHttpClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubLibroTimezoneConverter implements LibroTimezoneConverter {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubOpenTableTransport implements OpenTableTransport {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubOpenTableGateway implements OpenTableGateway {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSevenRoomsGateway implements SevenRoomsReservationGateway {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSevenRoomsAuthClient implements SevenRoomsAuthClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSevenRoomsWebhookClient implements SevenRoomsWebhookClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSevenRoomsReservationsClient
    implements SevenRoomsReservationsClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubTockTransport implements TockApiClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubTockFactSink implements TockFactSink {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}
