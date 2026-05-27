// Scenario Ops/DA-02 (data accuracy audit history toggle).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/DA-02: Data accuracy audit history controls render', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerTorontoLocationScope(tester);
    await tapAdminClusterRoute(tester, kAdminDataAccuracyRouteId);

    expectAdminKey('admin_data_accuracy_screen');
    expectAdminKey('admin_data_accuracy_audit_panel');
    expectAdminKey('admin_data_accuracy_audit_toggle');
  });
}
