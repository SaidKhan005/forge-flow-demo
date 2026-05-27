// integration_test/admin_pressure/ops_business_accounts/scenario_ops_ba_06_setup_tile_navigation.dart
//
// Ops/BA-06: per-business setup navigation opens a scoped route.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/BA-06: setup cluster navigation opens Timing', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerTorontoLocationScope(tester);

    expectAdminKey('admin_nav_per_business_cluster');
    await tapAdminClusterRoute(tester, kAdminTimingSetupRouteId);

    expectAdminKey('admin_timing_setup_screen');
    expectAdminKey('admin_timing_editor_scope_card');
  });
}
