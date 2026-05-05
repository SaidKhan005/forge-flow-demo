// Admin vendor status catalog drift tests.
//
// The proxy bootstrap reads a pure Dart copy of adapter capability
// metadata so `dart compile exe` does not pull Flutter-only adapter
// imports into the server binary. This test keeps that pure catalog
// aligned with the implemented adapter registries.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../tool/advisor_proxy/labor_adapter_registry.dart';
import '../../../tool/advisor_proxy/pos_adapter_registry.dart';
import '../../../tool/advisor_proxy/reservation_adapter_registry.dart';
import '../../../tool/advisor_proxy/vendor_admin_status_catalog.dart';

void main() {
  test('admin-visible vendor status catalog matches adapter registries', () {
    final registryProfiles = <String, VendorCapabilityProfile>{
      ...kPosCapabilityProfiles,
      ...kReservationCapabilityProfiles,
      ...kLaborCapabilityProfiles,
    };
    final adminProfiles = <String, VendorCapabilityProfile>{
      for (final profile in kAdminVisibleVendorCapabilityProfiles)
        profile.vendorId: profile,
    };

    expect(adminProfiles.keys.toSet(), registryProfiles.keys.toSet());
    expect(adminProfiles, hasLength(17));

    for (final entry in registryProfiles.entries) {
      final actual = adminProfiles[entry.key]!;
      final expected = entry.value;
      expect(actual.displayName, expected.displayName, reason: entry.key);
      expect(actual.category, expected.category, reason: entry.key);
      expect(actual.authMode, expected.authMode, reason: entry.key);
      expect(actual.grantScope, expected.grantScope, reason: entry.key);
      expect(actual.webhookSupport, expected.webhookSupport, reason: entry.key);
      expect(
        actual.coversFieldExposed,
        expected.coversFieldExposed,
        reason: entry.key,
      );
      expect(actual.lifecycle, expected.lifecycle, reason: entry.key);
      expect(actual.modules, expected.modules, reason: entry.key);
    }
  });
}
