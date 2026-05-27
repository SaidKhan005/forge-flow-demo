// integration_test/admin_pressure/setup_default_roles/scenario_setup_dr_02_publish_dialog_open_and_cancel.dart
//
// Setup/DR-02: Default roles publish action opens the confirmation dialog.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Setup/DR-02: publish dialog opens and cancels', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminDefaultRoleCatalogRouteId);

    await tapAdminKey(tester, 'admin_default_role_catalog_publish_button');
    expectAdminKey('admin_default_role_catalog_publish_dialog');

    await tapAdminKey(tester, 'admin_default_role_catalog_publish_cancel');
    expectAdminKey('admin_default_role_catalog_screen');
  });
}
