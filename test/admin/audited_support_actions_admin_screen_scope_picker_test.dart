// GAP B3 (redirect) — AuditedSupportActionsAdminScreen scope-picker
// widget tests.
//
// The screen F&F admins actually reach via the routed
// `audited-support-actions` ("Security & audit") tile previously had
// no hierarchy tree picker for audit-log scope — scope was fixed
// upstream and rendered read-only. This test proves the redirect:
//
//   * When the route feeds a populated InheritanceTreeNode (built via
//     the reused buildAuditLogAdminRootNode from the EXISTING
//     RolesHierarchySessionsAdminGateway), the screen renders the
//     shared InheritanceTree picker as the DEFAULT scope selector.
//   * When no tree is available (null rootNode — gateway empty / error
//     degradation), the screen keeps the read-only scope banner the
//     upstream hierarchy workspace already supplies. No regression.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/audited_support_actions_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/operator_picker_screen.dart';
import 'package:forge_and_flow/admin/services/audit_log_admin_rootnode_builder.dart';
import 'package:forge_and_flow/admin/services/demo_audited_support_actions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart'
    show kDemoDinerOperatorId, kDemoDinerLocationToronto;
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/inheritance_tree_node.dart';
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

  InMemoryAuditedSupportActionsAdminGateway buildGateway() =>
      InMemoryAuditedSupportActionsAdminGateway();

  Future<InheritanceTreeNode?> builtRootNode() async {
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      locationsByOperator: kDemoHierarchyLocationsByOperator(),
    );
    final orgUnits =
        await hierarchyGateway.listOrgUnits(operatorId: kDemoDinerOperatorId);
    final locations = await hierarchyGateway.listHierarchyLocations(
      operatorId: kDemoDinerOperatorId,
    );
    return buildAuditLogAdminRootNode(
      orgUnits: orgUnits,
      locations: locations,
    );
  }

  testWidgets(
      'renders the InheritanceTree scope picker (not just the read-only '
      'banner) when the org-units source is available', (tester) async {
    final rootNode = await builtRootNode();
    expect(rootNode, isNotNull);

    await tester.pumpWidget(
      wrap(
        AuditedSupportActionsAdminScreen(
          gateway: buildGateway(),
          actorUserId: 'demo-super-admin',
          pickedOperator: picked,
          auditScopeRootNode: rootNode,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The shared tree widget is present (tree-picker path), keyed
    // `inheritance_tree` by lib/widgets/inheritance_tree.dart, inside
    // the GAP B3 scope-picker card.
    expect(
      find.byKey(const Key('admin_asa_audit_scope_picker')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('inheritance_tree')), findsOneWidget);
    expect(
      find.byKey(const Key('inheritance_tree_empty')),
      findsNothing,
    );
    // Tree rows for the seeded hierarchy render.
    expect(find.text('Demo Diner Co.'), findsWidgets);
    expect(find.text('Toronto Yorkville'), findsOneWidget);

    // Tapping a location node updates the scope banner below the tree.
    await tester.tap(find.byKey(const Key('inheritance_tree_tap_'
        '$kDemoDinerLocationToronto')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin_asa_scope_banner')), findsOneWidget);
    expect(find.byKey(const Key('admin_asa_scope_label')), findsOneWidget);
  });

  testWidgets(
      'keeps the read-only scope-banner fallback when no tree is '
      'available (null rootNode)', (tester) async {
    final rootNode = buildAuditLogAdminRootNode(
      orgUnits: const <OrgUnitAdminNode>[],
      locations: const <HierarchyLocationLeaf>[],
    );
    expect(rootNode, isNull);

    await tester.pumpWidget(
      wrap(
        AuditedSupportActionsAdminScreen(
          gateway: buildGateway(),
          actorUserId: 'demo-super-admin',
          pickedOperator: picked,
          auditScopeRootNode: rootNode,
          hierarchyScope: const AdminHierarchyScopeIntent.business(
            operatorId: kDemoDinerOperatorId,
            operatorName: 'Demo Diner Co.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No tree picker card; the upstream read-only scope banner is the
    // graceful fallback.
    expect(
      find.byKey(const Key('admin_asa_audit_scope_picker')),
      findsNothing,
    );
    expect(find.byKey(const Key('inheritance_tree')), findsNothing);
    expect(find.byKey(const Key('admin_asa_scope_banner')), findsOneWidget);
  });
}
