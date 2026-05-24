// Phase 11A.0 - Admin shell.
//
// Branded scaffold that wraps the admin route surface. Renders a
// fixed left-side nav (icon + label) for desktop / wide web layouts
// and a brand header strip across the top with the signed-in admin
// identity and a sign-out affordance.
//
// The shell is intentionally render-only on a [List<AdminRoute>] -
// it does not own the route catalog. That lives in
// `admin_routes.dart` so later 11A.x slices add surfaces by
// extending the const list, not by editing the shell.

import 'package:flutter/material.dart';

import '../auth/permission_keys.dart';
import '../theme/app_theme.dart';
import 'admin_auth_gate.dart';
import 'admin_route_handoff.dart';
import 'admin_routes.dart';
import 'services/operator_location_admin_gateway.dart';
import 'widgets/admin_demo_banner.dart';
import 'widgets/admin_scope_picker.dart';

const double _kCompactShellBreakpoint = 720;

/// Fixed width of the wide-layout left side nav. Sized so the longest
/// nav labels ("Vendor Applicability", "Roles & permissions") and the
/// widest route badge ("Support + location repair") render in full
/// rather than truncating with an ellipsis. The label column works out
/// to roughly `_kSideNavWidth - 80` after the container, section-panel,
/// nav-item, and icon insets.
const double _kSideNavWidth = 280;

/// UX-parity Slice C — the six per-business screens, in the order the
/// approved mock renders them (`docs/_mockups/admin_unified_scope_sample.html`,
/// the `PERBIZ` cluster). These routes are `visibleInNav: false` in
/// [kAdminRoutes] because they need a business scope; the scope-aware
/// nav cluster surfaces them with operator-web vocabulary once a business
/// is selected, routing through the SAME `_selectIntent` scope path the
/// Business accounts drill-in uses. The Business accounts drill-in stays
/// the entry point when no scope is selected.
const List<String> kAdminPerBusinessClusterRouteIds = <String>[
  kAdminMembersRouteId,
  kAdminRolesHierarchySessionsRouteId,
  kAdminAuditedSupportActionsRouteId,
  kAdminVendorIntegrationsRouteId,
  kAdminDataAccuracyRouteId,
  kAdminTimingSetupRouteId,
];

class AdminShell extends StatefulWidget {
  const AdminShell({
    super.key,
    required this.session,
    required this.authSource,
    this.routes = kAdminRoutes,
    this.initialRouteId = kAdminOperatorsRouteId,
    this.sharePreviewMode = false,
  });

  final AdminAuthSession session;
  final AdminAuthSource authSource;
  final List<AdminRoute> routes;
  final String initialRouteId;
  final bool sharePreviewMode;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  late String _selectedRouteId;
  AdminSupportLogFilterIntent? _supportLogFilter;
  AdminOperatorLocationScopeIntent? _operatorLocationScope;
  AdminHierarchyScopeIntent? _hierarchyScope;

  /// UX-parity Slice C — whether the operator has DELIBERATELY chosen a
  /// business to manage (top-bar scope picker, a Business-accounts
  /// drill-in, or a per-business surface), as opposed to the operators
  /// list's automatic highlight of its first row on load. The per-business
  /// nav cluster gates on this so it stays absent on the bare Business
  /// accounts landing (the drill-in remains the entry point) and appears
  /// only once a business is genuinely selected. Latches true for the
  /// session; there is no "clear scope" affordance today.
  bool _businessScopeChosen = false;

  @override
  void initState() {
    super.initState();
    _selectedRouteId = _routeIdOrFallback(widget.initialRouteId);
  }

  String _routeIdOrFallback(String requested) {
    final hit = widget.routes.firstWhere(
      (r) => r.id == requested,
      orElse: () => widget.routes.first,
    );
    return hit.id;
  }

  AdminRoute get _currentRoute => widget.routes.firstWhere(
    (r) => r.id == _selectedRouteId,
    orElse: () => widget.routes.first,
  );

  String get _selectedNavRouteId =>
      _currentRoute.navAnchorRouteId ?? _selectedRouteId;

