// Phase 11W.3 - Org-unit tree view.
//
// Recursive widget that renders the per-operator org-unit tree with
// locations as leaves. Children render alphabetically by `label`;
// locations under each org-unit also render alphabetically by `label`
// so the operator-web walkthrough is reproducible across runs.
//
// Mutate affordances (add child unit, move location) are wired only
// when the actor holds `team.roles.assign` per the parity contract §
// Hierarchy Read-only audiences rule. Read-only audiences keep
// expand/collapse interactivity but see no mutate buttons.
//
// Move semantics use a dropdown picker (matches the mobile reference
// `lib/screens/settings/settings_org_hierarchy_section.dart` move
// dialog). Drag-and-drop is intentionally deferred so the click-path
// is consistent with the mobile surface and accessibility-friendly
// for keyboard users.

import 'package:flutter/material.dart';

import '../../services/auth/auth_operations_gateway.dart';
import '../../theme/app_theme.dart';
import 'location_card.dart';

typedef OrgUnitAddChildRequester = void Function(TeamOrgUnitEntry parent);
typedef LocationMoveRequester = void Function(TeamOrgLocationEntry location);

/// Recursive tree widget. Pass the full flat list of [orgUnits] +
/// [locations] (output of `WebTeamHierarchyGateway.listOrgHierarchy`);
/// the widget computes the parent / child grouping internally so the
/// caller does not have to pre-shape the data.
class OrgUnitTreeView extends StatefulWidget {
  const OrgUnitTreeView({
    super.key,
    required this.orgUnits,
    required this.locations,
    this.canMutate = false,
    this.busyOrgUnitIds = const <String>{},
    this.busyLocationIds = const <String>{},
    this.onAddChildOrgUnit,
    this.onMoveLocation,
  });

  final List<TeamOrgUnitEntry> orgUnits;
  final List<TeamOrgLocationEntry> locations;
  final bool canMutate;
  final Set<String> busyOrgUnitIds;
  final Set<String> busyLocationIds;
  final OrgUnitAddChildRequester? onAddChildOrgUnit;
  final LocationMoveRequester? onMoveLocation;

  @override
  State<OrgUnitTreeView> createState() => _OrgUnitTreeViewState();
}

class _OrgUnitTreeViewState extends State<OrgUnitTreeView> {
  final Set<String> _collapsed = <String>{};

  @override
  Widget build(BuildContext context) {
    if (widget.orgUnits.isEmpty) {
      return Container(
        key: const Key('operator_web_org_unit_tree_empty'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'No hierarchy yet. Setup needs a root unit first.',
          style: AppTextStyles.body13(color: AppColors.textMuted),
        ),
      );
    }

    final byParent = <String?, List<TeamOrgUnitEntry>>{};
    for (final unit in widget.orgUnits) {
      byParent
          .putIfAbsent(unit.parentOrgUnitId, () => <TeamOrgUnitEntry>[])
          .add(unit);
    }
    for (final entry in byParent.entries) {
      entry.value.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
    }
    final locationsByParent = <String, List<TeamOrgLocationEntry>>{};
    for (final loc in widget.locations) {
      locationsByParent
          .putIfAbsent(loc.parentOrgUnitId, () => <TeamOrgLocationEntry>[])
          .add(loc);
    }
    for (final entry in locationsByParent.entries) {
      entry.value.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
    }

    final roots = byParent[null] ?? const <TeamOrgUnitEntry>[];
    return Column(
      key: const Key('operator_web_org_unit_tree'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final root in roots)
          _OrgUnitNode(
            unit: root,
            depth: 0,
            byParent: byParent,
            locationsByParent: locationsByParent,
            collapsed: _collapsed,
            canMutate: widget.canMutate,
            busyOrgUnitIds: widget.busyOrgUnitIds,
            busyLocationIds: widget.busyLocationIds,
            onToggleExpanded: _toggleExpanded,
            onAddChildOrgUnit: widget.onAddChildOrgUnit,
            onMoveLocation: widget.onMoveLocation,
          ),
      ],
    );
  }

  void _toggleExpanded(String orgUnitId) {
    setState(() {
      if (!_collapsed.add(orgUnitId)) {
        _collapsed.remove(orgUnitId);
      }
    });
  }
}

