// Shared admin scope-tree pane.
//
// Extracted verbatim (behavior-preserving) from
// `admin_setup_workspace.dart` so the AI setup tabs (Plans and limits,
// Knowledge base, AI Metrics, System health, Launch controls) AND the
// Business accounts screen present scope the SAME way: one searchable
// business -> org unit -> location tree, ONE implementation, no
// copy-paste duplication.
//
// The widget keys and operator-facing copy are unchanged from the
// pre-extraction `_ScopePane` / `_BusinessTreeCard` / `_ScopeRow` so
// every existing `admin_setup_scope_*` test selector keeps matching.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/scope_icons.dart';
import '../admin_route_handoff.dart';
import '../models/operator_location_admin_models.dart';
import '../services/operator_location_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import 'admin_responsive_layout.dart';

const Duration _kScopeAttentionPulseDuration = Duration(milliseconds: 6200);

/// Resolved set of location ids for a selected hierarchy scope.
///
/// Moved here from `admin_setup_workspace.dart` (where it was
/// `AdminSetupWorkspaceSelection`) so both the AI workspace and the
/// Business accounts screen share one selection contract. A type alias
/// in `admin_setup_workspace.dart` keeps the old name compiling for
/// existing callers (e.g. `admin_routes.dart`).
class AdminScopeSelection {
  const AdminScopeSelection({required this.scope, required this.locationIds});

  final AdminHierarchyScopeIntent scope;
  final Set<String> locationIds;
}

/// Left-hand searchable scope tree shared by the AI setup tabs and the
/// Business accounts screen. Renders one [AdminScopeBusinessTreeCard]
/// per business; selecting any node (business / org unit / location)
/// reports the resolved [AdminHierarchyScopeIntent] through
/// [onSelectScope].
class AdminScopeTreePane extends StatelessWidget {
  const AdminScopeTreePane({
    super.key,
    required this.trees,
    required this.searchController,
    required this.selectedScope,
    required this.expandedOperatorIds,
    required this.loading,
    required this.onSelectScope,
    required this.onToggleExpanded,
    required this.forceExpanded,
    this.header,
    this.showAllBusinesses = false,
    this.allBusinessesSelected = false,
    this.onSelectAllBusinesses,
    this.attentionPulseToken = 0,
  });

  final List<AdminScopeTree> trees;
  final TextEditingController searchController;
  final AdminHierarchyScopeIntent? selectedScope;
  final Set<String> expandedOperatorIds;
  final bool loading;
  final ValueChanged<AdminHierarchyScopeIntent> onSelectScope;
  final ValueChanged<String> onToggleExpanded;
  final bool forceExpanded;

  /// Optional widget rendered above the search field. The Business
  /// accounts screen uses this slot to keep its "New business"
  /// onboarding affordance reachable from the scope pane.
  final Widget? header;

  /// When true, an additive "All businesses" row is rendered above the
  /// per-business tree. Opt-in (default off) so screens that are not
  /// platform-aggregate-capable are byte-unaffected. Selecting it yields
  /// the cross-business (platform-wide) view via [onSelectAllBusinesses].
  final bool showAllBusinesses;

  /// Whether the "All businesses" row is the active selection.
  final bool allBusinessesSelected;

  /// Invoked when the operator taps the "All businesses" row.
  final VoidCallback? onSelectAllBusinesses;

