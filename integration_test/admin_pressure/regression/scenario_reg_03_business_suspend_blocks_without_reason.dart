// integration_test/admin_pressure/regression/scenario_reg_03_business_suspend_blocks_without_reason.dart
//
// Reg-03: business suspend requires an audited reason before it can run.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Reg-03: business suspend blocks without a reason', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);

    await tapAdminKey(tester, 'admin_operator_suspend_button');
    expectAdminKey('admin_operator_suspend_dialog');

    await tapAdminKey(tester, 'admin_operator_suspend_submit');
    expect(find.text('Add a reason before continuing.'), findsOneWidget);
    expectAdminKey('admin_operator_suspend_reason');
  });
}
