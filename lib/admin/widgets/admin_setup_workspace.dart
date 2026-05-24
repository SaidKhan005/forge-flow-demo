import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_route_handoff.dart';
import '../services/operator_location_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import 'admin_business_accounts_back_button.dart';
import 'admin_responsive_layout.dart';
import 'admin_scope_tree_pane.dart';

typedef AdminSetupWorkspaceBuilder =
    Widget Function(
      BuildContext context,
      AdminHierarchyScopeIntent scope,
      AdminSetupWorkspaceSelection selection,
    );

/// Backward-compatible alias. The selection contract now lives in the
/// shared scope-tree pane ([AdminScopeSelection]) so the AI workspace
/// and the Business accounts screen share one type; existing callers
/// (e.g. `admin_routes.dart`) keep using `AdminSetupWorkspaceSelection`.
typedef AdminSetupWorkspaceSelection = AdminScopeSelection;

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
    this.showWorkspaceHeader = true,
  });

  final String functionTitle;
  final String? description;
  final OperatorLocationAdminGateway operatorGateway;
  final RolesHierarchySessionsAdminGateway? hierarchyGateway;
  final AdminHierarchyScopeIntent? initialScope;
  final ValueChanged<AdminHierarchyScopeIntent>? onScopeChanged;
  final VoidCallback? onBackToBusinessAccounts;
  final AdminSetupWorkspaceBuilder functionBuilder;

  /// When false, the function pane renders the builder's screen WITHOUT
  /// the generic workspace header bar, so a screen that owns a web-style
  /// `OperatorWebScreenHeader` (Team members, Vendor integrations, ...)
  /// is the single page header (operator-web parity). The 360px scope
  /// tree pane is unaffected. Defaults true for the setup workspaces that
  /// still rely on the shared header.
  final bool showWorkspaceHeader;

  @override
  State<AdminSetupWorkspace> createState() => _AdminSetupWorkspaceState();
}

class _AdminSetupWorkspaceState extends State<AdminSetupWorkspace> {
  late Future<List<AdminScopeTree>> _future;
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

  Future<List<AdminScopeTree>> _load() {
    return loadAdminScopeTrees(
      operatorGateway: widget.operatorGateway,
      hierarchyGateway: widget.hierarchyGateway,
    );
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

  bool _matchesSearch(AdminScopeTree tree) => tree.matchesSearch(_search);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 920;
        return FutureBuilder<List<AdminScopeTree>>(
          future: _future,
          builder: (context, snapshot) {
            final trees = snapshot.data ?? const <AdminScopeTree>[];
            final selectedScope = _selectedScope;
            final selection = selectedScope == null
                ? null
                : resolveAdminScopeSelection(trees, selectedScope);
            final scopePane = AdminScopeTreePane(
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
              showWorkspaceHeader: widget.showWorkspaceHeader,
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
}

class _FunctionPane extends StatelessWidget {
  const _FunctionPane({
    required this.title,
    required this.description,
    required this.selectedScope,
    required this.onBackToBusinessAccounts,
    required this.showWorkspaceHeader,
    required this.child,
  });

  final String title;
  final String? description;
  final AdminHierarchyScopeIntent? selectedScope;
  final VoidCallback? onBackToBusinessAccounts;
  final bool showWorkspaceHeader;
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
          : showWorkspaceHeader
          ? Column(
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
            )
          : child!,
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
            size: 22,
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
                  style: AppTextStyles.display20(
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

