// integration_test/admin_pressure/ops_business_accounts/scenario_ops_ba_03_account_profile_dialog_open_and_cancel.dart
//
// Ops/BA-03: account profile edit dialog opens and cancels cleanly.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/BA-03: account profile dialog opens and cancels', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);

    await tapAdminKey(tester, 'admin_operator_edit_button');
    expectAdminKey('admin_edit_operator_dialog');
    expectAdminKey('admin_edit_business_name');

    await tapAdminKey(tester, 'admin_edit_cancel_button');
    expectAdminKey('admin_operator_profile_card');
  });
}
