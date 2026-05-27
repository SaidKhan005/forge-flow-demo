// integration_test/admin_pressure/ops_members/scenario_ops_mem_03_suspend_requires_admin_reason.dart
//
// Ops/Mem-03: suspending a team member must open the audited reason gate
// and refuse submission without a reason.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/Mem-03: member suspend action requires an admin reason', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);
    await tapAdminClusterRoute(tester, kAdminMembersRouteId);

    expectAdminKey('admin_members_screen');
    await tapAdminKey(
      tester,
      'admin_members_row_actions_demo-user-diner-owner',
    );
    await tapAdminLabel(tester, 'Suspend');

    expectAdminKey('admin_members_reason_dialog');
    await tapAdminKey(tester, 'admin_members_reason_submit');

    expect(find.text('Add a reason before continuing.'), findsOneWidget);
  });
}
