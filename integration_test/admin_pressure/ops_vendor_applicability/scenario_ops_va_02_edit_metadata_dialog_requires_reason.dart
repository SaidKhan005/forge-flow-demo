// integration_test/admin_pressure/ops_vendor_applicability/scenario_ops_va_02_edit_metadata_dialog_requires_reason.dart
//
// Ops/VA-02: the vendor-applicability edit dialog requires an admin reason.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/VA-02: vendor-applicability edit dialog rejects empty reason',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminVendorApplicabilityRouteId);

      expectAdminKey('admin_vendor_applicability_screen');
      await tapAdminKey(tester, 'admin_vendor_applicability_add');

      expectAdminKey('admin_vendor_applicability_edit_dialog');
      expectAdminKey('admin_vendor_applicability_reason');

      await tapAdminKey(tester, 'admin_vendor_applicability_submit');

      final dialogStillOpen = isAdminKeyMounted(
        'admin_vendor_applicability_edit_dialog',
      );
      final dialogError = isAdminKeyMounted(
        'admin_vendor_applicability_dialog_error',
      );
      expect(dialogStillOpen || dialogError, isTrue);

      expect(tap.overflowErrors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
