// Phase 11W.3 - Operator Web Hierarchy screen.
//
// Web parity for the mobile Settings -> Org Hierarchy section. Mounted
// at the `/locations` route in the operator-web shell. Renders the
// per-operator org-unit tree with locations as leaves per the parity
// contract § Hierarchy:
//
//   * Tree shape: `org_units` form an n-ary tree per operator;
//     `locations` are leaves attached to a single `org_unit_id`.
//     Roots are units with `parent_org_unit_id IS NULL`.
//   * Display order: children sorted alphabetically by `name`;
//     locations sorted alphabetically within their org-unit.
//   * Move semantics: gated on `team.roles.assign`. Audited via the
//     existing proxy route + audit-log producer.
//   * Read-only audiences: floor managers (`location_manager`) and
//     supervisors (`supervisor`) see read-only; mutate buttons hidden;
//     tree expand/collapse stays interactive.
//   * Validation copy locked verbatim against the parity contract:
//       - empty name -> "Org unit name is required."
//       - duplicate name within parent -> "An org unit with this name
//         already exists in this group."
//       - move would create a cycle -> "Cannot move into a child of
//         itself."
//
// Permission gates mirror the proxy server-side gate. The screen
// prefers the live `OperatorWebSession.permissions` snapshot when
// present; it falls back to a role-tier set so the demo flavor and
// the pre-snapshot bootstrap stage of live mode still render.
//
// Wiring honesty: the screen reads + writes through
// [WebTeamHierarchyGateway] which the router binds to either the
// `package:http` live impl or the in-memory demo impl. No `dart:io`,
// no `sqflite`, no parallel HTTP stack.

import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../domain/hierarchy/org_unit_depth_rule.dart';
import '../../domain/models/inheritance_tree_node.dart';
import '../../services/auth/auth_operations_gateway.dart';
import '../../widgets/inheritance_tree.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/web_team_hierarchy_gateway.dart';
import '../widgets/operator_web_screen_body.dart';
import '../widgets/operator_web_surface.dart';
import '../../theme/app_theme.dart';

/// Roles admitted to the Hierarchy surface when the proxy permission
/// snapshot is not yet hydrated (demo flavor + bootstrap). The
/// authoritative gate is the `team.users.view` permission key per the
/// parity contract § Permission gate cheat sheet (Hierarchy row).
///
/// G7d (spec §2.B/§3): v2 catalog constants. Phantom
/// `'operator_admin'` dropped (folded into `operator_owner`); v1
/// soft-deleted `'operator_manager'` → `roleOperatorGeneralManager`
/// and `'operator_supervisor'` → `roleSupervisor` (map, don't drop —
/// migration-window robustness). `location_manager` kept (REAL v2).
const Set<String> kOperatorWebHierarchyAdmittedRoles = <String>{
  PermissionKeys.roleOperatorOwner,
  PermissionKeys.roleOperatorGeneralManager,
  PermissionKeys.roleSupervisor,
  PermissionKeys.roleLocationManager,
};

/// Role-tier fallback for the mutate actions (create org unit, move
/// location). Authoritative gate is the `team.roles.assign`
/// permission key; this set kicks in only when
/// `OperatorWebSession.permissions` is empty (demo + boot).
///
/// G7d (spec §2.B/§3): phantom `'operator_admin'` dropped.
const Set<String> kOperatorWebHierarchyWriteRoles = <String>{
  PermissionKeys.roleOperatorOwner,
};

/// Permission-key bound for the Hierarchy read surface. Live source
/// hydrates from `/v1/auth/permissions/snapshot`. Aliased to the
/// frozen catalog constant in `lib/auth/permission_keys.dart`.
const String kHierarchyViewPermissionKey = PermissionKeys.teamUsersView;

/// Permission-key bound for the create org unit + move location
/// actions per the parity contract § Hierarchy. Aliased to the
/// frozen catalog constant in `lib/auth/permission_keys.dart`.
const String kHierarchyAssignPermissionKey = PermissionKeys.teamRolesAssign;

/// Locked copy strings keyed off the parity contract § Hierarchy
/// Validation copy block. Pinned in `HierarchyCopy` so widget tests
/// can assert each one verbatim.
class HierarchyCopy {
  const HierarchyCopy._();

