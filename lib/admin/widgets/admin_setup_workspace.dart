import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_header_visibility.dart';

import '../../theme/app_theme.dart';
import '../admin_route_handoff.dart';
import '../services/operator_location_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
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
    this.allowAllBusinessesScope = false,
    this.allBusinessesBuilder,
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

  /// When true (and [allBusinessesBuilder] is provided), the scope picker
  /// shows an additive "All businesses" option that opens the
  /// platform-wide (cross-business) view. Opt-in and default off, so the
  /// other setup surfaces that share this workspace are unaffected.
  final bool allowAllBusinessesScope;

  /// Builds the function pane for the "All businesses" selection. Receives
  /// no hierarchy scope because the platform-wide view aggregates across
  /// every business (the screen reads with `operator_id = null`).
  final WidgetBuilder? allBusinessesBuilder;

  @override
  State<AdminSetupWorkspace> createState() => _AdminSetupWorkspaceState();
}

class _AdminSetupWorkspaceState extends State<AdminSetupWorkspace> {
  late Future<List<AdminScopeTree>> _future;
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _expandedOperatorIds = <String>{};
  AdminHierarchyScopeIntent? _selectedScope;
  String _search = '';
  bool _allBusinessesSelected = false;

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
      _allBusinessesSelected = false;
      _expandedOperatorIds.add(scope.operatorId);
    });
    widget.onScopeChanged?.call(scope);
  }

  void _selectAllBusinesses() {
    setState(() {
      _allBusinessesSelected = true;
      _selectedScope = null;
    });
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
            final showAllBusinesses =
                widget.allowAllBusinessesScope &&
                widget.allBusinessesBuilder != null;
            final scopePane = AdminScopeTreePane(
              trees: trees.where(_matchesSearch).toList(growable: false),
              searchController: _searchController,
              selectedScope: _selectedScope,
              expandedOperatorIds: _expandedOperatorIds,
              loading: snapshot.connectionState != ConnectionState.done,
              onSelectScope: _selectScope,
              onToggleExpanded: _toggleExpanded,
              forceExpanded: _search.isNotEmpty,
              showAllBusinesses: showAllBusinesses,
              allBusinessesSelected: _allBusinessesSelected,
              onSelectAllBusinesses: _selectAllBusinesses,
            );
            final Widget? functionChild;
            if (_allBusinessesSelected && widget.allBusinessesBuilder != null) {
              functionChild = KeyedSubtree(
                key: const ValueKey<String>(
                  'admin_setup_function_all_businesses',
                ),
                child: ConsoleHeaderVisibility(
                  suppressTitle: widget.showWorkspaceHeader,
                  child: widget.allBusinessesBuilder!(context),
                ),
              );
            } else if (_selectedScope == null) {
              functionChild = null;
            } else {
              functionChild = KeyedSubtree(
                key: ValueKey<String>(
                  'admin_setup_function_${_selectedScope!.cacheKey}',
                ),
                child: ConsoleHeaderVisibility(
                  suppressTitle: widget.showWorkspaceHeader,
                  child: widget.functionBuilder(
                    context,
                    _selectedScope!,
                    selection!,
                  ),
                ),
              );
            }
            final functionPane = _FunctionPane(
              title: widget.functionTitle,
              onBackToBusinessAccounts: widget.onBackToBusinessAccounts,
              showWorkspaceHeader: widget.showWorkspaceHeader,
              child: functionChild,
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
    required this.onBackToBusinessAccounts,
    required this.showWorkspaceHeader,
    required this.child,
  });

  final String title;
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
                child: _PickBusinessFirstState(
                  title: title,
                  onBackToBusinessAccounts: onBackToBusinessAccounts,
                ),
              ),
            )
          : child!,
    );
  }
}

class _PickBusinessFirstState extends StatelessWidget {
  const _PickBusinessFirstState({
    required this.title,
    required this.onBackToBusinessAccounts,
  });

  final String title;
  final VoidCallback? onBackToBusinessAccounts;

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      key: const Key('admin_setup_workspace_pick_business_first_state'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.sunset.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.apartment_outlined,
                  size: 20,
                  color: AppColors.sunsetDark,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pick a business first',
                      style: AppTextStyles.sectionTitle(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$title needs a selected business account before it can open.',
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Open Business accounts, choose the business, then this tab will load with that business selected.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          if (onBackToBusinessAccounts != null) ...[
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key(
                  'admin_setup_workspace_pick_business_first_link',
                ),
                onPressed: onBackToBusinessAccounts,
                icon: const Icon(Icons.apartment_outlined, size: 18),
                label: const Text('Open Business accounts'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