  void _selectIntent(AdminRouteIntent intent) {
    final nextRouteId = _routeIdOrFallback(intent.routeId);
    final explicitHierarchyScope = intent.effectiveHierarchyScope;
    final nextSupportLogFilter = nextRouteId == kAdminDebugConsoleRouteId
        ? intent.supportLogFilter ??
              (explicitHierarchyScope == null
                  ? null
                  : AdminSupportLogFilterIntent.fromHierarchyScope(
                      explicitHierarchyScope,
                    ))
        : null;
    final nextHierarchyScope = explicitHierarchyScope ?? _hierarchyScope;
    final nextOperatorLocationScope =
        nextHierarchyScope?.toOperatorLocationScope() ??
        intent.operatorLocationScope ??
        _operatorLocationScope;
    // A scope counts as deliberately chosen when the intent carries an
    // explicit hierarchy scope (top-bar picker / scope prompt) or targets a
    // per-business surface (a Business-accounts drill-in). The operators
    // list's auto-highlight emits only `operatorLocationScope` while staying
    // on the operators route, so it never flips this on. Latches once true.
    final nextBusinessScopeChosen =
        _businessScopeChosen ||
        _intentChoosesBusinessScope(intent, nextRouteId);
    if (_selectionUnchanged(
      nextRouteId: nextRouteId,
      nextSupportLogFilter: nextSupportLogFilter,
      nextOperatorLocationScope: nextOperatorLocationScope,
      nextHierarchyScope: nextHierarchyScope,
      nextBusinessScopeChosen: nextBusinessScopeChosen,
    )) {
      return;
    }
    setState(() {
      _selectedRouteId = nextRouteId;
      _supportLogFilter = nextSupportLogFilter;
      _operatorLocationScope = nextOperatorLocationScope;
      _hierarchyScope = nextHierarchyScope;
      _businessScopeChosen = nextBusinessScopeChosen;
    });
  }

  /// True when a recomputed selection matches the current shell state, so
  /// `_selectIntent` can early-return without a rebuild. Extracted so the
  /// equality chain does not count against `_selectIntent`'s complexity.
  bool _selectionUnchanged({
    required String nextRouteId,
    required AdminSupportLogFilterIntent? nextSupportLogFilter,
    required AdminOperatorLocationScopeIntent? nextOperatorLocationScope,
    required AdminHierarchyScopeIntent? nextHierarchyScope,
    required bool nextBusinessScopeChosen,
  }) {
    return nextRouteId == _selectedRouteId &&
        nextSupportLogFilter == _supportLogFilter &&
        nextOperatorLocationScope == _operatorLocationScope &&
        nextHierarchyScope == _hierarchyScope &&
        nextBusinessScopeChosen == _businessScopeChosen;
  }

  void _select(String id) {
    _selectIntent(AdminRouteIntent(routeId: id));
  }

  Widget _buildRouteBody() {
    return AdminRouteHandoff(
      selectedRouteId: _selectedRouteId,
      supportLogFilter: _supportLogFilter,
      operatorLocationScope: _operatorLocationScope,
      hierarchyScope: _hierarchyScope,
      onSelectRoute: _selectIntent,
      child: _AdminBody(
        key: ValueKey(
          'admin-body-${_currentRoute.id}-'
          '${_supportLogFilter?.cacheKey ?? 'none'}-'
          '${_routeUsesOperatorScope(_currentRoute.id) ? _hierarchyScope?.cacheKey ?? _operatorLocationScope?.cacheKey ?? 'all' : 'global'}',
        ),
        route: _currentRoute,
      ),
    );
  }

