// Scenario Ops/Mem-01 (members table).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/Mem-01: Members table renders seeded users', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);
    await tapAdminClusterRoute(tester, kAdminMembersRouteId);

    expectAdminKey('admin_members_screen');
    expectAdminKey('admin_members_row_demo-user-diner-owner');
    expectAdminKey('admin_members_row_demo-user-diner-manager');
  });
}