  static const String emptyOrgUnitName = 'Org unit name is required.';
  static const String duplicateOrgUnitName =
      'An org unit with this name already exists in this group.';
  static const String moveCycle = 'Cannot move into a child of itself.';

  /// GAP A4 — re-export of the shared depth-cap copy so widget tests
  /// can pin one string and assert web/admin parity against it. The
  /// source of truth is [OrgUnitDepthRule.depthCapMessage]; this is an
  /// alias, never a paraphrase.
  static const String depthCapReached = kOrgUnitDepthCapMessage;

  /// GAP A3 — friendly label for an org-unit `unit_type`. Keeps the
  /// raw schema vocabulary (`region` / `district` / `location_group`
  /// / `corp`) out of the operator's sight. Unknown values fall back
  /// to a generic "Group" rather than leaking a code.
  static String unitTypeLabel(String? unitType) {
    switch (unitType) {
      case 'corp':
        return 'Business';
      case 'brand':
        return 'Brand';
      case 'region':
        return 'Region';
      case 'district':
        return 'District';
      case 'location_group':
        return 'Location group';
      default:
        return 'Group';
    }
  }

  /// Friendly fallback when the proxy returns a non-`validation_failed`
  /// error code. Pinned here so the widget tests can assert the
  /// fallback path without coupling to dynamic strings.
  static const String mutationFailed =
      'Action could not be completed. Try again in a moment, or refresh '
      'the page if the problem keeps happening.';
}

/// Operator Web Hierarchy screen.
class HierarchyScreen extends StatefulWidget {
  const HierarchyScreen({
    super.key,
    required this.session,
    required this.gateway,
    this.idempotencyKeyFactory,
  });

  final OperatorWebSession session;
  final WebTeamHierarchyGateway gateway;

  /// Optional override for tests so an assertion can pin the
  /// idempotency-key value the screen forwards into the gateway.
  final String Function()? idempotencyKeyFactory;

  /// True iff the actor may read the Hierarchy surface. Prefers the
  /// proxy-side permission snapshot when present; falls back to the
  /// role-tier set so the demo flavor (no permissions snapshot) and
  /// the live bootstrap stage (snapshot still loading) render
  /// something useful.
  bool get _admitted {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kHierarchyViewPermissionKey);
    }
    return session.roles.any(kOperatorWebHierarchyAdmittedRoles.contains);
  }

  /// True iff the actor may create org units + move locations.
  /// Prefers the permission snapshot; falls back to the role tier
  /// when the snapshot has not hydrated yet.
  bool get _canMutate {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kHierarchyAssignPermissionKey);
    }
    return session.roles.any(kOperatorWebHierarchyWriteRoles.contains);
  }

  @override
  State<HierarchyScreen> createState() => _HierarchyScreenState();
}

