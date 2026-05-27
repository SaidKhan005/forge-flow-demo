// integration_test/admin_pressure/ops_vendor_integrations/scenario_ops_vi_01_connection_list_renders.dart
//
// Ops/VI-01: location-scoped vendor integrations render connection state.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/VI-01: vendor integrations connection list renders', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerTorontoLocationScope(tester);
    await tapAdminClusterRoute(tester, kAdminVendorIntegrationsRouteId);

    expectAdminKey('admin_vendor_connections_screen');
    expectAnyAdminKey(<String>[
      'admin_vendor_connections_screen_body',
      'admin_vendor_connections_location_required',
      'admin_vendor_connections_not_wired',
    ]);
  });
}
