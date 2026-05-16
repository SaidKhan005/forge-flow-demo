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
//     the audit surface render the InheritanceTree picker — NOT the
//     manual scope fallback.
//   * Empty org units → null rootNode → the surface keeps its
//     read-only scope-banner fallback (no regression).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/audit_log_admin_rootnode_builder.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart'
    show kDemoDinerOperatorId, kDemoSunsetOperatorId;
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/inheritance_tree_node.dart';

void main() {
  group('buildAuditLogAdminRootNode', () {
    test('returns null when the gateway exposes no org units '
        '(scope-banner fallback preserved)', () {
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

    test('single root collapses without a synthetic Whole business root',
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
}
