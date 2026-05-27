// integration_test/admin_pressure/setup_default_roles/scenario_setup_dr_01_versions_list_renders.dart
//
// Setup/DR-01: Default roles renders current/draft/history panels.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Setup/DR-01: default role versions render', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminDefaultRoleCatalogRouteId);

    expectAdminKey('admin_default_role_catalog_screen');
    expectAnyAdminKey(<String>[
      'admin_default_role_catalog_current_panel',
      'admin_default_role_catalog_current_empty',
    ]);
    expectAnyAdminKey(<String>[
      'admin_default_role_catalog_history_panel',
      'admin_default_role_catalog_history_empty',
    ]);
    expectAdminKey('admin_default_role_catalog_publish_button');
  });
}
