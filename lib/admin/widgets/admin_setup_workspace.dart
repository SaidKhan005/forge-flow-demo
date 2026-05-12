import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_route_handoff.dart';
import '../models/operator_location_admin_models.dart';
import '../services/operator_location_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import 'admin_business_accounts_back_button.dart';
import 'admin_responsive_layout.dart';

typedef AdminSetupWorkspaceBuilder =
    Widget Function(
      BuildContext context,
      AdminHierarchyScopeIntent scope,
      AdminSetupWorkspaceSelection selection,
    );

class AdminSetupWorkspaceSelection {
  const AdminSetupWorkspaceSelection({
    required this.scope,
    required this.locationIds,
  });

  final AdminHierarchyScopeIntent scope;
  final Set<String> locationIds;
}

class AdminSetupWorkspace extends StatefulWidget {
  const AdminSetupWorkspace({
    super.key,
    required this.functionTitle,
    required this.operatorGateway,
    required this.functionBuilder,
    this.hierarchyGateway,
    this.initialScope,
    this.onScopeChanged,
    this.onBackToBusinessAccounts,
    this.description,
  });

  final String functionTitle;
  final String? description;
  final OperatorLocationAdminGateway operatorGateway;
  final RolesHierarchySessionsAdminGateway? hierarchyGateway;
  final AdminHierarchyScopeIntent? initialScope;
  final ValueChanged<AdminHierarchyScopeIntent>? onScopeChanged;
  final VoidCallback? onBackToBusinessAccounts;
  final AdminSetupWorkspaceBuilder functionBuilder;

  @override
  State<AdminSetupWorkspace> createState() => _AdminSetupWorkspaceState();
}

