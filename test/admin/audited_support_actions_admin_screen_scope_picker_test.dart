// Admin Audit log scope exception tests.
//
// The audit tab itself must mirror ops/operator-web. The only
// intentional admin difference is the business/scope picker in the
// left admin workspace shell, so the right-side audit surface must not
// mount its former in-screen scope picker or scope banner.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/audited_support_actions_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/operator_picker_screen.dart';
import 'package:forge_and_flow/admin/services/demo_audited_support_actions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart'
    show kDemoDinerLocationToronto, kDemoDinerOperatorId;
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher;
    dispatcher.views.first.physicalSize = const Size(1600, 1600);
    dispatcher.views.first.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher;
    dispatcher.views.first.resetPhysicalSize();
    dispatcher.views.first.resetDevicePixelRatio();
  });

  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  const picked = OperatorPickerResult(
    operatorId: kDemoDinerOperatorId,
    locationId: '',
    operatorBusinessName: 'Demo Diner Co.',
    locationName: '',
  );

  Future<void> pumpAuditScreen(
    WidgetTester tester, {
    AdminHierarchyScopeIntent? hierarchyScope,
  }) async {
    await tester.pumpWidget(
      wrap(
        AuditedSupportActionsAdminScreen(
          gateway: InMemoryAuditedSupportActionsAdminGateway(
            auditLogByOperator: kDemoAuditLogByOperator(),
          ),
          actorUserId: 'demo-super-admin',
          pickedOperator: picked,
          hierarchyScope: hierarchyScope,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('does not render the old in-screen scope picker', (tester) async {
    await pumpAuditScreen(tester);

    expect(find.byKey(const Key('admin_asa_audit_scope_picker')), findsNothing);
    expect(find.byKey(const Key('inheritance_tree')), findsNothing);
    expect(find.byKey(const Key('admin_asa_scope_banner')), findsNothing);
    expect(find.byKey(const Key('admin_asa_filters')), findsOneWidget);
    expect(find.byKey(const Key('admin_asa_audit_log_list')), findsOneWidget);
  });

  testWidgets('ignores the old read-only scope banner fallback', (
    tester,
  ) async {
    await pumpAuditScreen(
      tester,
      hierarchyScope: const AdminHierarchyScopeIntent.location(
        operatorId: kDemoDinerOperatorId,
        locationId: kDemoDinerLocationToronto,
        operatorName: 'Demo Diner Co.',
        locationName: 'Toronto Yorkville',
        valueState: AdminHierarchyScopeValueState.locationOnly,
      ),
    );

    expect(find.byKey(const Key('admin_asa_scope_banner')), findsNothing);
    expect(find.byKey(const Key('admin_asa_filters')), findsOneWidget);
  });
}
