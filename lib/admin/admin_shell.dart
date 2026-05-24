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

import '../theme/app_theme.dart';
import '../theme/scope_icons.dart';
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
            children: <Widget>[
              // LEFT zone: brand mark + wordmark, left-aligned. Equal flex
              // with the right zone keeps the fixed-width picker at the true
              // centre of the bar (operator-web parity).
              Expanded(
                child: Row(
                  children: <Widget>[
                    ClipOval(
                      child: Image.asset(
                        'assets/images/forge_flow_splash_icon.png',
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      ),
                    ),
                    if (!compact) ...<Widget>[
                      const SizedBox(width: 12),
                      Flexible(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
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
                  ],
                ),
              ),
              // CENTRE zone: the management-scope picker, fixed to the same
              // width operator-web uses so the two consoles line up. Hidden
              // on the compact header (the Business accounts drill-in stays
              // the entry point there).
              if (!compact)
                SizedBox(
                  width: _pickerWidthFor(constraints.maxWidth),
                  child: AdminScopePicker(
                    gateway: scopeGateway,
                    selectedScope: selectedScope,
                    onSelectScope: onSelectScope,
                  ),
                ),
              // RIGHT zone: signed-in identity + sign out, right-aligned.
              // Equal flex with the left zone keeps the picker centred. The
              // demo-data and role badges were removed to declutter the bar;
              // demo state still shows in the banner below the header.
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    if (!compact) ...<Widget>[
                      Flexible(child: _IdentityChip(session: session)),
                      if (!sharePreviewMode) const SizedBox(width: 12),
                    ],
                    _signOutControl(compact: compact),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Sign-out affordance. Hidden in share-preview mode (read-only demo
  /// walkthroughs never sign out); a compact icon button on narrow
  /// headers; an operator-web-style flat text button otherwise.
  Widget _signOutControl({required bool compact}) {
    if (sharePreviewMode) return const SizedBox.shrink();
    if (compact) {
      return IconButton(
        key: const Key('admin_header_signout'),
        tooltip: 'Sign out',
        onPressed: onSignOut,
        icon: const Icon(
          Icons.logout_outlined,
          size: 20,
          color: AppColors.textSecondary,
        ),
      );
    }
    return Tooltip(
      message:
          'Sign out: ends this session and returns to the welcome screen.',
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
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          foregroundColor: AppColors.textSecondary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  /// Picker width mirroring operator-web's header so the admin "Managing"
  /// control is the same width as the operator-web management-scope picker.
  static double _pickerWidthFor(double maxWidth) {
    if (maxWidth >= 1440) return 540;
    if (maxWidth >= 1180) return 460;
    if (maxWidth >= 980) return 340;
    return 220;
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
      icon: Icons.dashboard_outlined,
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
            // Operator-approved IA: Business accounts is pinned at the very
            // top (the entry point for picking a business), the per-business
            // cluster sits directly below it, then the standing sections.
            // The Operations section renders WITHOUT Business accounts so the
            // row appears exactly once.
            ..._buildPinnedBusinessAccounts(context),
            ..._buildPerBusinessCluster(context),
            for (final section in _sections) ..._buildSection(context, section),
          ],
        ),
      ),
    );
  }

  /// Operator-approved IA — the Business accounts row pinned at the top of
  /// the wide side nav. Rendered outside [_buildSection] so it leads the
  /// nav; [_buildSection] then excludes it from the Operations panel so it
  /// is never duplicated. Keeps the standing `admin_nav_item_operators`
  /// item key so existing selectors and the compact nav stay aligned.
  List<Widget> _buildPinnedBusinessAccounts(BuildContext context) {
    final route = routes.firstWhere(
      (route) => route.id == kAdminOperatorsRouteId,
      orElse: () => routes.first,
    );
    if (route.id != kAdminOperatorsRouteId) return const <Widget>[];
    return <Widget>[
      Padding(
        key: const Key('admin_nav_business_accounts_pinned'),
        padding: const EdgeInsets.only(bottom: 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.sunset.withValues(alpha: 0.055),
            border: Border.all(
              color: AppColors.sunset.withValues(alpha: 0.18),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: _NavItem(
              key: Key('admin_nav_item_${route.id}'),
              route: route,
              selected: route.id == selectedRouteId,
              onTap: () => onSelect(route.id),
            ),
          ),
        ),
      ),
    ];
  }

  /// The per-business cluster of the six scope-aware screens. Operator-
  /// approved IA: the cluster is ALWAYS visible so the per-business
  /// surfaces are discoverable.
  ///
  /// - When a business/location scope is active, the cluster is headed by
  ///   the selected business name and its six rows are live, each routing
  ///   through the shell's existing `onSelect` -> `_selectIntent` path,
  ///   which carries the active scope forward (it preserves
  ///   `_hierarchyScope` when an intent omits one).
  /// - When NO business is picked yet, the same six rows render in a muted,
  ///   inactive state under a "Pick a business first" hint. They do not open
  ///   the per-business screens and do not auto-select a business; tapping a
  ///   row (or the hint) routes to Business accounts so the operator chooses
  ///   a business there. This preserves the deliberate-choice scope model.
  List<Widget> _buildPerBusinessCluster(BuildContext context) {
    final clusterRoutes = _resolvePerBusinessClusterRoutes(routes);
    if (clusterRoutes.isEmpty) return const <Widget>[];
    final activeScope = scope;
    return activeScope == null
        ? _buildInactivePerBusinessCluster(clusterRoutes)
        : _buildActivePerBusinessCluster(activeScope, clusterRoutes);
  }

  /// The active cluster: live rows headed by the selected business name.
  List<Widget> _buildActivePerBusinessCluster(
    AdminHierarchyScopeIntent activeScope,
    List<AdminRoute> clusterRoutes,
  ) {
    final businessName = _businessClusterLabel(activeScope);
    return <Widget>[
      _clusterShell(
        key: const Key('admin_nav_per_business_cluster'),
        children: <Widget>[
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
    ];
  }

  /// The inactive cluster shown before a business is picked: the same six
  /// rows, muted and non-navigating, under a "Pick a business first" hint.
  /// Every row (and the hint) routes to Business accounts via `onSelect`.
  List<Widget> _buildInactivePerBusinessCluster(
    List<AdminRoute> clusterRoutes,
  ) {
    void goToBusinessAccounts() => onSelect(kAdminOperatorsRouteId);
    return <Widget>[
      _clusterShell(
        key: const Key('admin_nav_per_business_cluster_inactive'),
        children: <Widget>[
          _PerBusinessClusterInactiveHint(onTap: goToBusinessAccounts),
          const SizedBox(height: 8),
          for (final route in clusterRoutes)
            _NavItem(
              key: Key('admin_nav_cluster_item_${route.id}'),
              route: route,
              selected: false,
              enabled: false,
              onTap: goToBusinessAccounts,
            ),
        ],
      ),
    ];
  }

  /// The sunset-tinted container both cluster states share.
  Widget _clusterShell({required Key key, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        key: key,
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
            children: children,
          ),
        ),
      ),
    );
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
          (route) =>
              route.section == section.section &&
              route.visibleInNav &&
              // Business accounts is pinned at the top by
              // [_buildPinnedBusinessAccounts]; exclude it here so the
              // Operations panel never duplicates the row.
              route.id != kAdminOperatorsRouteId,
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
            child: Icon(
              scopeIcon(kind: ScopeEntityKind.business),
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

/// Hint row shown atop the per-business cluster before a business is
/// picked. Reads "Pick a business first" in a muted style and is tappable:
/// tapping it routes to Business accounts (the place to choose a business),
/// matching the inactive cluster rows below it. Plain-English, no em dash.
class _PerBusinessClusterInactiveHint extends StatelessWidget {
  const _PerBusinessClusterInactiveHint({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Pick a business first',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: const Key('admin_nav_per_business_cluster_inactive_hint'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 2),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.sunset.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    scopeIcon(kind: ScopeEntityKind.business),
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Pick a business first',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.uiLabel(color: AppColors.textMuted),
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
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
    this.enabled = true,
  });

  final AdminRoute route;
  final bool selected;
  final VoidCallback onTap;

  /// When false, the row renders in a muted "inactive" state (no selected
  /// highlight, muted icon/label) used by the per-business cluster before a
  /// business is picked. The row stays tappable: tapping it routes to
  /// Business accounts so the operator can choose a business there.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final highlighted = enabled && selected;
    final Color iconColor = !enabled
        ? AppColors.textMuted
        : (selected ? AppColors.sunsetDark : AppColors.textSecondary);
    final Color titleColor = !enabled
        ? AppColors.textMuted
        : (selected ? AppColors.textPrimary : AppColors.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: highlighted
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
                color: highlighted
                    ? AppColors.sunset.withValues(alpha: 0.55)
                    : Colors.transparent,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(route.icon, size: 18, color: iconColor),
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
                        style: AppTextStyles.body14(color: titleColor),
                      ),
                      if (enabled && route.badge != null) ...[
                        const SizedBox(height: 4),
                        _NavRouteBadge(routeId: route.id, label: route.badge!),
                      ],
                    ],
                  ),
                ),
                if (enabled && route.placeholder)
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
