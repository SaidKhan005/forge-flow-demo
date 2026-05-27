// integration_test/admin_pressure/ops_business_accounts/scenario_ops_ba_05_org_unit_tree_renders_with_actions.dart
//
// Ops/BA-05: the hierarchy tree renders org units, locations, and actions.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart'
    show kDemoDinerLocationToronto;
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart'
    show kDemoDinerOrgUnitEast;

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/BA-05: org-unit tree renders with actions', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);

    expectAdminKey('admin_hierarchy_business_scope_row');
    expectAdminKey('admin_setup_scope_org_unit_$kDemoDinerOrgUnitEast');
    expectAdminKey('admin_setup_scope_location_$kDemoDinerLocationToronto');
    expectAdminKey('admin_hierarchy_org_unit_more_$kDemoDinerOrgUnitEast');
  });
}
