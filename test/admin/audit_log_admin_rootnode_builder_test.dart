// GAP B3 — admin audit-log scope-picker rootNode wiring tests.
//
// Proves the wiring that closes GAP B3:
//
//   * `buildAuditLogAdminRootNode` folds the flat org-unit + location
//     lists the EXISTING RolesHierarchySessionsAdminGateway exposes
//     into the Business → Org Unit → Location tree the shared
//     InheritanceTree widget consumes.
//   * Fed by the real demo gateway (the same gateway the Access /
//     Roles + Hierarchy admin tab uses), the built rootNode makes
//     AuditLogAdminScreen render the InheritanceTree picker — NOT the
//     manual text-field fallback.
//   * Empty org units → null rootNode → screen keeps its honest
//     text-field fallback (no regression).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/audit_log_admin_screen.dart';
import 'package:forge_and_flow/admin/services/audit_log_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/audit_log_admin_rootnode_builder.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart'
    show kDemoDinerOperatorId, kDemoSunsetOperatorId;
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/inheritance_tree_node.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  group('buildAuditLogAdminRootNode', () {
    test('returns null when the gateway exposes no org units '
        '(text-field fallback preserved)', () {
      final rootNode = buildAuditLogAdminRootNode(
        orgUnits: const <OrgUnitAdminNode>[],
        locations: const <HierarchyLocationLeaf>[],
      );
      expect(rootNode, isNull);
    });

    test('folds the demo gateway hierarchy into a Business → Org Unit '
        '→ Location tree', () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
        locationsByOperator: kDemoHierarchyLocationsByOperator(),
      );
      final orgUnits =
          await gateway.listOrgUnits(operatorId: kDemoDinerOperatorId);
      final locations = await gateway.listHierarchyLocations(
        operatorId: kDemoDinerOperatorId,
      );

      final root = buildAuditLogAdminRootNode(
        orgUnits: orgUnits,
        locations: locations,
      )!;

      // Single corp root collapses to the real root node (not the
      // synthetic "Whole business" wrapper).
      expect(root.scopeKind, InheritanceTreeScopeKind.business);
      expect(root.displayName, 'Demo Diner Co.');
      // East + West regions, alphabetically ordered.
      expect(root.children.map((n) => n.displayName).toList(),
          <String>['East region', 'West region']);
      final east = root.children.first;
      expect(east.scopeKind, InheritanceTreeScopeKind.orgUnit);
      // Location leaf hangs under its parent org unit.
      expect(east.children.single.scopeKind,
          InheritanceTreeScopeKind.location);
      expect(east.children.single.displayName, 'Toronto Yorkville');
    });

    test('multiple roots collapse under a synthetic Whole business root',
        () async {
      final gateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
        locationsByOperator: kDemoHierarchyLocationsByOperator(),
      );
      // Sunset has a single root; assert the single-root collapse path
      // does not fabricate a synthetic wrapper.
      final orgUnits = await gateway.listOrgUnits(
        operatorId: kDemoSunsetOperatorId,
      );
      final locations = await gateway.listHierarchyLocations(
        operatorId: kDemoSunsetOperatorId,
      );
      final root = buildAuditLogAdminRootNode(
        orgUnits: orgUnits,
        locations: locations,
      )!;
      expect(root.scopeId, isNot(kAdminAuditLogHierarchyRootScopeId));
      expect(root.displayName, 'Sunset Cafe Group');
    });
  });

  group('AuditLogAdminScreen with built rootNode', () {
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

    testWidgets('renders the InheritanceTree picker (not the text-field '
        'fallback) when the org-units source is available', (tester) async {
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
        locationsByOperator: kDemoHierarchyLocationsByOperator(),
      );
      final orgUnits = await hierarchyGateway.listOrgUnits(
        operatorId: kDemoDinerOperatorId,
      );
      final locations = await hierarchyGateway.listHierarchyLocations(
        operatorId: kDemoDinerOperatorId,
      );
      final rootNode = buildAuditLogAdminRootNode(
        orgUnits: orgUnits,
        locations: locations,
      );

      await tester.pumpWidget(
        wrap(
          AuditLogAdminScreen(
            gateway: InMemoryAuditLogAdminGateway(),
            rootNode: rootNode,
          ),
        ),
      );

      // The shared tree widget is present (tree-picker path), keyed
      // `inheritance_tree` by lib/widgets/inheritance_tree.dart.
      expect(find.byKey(const Key('inheritance_tree')), findsOneWidget);
      // The empty-tree placeholder is NOT shown.
      expect(
        find.byKey(const Key('inheritance_tree_empty')),
        findsNothing,
      );
      // Tree rows for the seeded hierarchy render.
      expect(find.text('Demo Diner Co.'), findsOneWidget);
      expect(find.text('Toronto Yorkville'), findsOneWidget);
    });

    testWidgets('keeps the text-field scope fallback when no org units '
        'are available (null rootNode)', (tester) async {
      final rootNode = buildAuditLogAdminRootNode(
        orgUnits: const <OrgUnitAdminNode>[],
        locations: const <HierarchyLocationLeaf>[],
      );

      await tester.pumpWidget(
        wrap(
          AuditLogAdminScreen(
            gateway: InMemoryAuditLogAdminGateway(),
            rootNode: rootNode,
          ),
        ),
      );

      // No tree picker; the manual scope_type control is the fallback.
      expect(find.byKey(const Key('inheritance_tree')), findsNothing);
      expect(
        find.byKey(const Key('admin_audit_log_scope_type')),
        findsOneWidget,
      );
    });
  });
}
