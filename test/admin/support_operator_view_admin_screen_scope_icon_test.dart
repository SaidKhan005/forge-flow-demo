// SupportOperatorViewAdminScreen scope-entity icon test.
//
// Pins the canonical scope-icon unification (shared scopeIcon helper):
// the "Business" stat in the consolidated support workspace must render
// the canonical business glyph (apartment), not the legacy admin
// business_outlined. The stat strip is rendered eagerly in the
// StatelessWidget build, so a vanilla pump exercises it without any
// gateway round-trip.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/operator_picker_screen.dart';
import 'package:forge_and_flow/admin/screens/support_operator_view_admin_screen.dart';
import 'package:forge_and_flow/admin/services/demo_audited_support_actions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/theme/scope_icons.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher;
    dispatcher.views.first.physicalSize = const Size(1600, 1200);
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

  testWidgets(
    'Business stat renders the canonical business glyph (apartment), '
    'not the legacy admin business_outlined',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          SupportOperatorViewAdminScreen(
            membersGateway: InMemoryMembersAdminGateway(),
            rolesGateway: InMemoryRolesHierarchySessionsAdminGateway(),
            supportGateway: InMemoryAuditedSupportActionsAdminGateway(),
            actorUserId: 'demo-super-admin',
            pickedOperator: const OperatorPickerResult(
              operatorId: 'op-demo',
              locationId: 'loc-demo',
              operatorBusinessName: 'Demo Diner Co.',
              locationName: 'Toronto Yorkville',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_support_operator_view_screen')),
        findsOneWidget,
      );
      // The canonical business glyph is present; the legacy admin glyph
      // is fully retired from the business stat.
      expect(
        find.byIcon(scopeIcon(kind: ScopeEntityKind.business)),
        findsWidgets,
      );
      expect(find.byIcon(Icons.business_outlined), findsNothing);
    },
  );
}
