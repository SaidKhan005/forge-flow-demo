// Scenario Ops/Acc-01 (Access three-tabs: Roles / Hierarchy / Sessions).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/Acc-01: Access opens with roles / hierarchy / sessions shell',
    (tester) async {
      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await selectDemoDinerBusinessScope(tester);
      await tapAdminClusterRoute(tester, kAdminRolesHierarchySessionsRouteId);

      expectAdminKey('admin_roles_hierarchy_sessions_screen');
      expectAdminKey('admin_rhs_roles_screen');
      expect(find.text('Roles'), findsAtLeast(1));
      expect(find.text('Hierarchy'), findsAtLeast(1));
      expect(find.text('Sessions'), findsAtLeast(1));
    },
  );
}
