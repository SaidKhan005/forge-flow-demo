// integration_test/admin_pressure/setup_feature_flags/scenario_setup_ff_01_flag_list_renders.dart
//
// Setup/FF-01: Launch controls renders the flag list.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Setup/FF-01: flag list renders', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminFeatureFlagsRouteId);

    expectAdminKey('admin_feature_flags_screen');
    expectAdminKey('admin_feature_flags_list');
  });
}