  /// Routes a scope chosen in the top-bar picker through the SAME
  /// `_selectIntent` path the Business accounts drill-in uses, so the
  /// six scope-aware screens react identically. Keeps the current route
  /// selected — the picker changes scope, not destination.
  void _selectScope(AdminHierarchyScopeIntent scope) {
    _selectIntent(
      AdminRouteIntent(routeId: _selectedRouteId, hierarchyScope: scope),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scopeGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
      context,
    );
    return Scaffold(
      key: const Key('admin_shell_scaffold'),
      backgroundColor: AppColors.backgroundDeep,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < _kCompactShellBreakpoint;
            return Column(
              children: [
                _AdminHeaderBar(
                  session: widget.session,
                  onSignOut: () => widget.authSource.signOut(),
                  sharePreviewMode: widget.sharePreviewMode,
                  scopeGateway: scopeGateway,
                  selectedScope: _hierarchyScope,
                  onSelectScope: _selectScope,
                ),
                AdminDemoBanner(sharePreviewMode: widget.sharePreviewMode),
                Expanded(
                  child: compact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _AdminCompactNav(
                              routes: widget.routes,
                              selectedRouteId: _selectedNavRouteId,
                              onSelect: _select,
                            ),
                            Expanded(child: _buildRouteBody()),
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _AdminSideNav(
                              routes: widget.routes,
                              selectedRouteId: _selectedNavRouteId,
                              activeRouteId: _selectedRouteId,
                              // Only feed a scope to the cluster once a
                              // business has been deliberately chosen, so the
                              // cluster is absent on the bare landing.
                              scope: _businessScopeChosen ? _hierarchyScope : null,
                              onSelect: _select,
                            ),
                            Expanded(child: _buildRouteBody()),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AdminCompactNav extends StatelessWidget {
  const _AdminCompactNav({
    required this.routes,
    required this.selectedRouteId,
    required this.onSelect,
  });

  final List<AdminRoute> routes;
  final String selectedRouteId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_compact_nav'),
      height: 74,
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border(
          bottom: BorderSide(
            color: AppColors.borderSubtle.withValues(alpha: 0.7),
            width: 1,
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          children: [
            for (final route in routes.where(
              (route) => route.visibleInNav,
            )) ...[
              _CompactNavItem(
                key: Key('admin_nav_item_${route.id}'),
                route: route,
                selected: route.id == selectedRouteId,
                onTap: () => onSelect(route.id),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _CompactNavItem extends StatelessWidget {
  const _CompactNavItem({
    super.key,
    required this.route,
    required this.selected,
    required this.onTap,
  });

  final AdminRoute route;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? AppColors.textPrimary : AppColors.textMuted;
    return Semantics(
      selected: selected,
      button: true,
      label: route.title,
      child: Material(
        color: selected
            ? AppColors.sunset.withValues(alpha: 0.10)
            : AppColors.backgroundDeep.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            width: 154,
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected
                    ? AppColors.sunset.withValues(alpha: 0.45)
                    : AppColors.borderSubtle.withValues(alpha: 0.75),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  route.icon,
                  size: 18,
                  color: selected ? AppColors.sunsetDark : AppColors.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    route.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body13(color: foreground),
                  ),
                ),
                if (route.placeholder) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.schedule_outlined,
                    size: 14,
                    color: AppColors.textMuted,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// UX-parity Slice C — whether [intent] represents a DELIBERATE business
/// selection (an explicit hierarchy scope from the top-bar picker / scope
/// prompt, or navigation into a per-business surface) rather than the
/// operators list's automatic first-row highlight. Extracted from
/// `_selectIntent` to keep that method within the complexity ratchet.
bool _intentChoosesBusinessScope(AdminRouteIntent intent, String nextRouteId) {
  if (intent.hierarchyScope != null) return true;
  return kAdminPerBusinessClusterRouteIds.contains(nextRouteId);
}

/// UX-parity Slice C — the [AdminRoute]s for the per-business cluster, in
/// [kAdminPerBusinessClusterRouteIds] order, filtered to those present in
/// [routes]. Top-level helper so the nested lookup does not count against
/// the side-nav cluster builder's complexity ratchet.
List<AdminRoute> _resolvePerBusinessClusterRoutes(List<AdminRoute> routes) {
  final byId = <String, AdminRoute>{for (final route in routes) route.id: route};
  return <AdminRoute>[
    for (final routeId in kAdminPerBusinessClusterRouteIds)
      if (byId[routeId] case final AdminRoute route) route,
  ];
}

bool _routeUsesOperatorScope(String routeId) {
  return routeId == kAdminDataAccuracyRouteId ||
      routeId == kAdminPollingPricingRouteId ||
      routeId == kAdminSupportOperatorViewRouteId ||
      routeId == kAdminMembersRouteId ||
      routeId == kAdminRolesHierarchySessionsRouteId ||
      routeId == kAdminAuditedSupportActionsRouteId;
}

class _AdminHeaderBar extends StatelessWidget {
  const _AdminHeaderBar({
    required this.session,
    required this.onSignOut,
    required this.sharePreviewMode,
    required this.scopeGateway,
    required this.selectedScope,
    required this.onSelectScope,
  });

  final AdminAuthSession session;
  final VoidCallback onSignOut;
  final bool sharePreviewMode;
  final OperatorLocationAdminGateway scopeGateway;
  final AdminHierarchyScopeIntent? selectedScope;
  final ValueChanged<AdminHierarchyScopeIntent> onSelectScope;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        return Container(
          key: const Key('admin_header_bar'),
          // UX-parity Slice B (V3): grown 64 to 96 to match operator-web
          // proportions and give the top-bar scope picker room.
          height: 96,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.backgroundDeep,
                AppColors.backgroundDeep.withValues(alpha: 0.85),
              ],
            ),
            border: Border(
              bottom: BorderSide(
                color: AppColors.borderSubtle.withValues(alpha: 0.7),
                width: 1,
              ),
            ),
          ),
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 20),
          child: Row(
            children: [
              ClipOval(
                child: Image.asset(
                  'assets/images/forge_flow_splash_icon.png',
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Forge & Flow',
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.display20(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        'Admin Console',
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.mono10(
                          color: AppColors.sunsetDark,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              // The top-bar scope picker is a wide-layout affordance. On
              // the compact header (narrow widths use the horizontal
              // compact nav) it is hidden — there is no room beside the
              // brand, role pill, and sign out.
              if (!compact) ...[
                Flexible(
                  child: AdminScopePicker(
                    gateway: scopeGateway,
                    selectedScope: selectedScope,
                    onSelectScope: onSelectScope,
                  ),
                ),
                const SizedBox(width: 12),
              ],
              if (sharePreviewMode) ...[
                const _SharePreviewPill(),
                SizedBox(width: compact ? 6 : 10),
              ],
              _RolePill(roles: session.roles),
              if (!compact) ...[
                const SizedBox(width: 12),
                Flexible(child: _IdentityChip(session: session)),
              ],
              if (!sharePreviewMode) SizedBox(width: compact ? 6 : 8),
              if (sharePreviewMode)
                const SizedBox.shrink()
              else if (compact)
                IconButton(
                  key: const Key('admin_header_signout'),
                  tooltip: 'Sign out',
                  onPressed: onSignOut,
                  icon: const Icon(
                    Icons.logout_outlined,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                )
              else
                Tooltip(
                  message:
                      'Sign out: ends this session and returns to the '
                      'welcome screen.',
                  child: TextButton.icon(
                    key: const Key('admin_header_signout'),
                    onPressed: onSignOut,
                    icon: const Icon(
                      Icons.logout_outlined,
                      size: 22,
                      color: AppColors.textSecondary,
                    ),
                    label: Text(
                      'Sign out',
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      foregroundColor: AppColors.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SharePreviewPill extends StatelessWidget {
  const _SharePreviewPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_header_share_preview_pill'),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.ocean.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.ocean.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Demo data',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.chipLabel(color: AppColors.peacockDark),
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  const _RolePill({required this.roles});

  final List<String> roles;

  @override
  Widget build(BuildContext context) {
    final adminRole = roles.firstWhere(
      kAdminConsoleRoles.contains,
      orElse: () => roles.isEmpty ? 'unknown' : roles.first,
    );
    final roleLabel = switch (adminRole) {
      PermissionKeys.roleSuperAdmin => 'Ecosystem admin',
      PermissionKeys.roleFfSupport => 'Support access',
      'unknown' => 'Unknown role',
      _ => adminRole.replaceAll('_', ' '),
    };
    return Container(
      key: const Key('admin_header_role_pill'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.12),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        roleLabel,
        style: AppTextStyles.mono8(color: AppColors.peacockDark),
      ),
    );
  }
}

class _IdentityChip extends StatelessWidget {
  const _IdentityChip({required this.session});

  final AdminAuthSession session;

  @override
  Widget build(BuildContext context) {
    final label = session.email.isNotEmpty ? session.email : session.uid;
    return Text(
      label,
      key: const Key('admin_header_identity'),
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.mono14(color: AppColors.textSecondary),
    );
  }
}

class _AdminSideNav extends StatelessWidget {
  const _AdminSideNav({
    required this.routes,
    required this.selectedRouteId,
    required this.activeRouteId,
    required this.scope,
    required this.onSelect,
  });

  final List<AdminRoute> routes;

  /// The nav row to highlight in the standing sections. Setup-only routes
  /// resolve this to their `navAnchorRouteId` (Business accounts), so the
  /// anchor stays lit while a per-business screen is open.
  final String selectedRouteId;

  /// The route actually open. Used only to highlight the per-business
  /// cluster row (which is the real destination, not the anchor).
  final String activeRouteId;

  /// The active business/location scope, or null when nothing is picked.
  /// The per-business cluster renders only when this is non-null.
  final AdminHierarchyScopeIntent? scope;

  final ValueChanged<String> onSelect;

  static const List<_NavSectionMeta> _sections = <_NavSectionMeta>[
    _NavSectionMeta(
      section: AdminRouteSection.operations,
      label: 'Operations',
      icon: Icons.storefront_outlined,
      accentColor: AppColors.sunset,
    ),
    _NavSectionMeta(
      section: AdminRouteSection.ai,
      label: 'AI',
      icon: Icons.auto_awesome_outlined,
      accentColor: AppColors.peacock,
      badge: 'Work in progress',
    ),
    _NavSectionMeta(
      section: AdminRouteSection.systemMonitoring,
      label: 'System monitoring',
      icon: Icons.monitor_heart_outlined,
      accentColor: AppColors.warning,
    ),
    _NavSectionMeta(
      section: AdminRouteSection.serviceSetup,
      label: 'Service setup',
      icon: Icons.settings_input_component_outlined,
      accentColor: AppColors.ocean,
    ),
    // Wave 2 W-4 — admin "My Account" parity section. Renders the
    // My Account row at the bottom of the side nav, mirroring the
    // operator-web shape where the account row anchors the navigation.
    _NavSectionMeta(
      section: AdminRouteSection.account,
      label: 'Your account',
      icon: Icons.person_outline,
      accentColor: AppColors.peacock,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_side_nav'),
      width: _kSideNavWidth,
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border(
          right: BorderSide(
            color: AppColors.borderSubtle.withValues(alpha: 0.7),
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._buildPerBusinessCluster(context),
            for (final section in _sections) ..._buildSection(context, section),
          ],
        ),
      ),
    );
  }

  /// UX-parity Slice C — the scope-gated per-business cluster. Absent
  /// until a business/location scope is active; the existing Business
  /// accounts drill-in remains the entry point. Headed by the selected
  /// business name and listing the six per-business screens with
  /// operator-web vocabulary, each routing through the shell's existing
  /// `onSelect` -> `_selectIntent` path, which carries the active scope
  /// forward (it preserves `_hierarchyScope` when an intent omits one).
  List<Widget> _buildPerBusinessCluster(BuildContext context) {
    final activeScope = scope;
    if (activeScope == null) return const <Widget>[];
    final clusterRoutes = _resolvePerBusinessClusterRoutes(routes);
    if (clusterRoutes.isEmpty) return const <Widget>[];
    final businessName = _businessClusterLabel(activeScope);
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DecoratedBox(
          key: const Key('admin_nav_per_business_cluster'),
          decoration: BoxDecoration(
            color: AppColors.sunset.withValues(alpha: 0.055),
            border: Border.all(
              color: AppColors.sunset.withValues(alpha: 0.18),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PerBusinessClusterHeader(businessName: businessName),
                const SizedBox(height: 8),
                for (final route in clusterRoutes)
                  _NavItem(
                    key: Key('admin_nav_cluster_item_${route.id}'),
                    route: route,
                    selected: route.id == activeRouteId,
                    onTap: () => onSelect(route.id),
                  ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  /// The business name shown as the cluster header. Falls back to a plain
  /// "Selected business" when the scope carries no operator name.
  static String _businessClusterLabel(AdminHierarchyScopeIntent scope) {
    final name = (scope.operatorName ?? '').trim();
    return name.isEmpty ? 'Selected business' : name;
  }

  List<Widget> _buildSection(BuildContext context, _NavSectionMeta section) {
    final sectionRoutes = routes
        .where(
          (route) => route.section == section.section && route.visibleInNav,
        )
        .toList(growable: false);
    if (sectionRoutes.isEmpty) return const <Widget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DecoratedBox(
          key: Key('admin_nav_section_panel_${section.section.name}'),
          decoration: BoxDecoration(
            color: section.accentColor.withValues(alpha: 0.055),
            border: Border.all(
              color: section.accentColor.withValues(alpha: 0.18),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _NavSectionHeader(section: section),
                const SizedBox(height: 8),
                _NavSectionDivider(section: section),
                const SizedBox(height: 8),
                for (final route in sectionRoutes)
                  _NavItem(
                    key: Key('admin_nav_item_${route.id}'),
                    route: route,
                    selected: route.id == selectedRouteId,
                    onTap: () => onSelect(route.id),
                  ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

/// Header row for the per-business cluster: a business icon plus the
/// selected business name, styled like the mock's per-business group
/// label (sunset-dark name, building glyph).
class _PerBusinessClusterHeader extends StatelessWidget {
  const _PerBusinessClusterHeader({required this.businessName});

  final String businessName;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('admin_nav_per_business_cluster_header'),
      padding: const EdgeInsets.fromLTRB(2, 0, 0, 0),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.sunset.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(
              Icons.business_outlined,
              size: 16,
              color: AppColors.sunsetDark,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              businessName,
              key: const Key('admin_nav_per_business_cluster_business_name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.uiLabel(color: AppColors.sunsetDark),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavSectionDivider extends StatelessWidget {
  const _NavSectionDivider({required this.section});

  final _NavSectionMeta section;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: Key('admin_nav_section_divider_${section.section.name}'),
      children: [
        Container(
          width: 34,
          height: 2,
          decoration: BoxDecoration(
            color: section.accentColor.withValues(alpha: 0.52),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              color: AppColors.borderSubtle.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ],
    );
  }
}

class _NavSectionMeta {
  const _NavSectionMeta({
    required this.section,
    required this.label,
    required this.icon,
    required this.accentColor,
    this.badge,
  });

  final AdminRouteSection section;
  final String label;
  final IconData icon;
  final Color accentColor;
  final String? badge;
}

class _NavSectionHeader extends StatelessWidget {
  const _NavSectionHeader({required this.section});

  final _NavSectionMeta section;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('admin_nav_section_${section.section.name}'),
      padding: const EdgeInsets.fromLTRB(2, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                key: Key('admin_nav_section_icon_${section.section.name}'),
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: section.accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  section.icon,
                  size: 16,
                  color: Color.alphaBlend(
                    section.accentColor.withValues(alpha: 0.88),
                    AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  section.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.uiLabel(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          if (section.badge != null) ...[
            const SizedBox(height: 7),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                key: Key('admin_nav_section_badge_${section.section.name}'),
                constraints: const BoxConstraints(maxWidth: 150),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.peacock.withValues(alpha: 0.10),
                  border: Border.all(
                    color: AppColors.peacock.withValues(alpha: 0.35),
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  section.badge!,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.chipLabel(color: AppColors.peacockDark),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.route,
    required this.selected,
    required this.onTap,
  });

  final AdminRoute route;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? AppColors.sunset.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected
                    ? AppColors.sunset.withValues(alpha: 0.55)
                    : Colors.transparent,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  route.icon,
                  size: 18,
                  color: selected
                      ? AppColors.sunsetDark
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        route.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.body14(
                          color: selected
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                        ),
                      ),
                      if (route.badge != null) ...[
                        const SizedBox(height: 4),
                        _NavRouteBadge(routeId: route.id, label: route.badge!),
                      ],
                    ],
                  ),
                ),
                if (route.placeholder)
                  Text(
                    'Coming soon',
                    style: AppTextStyles.chipLabel(color: AppColors.textMuted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavRouteBadge extends StatelessWidget {
  const _NavRouteBadge({required this.routeId, required this.label});

  final String routeId;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_nav_item_badge_$routeId'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.chipLabel(color: AppColors.peacockDark),
      ),
    );
  }
}

class _AdminBody extends StatelessWidget {
  const _AdminBody({super.key, required this.route});

  final AdminRoute route;

  @override
  Widget build(BuildContext context) {
    if (route.placeholder) {
      return _PlaceholderBody(route: route);
    }
    return route.builder(context);
  }
}

class _PlaceholderBody extends StatelessWidget {
  const _PlaceholderBody({required this.route});

  final AdminRoute route;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: Key('admin_placeholder_${route.id}'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(route.icon, size: 22, color: AppColors.sunsetDark),
                  const SizedBox(width: 10),
                  Text(
                    route.title,
                    style: AppTextStyles.display20(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                route.subtitle ?? 'This page is not ready yet.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