class _HierarchyScreenState extends State<HierarchyScreen> {
  List<TeamOrgUnitEntry> _orgUnits = const <TeamOrgUnitEntry>[];
  List<TeamOrgLocationEntry> _locations = const <TeamOrgLocationEntry>[];
  bool _loading = true;
  String? _loadError;
  final Set<String> _busyOrgUnitIds = <String>{};
  final Set<String> _busyLocationIds = <String>{};
  final Set<String> _legacyCollapsedScopeIds = <String>{};
  int _loadGeneration = 0;
  int _idempotencySeq = 0;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result = await widget.gateway.listOrgHierarchy(_listCommand());
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _orgUnits = result.orgUnits;
        _locations = result.locations;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadError = _friendlyLoadError(error);
      });
    }
  }

  String _friendlyLoadError(Object error) {
    if (error is WebTeamHierarchyError) {
      return 'Could not load the locations list (${error.code}). Refresh '
          'the page or try again in a moment.';
    }
    return 'Could not load the locations list. Refresh the page or try '
        'again in a moment.';
  }

  TeamOrgHierarchyListCommand _listCommand() {
    return TeamOrgHierarchyListCommand(
      actorUserId: widget.session.uid,
      operatorId: widget.session.operatorId,
      locationId: widget.session.primaryLocationId ?? '',
    );
  }

  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencySeq += 1;
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'op-web-hierarchy-${widget.session.uid}-$ts-$_idempotencySeq';
  }

  Future<void> _onAddChildOrgUnit(TeamOrgUnitEntry parent) async {
    if (!widget._canMutate) return;
    // GAP A4 — first guard layer: the parent's depth comes straight
    // from its ltree path (TeamOrgUnitEntry.path is the materialized
    // path string, e.g. "demo_bistro.east_region"). If the parent is
    // already at the deepest allowed level we never open the dialog;
    // we explain why with the locked copy instead. This mirrors the
    // proxy guard at org_units_repository.dart:241.
    final parentDepth = OrgUnitDepthRule.depthFromPath(parent.path);
    if (!OrgUnitDepthRule.canAddChild(parentDepth)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(HierarchyCopy.depthCapReached)),
      );
      return;
    }
    final draft = await showDialog<_AddOrgUnitDraft>(
      context: context,
      builder: (context) => _AddChildOrgUnitDialog(
        parent: parent,
        existingNames: _siblingNames(parent.orgUnitId),
        parentDepth: parentDepth,
      ),
    );
    if (draft == null || !mounted) return;
    setState(() => _busyOrgUnitIds.add(parent.orgUnitId));
    try {
      await widget.gateway.createOrgUnit(
        TeamOrgUnitCreateCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId ?? '',
          parentOrgUnitId: parent.orgUnitId,
          unitType: draft.unitType,
          label: draft.label,
          name: draft.name,
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Org unit added.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    } finally {
      if (mounted) {
        setState(() => _busyOrgUnitIds.remove(parent.orgUnitId));
      }
    }
  }

  Future<void> _onRenameOrgUnit(TeamOrgUnitEntry unit) async {
    if (!widget._canMutate) return;
    // The corp root IS renameable (it is the operator-facing Business
    // label). Same write key as create/move; no root carve-out here or
    // in the annotation.
    final draft = await showDialog<String>(
      context: context,
      builder: (context) => _RenameOrgUnitDialog(
        unit: unit,
        // Sibling names within the same parent, excluding this unit so
        // re-submitting its own current name (a no-op) is not blocked.
        existingNames: _siblingNamesExcluding(
          unit.parentOrgUnitId,
          unit.orgUnitId,
        ),
      ),
    );
    if (draft == null || !mounted) return;
    setState(() => _busyOrgUnitIds.add(unit.orgUnitId));
    try {
      await widget.gateway.renameOrgUnit(
        TeamOrgUnitRenameCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId ?? '',
          orgUnitId: unit.orgUnitId,
          name: draft,
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Org unit renamed.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    } finally {
      if (mounted) {
        setState(() => _busyOrgUnitIds.remove(unit.orgUnitId));
      }
    }
  }

  Set<String> _siblingNamesExcluding(
    String? parentOrgUnitId,
    String excludeOrgUnitId,
  ) {
    return <String>{
      for (final unit in _orgUnits)
        if (unit.parentOrgUnitId == parentOrgUnitId &&
            unit.orgUnitId != excludeOrgUnitId)
          unit.label.toLowerCase(),
    };
  }

  Future<void> _onMoveLocation(TeamOrgLocationEntry location) async {
    if (!widget._canMutate) return;
    final targets = _orgUnits
        .where((unit) => unit.orgUnitId != location.parentOrgUnitId)
        .toList(growable: false);
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add another unit before moving this location.'),
        ),
      );
      return;
    }
    final selected = await showDialog<TeamOrgUnitEntry>(
      context: context,
      builder: (context) =>
          _MoveLocationDialog(location: location, targets: targets),
    );
    if (selected == null || !mounted) return;
    setState(() => _busyLocationIds.add(location.locationId));
    try {
      await widget.gateway.moveLocationToOrgUnit(
        TeamLocationOrgUnitMoveCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId ?? '',
          targetLocationId: location.locationId,
          parentOrgUnitId: selected.orgUnitId,
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Location moved.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    } finally {
      if (mounted) {
        setState(() => _busyLocationIds.remove(location.locationId));
      }
    }
  }

  Set<String> _siblingNames(String parentOrgUnitId) {
    return <String>{
      for (final unit in _orgUnits)
        if (unit.parentOrgUnitId == parentOrgUnitId) unit.label.toLowerCase(),
    };
  }

  String _friendlyMutationError(Object error) {
    if (error is WebTeamHierarchyError) {
      if (error.code == 'validation_failed') {
        return error.message;
      }
      if (error.code == 'cycle_detected') {
        return HierarchyCopy.moveCycle;
      }
      return 'Action could not be completed (${error.code}). Try again in '
          'a moment, or refresh the page if the problem keeps happening.';
    }
    return HierarchyCopy.mutationFailed;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget._admitted) {
      return const _HierarchyForbiddenSurface(
        key: Key('operator_web_hierarchy_forbidden'),
      );
    }
    if (_loading) {
      return const Center(
        key: Key('operator_web_hierarchy_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (_loadError != null) {
      return Center(
        key: const Key('operator_web_hierarchy_load_error'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Locations could not load',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  _loadError!,
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const Key('operator_web_hierarchy_load_retry'),
                    onPressed: _loadAll,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.sunsetDark,
                      side: const BorderSide(
                        color: AppColors.sunsetDark,
                        width: 1,
                      ),
                    ),
                    child: const Text('Retry'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return OperatorWebScreenBody(
      scrollKey: const Key('operator_web_hierarchy_screen'),
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _HierarchyHeader(),
          const SizedBox(height: 20),
          _HierarchySummaryRow(
            orgUnitCount: _orgUnits.length,
            locationCount: _locations.length,
          ),
          const SizedBox(height: 18),
          if (!widget._canMutate)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: OperatorWebBanner(
                key: const Key('operator_web_hierarchy_readonly_notice'),
                title: 'View-only access',
                message:
                    'Read-only view. Your operator owner or admin can edit '
                    'the hierarchy.',
                icon: Icons.visibility_outlined,
              ),
            ),
          OperatorWebPanel(
            key: const Key('operator_web_hierarchy_tree_panel'),
            title: 'Location hierarchy',
            tone: OperatorWebPanelTone.highlight,
            padding: const EdgeInsets.fromLTRB(28, 24, 24, 28),
            child: LayoutBuilder(
              key: const Key('operator_web_hierarchy_tree_frame'),
              builder: (context, constraints) {
                final treeWidth = constraints.maxWidth < 720
                    ? 720.0
                    : constraints.maxWidth;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: treeWidth,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 430),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                        child: _OperatorWebHierarchyInheritanceTree(
                          orgUnits: _orgUnits,
                          locations: _locations,
                          canMutate: widget._canMutate,
                          busyOrgUnitIds: _busyOrgUnitIds,
                          busyLocationIds: _busyLocationIds,
                          collapsedScopeIds: _legacyCollapsedScopeIds,
                          onToggleCollapsed: _toggleLegacyCollapsed,
                          onAddChildOrgUnit: _onAddChildOrgUnit,
                          onRenameOrgUnit: _onRenameOrgUnit,
                          onMoveLocation: _onMoveLocation,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _toggleLegacyCollapsed(String scopeId) {
    setState(() {
      if (!_legacyCollapsedScopeIds.add(scopeId)) {
        _legacyCollapsedScopeIds.remove(scopeId);
      }
    });
  }
}

class _HierarchySummaryRow extends StatelessWidget {
  const _HierarchySummaryRow({
    required this.orgUnitCount,
    required this.locationCount,
  });

  final int orgUnitCount;
  final int locationCount;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const Key('operator_web_hierarchy_summary'),
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        _HierarchySummaryMetric(
          keyName: 'operator_web_hierarchy_summary_units',
          icon: Icons.account_tree_outlined,
          label: 'Groups',
          value: orgUnitCount.toString(),
        ),
        _HierarchySummaryMetric(
          keyName: 'operator_web_hierarchy_summary_locations',
          icon: Icons.storefront_outlined,
          label: 'Locations',
          value: locationCount.toString(),
        ),
      ],
    );
  }
}

class _HierarchySummaryMetric extends StatelessWidget {
  const _HierarchySummaryMetric({
    required this.keyName,
    required this.icon,
    required this.label,
    required this.value,
  });

  final String keyName;
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyName),
      constraints: const BoxConstraints(minWidth: 190, minHeight: 72),
      padding: const EdgeInsets.fromLTRB(16, 14, 18, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.cardGlow,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 18, color: AppColors.sunsetDark),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: AppTextStyles.uiLabel(color: AppColors.textMuted),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OperatorWebHierarchyInheritanceTree extends StatelessWidget {
  const _OperatorWebHierarchyInheritanceTree({
    required this.orgUnits,
    required this.locations,
    required this.canMutate,
    required this.busyOrgUnitIds,
    required this.busyLocationIds,
    required this.collapsedScopeIds,
    required this.onToggleCollapsed,
    required this.onAddChildOrgUnit,
    required this.onRenameOrgUnit,
    required this.onMoveLocation,
  });

  final List<TeamOrgUnitEntry> orgUnits;
  final List<TeamOrgLocationEntry> locations;
  final bool canMutate;
  final Set<String> busyOrgUnitIds;
  final Set<String> busyLocationIds;
  final Set<String> collapsedScopeIds;
  final ValueChanged<String> onToggleCollapsed;
  final ValueChanged<TeamOrgUnitEntry> onAddChildOrgUnit;
  final ValueChanged<TeamOrgUnitEntry> onRenameOrgUnit;
  final ValueChanged<TeamOrgLocationEntry> onMoveLocation;

  @override
  Widget build(BuildContext context) {
    if (orgUnits.isEmpty) {
      return OperatorWebBanner(
        key: const Key('operator_web_org_unit_tree_empty'),
        title: 'No hierarchy yet',
        message: 'Setup needs a root unit before locations can be grouped.',
        icon: Icons.account_tree_outlined,
      );
    }

    final orgUnitsById = <String, TeamOrgUnitEntry>{
      for (final unit in orgUnits) unit.orgUnitId: unit,
    };
    final locationsById = <String, TeamOrgLocationEntry>{
      for (final location in locations) location.locationId: location,
    };
    final rootNode = _buildInheritanceRoot();
    return KeyedSubtree(
      key: const Key('operator_web_org_unit_tree'),
      child: InheritanceTree(
        key: ValueKey<String>(
          'operator_web_org_unit_tree_${collapsedScopeIds.join('|')}',
        ),
        rootNode: rootNode,
        initiallyCollapsedScopeIds: collapsedScopeIds,
        emptyMessage: 'No hierarchy yet. Setup needs a root unit first.',
        indentWidth: 22,
        rowGap: 10,
        annotationBuilder: (context, node) {
          if (node.scopeKind == InheritanceTreeScopeKind.location) {
            final location = locationsById[node.scopeId];
            if (location == null) return const SizedBox.shrink();
            return _LocationNodeAnnotation(
              location: location,
              canMutate: canMutate,
              busy: busyLocationIds.contains(location.locationId),
              onMoveLocation: onMoveLocation,
            );
          }
          final unit = orgUnitsById[node.scopeId];
          if (unit == null) return const SizedBox.shrink();
          return _OrgUnitNodeAnnotation(
            node: node,
            unit: unit,
            canMutate: canMutate,
            busy: busyOrgUnitIds.contains(unit.orgUnitId),
            collapsed: collapsedScopeIds.contains(unit.orgUnitId),
            onToggleCollapsed: onToggleCollapsed,
            onAddChildOrgUnit: onAddChildOrgUnit,
            onRenameOrgUnit: onRenameOrgUnit,
          );
        },
      ),
    );
  }

  InheritanceTreeNode _buildInheritanceRoot() {
    final byParent = <String?, List<TeamOrgUnitEntry>>{};
    for (final unit in orgUnits) {
      byParent
          .putIfAbsent(unit.parentOrgUnitId, () => <TeamOrgUnitEntry>[])
          .add(unit);
    }
    for (final list in byParent.values) {
      list.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
    }
    final locationsByParent = <String, List<TeamOrgLocationEntry>>{};
    for (final location in locations) {
      locationsByParent
          .putIfAbsent(location.parentOrgUnitId, () => <TeamOrgLocationEntry>[])
          .add(location);
    }
    for (final list in locationsByParent.values) {
      list.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
    }
    final roots = byParent[null] ?? const <TeamOrgUnitEntry>[];
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
      scopeId: 'operator_web_hierarchy_root',
      displayName: 'Business',
      children: children,
    );
  }

  InheritanceTreeNode _buildUnitNode(
    TeamOrgUnitEntry unit, {
    required int depth,
    required Map<String?, List<TeamOrgUnitEntry>> byParent,
    required Map<String, List<TeamOrgLocationEntry>> locationsByParent,
  }) {
    final childOrgUnits =
        byParent[unit.orgUnitId] ?? const <TeamOrgUnitEntry>[];
    final childLocations =
        locationsByParent[unit.orgUnitId] ?? const <TeamOrgLocationEntry>[];
    final childNodes =
        <InheritanceTreeNode>[
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
              displayName: location.label,
              parentScopeId: location.parentOrgUnitId,
              depth: depth + 1,
              metadata: <String, Object?>{
                'org_unit_path': location.orgUnitPath,
                'suspended_at': location.suspendedAt,
                'deleted_at': location.deletedAt,
              },
            ),
        ]..sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
    return InheritanceTreeNode(
      scopeKind: unit.parentOrgUnitId == null
          ? InheritanceTreeScopeKind.business
          : InheritanceTreeScopeKind.orgUnit,
      scopeId: unit.orgUnitId,
      displayName: unit.label,
      parentScopeId: unit.parentOrgUnitId,
      depth: depth,
      children: List<InheritanceTreeNode>.unmodifiable(childNodes),
      metadata: <String, Object?>{
        'unit_type': unit.unitType,
        'path': unit.path,
        'suspended_at': unit.suspendedAt,
        'deleted_at': unit.deletedAt,
      },
    );
  }
}

class _OrgUnitNodeAnnotation extends StatelessWidget {
  const _OrgUnitNodeAnnotation({
    required this.node,
    required this.unit,
    required this.canMutate,
    required this.busy,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.onAddChildOrgUnit,
    required this.onRenameOrgUnit,
  });

  final InheritanceTreeNode node;
  final TeamOrgUnitEntry unit;
  final bool canMutate;
  final bool busy;
  final bool collapsed;
  final ValueChanged<String> onToggleCollapsed;
  final ValueChanged<TeamOrgUnitEntry> onAddChildOrgUnit;
  final ValueChanged<TeamOrgUnitEntry> onRenameOrgUnit;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: Key('operator_web_org_unit_actions_${unit.orgUnitId}'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // GAP A3 — plain-English type label so the operator can tell a
        // region from a district at a glance. Reads the real
        // `unit_type` carried in node metadata; never shows the raw
        // schema vocabulary.
        Container(
          key: Key('operator_web_org_unit_type_${unit.orgUnitId}'),
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            HierarchyCopy.unitTypeLabel(unit.unitType),
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ),
        IconButton(
          key: Key('operator_web_org_unit_toggle_${unit.orgUnitId}'),
          icon: Icon(
            node.hasChildren
                ? (collapsed ? Icons.chevron_right : Icons.expand_more)
                : Icons.remove,
            size: 18,
            color: node.hasChildren
                ? AppColors.sunsetDark
                : AppColors.borderSubtle,
          ),
          tooltip: node.hasChildren
              ? (collapsed ? 'Expand' : 'Collapse')
              : 'No children',
          onPressed: node.hasChildren
              ? () => onToggleCollapsed(unit.orgUnitId)
              : null,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
        if (canMutate) ...<Widget>[
          IconButton(
            key: Key('operator_web_org_unit_rename_${unit.orgUnitId}'),
            tooltip: 'Rename',
            icon: const Icon(Icons.drive_file_rename_outline, size: 18),
            color: AppColors.sunsetDark,
            onPressed: busy ? null : () => onRenameOrgUnit(unit),
          ),
          IconButton(
            key: Key('operator_web_org_unit_add_child_${unit.orgUnitId}'),
            tooltip: 'Add child unit',
            icon: const Icon(Icons.add_circle_outline, size: 18),
            color: AppColors.sunsetDark,
            onPressed: busy ? null : () => onAddChildOrgUnit(unit),
          ),
        ],
      ],
    );
  }
}

class _LocationNodeAnnotation extends StatelessWidget {
  const _LocationNodeAnnotation({
    required this.location,
    required this.canMutate,
    required this.busy,
    required this.onMoveLocation,
  });

  final TeamOrgLocationEntry location;
  final bool canMutate;
  final bool busy;
  final ValueChanged<TeamOrgLocationEntry> onMoveLocation;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      key: Key('operator_web_location_card_${location.locationId}'),
      constraints: const BoxConstraints(maxWidth: 320),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.storefront_outlined,
                size: 16,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Location',
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ),
              if (canMutate) ...<Widget>[
                const SizedBox(width: 12),
                TextButton.icon(
                  key: Key(
                    'operator_web_location_card_move_${location.locationId}',
                  ),
                  onPressed: busy ? null : () => onMoveLocation(location),
                  icon: const Icon(Icons.swap_vert_outlined, size: 16),
                  label: const Text('Move'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.sunsetDark,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ] else if (busy) ...<Widget>[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.sunsetDark,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HierarchyHeader extends StatelessWidget {
  const _HierarchyHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(
              Icons.account_tree_outlined,
              size: 22,
              color: AppColors.sunsetDark,
            ),
            const SizedBox(width: 10),
            Text(
              'Locations',
              style: AppTextStyles.display20(color: AppColors.textPrimary),
            ),
          ],
        ),
      ],
    );
  }
}

