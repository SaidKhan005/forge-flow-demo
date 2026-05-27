// Scenario Ops/DA-01 (data accuracy table).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/DA-01: Data accuracy renders for a selected location', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerTorontoLocationScope(tester);
    await tapAdminClusterRoute(tester, kAdminDataAccuracyRouteId);

    expectAdminKey('admin_data_accuracy_screen');
    expectAdminKey('operator_web_data_accuracy_screen');
    expectAdminKey('data_accuracy_covers_source_card');
    expectAdminKey('data_accuracy_wage_source_card');
  });
}
