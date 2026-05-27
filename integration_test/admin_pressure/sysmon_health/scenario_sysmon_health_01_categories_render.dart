// integration_test/admin_pressure/sysmon_health/scenario_sysmon_health_01_categories_render.dart
//
// Sysmon/Health-01: System health renders summary categories.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Sysmon/Health-01: health categories render', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminHealthRouteId);

    expectAdminKey('admin_health_screen');
    expectAdminKey('admin_health_summary');
    expectAdminKey('admin_health_tabs');
  });
}
