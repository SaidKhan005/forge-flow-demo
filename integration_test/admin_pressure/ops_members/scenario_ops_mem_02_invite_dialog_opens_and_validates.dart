// Scenario Ops/Mem-02 (invite dialog).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/Mem-02: Invite dialog opens from Members', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);
    await tapAdminClusterRoute(tester, kAdminMembersRouteId);

    expectAdminKey('admin_members_screen');
    await tapAdminKey(tester, 'admin_members_invite_button');

    expectAdminKey('admin_members_invite_dialog');
  });
}
