// integration_test/admin_pressure/ops_business_accounts/scenario_ops_ba_02_drill_into_demo_diner.dart
//
// Ops/BA-02: selecting Demo Diner opens the business profile pane.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/BA-02: Demo Diner drill-in opens profile details', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);

    expectAdminKey('admin_operators_screen');
    expectAdminKey('admin_operator_profile_card');
    expectAdminKey('admin_nav_per_business_cluster');
    expect(find.text('Demo Diner Co.'), findsAtLeast(1));
  });
}
