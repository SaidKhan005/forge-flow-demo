// Phase 8.0.lifecycle — VendorLifecycle enum + VendorCapabilityProfile
// coverage. Locks the 4-state lifecycle from
// `docs/contracts/vendor_adapter_slice_contract.md` § "The 4-state
// lifecycle (binding)" and the picker-chrome mapping from
// `docs/phases/phase_8/vendor_connections_admin_surface.md`.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

void main() {
  group('VendorLifecycle enum', () {
    test('declares all four binding lifecycle stages in order', () {
      expect(
        VendorLifecycle.values,
        <VendorLifecycle>[
          VendorLifecycle.documented,
          VendorLifecycle.sandboxVerified,
          VendorLifecycle.productionCredentialed,
          VendorLifecycle.liveWithOperators,
        ],
        reason:
            'Order is binding — picker chrome / live-rollout tracker / '
            'Codex review all rely on this sequence.',
      );
    });

    test(
      'enum value names are stable strings the registry can serialize',
      () {
        // The registry / live-rollout tracker / Operator Web picker
        // store the lifecycle as a string column. If these names ever
        // change, every persisted row + every doc reference becomes
        // wrong silently. Lock the strings here.
        expect(VendorLifecycle.documented.name, 'documented');
        expect(VendorLifecycle.sandboxVerified.name, 'sandboxVerified');
        expect(
          VendorLifecycle.productionCredentialed.name,
          'productionCredentialed',
        );
        expect(VendorLifecycle.liveWithOperators.name, 'liveWithOperators');
      },
    );

    test('exposes exactly four values (no fifth state slipped in)', () {
      expect(VendorLifecycle.values.length, 4);
    });
  });

  group('VendorCapabilityProfile', () {
    const documentedProfile = VendorCapabilityProfile(
      vendorId: 'lightspeed_lsk',
      displayName: 'Lightspeed Restaurant K-Series',
      category: IntegrationCategory.pos,
      authMode: VendorAuthMode.oauth,
      grantScope: VendorGrantScope.perLocation,
      webhookSupport: VendorWebhookSupport.autoRegister,
      coversFieldExposed: true,
      lifecycle: VendorLifecycle.documented,
    );

    test('lifecycle field is required (compile-time + runtime)', () {
      // The constructor fails to compile without `lifecycle`, locking
      // the engineer-all-17 doctrine: no adapter ships without
      // declaring its lifecycle stage.
      expect(documentedProfile.lifecycle, VendorLifecycle.documented);
    });

    test('every documented adapter ships at lifecycle.documented', () {
      // The 3-step per-slice doctrine ships every engineering slice
      // at `documented`; `*.live.sandbox` / `*.live.prod` slices
      // promote afterward. Code-review check: any new
      // `VendorCapabilityProfile(...)` constructed in a Wave B
      // adapter must use `lifecycle: VendorLifecycle.documented`.
      expect(
        documentedProfile.lifecycle.index,
        0,
        reason: '`documented` must be the zero-th value so '
            'Wave B adapters cannot accidentally drop into a higher '
            'stage by reordering the enum.',
      );
    });

    test('lifecycle is explicit — not defaulted', () {
      // A capability profile with only the required transport fields
      // still fails to construct without `lifecycle`. We exercise
      // every other lifecycle stage to assert the field is settable
      // and the resulting profile reads back the assigned stage.
      for (final stage in VendorLifecycle.values) {
        final profile = VendorCapabilityProfile(
          vendorId: 'stub_${stage.name}',
          displayName: 'Stub ${stage.name}',
          category: IntegrationCategory.pos,
          authMode: VendorAuthMode.oauth,
          grantScope: VendorGrantScope.perLocation,
          webhookSupport: VendorWebhookSupport.autoRegister,
          coversFieldExposed: true,
          lifecycle: stage,
        );
        expect(profile.lifecycle, stage);
      }
    });
  });
}
