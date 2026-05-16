// GAP B3 — admin audit-log scope-picker rootNode builder.
//
// Converts the flat org-unit + location lists already returned by the
// existing [RolesHierarchySessionsAdminGateway] (the gateway the admin
// Access / Roles + Hierarchy tab uses) into the
// [InheritanceTreeNode] graph the shared [InheritanceTree] widget
// expects. This is the admin analogue of the operator-web
// `_buildInheritanceRoot` in
// `lib/operator_web/screens/audit_log_hierarchy_filter_pane.dart`
// (Lane B B8.b parity) — same Business → Org Unit → Location chain,
// same alphabetical child ordering, same single-root collapse.
//
// No proxy route, no new gateway method: this helper only re-shapes
// data the admin Roles/Hierarchy surface already loads. Pure value
// transform — no I/O, no Flutter import.
//
// When the gateway returns no org units the builder returns `null`;
// the audit-log surface then renders its existing manual scope
// fallback rather than an empty tree.

import '../../domain/models/inheritance_tree_node.dart';
import 'roles_hierarchy_sessions_admin_gateway.dart';

/// Stable scope id for the synthetic "Whole business" root used when
/// the operator has multiple org-unit roots (no single corp root).
const String kAdminAuditLogHierarchyRootScopeId =
    'admin_audit_log_hierarchy_root';

/// Builds the Business → Org Unit → Location tree for the admin
/// audit-log scope picker from the flat lists the
/// [RolesHierarchySessionsAdminGateway] already exposes.
///
/// Returns `null` when [orgUnits] is empty so the caller can fall back
/// to the manual scope inputs.
InheritanceTreeNode? buildAuditLogAdminRootNode({
  required List<OrgUnitAdminNode> orgUnits,
  required List<HierarchyLocationLeaf> locations,
}) {
  if (orgUnits.isEmpty) {
    return null;
  }

  final byParent = <String?, List<OrgUnitAdminNode>>{};
  for (final unit in orgUnits) {
    byParent
        .putIfAbsent(unit.parentOrgUnitId, () => <OrgUnitAdminNode>[])
        .add(unit);
  }
  for (final list in byParent.values) {
    list.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  final locationsByParent = <String, List<HierarchyLocationLeaf>>{};
  for (final location in locations) {
    locationsByParent
        .putIfAbsent(location.orgUnitId, () => <HierarchyLocationLeaf>[])
        .add(location);
  }
  for (final list in locationsByParent.values) {
    list.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  final roots = byParent[null] ?? const <OrgUnitAdminNode>[];
  if (roots.isEmpty) {
    // Defensive: org units exist but none is a root (cyclic / orphaned
    // parent ids). Treat every node as a child of a synthetic root so
    // the picker still renders rather than silently dropping rows.
    final orphanChildren = <InheritanceTreeNode>[
      for (final unit in orgUnits)
        _buildUnitNode(
          unit,
          depth: 1,
          byParent: <String?, List<OrgUnitAdminNode>>{},
          locationsByParent: locationsByParent,
        ),
    ]..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    return InheritanceTreeNode(
      scopeKind: InheritanceTreeScopeKind.business,
      scopeId: kAdminAuditLogHierarchyRootScopeId,
      displayName: 'Whole business',
      children: List<InheritanceTreeNode>.unmodifiable(orphanChildren),
    );
  }

  if (roots.length == 1) {
    return _buildUnitNode(
      roots.single,
      depth: 0,
      byParent: byParent,
      locationsByParent: locationsByParent,
    );
  }

  final children = <InheritanceTreeNode>[
    for (final root in roots)
      _buildUnitNode(
        root,
        depth: 1,
        byParent: byParent,
        locationsByParent: locationsByParent,
      ),
  ];
  return InheritanceTreeNode(
    scopeKind: InheritanceTreeScopeKind.business,
    scopeId: kAdminAuditLogHierarchyRootScopeId,
    displayName: 'Whole business',
    children: List<InheritanceTreeNode>.unmodifiable(children),
  );
}

InheritanceTreeNode _buildUnitNode(
  OrgUnitAdminNode unit, {
  required int depth,
  required Map<String?, List<OrgUnitAdminNode>> byParent,
  required Map<String, List<HierarchyLocationLeaf>> locationsByParent,
}) {
  final childOrgUnits =
      byParent[unit.orgUnitId] ?? const <OrgUnitAdminNode>[];
  final childLocations =
      locationsByParent[unit.orgUnitId] ?? const <HierarchyLocationLeaf>[];
  final childNodes = <InheritanceTreeNode>[
    for (final child in childOrgUnits)
      _buildUnitNode(
        child,
        depth: depth + 1,
        byParent: byParent,
        locationsByParent: locationsByParent,
      ),
    for (final location in childLocations)
      InheritanceTreeNode(
        scopeKind: InheritanceTreeScopeKind.location,
        scopeId: location.locationId,
        displayName: location.name,
        parentScopeId: location.orgUnitId,
        depth: depth + 1,
      ),
  ]..sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
  return InheritanceTreeNode(
    scopeKind: unit.parentOrgUnitId == null
        ? InheritanceTreeScopeKind.business
        : InheritanceTreeScopeKind.orgUnit,
    scopeId: unit.orgUnitId,
    displayName: unit.name,
    parentScopeId: unit.parentOrgUnitId,
    depth: depth,
    children: List<InheritanceTreeNode>.unmodifiable(childNodes),
  );
}