class _AdminSetupWorkspaceState extends State<AdminSetupWorkspace> {
  late Future<List<_BusinessScopeTree>> _future;
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _expandedOperatorIds = <String>{};
  AdminHierarchyScopeIntent? _selectedScope;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _selectedScope = widget.initialScope;
    final initialOperatorId = widget.initialScope?.operatorId;
    if (initialOperatorId != null) {
      _expandedOperatorIds.add(initialOperatorId);
    }
    _future = _load();
    _searchController.addListener(() {
      setState(() => _search = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void didUpdateWidget(covariant AdminSetupWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operatorGateway != widget.operatorGateway ||
        oldWidget.hierarchyGateway != widget.hierarchyGateway) {
      _future = _load();
    }
    if (oldWidget.initialScope != widget.initialScope &&
        widget.initialScope != null) {
      _selectedScope = widget.initialScope;
      _expandedOperatorIds.add(widget.initialScope!.operatorId);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<_BusinessScopeTree>> _load() async {
    final bundles = await widget.operatorGateway.listOperators();
    final hierarchyGateway = widget.hierarchyGateway;
    if (hierarchyGateway == null) {
      return <_BusinessScopeTree>[
        for (final bundle in bundles)
          _BusinessScopeTree.fromBundle(
            bundle: bundle,
            orgUnits: const <OrgUnitAdminNode>[],
            locations: <_WorkspaceLocation>[
              for (final location in bundle.locations)
                _WorkspaceLocation(
                  locationId: location.locationId,
                  name: location.name,
                  operatorId: location.operatorId,
                  orgUnitId: location.parentOrgUnitId,
                ),
            ],
          ),
      ];
    }
    return Future.wait(<Future<_BusinessScopeTree>>[
      for (final bundle in bundles)
        () async {
          final results = await Future.wait<Object>([
            hierarchyGateway.listOrgUnits(
              operatorId: bundle.operator.operatorId,
            ),
            hierarchyGateway.listHierarchyLocations(
              operatorId: bundle.operator.operatorId,
            ),
          ]);
          final orgUnits = results[0] as List<OrgUnitAdminNode>;
          final leaves = results[1] as List<HierarchyLocationLeaf>;
          return _BusinessScopeTree.fromBundle(
            bundle: bundle,
            orgUnits: orgUnits,
            locations: <_WorkspaceLocation>[
              if (leaves.isNotEmpty)
                for (final leaf in leaves)
                  _WorkspaceLocation(
                    locationId: leaf.locationId,
                    name: leaf.name,
                    operatorId: leaf.operatorId,
                    orgUnitId: leaf.orgUnitId,
                  )
              else
                for (final location in bundle.locations)
                  _WorkspaceLocation(
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

  void _selectScope(AdminHierarchyScopeIntent scope) {
    setState(() {
      _selectedScope = scope;
      _expandedOperatorIds.add(scope.operatorId);
    });
    widget.onScopeChanged?.call(scope);
  }

  void _toggleExpanded(String operatorId) {
    setState(() {
      if (!_expandedOperatorIds.add(operatorId)) {
        _expandedOperatorIds.remove(operatorId);
      }
    });
  }

  bool _matchesSearch(_BusinessScopeTree tree) {
    if (_search.isEmpty) return true;
    if (tree.operator.businessName.toLowerCase().contains(_search)) {
      return true;
    }
    for (final unit in tree.orgUnits) {
      if (unit.name.toLowerCase().contains(_search)) return true;
    }
    for (final location in tree.locations) {
      if (location.name.toLowerCase().contains(_search)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 920;
        return FutureBuilder<List<_BusinessScopeTree>>(
          future: _future,
          builder: (context, snapshot) {
            final trees = snapshot.data ?? const <_BusinessScopeTree>[];
            final selectedScope = _selectedScope;
            final selection = selectedScope == null
                ? null
                : _selectionForScope(trees, selectedScope);
            final scopePane = _ScopePane(
              trees: trees.where(_matchesSearch).toList(growable: false),
              searchController: _searchController,
              selectedScope: _selectedScope,
              expandedOperatorIds: _expandedOperatorIds,
              loading: snapshot.connectionState != ConnectionState.done,
              onSelectScope: _selectScope,
              onToggleExpanded: _toggleExpanded,
              forceExpanded: _search.isNotEmpty,
            );
            final functionPane = _FunctionPane(
              title: widget.functionTitle,
              description: widget.description,
              selectedScope: _selectedScope,
              onBackToBusinessAccounts: widget.onBackToBusinessAccounts,
              child: _selectedScope == null
                  ? null
                  : KeyedSubtree(
                      key: ValueKey<String>(
                        'admin_setup_function_${_selectedScope!.cacheKey}',
                      ),
                      child: widget.functionBuilder(
                        context,
                        _selectedScope!,
                        selection!,
                      ),
                    ),
            );
            if (compact) {
              return DefaultTabController(
                length: 2,
                child: Column(
                  key: const Key('admin_setup_workspace_tabs'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Material(
                      color: AppColors.backgroundMid,
                      child: TabBar(
                        labelColor: AppColors.textPrimary,
                        unselectedLabelColor: AppColors.textMuted,
                        indicatorColor: AppColors.sunsetDark,
                        tabs: [
                          const Tab(text: 'Scope'),
                          Tab(text: widget.functionTitle),
                        ],
                      ),
                    ),
                    Expanded(
                      child: TabBarView(children: [scopePane, functionPane]),
                    ),
                  ],
                ),
              );
            }
            return Row(
              key: const Key('admin_setup_workspace_split'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 360, child: scopePane),
                const VerticalDivider(width: 1),
                Expanded(child: functionPane),
              ],
            );
          },
        );
      },
    );
  }

  AdminSetupWorkspaceSelection _selectionForScope(
    List<_BusinessScopeTree> trees,
    AdminHierarchyScopeIntent scope,
  ) {
    _BusinessScopeTree? tree;
    for (final candidate in trees) {
      if (candidate.operator.operatorId == scope.operatorId) {
        tree = candidate;
        break;
      }
    }
    if (tree == null) {
      return AdminSetupWorkspaceSelection(
        scope: scope,
        locationIds: _fallbackLocationIds(scope),
      );
    }
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return AdminSetupWorkspaceSelection(
          scope: scope,
          locationIds: tree.locations
              .map((location) => location.locationId)
              .toSet(),
        );
      case AdminHierarchyScopeType.orgUnit:
        return AdminSetupWorkspaceSelection(
          scope: scope,
          locationIds: tree.locationIdsForOrgUnit(scope.orgUnitId),
        );
      case AdminHierarchyScopeType.location:
        return AdminSetupWorkspaceSelection(
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
}

class _ScopePane extends StatelessWidget {
  const _ScopePane({
    required this.trees,
    required this.searchController,
    required this.selectedScope,
    required this.expandedOperatorIds,
    required this.loading,
    required this.onSelectScope,
    required this.onToggleExpanded,
    required this.forceExpanded,
  });

  final List<_BusinessScopeTree> trees;
  final TextEditingController searchController;
  final AdminHierarchyScopeIntent? selectedScope;
  final Set<String> expandedOperatorIds;
  final bool loading;
  final ValueChanged<AdminHierarchyScopeIntent> onSelectScope;
  final ValueChanged<String> onToggleExpanded;
  final bool forceExpanded;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_setup_workspace_scope_pane'),
      color: AppColors.backgroundMid.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            if (loading) const LinearProgressIndicator(minHeight: 2),
            if (loading) const SizedBox(height: 12),
            Expanded(
              child: trees.isEmpty && !loading
                  ? const _EmptyHierarchyState()
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
                        return _BusinessTreeCard(
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

class _BusinessTreeCard extends StatelessWidget {
  const _BusinessTreeCard({
    required this.tree,
    required this.selectedScope,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onSelectScope,
  });

  final _BusinessScopeTree tree;
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
          _ScopeRow(
            key: Key('admin_setup_scope_business_${tree.operator.operatorId}'),
            icon: Icons.business_outlined,
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
        _ScopeRow(
          key: Key('admin_setup_scope_org_unit_${unit.orgUnitId}'),
          icon: Icons.account_tree_outlined,
          label: unit.name,
          detail: 'Org unit scope',
          selected: selectedScope?.cacheKey == scope.cacheKey,
          depth: parentPath.length + 1,
          onTap: () => onSelectScope(scope),
        ),
      );
      final locations =
          tree.locationsByOrgUnit[unit.orgUnitId] ??
          const <_WorkspaceLocation>[];
      for (final location in locations) {
        rows.add(_locationRow(location, path, unit));
      }
      rows.addAll(_buildOrgUnitRows(tree.childrenOf(unit), path));
    }
    return rows;
  }

  Widget _locationRow(
    _WorkspaceLocation location,
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
    return _ScopeRow(
      key: Key('admin_setup_scope_location_${location.locationId}'),
      icon: Icons.storefront_outlined,
      label: location.name,
      detail: 'Location scope',
      selected: selectedScope?.cacheKey == scope.cacheKey,
      depth: parentPath.length + 1,
      onTap: () => onSelectScope(scope),
    );
  }
}

class _ScopeRow extends StatelessWidget {
  const _ScopeRow({
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

class _FunctionPane extends StatelessWidget {
  const _FunctionPane({
    required this.title,
    required this.description,
    required this.selectedScope,
    required this.onBackToBusinessAccounts,
    required this.child,
  });

  final String title;
  final String? description;
  final AdminHierarchyScopeIntent? selectedScope;
  final VoidCallback? onBackToBusinessAccounts;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_setup_workspace_function_pane'),
      color: AppColors.backgroundDeep,
      child: child == null
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: AdminCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppTextStyles.sectionTitle(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Select a business, org unit, or location to open this setup function.',
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _WorkspaceHeader(
                  title: title,
                  description: description,
                  selectedScope: selectedScope!,
                  onBackToBusinessAccounts: onBackToBusinessAccounts,
                ),
                Expanded(child: child!),
              ],
            ),
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({
    required this.title,
    required this.description,
    required this.selectedScope,
    required this.onBackToBusinessAccounts,
  });

  final String title;
  final String? description;
  final AdminHierarchyScopeIntent selectedScope;
  final VoidCallback? onBackToBusinessAccounts;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_setup_workspace_header'),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border(
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (onBackToBusinessAccounts != null) ...[
            AdminBusinessAccountsBackButton(
              onPressed: onBackToBusinessAccounts!,
            ),
            const SizedBox(width: 10),
          ],
          const Icon(
            Icons.account_tree_outlined,
            size: 20,
            color: AppColors.sunsetDark,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: AppTextStyles.sectionTitle(
                    color: AppColors.textPrimary,
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    description!,
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  'Selected ${selectedScope.scopeType.label.toLowerCase()} scope: ${selectedScope.displayLabel}',
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.uiLabel(color: AppColors.peacockDark),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHierarchyState extends StatelessWidget {
  const _EmptyHierarchyState();

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

class _BusinessScopeTree {
  _BusinessScopeTree({
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
          .putIfAbsent(location.orgUnitId, () => <_WorkspaceLocation>[])
          .add(location);
    }
  }

  factory _BusinessScopeTree.fromBundle({
    required OperatorAdminBundle bundle,
    required List<OrgUnitAdminNode> orgUnits,
    required List<_WorkspaceLocation> locations,
  }) {
    return _BusinessScopeTree(
      operator: bundle.operator,
      orgUnits: orgUnits,
      locations: locations,
    );
  }

  final OperatorAdminRecord operator;
  final List<OrgUnitAdminNode> orgUnits;
  final List<_WorkspaceLocation> locations;
  final Map<String?, List<OrgUnitAdminNode>> _childrenByParent =
      <String?, List<OrgUnitAdminNode>>{};
  final Map<String, OrgUnitAdminNode> _orgUnitById =
      <String, OrgUnitAdminNode>{};
  final Map<String?, List<_WorkspaceLocation>> _locationsByOrgUnit =
      <String?, List<_WorkspaceLocation>>{};

  List<OrgUnitAdminNode> get rootOrgUnits =>
      _childrenByParent[null] ?? const <OrgUnitAdminNode>[];

  List<_WorkspaceLocation> get unassignedLocations =>
      _locationsByOrgUnit[null] ?? const <_WorkspaceLocation>[];

  Map<String?, List<_WorkspaceLocation>> get locationsByOrgUnit =>
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
          _locationsByOrgUnit[currentOrgUnitId] ?? const <_WorkspaceLocation>[];
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
}

class _WorkspaceLocation {
  const _WorkspaceLocation({
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
