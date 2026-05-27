// integration_test/admin_pressure/ops_timing/scenario_ops_tim_01_resolution_renders.dart
//
// Ops/Tim-01: Service periods renders the effective timing editor.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/Tim-01: timing resolution renders', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerTorontoLocationScope(tester);
    await tapAdminClusterRoute(tester, kAdminTimingSetupRouteId);

    expectAdminKey('admin_timing_setup_screen');
    expectAdminKey('admin_timing_setup_screen_body');
    expectAdminKey('admin_timing_editor_scope_card');
    expectAdminKey('admin_timing_editor_periods');
  });
}
