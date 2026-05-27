// Scenario Sysmon/Debug-01 (support logs list).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Sysmon/Debug-01: Support logs list shell renders', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminDebugConsoleRouteId);

    expectAdminKey('admin_debug_console_screen');
    expectAdminKey('admin_debug_console_request_log_body');
    expect(find.text('Support logs'), findsAtLeast(1));
  });
}
