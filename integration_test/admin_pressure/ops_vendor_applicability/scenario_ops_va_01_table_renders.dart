// integration_test/admin_pressure/ops_vendor_applicability/scenario_ops_va_01_table_renders.dart
//
// Ops/VA-01: Vendor applicability renders its table and toolbar.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/VA-01: vendor applicability table renders', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminVendorApplicabilityRouteId);

    expectAdminKey('admin_vendor_applicability_screen');
    expectAdminKey('admin_vendor_applicability_toolbar');
    expectAdminKey('admin_vendor_applicability_list');
  });
}
