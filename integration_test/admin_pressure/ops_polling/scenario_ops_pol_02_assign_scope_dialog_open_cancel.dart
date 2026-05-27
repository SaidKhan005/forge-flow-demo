// integration_test/admin_pressure/ops_polling/scenario_ops_pol_02_assign_scope_dialog_open_cancel.dart
//
// Ops/Pol-02: scope assignment opens and cancels from Polling Setup.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/Pol-02: polling assign-scope dialog opens and cancels', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);
    await tapAdminClusterRoute(tester, kAdminPollingPricingRouteId);

    await tapAdminKey(tester, 'admin_polling_setup_scope_assign');
    expectAdminKey('admin_tier_assignment_dialog');
    expectAdminKey('admin_tier_assignment_dialog_tier');

    await tapAdminKey(tester, 'admin_tier_assignment_dialog_cancel');
    expectAdminKey('admin_polling_pricing_screen');
  });
}
