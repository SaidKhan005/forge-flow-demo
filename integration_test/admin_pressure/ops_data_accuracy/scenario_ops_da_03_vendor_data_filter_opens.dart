// Scenario Ops/DA-03 (data accuracy vendor filter).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/DA-03: Data accuracy vendor filter is present', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerTorontoLocationScope(tester);
    await tapAdminClusterRoute(tester, kAdminDataAccuracyRouteId);

    expectAdminKey('admin_data_accuracy_screen');
    expectAdminKey('admin_data_accuracy_vendor_source_filter');
  });
}
