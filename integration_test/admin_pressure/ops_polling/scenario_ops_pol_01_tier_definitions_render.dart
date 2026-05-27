// integration_test/admin_pressure/ops_polling/scenario_ops_pol_01_tier_definitions_render.dart
//
// Ops/Pol-01: Polling Setup renders tier definitions and assignment table.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/Pol-01: polling tier definitions render', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);
    await tapAdminClusterRoute(tester, kAdminPollingPricingRouteId);

    expectAdminKey('admin_polling_pricing_screen');
    expectAdminKey('admin_tier_assignment_table');
    expectAdminKey('admin_polling_cost_calculator');
  });
}
