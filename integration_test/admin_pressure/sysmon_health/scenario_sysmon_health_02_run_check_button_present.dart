// integration_test/admin_pressure/sysmon_health/scenario_sysmon_health_02_run_check_button_present.dart
//
// Sysmon/Health-02: System health exposes the manual refresh/check action.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Sysmon/Health-02: run-check button is present', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminHealthRouteId);

    expectAdminKey('admin_health_screen');
    expectAdminKey('admin_health_refresh_button');
  });
}
