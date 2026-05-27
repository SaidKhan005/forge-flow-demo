// integration_test/admin_pressure/setup_integrations/scenario_setup_int_01_provider_tiles_render.dart
//
// Setup/Int-01: Connected services renders provider tiles.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Setup/Int-01: provider tiles render', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await tapAdminNav(tester, kAdminIntegrationsRouteId);

    expectAdminKey('admin_integrations_screen');
    expectAdminKey('admin_integrations_provider_anthropic');
    expectAdminKey('admin_integrations_provider_sendgrid');
  });
}