class _OrgUnitNode extends StatelessWidget {
  const _OrgUnitNode({
    required this.unit,
    required this.depth,
    required this.byParent,
    required this.locationsByParent,
    required this.collapsed,
    required this.canMutate,
    required this.busyOrgUnitIds,
    required this.busyLocationIds,
    required this.onToggleExpanded,
    required this.onAddChildOrgUnit,
    required this.onMoveLocation,
  });

  final TeamOrgUnitEntry unit;
  final int depth;
  final Map<String?, List<TeamOrgUnitEntry>> byParent;
  final Map<String, List<TeamOrgLocationEntry>> locationsByParent;
  final Set<String> collapsed;
  final bool canMutate;
  final Set<String> busyOrgUnitIds;
  final Set<String> busyLocationIds;
  final ValueChanged<String> onToggleExpanded;
  final OrgUnitAddChildRequester? onAddChildOrgUnit;
  final LocationMoveRequester? onMoveLocation;

  @override
  Widget build(BuildContext context) {
    final children = byParent[unit.orgUnitId] ?? const <TeamOrgUnitEntry>[];
    final locations =
        locationsByParent[unit.orgUnitId] ?? const <TeamOrgLocationEntry>[];
    final hasContent = children.isNotEmpty || locations.isNotEmpty;
    final isCollapsed = collapsed.contains(unit.orgUnitId);
    final indent = depth * 18.0;
    final busy = busyOrgUnitIds.contains(unit.orgUnitId);

    return Padding(
      padding: EdgeInsets.only(left: indent, top: depth == 0 ? 0 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton(
                key: Key('operator_web_org_unit_toggle_${unit.orgUnitId}'),
                icon: Icon(
                  hasContent
                      ? (isCollapsed ? Icons.chevron_right : Icons.expand_more)
                      : Icons.remove,
                  size: 18,
                  color: hasContent
                      ? AppColors.sunsetDark
                      : AppColors.borderSubtle,
                ),
                tooltip: hasContent
                    ? (isCollapsed ? 'Expand' : 'Collapse')
                    : 'No children',
                onPressed: hasContent
                    ? () => onToggleExpanded(unit.orgUnitId)
                    : null,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              Icon(
                _iconFor(unit.unitType),
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      unit.label,
                      style: AppTextStyles.body13(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      _unitTypeLabel(unit.unitType),
                      style: AppTextStyles.body12(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              if (canMutate && onAddChildOrgUnit != null)
                IconButton(
                  key: Key('operator_web_org_unit_add_child_${unit.orgUnitId}'),
                  tooltip: 'Add child unit',
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  color: AppColors.sunsetDark,
                  onPressed: busy ? null : () => onAddChildOrgUnit!(unit),
                ),
            ],
          ),
          if (!isCollapsed) ...<Widget>[
            for (final loc in locations)
              Padding(
                padding: EdgeInsets.only(left: indent + 32, top: 6),
                child: LocationCard(
                  location: loc,
                  onMove: canMutate && onMoveLocation != null
                      ? () => onMoveLocation!(loc)
                      : null,
                  busy: busyLocationIds.contains(loc.locationId),
                ),
              ),
            for (final child in children)
              _OrgUnitNode(
                unit: child,
                depth: depth + 1,
                byParent: byParent,
                locationsByParent: locationsByParent,
                collapsed: collapsed,
                canMutate: canMutate,
                busyOrgUnitIds: busyOrgUnitIds,
                busyLocationIds: busyLocationIds,
                onToggleExpanded: onToggleExpanded,
                onAddChildOrgUnit: onAddChildOrgUnit,
                onMoveLocation: onMoveLocation,
              ),
          ],
        ],
      ),
    );
  }

  static IconData _iconFor(String unitType) {
    return switch (unitType) {
      'corp' => Icons.apartment,
      'brand' => Icons.sell_outlined,
      'region' => Icons.public,
      'district' => Icons.map_outlined,
      'location_group' => Icons.layers_outlined,
      _ => Icons.account_tree_outlined,
    };
  }

  static String _unitTypeLabel(String unitType) {
    return switch (unitType) {
      'corp' => 'Operator',
      'brand' => 'Brand',
      'region' => 'Region',
      'district' => 'District',
      'location_group' => 'Location group',
      _ => unitType,
    };
  }
}
