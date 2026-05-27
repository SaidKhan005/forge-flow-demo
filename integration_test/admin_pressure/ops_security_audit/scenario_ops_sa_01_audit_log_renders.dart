// integration_test/admin_pressure/ops_security_audit/scenario_ops_sa_01_audit_log_renders.dart
//
// Ops/SA-01: the per-business audit log renders rows and filters.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/SA-01: audit log renders', (tester) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);
    await tapAdminClusterRoute(tester, kAdminAuditedSupportActionsRouteId);

    expectAdminKey('admin_audited_support_actions_screen');
    expectAdminKey('admin_asa_filters');
    expectAdminKey('admin_asa_audit_log_list');
  });
}