  /// Incremented by the shell when it needs to draw attention back to this
  /// pane after a "pick a business first" redirect.
  final int attentionPulseToken;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey<int>(attentionPulseToken),
      tween: Tween<double>(begin: 0, end: attentionPulseToken > 0 ? 1 : 0),
      duration: _kScopeAttentionPulseDuration,
      curve: Curves.linear,
      builder: (context, progress, child) {
        final active = attentionPulseToken > 0 && progress < 1;
        final intensity = attentionPulseToken > 0
            ? Curves.easeOut.transform(1 - progress)
            : 0.0;
        final flash = active
            ? 0.55 + (0.45 * math.sin(progress * math.pi * 16).abs())
            : 0.0;
        final borderAlpha = (0.22 + 0.48 * flash) * intensity;
        return Container(
          key: const Key('admin_setup_workspace_scope_pane'),
          decoration: BoxDecoration(
            color: AppColors.backgroundMid.withValues(alpha: 0.5),
            border: Border.all(
              color: AppColors.sunsetDark.withValues(alpha: borderAlpha),
              width: 3,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(child: child!),
              if (active)
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        isComplex: false,
                        willChange: true,
                        painter: _ScopeAttentionSweepPainter(
                          progress: progress,
                          intensity: intensity,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null) ...[header!, const SizedBox(height: 12)],
            Text(
              'Scope',
              style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              'Choose a business, org unit, or location.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_setup_scope_search'),
              controller: searchController,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search hierarchy',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (showAllBusinesses) ...[
              AdminAllBusinessesScopeButton(
                key: const Key('admin_setup_scope_all_businesses'),
                selected: allBusinessesSelected,
                onTap: onSelectAllBusinesses ?? () {},
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 12),
            ],
            if (loading) const LinearProgressIndicator(minHeight: 2),
            if (loading) const SizedBox(height: 12),
            Expanded(
              child: trees.isEmpty && !loading
                  ? const AdminScopeEmptyState()
                  : ListView.separated(
                      itemCount: trees.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final tree = trees[index];
                        final expanded =
                            forceExpanded ||
                            expandedOperatorIds.contains(
                              tree.operator.operatorId,
                            );
                        return AdminScopeBusinessTreeCard(
                          tree: tree,
                          selectedScope: selectedScope,
                          expanded: expanded,
                          onToggleExpanded: () =>
                              onToggleExpanded(tree.operator.operatorId),
                          onSelectScope: onSelectScope,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScopeAttentionSweepPainter extends CustomPainter {
  const _ScopeAttentionSweepPainter({
    required this.progress,
    required this.intensity,
  });

  final double progress;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0 || size.isEmpty) return;
    final rect = Offset.zero & size;
    final insetRect = rect.deflate(4);
    if (insetRect.isEmpty) return;

    final sweepPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5
      ..color = AppColors.sunset.withValues(alpha: 0.88 * intensity);
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 13
      ..color = AppColors.sunset.withValues(alpha: 0.18 * intensity);

    final startAngle = (progress * math.pi * 2 * 2.2) - math.pi / 2;
    const sweepAngle = math.pi / 2.7;
    canvas.drawArc(insetRect, startAngle, sweepAngle, false, glowPaint);
    canvas.drawArc(insetRect, startAngle, sweepAngle, false, sweepPaint);
  }

  @override
  bool shouldRepaint(_ScopeAttentionSweepPainter oldDelegate) {
    return progress != oldDelegate.progress ||
        intensity != oldDelegate.intensity;
  }
}

/// Platform-wide scope affordance for aggregate-capable admin screens.
///
/// This intentionally reads like the AI Metrics month selector's active
/// segment: filled sunset, white text, and the same row footprint the
/// regular scope row used before.
class AdminAllBusinessesScopeButton extends StatelessWidget {
  const AdminAllBusinessesScopeButton({
    super.key,
    required this.selected,
    required this.onTap,
  });

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.sunset,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.sunset, width: 1),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.public_outlined,
                size: 18,
                color: AppColors.backgroundSurface,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'All businesses',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.buttonLabel(
                        color: AppColors.backgroundSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Every business on the platform',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body11(
                        color: AppColors.backgroundSurface,
                      ).copyWith(fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_circle,
                  size: 17,
                  color: AppColors.backgroundSurface,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One business card in [AdminScopeTreePane]: a selectable business row
/// plus, when expanded, its org-unit / location subtree.
class AdminScopeBusinessTreeCard extends StatelessWidget {
  const AdminScopeBusinessTreeCard({
    super.key,
    required this.tree,
    required this.selectedScope,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onSelectScope,
  });

  final AdminScopeTree tree;
  final AdminHierarchyScopeIntent? selectedScope;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<AdminHierarchyScopeIntent> onSelectScope;

  @override
  Widget build(BuildContext context) {
    final businessScope = AdminHierarchyScopeIntent.business(
      operatorId: tree.operator.operatorId,
      operatorName: tree.operator.businessName,
    );
    return AdminCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdminScopeRow(
            key: Key('admin_setup_scope_business_${tree.operator.operatorId}'),
            icon: scopeIcon(kind: ScopeEntityKind.business),
            label: tree.operator.businessName,
            detail: 'Business scope',
            selected: selectedScope?.cacheKey == businessScope.cacheKey,
            depth: 0,
            onTap: () => onSelectScope(businessScope),
            trailing: IconButton(
              key: Key('admin_setup_scope_expand_${tree.operator.operatorId}'),
              tooltip: expanded ? 'Collapse hierarchy' : 'Expand hierarchy',
              onPressed: onToggleExpanded,
              icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            ..._buildOrgUnitRows(tree.rootOrgUnits, const <String>[]),
            if (tree.unassignedLocations.isNotEmpty)
              for (final location in tree.unassignedLocations)
                _locationRow(location, const <String>[], null),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildOrgUnitRows(
    List<OrgUnitAdminNode> units,
    List<String> parentPath,
  ) {
    final rows = <Widget>[];
    for (final unit in units) {
      final path = <String>[...parentPath, unit.name];
      final scope = AdminHierarchyScopeIntent.orgUnit(
        operatorId: tree.operator.operatorId,
        operatorName: tree.operator.businessName,
        orgUnitId: unit.orgUnitId,
        orgUnitName: unit.name,
        hierarchyPath: parentPath,
      );
      rows.add(
        AdminScopeRow(
          key: Key('admin_setup_scope_org_unit_${unit.orgUnitId}'),
          icon: scopeIcon(kind: ScopeEntityKind.orgUnit),
          label: unit.name,
          detail: 'Org unit scope',
          selected: selectedScope?.cacheKey == scope.cacheKey,
          depth: parentPath.length + 1,
          onTap: () => onSelectScope(scope),
        ),
      );
      final locations =
          tree.locationsByOrgUnit[unit.orgUnitId] ??
          const <AdminScopeWorkspaceLocation>[];
      for (final location in locations) {
        rows.add(_locationRow(location, path, unit));
      }
      rows.addAll(_buildOrgUnitRows(tree.childrenOf(unit), path));
    }
    return rows;
  }

  Widget _locationRow(
    AdminScopeWorkspaceLocation location,
    List<String> parentPath,
    OrgUnitAdminNode? unit,
  ) {
    final scope = AdminHierarchyScopeIntent.location(
      operatorId: tree.operator.operatorId,
      operatorName: tree.operator.businessName,
      locationId: location.locationId,
      locationName: location.name,
      orgUnitId: unit?.orgUnitId ?? location.orgUnitId,
      orgUnitName: unit?.name ?? tree.orgUnitName(location.orgUnitId),
      hierarchyPath: parentPath,
    );
    return AdminScopeRow(
      key: Key('admin_setup_scope_location_${location.locationId}'),
      icon: scopeIcon(kind: ScopeEntityKind.location),
      label: location.name,
      detail: 'Location scope',
      selected: selectedScope?.cacheKey == scope.cacheKey,
      depth: parentPath.length + 1,
      onTap: () => onSelectScope(scope),
    );
  }
}

/// Single selectable row inside the scope tree (business / org unit /
/// location). Shows a left accent + check when [selected].
class AdminScopeRow extends StatelessWidget {
  const AdminScopeRow({
    super.key,
    required this.icon,
    required this.label,
    required this.detail,
    required this.selected,
    required this.depth,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String detail;
  final bool selected;
  final int depth;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppColors.sunset.withValues(alpha: 0.10)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.fromLTRB(12 + depth * 16, 10, 8, 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? AppColors.sunsetDark : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? AppColors.sunsetDark : AppColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body14(
                        color: selected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_circle,
                  size: 17,
                  color: AppColors.sunsetDark,
                ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

/// Empty-state card shown when no business matches the current search.
class AdminScopeEmptyState extends StatelessWidget {
  const AdminScopeEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      key: const Key('admin_setup_scope_empty'),
      child: Text(
        'No business accounts match this search.',
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
    );
  }
}

/// One business in the scope tree, with its org units and locations
/// indexed for cheap parent/child lookups.
class AdminScopeTree {
  AdminScopeTree({
    required this.operator,
    required this.orgUnits,
    required this.locations,
  }) {
    for (final unit in orgUnits) {
      _childrenByParent.putIfAbsent(unit.parentOrgUnitId, () => []).add(unit);
      _orgUnitById[unit.orgUnitId] = unit;
    }
    for (final location in locations) {
      _locationsByOrgUnit
          .putIfAbsent(
            location.orgUnitId,
            () => <AdminScopeWorkspaceLocation>[],
          )
          .add(location);
    }
  }

  factory AdminScopeTree.fromBundle({
    required OperatorAdminBundle bundle,
    required List<OrgUnitAdminNode> orgUnits,
    required List<AdminScopeWorkspaceLocation> locations,
  }) {
    return AdminScopeTree(
      operator: bundle.operator,
      orgUnits: orgUnits,
      locations: locations,
    );
  }

  final OperatorAdminRecord operator;
  final List<OrgUnitAdminNode> orgUnits;
  final List<AdminScopeWorkspaceLocation> locations;
  final Map<String?, List<OrgUnitAdminNode>> _childrenByParent =
      <String?, List<OrgUnitAdminNode>>{};
  final Map<String, OrgUnitAdminNode> _orgUnitById =
      <String, OrgUnitAdminNode>{};
  final Map<String?, List<AdminScopeWorkspaceLocation>> _locationsByOrgUnit =
      <String?, List<AdminScopeWorkspaceLocation>>{};

  List<OrgUnitAdminNode> get rootOrgUnits =>
      _childrenByParent[null] ?? const <OrgUnitAdminNode>[];

  List<AdminScopeWorkspaceLocation> get unassignedLocations =>
      _locationsByOrgUnit[null] ?? const <AdminScopeWorkspaceLocation>[];

  Map<String?, List<AdminScopeWorkspaceLocation>> get locationsByOrgUnit =>
      _locationsByOrgUnit;

  List<OrgUnitAdminNode> childrenOf(OrgUnitAdminNode unit) {
    return _childrenByParent[unit.orgUnitId] ?? const <OrgUnitAdminNode>[];
  }

  String? orgUnitName(String? orgUnitId) {
    if (orgUnitId == null) return null;
    return _orgUnitById[orgUnitId]?.name;
  }

  Set<String> locationIdsForOrgUnit(String? orgUnitId) {
    if (orgUnitId == null) return const <String>{};
    final ids = <String>{};
    void collect(String? currentOrgUnitId) {
      final locations =
          _locationsByOrgUnit[currentOrgUnitId] ??
          const <AdminScopeWorkspaceLocation>[];
      for (final location in locations) {
        ids.add(location.locationId);
      }
      for (final child
          in _childrenByParent[currentOrgUnitId] ??
              const <OrgUnitAdminNode>[]) {
        collect(child.orgUnitId);
      }
    }

    collect(orgUnitId);
    return ids;
  }

  /// True when [operator] / its org units / its locations contain
  /// [search] (already lower-cased). Empty search matches everything.
  bool matchesSearch(String search) {
    if (search.isEmpty) return true;
    if (operator.businessName.toLowerCase().contains(search)) {
      return true;
    }
    for (final unit in orgUnits) {
      if (unit.name.toLowerCase().contains(search)) return true;
    }
    for (final location in locations) {
      if (location.name.toLowerCase().contains(search)) return true;
    }
    return false;
  }
}

/// A location leaf in the scope tree.
class AdminScopeWorkspaceLocation {
  const AdminScopeWorkspaceLocation({
    required this.locationId,
    required this.name,
    required this.operatorId,
    required this.orgUnitId,
  });

  final String locationId;
  final String name;
  final String operatorId;
  final String? orgUnitId;
}

/// Loads the full [AdminScopeTree] list for every business the
/// [operatorGateway] exposes, enriching each with org units +
/// hierarchy locations when a [hierarchyGateway] is available. Shared
/// by the AI workspace and the Business accounts screen so the tree is
/// built one way.
Future<List<AdminScopeTree>> loadAdminScopeTrees({
  required OperatorLocationAdminGateway operatorGateway,
  RolesHierarchySessionsAdminGateway? hierarchyGateway,
}) async {
  final bundles = await operatorGateway.listOperators();
  if (hierarchyGateway == null) {
    return <AdminScopeTree>[
      for (final bundle in bundles)
        AdminScopeTree.fromBundle(
          bundle: bundle,
          orgUnits: const <OrgUnitAdminNode>[],
          locations: <AdminScopeWorkspaceLocation>[
            for (final location in bundle.locations)
              AdminScopeWorkspaceLocation(
                locationId: location.locationId,
                name: location.name,
                operatorId: location.operatorId,
                orgUnitId: location.parentOrgUnitId,
              ),
          ],
        ),
    ];
  }
  return Future.wait(<Future<AdminScopeTree>>[
    for (final bundle in bundles)
      () async {
        final results = await Future.wait<Object>([
          hierarchyGateway.listOrgUnits(operatorId: bundle.operator.operatorId),
          hierarchyGateway.listHierarchyLocations(
            operatorId: bundle.operator.operatorId,
          ),
        ]);
        final orgUnits = results[0] as List<OrgUnitAdminNode>;
        final leaves = results[1] as List<HierarchyLocationLeaf>;
        return AdminScopeTree.fromBundle(
          bundle: bundle,
          orgUnits: orgUnits,
          locations: <AdminScopeWorkspaceLocation>[
            if (leaves.isNotEmpty)
              for (final leaf in leaves)
                AdminScopeWorkspaceLocation(
                  locationId: leaf.locationId,
                  name: leaf.name,
                  operatorId: leaf.operatorId,
                  orgUnitId: leaf.orgUnitId,
                )
            else
              for (final location in bundle.locations)
                AdminScopeWorkspaceLocation(
                  locationId: location.locationId,
                  name: location.name,
                  operatorId: location.operatorId,
                  orgUnitId: location.parentOrgUnitId,
                ),
          ],
        );
      }(),
  ]);
}

/// Resolves the set of location ids covered by [scope] given the loaded
/// [trees]. Mirrors the previous `_selectionForScope` logic so the AI
/// workspace keeps the same behavior after extraction.
AdminScopeSelection resolveAdminScopeSelection(
  List<AdminScopeTree> trees,
  AdminHierarchyScopeIntent scope,
) {
  AdminScopeTree? tree;
  for (final candidate in trees) {
    if (candidate.operator.operatorId == scope.operatorId) {
      tree = candidate;
      break;
    }
  }
  if (tree == null) {
    return AdminScopeSelection(
      scope: scope,
      locationIds: _fallbackLocationIds(scope),
    );
  }
  switch (scope.scopeType) {
    case AdminHierarchyScopeType.business:
      return AdminScopeSelection(
        scope: scope,
        locationIds: tree.locations
            .map((location) => location.locationId)
            .toSet(),
      );
    case AdminHierarchyScopeType.orgUnit:
      return AdminScopeSelection(
        scope: scope,
        locationIds: tree.locationIdsForOrgUnit(scope.orgUnitId),
      );
    case AdminHierarchyScopeType.location:
      return AdminScopeSelection(
        scope: scope,
        locationIds: _fallbackLocationIds(scope),
      );
  }
}

Set<String> _fallbackLocationIds(AdminHierarchyScopeIntent scope) {
  final locationId = scope.locationId;
  if (locationId == null || locationId.isEmpty) {
    return const <String>{};
  }
  return <String>{locationId};
}
