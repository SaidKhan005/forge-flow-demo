// integration_test/admin_pressure/setup_feature_flags/scenario_setup_ff_02_destructive_flag_requires_type_to_confirm.dart
//
// Setup/FF-02: destructive launch-control toggles require type-to-confirm.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Setup/FF-02: destructive flag opens confirmation dialog', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminFeatureFlagsRouteId);

    expectAdminKey('admin_feature_flags_screen');
    await tapAdminKey(
      tester,
      'admin_feature_flag_toggle_00000000-0000-4000-8000-0000000000f1',
    );

    expectAdminKey('admin_feature_flag_danger_dialog');
    expectAdminKey('admin_feature_flag_danger_input');
    expectAdminKey(
      'admin_feature_flag_danger_confirm',
      matcher: findsAtLeast(1),
    );
  });
}
