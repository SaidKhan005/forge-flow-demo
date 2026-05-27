// integration_test/admin_pressure/account_my_account/scenario_account_ma_02_sessions_list_present.dart
//
// Account/MA-02: My account exposes active session management.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Account/MA-02: active sessions list opens', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminMyAccountRouteId);

    expectAdminKey('admin_my_account_active_sessions_card');
    await tapAdminKey(tester, 'admin_my_account_active_sessions_manage');

    expectAdminKey('admin_my_account_active_sessions_dialog');
    expectAdminKey('admin_my_account_current_session_row');
  });
}
