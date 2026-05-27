// integration_test/admin_pressure/ops_security_audit/scenario_ops_sa_02_reset_mfa_disabled_when_not_mfa_fresh.dart
//
// Ops/SA-02: non-fresh share-preview sessions do not expose support actions.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('Ops/SA-02: reset-MFA actions stay hidden when MFA is stale', (
    tester,
  ) async {
    await launchAdminSharePreview(tester);
    await expectAdminShellMounted(tester);
    await selectDemoDinerBusinessScope(tester);
    await tapAdminClusterRoute(tester, kAdminAuditedSupportActionsRouteId);

    expectAdminKey('admin_audited_support_actions_screen');
    expectAdminKey('admin_asa_audit_log_list');
    expectAdminKey('admin_asa_actions_panel', matcher: findsNothing);
    expectAdminKey('admin_asa_reason_dialog', matcher: findsNothing);
  });
}
