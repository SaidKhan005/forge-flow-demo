// integration_test/admin_pressure/account_my_account/scenario_account_ma_01_identity_displayed.dart
//
// Account/MA-01: My account renders the signed-in admin identity card.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Account/MA-01: My account identity card renders', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminMyAccountRouteId);

    expectAdminKey('admin_my_account_screen');
    expectAdminKey('admin_my_account_identity_card');
    expectAdminKey('admin_my_account_role_badge');
  });
}
