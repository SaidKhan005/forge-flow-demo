import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/screens/operator_picker_screen.dart';
import 'package:forge_and_flow/admin/screens/support_operator_view_admin_screen.dart';
import 'package:forge_and_flow/admin/services/demo_audited_support_actions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  OperatorPickerResult demoPick() => const OperatorPickerResult(
    operatorId: kDemoDinerOperatorId,
    locationId: kDemoDinerLocationToronto,
    operatorBusinessName: 'Demo Diner Co.',
    locationName: 'Toronto Yorkville',
  );

  void wideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1680, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  SupportOperatorViewAdminScreen buildScreen({bool editingEnabled = true}) {
    return SupportOperatorViewAdminScreen(
      membersGateway: InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      ),
      rolesGateway: InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: kDemoRolesByOperator(),
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
        locationsByOperator: kDemoHierarchyLocationsByOperator(),
        sessionsByOperator: kDemoSessionsByOperator(),
      ),
      supportGateway: InMemoryAuditedSupportActionsAdminGateway(
        auditLogByOperator: kDemoAuditLogByOperator(),
        membersByOperator: kDemoSupportActionsMembersByOperator(),
      ),
      actorUserId: 'demo-super-admin',
      pickedOperator: demoPick(),
      editingEnabled: editingEnabled,
    );
  }

  testWidgets('groups support work into simple scoped tabs', (tester) async {
    wideViewport(tester);
    await tester.pumpWidget(wrap(buildScreen()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_support_operator_view_screen')),
      findsOneWidget,
    );
    expect(find.text('Support workspace'), findsOneWidget);
    expect(find.text('Demo Diner Co.'), findsWidgets);
    expect(find.text('Toronto Yorkville'), findsWidgets);
    expect(
      find.byKey(const Key('admin_support_operator_view_tabs')),
      findsOneWidget,
    );

    expect(find.byKey(const Key('admin_members_screen')), findsOneWidget);

    await tester.tap(find.text('Access'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_roles_hierarchy_sessions_screen')),
      findsOneWidget,
    );

    await tester.tap(find.text('Audit log'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_audited_support_actions_screen')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_asa_filters')), findsOneWidget);
    expect(find.byKey(const Key('admin_asa_audit_log_list')), findsOneWidget);
    expect(find.byKey(const Key('admin_asa_actions_panel')), findsNothing);

    await tester.tap(find.text('Vendors'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_vendor_connections_screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_vendor_connections_not_wired')),
      findsOneWidget,
    );
  });

  testWidgets('read-only support mode keeps mutation affordances hidden', (
    tester,
  ) async {
    wideViewport(tester);
    await tester.pumpWidget(wrap(buildScreen(editingEnabled: false)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_support_operator_view_readonly_banner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_members_readonly_banner')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_members_invite_button')), findsNothing);
  });
}
