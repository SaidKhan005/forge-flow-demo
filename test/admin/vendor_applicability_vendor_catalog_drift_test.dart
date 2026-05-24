// Drift guard: the friendly Vendor applicability screen keeps a
// `lib/`-side projection of the admin-visible vendor catalog
// (`kAdminVendorApplicabilityOptions`) because `lib/` app code must not
// import the proxy's `tool/` catalog. This test fails the moment the
// two diverge on any field the screen renders (display name, category,
// covers-field exposure, webhook support) or on the vendor set itself.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/vendor_applicability_vendor_catalog.dart';

import '../../tool/advisor_proxy/vendor_admin_status_catalog.dart';

void main() {
  test('lib vendor option catalog matches the proxy admin catalog', () {
    final libById = <String, AdminVendorOption>{
      for (final option in kAdminVendorApplicabilityOptions)
        option.vendorId: option,
    };
    final proxyById = <String, dynamic>{
      for (final profile in kAdminVisibleVendorCapabilityProfiles)
        profile.vendorId: profile,
    };

    expect(libById.keys.toSet(), proxyById.keys.toSet());
    expect(libById, hasLength(17));

    for (final entry in proxyById.entries) {
      final lib = libById[entry.key]!;
      final proxy = entry.value;
      expect(lib.displayName, proxy.displayName, reason: entry.key);
      expect(lib.category, proxy.category, reason: entry.key);
      expect(
        lib.coversFieldExposed,
        proxy.coversFieldExposed,
        reason: entry.key,
      );
      expect(lib.webhookSupport, proxy.webhookSupport, reason: entry.key);
    }
  });
}