class _HierarchyForbiddenSurface extends StatelessWidget {
  const _HierarchyForbiddenSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.lock_outline,
                    size: 20,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Admin or owner access needed',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Your operator owner or admin can group locations under '
                'regions or districts. Ask them to add you to the right '
                'role if you need to change the layout.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddOrgUnitDraft {
  const _AddOrgUnitDraft({
    required this.unitType,
    required this.label,
    required this.name,
  });

  final String unitType;
  final String label;
  final String name;
}

class _AddChildOrgUnitDialog extends StatefulWidget {
  const _AddChildOrgUnitDialog({
    required this.parent,
    required this.existingNames,
    required this.parentDepth,
  });

  final TeamOrgUnitEntry parent;
  final Set<String> existingNames;

  /// GAP A4 — depth of [parent] in the org-unit chain, computed by
  /// the caller from the parent's ltree path. The in-dialog backstop
  /// re-checks the cap here so a stale tree (parent that grew deeper
  /// after the dialog opened) still gets a friendly inline error
  /// rather than a raw server rejection.
  final int parentDepth;

  @override
  State<_AddChildOrgUnitDialog> createState() => _AddChildOrgUnitDialogState();
}

class _AddChildOrgUnitDialogState extends State<_AddChildOrgUnitDialog> {
  String _unitType = 'region';
  final TextEditingController _label = TextEditingController();
  final TextEditingController _name = TextEditingController();
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _label.addListener(_handleTextChanged);
    _name.addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    _label.removeListener(_handleTextChanged);
    _name.removeListener(_handleTextChanged);
    _label.dispose();
    _name.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    if (mounted) setState(() => _errorText = null);
  }

  void _submit() {
    // GAP A4 — second guard layer (backstop). Mirrors the proxy guard
    // at org_units_repository.dart:241 exactly.
    if (!OrgUnitDepthRule.canAddChild(widget.parentDepth)) {
      setState(() => _errorText = HierarchyCopy.depthCapReached);
      return;
    }
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _errorText = HierarchyCopy.emptyOrgUnitName);
      return;
    }
    if (widget.existingNames.contains(name.toLowerCase())) {
      setState(() => _errorText = HierarchyCopy.duplicateOrgUnitName);
      return;
    }
    final rawLabel = _label.text.trim();
    final label = rawLabel.isEmpty ? _sanitiseLabel(name) : rawLabel;
    Navigator.of(
      context,
    ).pop(_AddOrgUnitDraft(unitType: _unitType, label: label, name: name));
  }

  /// Squashes a free-text display name into the `a-z, 0-9, underscore`
  /// label format the proxy expects when the user has not typed an
  /// explicit label. Any non-alphanumeric run becomes a single
  /// underscore; leading and trailing underscores are trimmed so a
  /// name like `"South-West Region"` lands as `"south_west_region"`
  /// rather than `"south-west_region"` (which would fail server-side
  /// label validation).
  static String _sanitiseLabel(String name) {
    final lowered = name.toLowerCase();
    final collapsed = lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return collapsed.replaceAll(RegExp(r'^_+|_+$'), '');
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('operator_web_org_unit_add_dialog'),
      title: 'Add child unit',
      icon: Icons.add_circle_outline,
      maxWidth: 430,
      actions: <Widget>[
        TextButton(
          key: const Key('operator_web_org_unit_add_dialog_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('operator_web_org_unit_add_dialog_submit'),
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Under ${widget.parent.label}',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('operator_web_org_unit_add_dialog_unit_type'),
              initialValue: _unitType,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Unit type',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'brand', child: Text('Brand')),
                DropdownMenuItem(value: 'region', child: Text('Region')),
                DropdownMenuItem(value: 'district', child: Text('District')),
                DropdownMenuItem(
                  value: 'location_group',
                  child: Text('Location group'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _unitType = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('operator_web_org_unit_add_dialog_name'),
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Display name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('operator_web_org_unit_add_dialog_label'),
              controller: _label,
              decoration: const InputDecoration(
                labelText: 'Label (a-z, 0-9, underscore)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_errorText != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                _errorText!,
                key: const Key('operator_web_org_unit_add_dialog_error'),
                style: AppTextStyles.body12(color: AppColors.negative),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// GAP A1 — rename an org unit's display name. The corp root IS
/// renameable (it is the operator-facing Business label), so this
/// dialog has no root carve-out. Duplicate-name-within-parent is
/// re-validated client-side here with the same locked copy the server
/// returns, so the operator sees the guidance without a round-trip.
class _RenameOrgUnitDialog extends StatefulWidget {
  const _RenameOrgUnitDialog({required this.unit, required this.existingNames});

  final TeamOrgUnitEntry unit;

  /// Sibling display names (lowercased) in the same parent, excluding
  /// this unit, so re-submitting its own current name is allowed.
  final Set<String> existingNames;

  @override
  State<_RenameOrgUnitDialog> createState() => _RenameOrgUnitDialogState();
}

class _RenameOrgUnitDialogState extends State<_RenameOrgUnitDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.unit.label,
  );
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _name.addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    _name.removeListener(_handleTextChanged);
    _name.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    if (mounted && _errorText != null) {
      setState(() => _errorText = null);
    }
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _errorText = HierarchyCopy.emptyOrgUnitName);
      return;
    }
    if (widget.existingNames.contains(name.toLowerCase())) {
      setState(() => _errorText = HierarchyCopy.duplicateOrgUnitName);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('operator_web_org_unit_rename_dialog'),
      title: 'Rename org unit',
      icon: Icons.drive_file_rename_outline,
      maxWidth: 430,
      actions: <Widget>[
        TextButton(
          key: const Key('operator_web_org_unit_rename_dialog_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('operator_web_org_unit_rename_dialog_submit'),
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'This changes how the unit is named everywhere your team '
              'sees it. It does not move anything.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('operator_web_org_unit_rename_dialog_name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Display name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_errorText != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                _errorText!,
                key: const Key('operator_web_org_unit_rename_dialog_error'),
                style: AppTextStyles.body12(color: AppColors.negative),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MoveLocationDialog extends StatefulWidget {
  const _MoveLocationDialog({required this.location, required this.targets});

  final TeamOrgLocationEntry location;
  final List<TeamOrgUnitEntry> targets;

  @override
  State<_MoveLocationDialog> createState() => _MoveLocationDialogState();
}

class _MoveLocationDialogState extends State<_MoveLocationDialog> {
  String? _selectedOrgUnitId;

  @override
  Widget build(BuildContext context) {
    final sortedTargets = <TeamOrgUnitEntry>[...widget.targets]
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return OperatorWebDialog(
      key: const Key('operator_web_location_move_dialog'),
      title: 'Move location',
      icon: Icons.swap_vert_outlined,
      maxWidth: 430,
      actions: <Widget>[
        TextButton(
          key: const Key('operator_web_location_move_dialog_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('operator_web_location_move_dialog_submit'),
          onPressed: _selectedOrgUnitId == null
              ? null
              : () {
                  final picked = sortedTargets.firstWhere(
                    (target) => target.orgUnitId == _selectedOrgUnitId,
                  );
                  Navigator.of(context).pop(picked);
                },
          child: const Text('Move'),
        ),
      ],
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.location.label,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('operator_web_location_move_dialog_target'),
              initialValue: _selectedOrgUnitId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Move under',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: <DropdownMenuItem<String>>[
                for (final target in sortedTargets)
                  DropdownMenuItem<String>(
                    value: target.orgUnitId,
                    child: Text(
                      '${HierarchyCopy.unitTypeLabel(target.unitType)}: '
                      '${target.label}',
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _selectedOrgUnitId = value),
            ),
          ],
        ),
      ),
    );
  }
}
