// Scenario Sysmon/Debug-02 (support logs scope filter).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Sysmon/Debug-02: Support logs expose scope filter controls', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminDebugConsoleRouteId);

    expectAdminKey('admin_debug_console_screen');
    expectAdminKey('admin_debug_console_scope_body');
    expectAdminKey('admin_debug_console_request_log_body');
  });
}
