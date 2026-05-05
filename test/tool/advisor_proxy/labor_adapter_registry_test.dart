// Phase 8 Wave B — `8.spine-bridge.0` — labor adapter registry tests.
//
// Verifies the registry binds all 6 Wave B labor / scheduling adapters
// by vendorId and that lookup short-circuits on unknown vendors. No
// live HTTP, no Postgres. Stubs use `noSuchMethod` so the per-vendor
// abstract surface area is not re-spelled here.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/adp_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/agendrix_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/humanity_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/push_operations_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/quickbooks_time_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';

import '../../../tool/advisor_proxy/labor_adapter_registry.dart';

void main() {
  group('kLaborAdapters registry', () {
    test('exposes exactly the 6 Wave B labor vendor ids', () {
      expect(
        registeredLaborVendorIds.toSet(),
        <String>{
          kAdpVendorId,
          agendrixVendorId,
          kHumanityVendorId,
          pushOperationsVendorId,
          kQuickBooksTimeVendorId,
          kSevenShiftsVendorId,
        },
      );
      expect(registeredLaborVendorIds, hasLength(6));
    });

    test('lookupLaborAdapter returns null on unknown vendor', () {
      final result = lookupLaborAdapter(
        'unknown_labor_vendor',
        deps: AdpLaborAdapterDeps(
          transport: _StubAdpTransport(),
          gateway: _StubAdpGateway(),
        ),
      );
      expect(result, isNull);
    });

    test('lookupLaborAdapter throws ArgumentError on deps/vendorId mismatch',
        () {
      expect(
        () => lookupLaborAdapter(
          kSevenShiftsVendorId,
          deps: AdpLaborAdapterDeps(
            transport: _StubAdpTransport(),
            gateway: _StubAdpGateway(),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('every registered adapter implements LaborAdapter', () {
      final cases = <String, LaborAdapter>{
        kAdpVendorId: lookupLaborAdapter(
          kAdpVendorId,
          deps: AdpLaborAdapterDeps(
            transport: _StubAdpTransport(),
            gateway: _StubAdpGateway(),
          ),
        )!,
        agendrixVendorId: lookupLaborAdapter(
          agendrixVendorId,
          deps: AgendrixLaborAdapterDeps(
            apiClient: _StubAgendrixApiClient(),
            canonicalSink: _StubAgendrixCanonicalSink(),
          ),
        )!,
        kHumanityVendorId: lookupLaborAdapter(
          kHumanityVendorId,
          deps: HumanityLaborAdapterDeps(
            httpClient: _StubHumanityHttpClient(),
            gateway: _StubHumanityGateway(),
          ),
        )!,
        pushOperationsVendorId: lookupLaborAdapter(
          pushOperationsVendorId,
          deps: PushOperationsLaborAdapterDeps(
            apiClient: _StubPushOperationsApiClient(),
            canonicalSink: _StubPushOperationsCanonicalSink(),
          ),
        )!,
        kQuickBooksTimeVendorId: lookupLaborAdapter(
          kQuickBooksTimeVendorId,
          deps: QuickBooksTimeLaborAdapterDeps(
            transport: _StubQuickBooksTimeTransport(),
            gateway: _StubQuickBooksTimeGateway(),
          ),
        )!,
        kSevenShiftsVendorId: lookupLaborAdapter(
          kSevenShiftsVendorId,
          deps: SevenShiftsLaborAdapterDeps(
            transport: _StubSevenShiftsTransport(),
            gateway: _StubSevenShiftsGateway(),
          ),
        )!,
      };

      expect(cases, hasLength(6));
      cases.forEach((vendorId, adapter) {
        expect(adapter, isA<LaborAdapter>(),
            reason: '$vendorId must implement LaborAdapter');
        expect(adapter.vendorId, vendorId,
            reason: '$vendorId adapter.vendorId must match registry key');
      });
    });

    test(
        'lookupLaborCapability returns the VendorCapabilityProfile for every '
        'registered vendor and null for unknown vendors', () {
      expect(lookupLaborCapability('unknown_labor_vendor'), isNull);

      for (final vendorId in registeredLaborVendorIds) {
        final profile = lookupLaborCapability(vendorId);
        expect(profile, isNotNull,
            reason: 'lookupLaborCapability($vendorId) must not be null');
        expect(profile!.vendorId, vendorId);
        expect(profile.category, IntegrationCategory.labor);
      }

      expect(kLaborCapabilityProfiles.keys.toSet(),
          registeredLaborVendorIds.toSet());
    });

    test(
        'ADP capability profile carries webhookSupport.autoRegister '
        '(architecture amendment: ADP is NOT pollOnly)', () {
      // The cadence picker keys off this field. ADP must enroll
      // through the webhook auto-register path, not the pollOnly path.
      final adp = lookupLaborCapability(kAdpVendorId);
      expect(adp, isNotNull);
      expect(adp!.webhookSupport, VendorWebhookSupport.autoRegister,
          reason:
              'ADP capability MUST be autoRegister; if this assertion '
              'fires, the architecture amendment regressed and the cadence '
              'picker would wrongly enroll ADP in the pollOnly cohort.');
    });

    test(
        'capability mirror does not drift from each adapter\'s runtime '
        'capabilityProfile', () {
      final adapters = <String, LaborAdapter>{
        kAdpVendorId: lookupLaborAdapter(
          kAdpVendorId,
          deps: AdpLaborAdapterDeps(
            transport: _StubAdpTransport(),
            gateway: _StubAdpGateway(),
          ),
        )!,
        agendrixVendorId: lookupLaborAdapter(
          agendrixVendorId,
          deps: AgendrixLaborAdapterDeps(
            apiClient: _StubAgendrixApiClient(),
            canonicalSink: _StubAgendrixCanonicalSink(),
          ),
        )!,
        kHumanityVendorId: lookupLaborAdapter(
          kHumanityVendorId,
          deps: HumanityLaborAdapterDeps(
            httpClient: _StubHumanityHttpClient(),
            gateway: _StubHumanityGateway(),
          ),
        )!,
        pushOperationsVendorId: lookupLaborAdapter(
          pushOperationsVendorId,
          deps: PushOperationsLaborAdapterDeps(
            apiClient: _StubPushOperationsApiClient(),
            canonicalSink: _StubPushOperationsCanonicalSink(),
          ),
        )!,
        kQuickBooksTimeVendorId: lookupLaborAdapter(
          kQuickBooksTimeVendorId,
          deps: QuickBooksTimeLaborAdapterDeps(
            transport: _StubQuickBooksTimeTransport(),
            gateway: _StubQuickBooksTimeGateway(),
          ),
        )!,
        kSevenShiftsVendorId: lookupLaborAdapter(
          kSevenShiftsVendorId,
          deps: SevenShiftsLaborAdapterDeps(
            transport: _StubSevenShiftsTransport(),
            gateway: _StubSevenShiftsGateway(),
          ),
        )!,
      };

      adapters.forEach((vendorId, adapter) {
        final mirror = kLaborCapabilityProfiles[vendorId];
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

class _StubAdpTransport implements AdpTransport {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubAdpGateway implements AdpGateway {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubAgendrixApiClient implements AgendrixApiClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubAgendrixCanonicalSink implements AgendrixCanonicalSink {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubHumanityHttpClient implements HumanityHttpClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubHumanityGateway implements HumanityGateway {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubPushOperationsApiClient implements PushOperationsApiClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubPushOperationsCanonicalSink
    implements PushOperationsCanonicalSink {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubQuickBooksTimeTransport implements QuickBooksTimeTransport {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubQuickBooksTimeGateway implements QuickBooksTimeGateway {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSevenShiftsTransport implements SevenShiftsTransport {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}

class _StubSevenShiftsGateway implements SevenShiftsGateway {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('stub for spine-bridge.0 type-check');
}
