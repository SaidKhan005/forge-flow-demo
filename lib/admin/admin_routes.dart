// Phase 11A.0 - Admin route table.
//
// The admin console is a multi-surface back-office. Keeping the route
// catalog in a single typed list lets the shell nav render live
// surfaces without scattering `if (slice >= X)` flags across the UI.
//
// 11A.1 - the Operators route flips from placeholder to live; its
// builder reads the [OperatorLocationAdminGateway] from
// [AdminConsoleServicesScope] so production can bind the HTTP
// gateway without rewriting the route catalog. The default
// fallback is an in-memory demo gateway preloaded with two
// fixtures so the kDemoMode walkthrough click path runs without
// the Cloud Run admin proxy.

import 'package:flutter/material.dart';

import '../auth/auth_session.dart';
import '../auth/fresh_mfa_resolver.dart';
import '../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../theme/app_theme.dart';
import 'admin_auth_gate.dart';
import 'admin_route_handoff.dart';
import 'models/corpus_admin_models.dart';
import 'models/debug_console_admin_models.dart';
import 'models/feature_flags_admin_models.dart';
import 'models/integration_admin_models.dart';
import 'models/operator_location_admin_models.dart';
import 'models/pricing_tier_admin_models.dart';
import 'screens/corpus_admin_screen.dart';
import 'screens/debug_console_admin_screen.dart';
import 'screens/feature_flags_admin_screen.dart';
import 'screens/health_admin_screen.dart';
import 'screens/integration_admin_screen.dart';
import 'screens/members_admin_screen.dart';
import 'screens/observability_admin_screen.dart';
import 'screens/operator_location_admin_screen.dart';
import 'screens/operator_picker_screen.dart';
import 'screens/audited_support_actions_admin_screen.dart';
import 'screens/per_location_data_accuracy_screen.dart';
import 'screens/polling_and_pricing_admin_screen.dart';
import 'screens/pricing_tier_admin_screen.dart';
import 'screens/roles_hierarchy_sessions_admin_screen.dart';
import 'screens/support_operator_view_admin_screen.dart';
import 'services/audited_support_actions_admin_gateway.dart';
import 'services/corpus_admin_gateway.dart';
import 'services/data_accuracy_admin_gateway.dart';
import 'services/debug_console_admin_gateway.dart';
import 'services/demo_audited_support_actions_admin_gateway.dart';
import 'services/demo_members_admin_gateway.dart';
import 'services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'services/feature_flags_admin_gateway.dart';
import 'services/health_admin_gateway.dart';
import 'services/integration_admin_gateway.dart';
import 'services/members_admin_gateway.dart';
import 'services/observability_admin_gateway.dart';
import 'services/operator_location_admin_gateway.dart';
import 'services/pricing_tier_admin_gateway.dart';
import 'services/roles_hierarchy_sessions_admin_gateway.dart';
import '../domain/models/forge_flow_polling_tier_assignment.dart';

/// CODE_OPS_DEBT Theme A item 1 — overridable MFA-freshness resolver
/// for the four MFA-pinned admin actions. Tests inject a
/// [FakeFreshMfaResolver]; production binds [JwtFreshMfaResolver]
/// once at app boot. Lazy default keeps the boot cost off the
/// critical path (the resolver reads `Platform.environment` once
/// for the optional `MFA_FRESHNESS_WINDOW_SECONDS` override).
FreshMfaResolver? _freshMfaResolverOverride;

/// Bind a custom resolver. Pass `null` to revert to the default
/// [JwtFreshMfaResolver].
@visibleForTesting
void debugSetFreshMfaResolver(FreshMfaResolver? resolver) {
  _freshMfaResolverOverride = resolver;
}

FreshMfaResolver get _freshMfaResolver =>
    _freshMfaResolverOverride ??= JwtFreshMfaResolver();

/// Resolves whether [session]'s MFA stamp is fresh enough to expose
/// MFA-pinned admin affordances. Returns false when the admin
/// session is null OR when the credential was sourced from a code
/// path that does not carry `lastFreshAuthAt` (legacy demo fixtures
/// → fail closed, never expose the affordance).
bool _isAdminMfaFresh(AdminAuthSession? session) {
  if (session == null) return false;
  final stamp = session.lastFreshAuthAt;
  if (stamp == null) return false;
  // Re-use the operator-app AuthSession freshness logic by wrapping
  // the admin session into the same shape. Only `lastFreshAuthAt`
  // matters for this resolver; other fields are placeholders that
  // the resolver does not read.
  final wrapped = AuthSession(
    userId: session.uid,
    operatorId: '',
    locationId: '',
    firebaseIdToken: '',
    issuedAt: stamp,
    expiresAt: stamp.add(const Duration(hours: 1)),
    lastFreshAuthAt: stamp,
    roles: session.roles,
    mfaEnrolled: true,
  );
  return _freshMfaResolver.isFresh(wrapped);
}

/// One entry in the admin route catalog.
@immutable
class AdminRoute {
  const AdminRoute({
    required this.id,
    required this.title,
    required this.path,
    required this.icon,
    required this.section,
    required this.builder,
    this.subtitle,
    this.badge,
    this.placeholder = false,
    this.visibleInNav = true,
    this.navAnchorRouteId,
  });

  /// Stable ID used by tests, deep-links, and audit logs.
  final String id;

  /// Human-readable label shown in the side nav.
  final String title;

  /// Canonical route path (`/`, `/operators`, `/pricing`, ...).
  /// Future slices will use this with a router; 11A.0 only needs
  /// stable IDs the shell can switch on.
  final String path;

  /// Material icon shown in the side nav.
  final IconData icon;

  /// High-level side-nav category.
  final AdminRouteSection section;

  /// Optional one-line description for the empty-state body when the
  /// route is opened ahead of its slice landing.
  final String? subtitle;

  /// Optional short nav chip for route-level status.
  final String? badge;

  /// True when the route is a placeholder for a slice that hasn't
  /// landed yet. The shell renders a "coming in 11A.x" empty state
  /// instead of [builder] so the nav structure is visible from
  /// 11A.0 without exposing scaffolding.
  final bool placeholder;

  /// Whether this route appears as a primary side-nav destination.
  ///
  /// Some settings routes are still real destinations for route
  /// handoff/deep-link tests, but the product IA reaches them from
  /// Business accounts setup tiles rather than exposing duplicate
  /// top-level Operations entries.
  final bool visibleInNav;

  /// Optional visible route that should stay highlighted while this
  /// route is active. Setup-only routes anchor to Business accounts
  /// because the business hierarchy workspace is their entry point.
  final String? navAnchorRouteId;

  /// Builds the route surface. For [placeholder] routes the shell
  /// substitutes a branded "coming soon" panel; for live routes the
  /// builder runs.
  final Widget Function(BuildContext context) builder;
}

enum AdminRouteSection { ai, operations, serviceSetup, systemMonitoring }

/// Canonical Operators route ID (11A.1).
const String kAdminOperatorsRouteId = 'operators';

/// Cross-operator support workspace. F&F staff chooses a business +
/// location scope in Business accounts, then lands here to work across
/// People, Access, Security/Audit, and Vendors without re-picking the
/// business for each tab.
const String kAdminSupportOperatorViewRouteId = 'support-operator-view';

/// Canonical Pricing route ID (11A.2).
const String kAdminPricingRouteId = 'pricing';

/// Canonical Corpus route ID (11A.3a).
const String kAdminCorpusRouteId = 'corpus';

/// Canonical Integrations route ID (11A.4).
const String kAdminIntegrationsRouteId = 'integrations';

/// Canonical Health route ID (Phase 11A.UX.health / F.1).
const String kAdminHealthRouteId = 'health';

/// Canonical Feature Flags route ID (11A.7).
const String kAdminFeatureFlagsRouteId = 'feature_flags';

/// Canonical Debug console route ID (11A.5).
const String kAdminDebugConsoleRouteId = 'debug';

/// Canonical Observability route ID (Phase 11A.6). The Observability
/// surface is the cost-telemetry / dormancy / margin / cap-event /
/// graph / Cloud-Run dashboard. The /health envelope viewer is owned
/// by [kAdminHealthRouteId] and is intentionally a different route.
const String kAdminObservabilityRouteId = 'observability';

/// Phase 8 spine-bridge Lane .C - Data Accuracy admin tab (Tab 1).
const String kAdminDataAccuracyRouteId = 'data-accuracy';

/// Phase 8 spine-bridge Lane .C - Polling & Pricing admin tab (Tab 2).
const String kAdminPollingPricingRouteId = 'polling-pricing';

/// Phase 11A.12 - cross-operator Members + Invites surface. Mounted
/// after the operator picker; the F&F admin opens this route, picks
/// an operator, and lands on the members table scoped to the chosen
/// operator.
const String kAdminMembersRouteId = 'members';

/// Phase 11A.13 - cross-operator Roles + Hierarchy + Sessions inspect
/// surface. Mounted after the operator picker; same pattern as
/// `kAdminMembersRouteId` — the F&F admin opens this route, picks an
/// operator, and lands on a three-tab screen scoped to that operator.
const String kAdminRolesHierarchySessionsRouteId = 'roles-hierarchy-sessions';

/// Phase 11A.14 - cross-operator Audited support actions surface
/// (audit log review + Reset MFA / password reset / paired-approval
/// erasure). Mounted after the operator picker; same shell pattern
/// as `kAdminMembersRouteId` and `kAdminRolesHierarchySessionsRouteId`.
const String kAdminAuditedSupportActionsRouteId = 'audited-support-actions';

/// Canonical operator-picker route ID (11A.3a follow-up; reused by
/// 11A.12). The picker is reached via Navigator.push from any host
/// screen that scopes to a single operator (Corpus admin's "Graph
/// candidates" tab and the Members + Invites surface ship today;
/// future operator-scoped admin surfaces will reuse the same path).
/// It is intentionally NOT in [kAdminRoutes] (no side-nav item)
/// because no admin destination "is" the picker — it is always a
/// dependency of another surface. The constant exists so audit logs
/// and route observers have a stable name to refer to the modal
/// target.
const String kAdminOperatorPickerRouteId = 'operator-picker';

/// The admin route table. Order is the side-nav order.
const List<AdminRoute> kAdminRoutes = <AdminRoute>[
  AdminRoute(
    id: kAdminOperatorsRouteId,
    title: 'Business accounts',
    path: '/operators',
    icon: Icons.business_outlined,
    section: AdminRouteSection.operations,
    subtitle:
        'Find a business, review setup, and drill into locations, team, access, audit, and data controls.',
    builder: _buildOperators,
  ),
  AdminRoute(
    id: kAdminSupportOperatorViewRouteId,
    title: 'Support workspace',
    path: '/admin/support-operator-view',
    icon: Icons.support_agent_outlined,
    section: AdminRouteSection.operations,
    subtitle:
        'Work across people, access, security, audit, and vendors for the selected business.',
    builder: _buildSupportOperatorView,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
  AdminRoute(
    id: kAdminPricingRouteId,
    title: 'Plans and limits',
    path: '/pricing',
    icon: Icons.tune_outlined,
    section: AdminRouteSection.ai,
    subtitle: 'Review AI plans and set usage limits by operator and location.',
    builder: _buildPricing,
  ),
  AdminRoute(
    id: kAdminCorpusRouteId,
    title: 'Knowledge base',
    path: '/corpus',
    icon: Icons.menu_book_outlined,
    section: AdminRouteSection.ai,
    subtitle: 'Upload, review, publish, and restore advisor knowledge content.',
    builder: _buildCorpus,
  ),
  AdminRoute(
    id: kAdminIntegrationsRouteId,
    title: 'Connected services',
    path: '/integrations',
    icon: Icons.extension_outlined,
    section: AdminRouteSection.serviceSetup,
    subtitle: 'Check provider status and rotate service keys safely.',
    builder: _buildIntegrations,
  ),
  AdminRoute(
    id: kAdminHealthRouteId,
    title: 'System health',
    path: '/health',
    icon: Icons.monitor_heart_outlined,
    section: AdminRouteSection.systemMonitoring,
    subtitle: 'Run a read-only system check before investigating live issues.',
    builder: _buildHealth,
  ),
  AdminRoute(
    id: kAdminFeatureFlagsRouteId,
    title: 'Launch controls',
    path: '/feature-flags',
    icon: Icons.flag_outlined,
    section: AdminRouteSection.serviceSetup,
    subtitle: 'Control staged features without shipping a new build.',
    builder: _buildFeatureFlags,
  ),
  AdminRoute(
    id: kAdminDebugConsoleRouteId,
    title: 'Support logs',
    path: '/debug',
    icon: Icons.bug_report_outlined,
    section: AdminRouteSection.systemMonitoring,
    subtitle:
        'Search recent operator requests and inspect support-safe details.',
    builder: _buildDebugConsole,
  ),
  AdminRoute(
    id: kAdminObservabilityRouteId,
    title: 'System metrics',
    path: '/observability',
    icon: Icons.insights_outlined,
    section: AdminRouteSection.systemMonitoring,
    subtitle:
        'Review cost, usage limits, operator activity, graph health, and hosting.',
    builder: _buildObservability,
  ),
  AdminRoute(
    id: kAdminDataAccuracyRouteId,
    title: 'Data accuracy',
    path: '/data-accuracy',
    icon: Icons.fact_check_outlined,
    section: AdminRouteSection.operations,
    badge: 'Work in progress',
    subtitle: 'Inspect and override per-location covers and wage source.',
    builder: _buildDataAccuracy,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
  AdminRoute(
    id: kAdminPollingPricingRouteId,
    title: 'Polling & pricing',
    path: '/polling-pricing',
    icon: Icons.payments_outlined,
    section: AdminRouteSection.operations,
    badge: 'Work in progress',
    subtitle:
        'Set tier definitions, per-location assignments, and review margin.',
    builder: _buildPollingPricing,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
  AdminRoute(
    id: kAdminMembersRouteId,
    title: 'People, access & roles',
    path: '/admin/members',
    icon: Icons.people_alt_outlined,
    section: AdminRouteSection.operations,
    subtitle:
        'Review members, invites, role grants, and role policy for one business.',
    builder: _buildMembers,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
  AdminRoute(
    id: kAdminRolesHierarchySessionsRouteId,
    title: 'Access',
    path: '/admin/roles-hierarchy-sessions',
    icon: Icons.account_tree_outlined,
    section: AdminRouteSection.operations,
    subtitle: 'Review hierarchy and active sessions for the selected business.',
    builder: _buildRolesHierarchySessions,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
  AdminRoute(
    id: kAdminAuditedSupportActionsRouteId,
    title: 'Security & audit',
    path: '/admin/audited-support-actions',
    icon: Icons.security_outlined,
    section: AdminRouteSection.operations,
    subtitle:
        'Review audit history and gated support actions for one operator.',
    builder: _buildAuditedSupportActions,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
];

Widget _buildOperators(BuildContext context) {
  final gateway = AdminConsoleServicesScope.operatorLocationGatewayOf(context);
  final hierarchyGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final vendorConnectionsGateway =
      AdminConsoleServicesScope.vendorConnectionsGatewayOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  Widget buildScreen({
    required bool editingEnabled,
    String actorUserId = 'admin-console',
  }) {
    return OperatorLocationAdminScreen(
      gateway: gateway,
      hierarchyGateway: hierarchyGateway,
      vendorConnectionsGateway: vendorConnectionsGateway,
      editingEnabled: editingEnabled,
      actorUserId: actorUserId,
      onOpenSupportLogs: handoff == null
          ? null
          : (operatorId, locationId) {
              final scope = locationId == null
                  ? AdminHierarchyScopeIntent.business(operatorId: operatorId)
                  : AdminHierarchyScopeIntent.location(
                      operatorId: operatorId,
                      locationId: locationId,
                    );
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminDebugConsoleRouteId,
                  supportLogFilter:
                      AdminSupportLogFilterIntent.fromHierarchyScope(scope),
                ),
              );
            },
      onOpenSupportLogsScope: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminDebugConsoleRouteId,
                  hierarchyScope: scope,
                  supportLogFilter:
                      AdminSupportLogFilterIntent.fromHierarchyScope(scope),
                ),
              );
            },
      onOpenDataAccuracy: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminDataAccuracyRouteId,
                  operatorLocationScope: scope,
                ),
              );
            },
      onOpenDataAccuracyScope: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminDataAccuracyRouteId,
                  hierarchyScope: scope,
                ),
              );
            },
      onOpenPollingPricing: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminPollingPricingRouteId,
                  operatorLocationScope: scope,
                ),
              );
            },
      onOpenPollingPricingScope: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminPollingPricingRouteId,
                  hierarchyScope: scope,
                ),
              );
            },
      onOpenSupportOperatorView: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminSupportOperatorViewRouteId,
                  operatorLocationScope: scope,
                ),
              );
            },
      onOpenTeam: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminMembersRouteId,
                  operatorLocationScope: scope,
                ),
              );
            },
      onOpenAccess: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminRolesHierarchySessionsRouteId,
                  operatorLocationScope: scope,
                ),
              );
            },
      onOpenPeopleAccessRolesScope: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminMembersRouteId,
                  hierarchyScope: scope,
                ),
              );
            },
      onOpenAuditSupport: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminAuditedSupportActionsRouteId,
                  operatorLocationScope: scope,
                ),
              );
            },
      onOpenSecurityAuditSessionsScope: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminAuditedSupportActionsRouteId,
                  hierarchyScope: scope,
                ),
              );
            },
      onSelectOperatorScope: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: handoff.selectedRouteId,
                  operatorLocationScope: scope,
                ),
              );
            },
    );
  }

  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  if (source == null) {
    return buildScreen(editingEnabled: true);
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      return buildScreen(
        editingEnabled: canEdit,
        actorUserId: session?.uid ?? 'admin-console',
      );
    },
  );
}

VoidCallback? _backToBusinessAccounts(BuildContext context) {
  final handoff = AdminRouteHandoff.maybeOf(context);
  if (handoff == null) return null;
  return () => handoff.onSelectRoute(
    const AdminRouteIntent(routeId: kAdminOperatorsRouteId),
  );
}

// Retained for backwards-compatible deep-link handoff while the primary IA
// moves Support Workspace functions into scoped setup tiles.
// ignore: unused_element
Widget _buildSupportOperatorView(BuildContext context) {
  final membersGateway = AdminConsoleServicesScope.membersAdminGatewayOf(
    context,
  );
  final rolesGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final supportGateway =
      AdminConsoleServicesScope.auditedSupportActionsAdminGatewayOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final initialPicked = _pickerResultFromScope(handoff?.operatorLocationScope);

  void rememberPickedOperator(OperatorPickerResult result) {
    handoff?.onSelectRoute(
      AdminRouteIntent(
        routeId: kAdminSupportOperatorViewRouteId,
        operatorLocationScope: _scopeFromPickerResult(result),
      ),
    );
  }

  Future<OperatorPickerResult?> openPicker(
    BuildContext routeContext,
    String? adminUid,
  ) {
    return Navigator.of(routeContext).push<OperatorPickerResult?>(
      MaterialPageRoute<OperatorPickerResult?>(
        settings: const RouteSettings(
          name: '/admin/support-operator-view/operator-picker',
        ),
        builder: (_) =>
            OperatorPickerScreen(gateway: operatorGateway, adminUid: adminUid),
      ),
    );
  }

  if (source == null) {
    return _SupportOperatorViewRouteShell(
      membersGateway: membersGateway,
      rolesGateway: rolesGateway,
      supportGateway: supportGateway,
      actorUserId: 'demo-super-admin',
      editingEnabled: true,
      canEditSeededRoles: false,
      canResetMfaFactors: false,
      canIssuePairedErasure: false,
      canExportAuditLog: false,
      adminUid: null,
      initialPicked: initialPicked,
      openPicker: openPicker,
      onOperatorPicked: rememberPickedOperator,
    );
  }

  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      return _SupportOperatorViewRouteShell(
        membersGateway: membersGateway,
        rolesGateway: rolesGateway,
        supportGateway: supportGateway,
        actorUserId: session?.uid ?? 'unknown',
        editingEnabled: canEdit,
        // CODE_OPS_DEBT Theme A item 1 — resolved off the JWT
        // `auth_time` claim (carried via
        // [AdminAuthSession.lastFreshAuthAt]) through the shared
        // [FreshMfaResolver] (1-hour window, env-overridable). The
        // proxy is authoritative on the per-call check; the UI just
        // hides affordances when the resolver says stale.
        canEditSeededRoles: _isAdminMfaFresh(session),
        canResetMfaFactors: _isAdminMfaFresh(session),
        canIssuePairedErasure: _isAdminMfaFresh(session),
        canExportAuditLog: _isAdminMfaFresh(session),
        adminUid: session?.uid,
        initialPicked: initialPicked,
        openPicker: openPicker,
        onOperatorPicked: rememberPickedOperator,
      );
    },
  );
}

class _SupportOperatorViewRouteShell extends StatefulWidget {
  const _SupportOperatorViewRouteShell({
    required this.membersGateway,
    required this.rolesGateway,
    required this.supportGateway,
    required this.actorUserId,
    required this.editingEnabled,
    required this.canEditSeededRoles,
    required this.canResetMfaFactors,
    required this.canIssuePairedErasure,
    required this.canExportAuditLog,
    required this.adminUid,
    required this.initialPicked,
    required this.openPicker,
    required this.onOperatorPicked,
  });

  final MembersAdminGateway membersGateway;
  final RolesHierarchySessionsAdminGateway rolesGateway;
  final AuditedSupportActionsAdminGateway supportGateway;
  final String actorUserId;
  final bool editingEnabled;
  final bool canEditSeededRoles;
  final bool canResetMfaFactors;
  final bool canIssuePairedErasure;
  final bool canExportAuditLog;
  final String? adminUid;
  final OperatorPickerResult? initialPicked;
  final Future<OperatorPickerResult?> Function(
    BuildContext context,
    String? adminUid,
  )
  openPicker;
  final ValueChanged<OperatorPickerResult> onOperatorPicked;

  @override
  State<_SupportOperatorViewRouteShell> createState() =>
      _SupportOperatorViewRouteShellState();
}

class _SupportOperatorViewRouteShellState
    extends State<_SupportOperatorViewRouteShell> {
  OperatorPickerResult? _picked;
  bool _pickerInflight = false;

  @override
  void initState() {
    super.initState();
    _picked = widget.initialPicked;
  }

  @override
  void didUpdateWidget(covariant _SupportOperatorViewRouteShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePickerResult(widget.initialPicked, oldWidget.initialPicked) &&
        !_samePickerResult(widget.initialPicked, _picked)) {
      setState(() => _picked = widget.initialPicked);
    }
  }

  Future<void> _openPicker() async {
    if (_pickerInflight) return;
    _pickerInflight = true;
    try {
      final result = await widget.openPicker(context, widget.adminUid);
      if (!mounted) return;
      if (result != null) {
        setState(() => _picked = result);
        widget.onOperatorPicked(result);
      } else {
        setState(() {});
      }
    } finally {
      _pickerInflight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    if (picked == null) {
      return Container(
        key: const Key('admin_support_operator_view_no_scope_state'),
        color: AppColors.backgroundDeep,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Choose a business',
                    style: AppTextStyles.display20(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Support work starts with one business and one location '
                    'scope. After that, People, Access, Security, Audit, and '
                    'Vendors stay in the same workspace.',
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('admin_support_operator_view_open_picker'),
                    onPressed: _openPicker,
                    icon: const Icon(Icons.business_outlined, size: 16),
                    label: const Text('Choose business'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SupportOperatorViewAdminScreen(
      key: ValueKey<String>(
        'support-operator-${picked.operatorId}-${picked.locationId}',
      ),
      membersGateway: widget.membersGateway,
      rolesGateway: widget.rolesGateway,
      supportGateway: widget.supportGateway,
      actorUserId: widget.actorUserId,
      pickedOperator: picked,
      editingEnabled: widget.editingEnabled,
      canEditSeededRoles: widget.canEditSeededRoles,
      canResetMfaFactors: widget.canResetMfaFactors,
      canIssuePairedErasure: widget.canIssuePairedErasure,
      canExportAuditLog: widget.canExportAuditLog,
      onChangeOperator: _openPicker,
    );
  }
}

Widget _buildPricing(BuildContext context) {
  final gateway = AdminConsoleServicesScope.pricingTierGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  if (source == null) {
    // No source wired (typical widget-test path) - default to live
    // edit affordances. Production wires `source` from main_admin so
    // `ff_support` lands on the read-only branch below.
    return PricingTierAdminScreen(gateway: gateway);
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      return PricingTierAdminScreen(gateway: gateway, editingEnabled: canEdit);
    },
  );
}

/// Phase 11A.3b - demo-mode tenant the Graph candidates tab targets
/// when the in-memory demo gateway is mounted. The IDs match the
/// kDemoMode tenant seed in [_defaultDemoGateway] below so the
/// 11A.3b walkthrough writes against the same demo operator the
/// rest of the admin shell reads.
///
/// Live mode (HTTP gateway) deliberately leaves both null until the
/// operator-picker slice ships - the screen disables the Graph
/// candidates commit button with a banner in that case so a
/// super_admin cannot accidentally write graph approvals against
/// the demo IDs (which do not exist as real tenants in production).
const String kCorpusAdminDemoTargetOperatorId =
    '00000000-0000-4000-8000-000000000001';
const String kCorpusAdminDemoTargetLocationId =
    '00000000-0000-4000-8000-0000000000a1';

Widget _buildCorpus(BuildContext context) {
  final gateway = AdminConsoleServicesScope.corpusAdminGatewayOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  // Demo mode (in-memory gateway) targets the seeded demo tenant.
  // Live mode (HTTP gateway, or any non-in-memory binding) leaves
  // the targets null so the Graph candidates commit button starts
  // disabled. The "Pick operator" button on that surface opens
  // [OperatorPickerScreen] via [_openOperatorPickerFromContext]; once
  // the admin confirms a pair, the corpus screen state takes over
  // and the commit button enables.
  final isDemoGateway = gateway is InMemoryCorpusAdminGateway;
  final demoTargetOperatorId = isDemoGateway
      ? kCorpusAdminDemoTargetOperatorId
      : null;
  final demoTargetLocationId = isDemoGateway
      ? kCorpusAdminDemoTargetLocationId
      : null;
  Future<OperatorPickerResult?> openPicker(BuildContext routeContext) {
    final state = source?.current;
    final adminUid = state is AdminAuthAuthenticated ? state.session.uid : null;
    return Navigator.of(routeContext).push<OperatorPickerResult?>(
      MaterialPageRoute<OperatorPickerResult?>(
        settings: const RouteSettings(name: '/operator-picker'),
        builder: (_) =>
            OperatorPickerScreen(gateway: operatorGateway, adminUid: adminUid),
      ),
    );
  }

  if (source == null) {
    // No source wired (test path) - default to live edit affordances.
    return CorpusAdminScreen(
      gateway: gateway,
      targetOperatorId: demoTargetOperatorId,
      targetLocationId: demoTargetLocationId,
      operatorPickerOpener: openPicker,
    );
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      return CorpusAdminScreen(
        gateway: gateway,
        editingEnabled: canEdit,
        targetOperatorId: demoTargetOperatorId,
        targetLocationId: demoTargetLocationId,
        operatorPickerOpener: openPicker,
      );
    },
  );
}

Widget _buildIntegrations(BuildContext context) {
  final gateway = AdminConsoleServicesScope.integrationGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  if (source == null) {
    return IntegrationAdminScreen(gateway: gateway);
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      return IntegrationAdminScreen(gateway: gateway, editingEnabled: canEdit);
    },
  );
}

Widget _buildHealth(BuildContext context) {
  // F.1 - read-only for both `super_admin` and `ff_support`. The
  // gateway is the only injection point; there is no editingEnabled
  // flag because the surface has no mutate affordances.
  final gateway = AdminConsoleServicesScope.healthGatewayOf(context);
  return HealthAdminScreen(gateway: gateway);
}

Widget _buildObservability(BuildContext context) {
  // 11A.6 - read-only surface. Same admit posture as Health: both
  // `super_admin` and `ff_support` see the full cost-telemetry +
  // dormancy + margin + cap-event + graph + Cloud Run dashboard.
  // No editingEnabled flag because there are no mutate affordances.
  final gateway = AdminConsoleServicesScope.observabilityGatewayOf(context);
  return ObservabilityAdminScreen(gateway: gateway);
}

Widget _buildFeatureFlags(BuildContext context) {
  final gateway = AdminConsoleServicesScope.featureFlagsGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  if (source == null) {
    return FeatureFlagsAdminScreen(gateway: gateway);
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      return FeatureFlagsAdminScreen(gateway: gateway, editingEnabled: canEdit);
    },
  );
}

Widget _buildDataAccuracy(BuildContext context) {
  final gateway = AdminConsoleServicesScope.dataAccuracyAdminGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final scope = AdminRouteHandoff.maybeOf(context)?.operatorLocationScope;
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);
  if (source == null) {
    return PerLocationDataAccuracyScreen(
      gateway: gateway,
      actorUserId: 'demo-super-admin',
      initialScope: scope,
      onBackToBusinessAccounts: onBackToBusinessAccounts,
    );
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      return PerLocationDataAccuracyScreen(
        gateway: gateway,
        actorUserId: session?.uid ?? 'unknown',
        editingEnabled: canEdit,
        initialScope: scope,
        onBackToBusinessAccounts: onBackToBusinessAccounts,
      );
    },
  );
}

Widget _buildPollingPricing(BuildContext context) {
  final gateway = AdminConsoleServicesScope.dataAccuracyAdminGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final scope = AdminRouteHandoff.maybeOf(context)?.operatorLocationScope;
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);
  if (source == null) {
    return PollingAndPricingAdminScreen(
      gateway: gateway,
      actorUserId: 'demo-super-admin',
      initialScope: scope,
      onBackToBusinessAccounts: onBackToBusinessAccounts,
    );
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      return PollingAndPricingAdminScreen(
        gateway: gateway,
        actorUserId: session?.uid ?? 'unknown',
        editingEnabled: canEdit,
        initialScope: scope,
        onBackToBusinessAccounts: onBackToBusinessAccounts,
      );
    },
  );
}

OperatorPickerResult? _pickerResultFromScope(
  AdminOperatorLocationScopeIntent? scope, {
  bool allowBusinessScope = false,
}) {
  if (scope == null) return null;
  final locationId = scope.locationId;
  final hasLocation = locationId != null && locationId.isNotEmpty;
  if (!hasLocation && !allowBusinessScope) return null;
  return OperatorPickerResult(
    operatorId: scope.operatorId,
    locationId: locationId ?? '',
    operatorBusinessName: scope.operatorName ?? 'Selected operator',
    locationName: hasLocation
        ? scope.locationName ?? 'Selected location'
        : 'Business scope',
  );
}

AdminOperatorLocationScopeIntent _scopeFromPickerResult(
  OperatorPickerResult result,
) {
  final locationId = result.locationId.isEmpty ? null : result.locationId;
  return AdminOperatorLocationScopeIntent(
    operatorId: result.operatorId,
    locationId: locationId,
    operatorName: result.operatorBusinessName,
    locationName: locationId == null ? null : result.locationName,
  );
}

bool _samePickerResult(OperatorPickerResult? a, OperatorPickerResult? b) {
  return a?.operatorId == b?.operatorId &&
      a?.locationId == b?.locationId &&
      a?.operatorBusinessName == b?.operatorBusinessName &&
      a?.locationName == b?.locationName;
}

Widget _buildMembers(BuildContext context) {
  final gateway = AdminConsoleServicesScope.membersAdminGatewayOf(context);
  final rolesGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final initialScope = handoff?.effectiveHierarchyScope;
  final initialPicked = _pickerResultFromScope(
    handoff?.operatorLocationScope ?? initialScope?.toOperatorLocationScope(),
    allowBusinessScope: true,
  );
  void rememberPickedOperator(OperatorPickerResult result) {
    handoff?.onSelectRoute(
      AdminRouteIntent(
        routeId: kAdminMembersRouteId,
        operatorLocationScope: _scopeFromPickerResult(result),
      ),
    );
  }

  void openScopedAccess(OperatorPickerResult result) {
    handoff?.onSelectRoute(
      AdminRouteIntent(
        routeId: kAdminRolesHierarchySessionsRouteId,
        operatorLocationScope: _scopeFromPickerResult(result),
      ),
    );
  }

  Future<OperatorPickerResult?> openPicker(
    BuildContext routeContext,
    String? adminUid,
  ) {
    return Navigator.of(routeContext).push<OperatorPickerResult?>(
      MaterialPageRoute<OperatorPickerResult?>(
        settings: const RouteSettings(name: '/admin/members/operator-picker'),
        builder: (_) =>
            OperatorPickerScreen(gateway: operatorGateway, adminUid: adminUid),
      ),
    );
  }

  if (source == null) {
    // Test path: default to live edit affordances.
    return _MembersAdminRouteShell(
      gateway: gateway,
      rolesGateway: rolesGateway,
      actorUserId: 'demo-super-admin',
      editingEnabled: true,
      canEditSeededRoles: false,
      adminUid: null,
      initialPicked: initialPicked,
      initialScope: initialScope,
      openPicker: openPicker,
      onOperatorPicked: rememberPickedOperator,
      onOpenAccess: handoff == null ? null : openScopedAccess,
      onBackToBusinessAccounts: _backToBusinessAccounts(context),
    );
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      return _MembersAdminRouteShell(
        gateway: gateway,
        rolesGateway: rolesGateway,
        actorUserId: session?.uid ?? 'unknown',
        editingEnabled: canEdit,
        canEditSeededRoles: _isAdminMfaFresh(session),
        adminUid: session?.uid,
        initialPicked: initialPicked,
        initialScope: initialScope,
        openPicker: openPicker,
        onOperatorPicked: rememberPickedOperator,
        onOpenAccess: handoff == null ? null : openScopedAccess,
        onBackToBusinessAccounts: _backToBusinessAccounts(context),
      );
    },
  );
}

class _MembersAdminRouteShell extends StatefulWidget {
  const _MembersAdminRouteShell({
    required this.gateway,
    required this.rolesGateway,
    required this.actorUserId,
    required this.editingEnabled,
    required this.canEditSeededRoles,
    required this.adminUid,
    required this.initialPicked,
    required this.initialScope,
    required this.openPicker,
    required this.onOperatorPicked,
    required this.onOpenAccess,
    required this.onBackToBusinessAccounts,
  });

  final MembersAdminGateway gateway;
  final RolesHierarchySessionsAdminGateway rolesGateway;
  final String actorUserId;
  final bool editingEnabled;
  final bool canEditSeededRoles;
  final String? adminUid;
  final OperatorPickerResult? initialPicked;
  final AdminHierarchyScopeIntent? initialScope;
  final Future<OperatorPickerResult?> Function(
    BuildContext context,
    String? adminUid,
  )
  openPicker;
  final ValueChanged<OperatorPickerResult> onOperatorPicked;
  final ValueChanged<OperatorPickerResult>? onOpenAccess;
  final VoidCallback? onBackToBusinessAccounts;

  @override
  State<_MembersAdminRouteShell> createState() =>
      _MembersAdminRouteShellState();
}

class _MembersAdminRouteShellState extends State<_MembersAdminRouteShell> {
  OperatorPickerResult? _picked;

  /// Inflight guard. Set true while a picker push is awaiting; reset
  /// when the navigator pops (with a result or a cancel). Prevents
  /// double-pushes from a fast double-tap on the host's `Pick
  /// operator` / `Change operator` buttons.
  bool _pickerInflight = false;

  @override
  void initState() {
    super.initState();
    _picked = widget.initialPicked;
  }

  @override
  void didUpdateWidget(covariant _MembersAdminRouteShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePickerResult(widget.initialPicked, oldWidget.initialPicked) &&
        !_samePickerResult(widget.initialPicked, _picked)) {
      setState(() => _picked = widget.initialPicked);
    }
  }

  Future<void> _openPicker() async {
    if (_pickerInflight) return;
    _pickerInflight = true;
    try {
      final result = await widget.openPicker(context, widget.adminUid);
      if (!mounted) return;
      if (result != null) {
        setState(() => _picked = result);
        widget.onOperatorPicked(result);
      } else {
        // Cancel: stay on the no-operator state. The user can reopen
        // the picker via the inline button.
        setState(() {});
      }
    } finally {
      _pickerInflight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    if (picked == null) {
      return Container(
        key: const Key('admin_members_no_operator_state'),
        color: AppColors.backgroundDeep,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Choose an operator',
                    style: AppTextStyles.display20(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Team work is scoped to one operator. Choose an operator '
                    'once, then move between Team, Access, and Audit without '
                    'choosing again.',
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('admin_members_open_picker'),
                    onPressed: _openPicker,
                    icon: const Icon(Icons.business_outlined, size: 16),
                    label: const Text('Choose operator'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    // Members surface is operator-scoped; keying on operatorId alone
    // preserves the table state, filter chips, and scroll position
    // when the user picks the same operator again with a different
    // location (the picker carries a locationId, but the screen does
    // not narrow on it).
    return MembersAdminScreen(
      key: ValueKey<String>('members-${picked.operatorId}'),
      gateway: widget.gateway,
      rolesGateway: widget.rolesGateway,
      actorUserId: widget.actorUserId,
      pickedOperator: picked,
      editingEnabled: widget.editingEnabled,
      canEditSeededRoles: widget.canEditSeededRoles,
      initialScope: widget.initialScope,
      onChangeOperator: _openPicker,
      onOpenAccess: widget.onOpenAccess == null
          ? null
          : () => widget.onOpenAccess!(picked),
      onBackToBusinessAccounts: widget.onBackToBusinessAccounts,
    );
  }
}

Widget _buildRolesHierarchySessions(BuildContext context) {
  final gateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final initialScope = handoff?.effectiveHierarchyScope;
  final initialPicked = _pickerResultFromScope(
    handoff?.operatorLocationScope ?? initialScope?.toOperatorLocationScope(),
    allowBusinessScope: true,
  );
  void rememberPickedOperator(OperatorPickerResult result) {
    handoff?.onSelectRoute(
      AdminRouteIntent(
        routeId: kAdminRolesHierarchySessionsRouteId,
        operatorLocationScope: _scopeFromPickerResult(result),
      ),
    );
  }

  Future<OperatorPickerResult?> openPicker(
    BuildContext routeContext,
    String? adminUid,
  ) {
    return Navigator.of(routeContext).push<OperatorPickerResult?>(
      MaterialPageRoute<OperatorPickerResult?>(
        settings: const RouteSettings(
          name: '/admin/roles-hierarchy-sessions/operator-picker',
        ),
        builder: (_) =>
            OperatorPickerScreen(gateway: operatorGateway, adminUid: adminUid),
      ),
    );
  }

  if (source == null) {
    return _RolesHierarchySessionsRouteShell(
      gateway: gateway,
      actorUserId: 'demo-super-admin',
      editingEnabled: true,
      // Demo / test path: leave seeded-role edit disabled. Production
      // wires `canEditSeededRoles` from MFA-required admin claims.
      canEditSeededRoles: false,
      adminUid: null,
      initialPicked: initialPicked,
      openPicker: openPicker,
      onOperatorPicked: rememberPickedOperator,
      onBackToBusinessAccounts: _backToBusinessAccounts(context),
    );
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      // CODE_OPS_DEBT Theme A item 1 — un-pin from `const false`.
      // `admin.roles.edit_seeded` is MFA-required per the parity
      // contract § "Seeded roles" line 104. We now resolve the
      // affordance off the JWT `auth_time` claim (carried through
      // [AdminAuthSession.lastFreshAuthAt] from
      // [FirebaseAdminAuthSource]) via the shared
      // [FreshMfaResolver] (1-hour window, env-overridable via
      // `MFA_FRESHNESS_WINDOW_SECONDS`). Stale → affordance hidden;
      // the proxy stays authoritative and double-rejects on a stale
      // claim regardless.
      final canEditSeeded = _isAdminMfaFresh(session);
      return _RolesHierarchySessionsRouteShell(
        gateway: gateway,
        actorUserId: session?.uid ?? 'unknown',
        editingEnabled: canEdit,
        canEditSeededRoles: canEditSeeded,
        adminUid: session?.uid,
        initialPicked: initialPicked,
        openPicker: openPicker,
        onOperatorPicked: rememberPickedOperator,
        onBackToBusinessAccounts: _backToBusinessAccounts(context),
      );
    },
  );
}

class _RolesHierarchySessionsRouteShell extends StatefulWidget {
  const _RolesHierarchySessionsRouteShell({
    required this.gateway,
    required this.actorUserId,
    required this.editingEnabled,
    required this.canEditSeededRoles,
    required this.adminUid,
    required this.initialPicked,
    required this.openPicker,
    required this.onOperatorPicked,
    required this.onBackToBusinessAccounts,
  });

  final RolesHierarchySessionsAdminGateway gateway;
  final String actorUserId;
  final bool editingEnabled;
  final bool canEditSeededRoles;
  final String? adminUid;
  final OperatorPickerResult? initialPicked;
  final Future<OperatorPickerResult?> Function(
    BuildContext context,
    String? adminUid,
  )
  openPicker;
  final ValueChanged<OperatorPickerResult> onOperatorPicked;
  final VoidCallback? onBackToBusinessAccounts;

  @override
  State<_RolesHierarchySessionsRouteShell> createState() =>
      _RolesHierarchySessionsRouteShellState();
}

class _RolesHierarchySessionsRouteShellState
    extends State<_RolesHierarchySessionsRouteShell> {
  OperatorPickerResult? _picked;
  bool _pickerInflight = false;

  @override
  void initState() {
    super.initState();
    _picked = widget.initialPicked;
  }

  @override
  void didUpdateWidget(covariant _RolesHierarchySessionsRouteShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePickerResult(widget.initialPicked, oldWidget.initialPicked) &&
        !_samePickerResult(widget.initialPicked, _picked)) {
      setState(() => _picked = widget.initialPicked);
    }
  }

  Future<void> _openPicker() async {
    if (_pickerInflight) return;
    _pickerInflight = true;
    try {
      final result = await widget.openPicker(context, widget.adminUid);
      if (!mounted) return;
      if (result != null) {
        setState(() => _picked = result);
        widget.onOperatorPicked(result);
      } else {
        setState(() {});
      }
    } finally {
      _pickerInflight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    if (picked == null) {
      return Container(
        key: const Key('admin_rhs_no_operator_state'),
        color: AppColors.backgroundDeep,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Choose an operator',
                    style: AppTextStyles.display20(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Access work is scoped to one operator. Choose an operator '
                    'once, then move between Team, Access, and Audit without '
                    'choosing again.',
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('admin_rhs_open_picker'),
                    onPressed: _openPicker,
                    icon: const Icon(Icons.business_outlined, size: 16),
                    label: const Text('Choose operator'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return RolesHierarchySessionsAdminScreen(
      key: ValueKey<String>('rhs-${picked.operatorId}'),
      gateway: widget.gateway,
      actorUserId: widget.actorUserId,
      pickedOperator: picked,
      editingEnabled: widget.editingEnabled,
      canEditSeededRoles: widget.canEditSeededRoles,
      onChangeOperator: _openPicker,
      onBackToBusinessAccounts: widget.onBackToBusinessAccounts,
    );
  }
}

Widget _buildAuditedSupportActions(BuildContext context) {
  final gateway = AdminConsoleServicesScope.auditedSupportActionsAdminGatewayOf(
    context,
  );
  final sessionsGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final initialScope = handoff?.effectiveHierarchyScope;
  final initialPicked = _pickerResultFromScope(
    handoff?.operatorLocationScope ?? initialScope?.toOperatorLocationScope(),
    allowBusinessScope: true,
  );
  void rememberPickedOperator(OperatorPickerResult result) {
    handoff?.onSelectRoute(
      AdminRouteIntent(
        routeId: kAdminAuditedSupportActionsRouteId,
        operatorLocationScope: _scopeFromPickerResult(result),
      ),
    );
  }

  Future<OperatorPickerResult?> openPicker(
    BuildContext routeContext,
    String? adminUid,
  ) {
    return Navigator.of(routeContext).push<OperatorPickerResult?>(
      MaterialPageRoute<OperatorPickerResult?>(
        settings: const RouteSettings(
          name: '/admin/audited-support-actions/operator-picker',
        ),
        builder: (_) =>
            OperatorPickerScreen(gateway: operatorGateway, adminUid: adminUid),
      ),
    );
  }

  if (source == null) {
    return _AuditedSupportActionsRouteShell(
      gateway: gateway,
      sessionsGateway: sessionsGateway,
      actorUserId: 'demo-super-admin',
      editingEnabled: true,
      // Demo / test path: leave MFA-required affordances disabled.
      // Production wires `canResetMfaFactors` / `canIssuePairedErasure`
      // / `canExportAuditLog` from MFA-required admin claims.
      canResetMfaFactors: false,
      canIssuePairedErasure: false,
      canExportAuditLog: false,
      adminUid: null,
      initialPicked: initialPicked,
      initialScope: initialScope,
      openPicker: openPicker,
      onOperatorPicked: rememberPickedOperator,
      onBackToBusinessAccounts: _backToBusinessAccounts(context),
    );
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      // CODE_OPS_DEBT Theme A item 1 — un-pin from `const false`.
      // The three MFA-required audited-support actions
      // (`admin.users.reset_mfa_factors`,
      // `admin.users.issue_paired_erasure`,
      // `admin.audit.export`) all gate on the same fresh-MFA window.
      // Resolve via the shared [FreshMfaResolver] (1-hour default,
      // env-overridable). The proxy double-rejects on stale claims
      // regardless of what the UI exposes.
      final fresh = _isAdminMfaFresh(session);
      final canResetMfa = fresh;
      final canIssuePairedErasure = fresh;
      final canExportAuditLog = fresh;
      return _AuditedSupportActionsRouteShell(
        gateway: gateway,
        sessionsGateway: sessionsGateway,
        actorUserId: session?.uid ?? 'unknown',
        editingEnabled: canEdit,
        canResetMfaFactors: canResetMfa,
        canIssuePairedErasure: canIssuePairedErasure,
        canExportAuditLog: canExportAuditLog,
        adminUid: session?.uid,
        initialPicked: initialPicked,
        initialScope: initialScope,
        openPicker: openPicker,
        onOperatorPicked: rememberPickedOperator,
        onBackToBusinessAccounts: _backToBusinessAccounts(context),
      );
    },
  );
}

class _AuditedSupportActionsRouteShell extends StatefulWidget {
  const _AuditedSupportActionsRouteShell({
    required this.gateway,
    required this.sessionsGateway,
    required this.actorUserId,
    required this.editingEnabled,
    required this.canResetMfaFactors,
    required this.canIssuePairedErasure,
    required this.canExportAuditLog,
    required this.adminUid,
    required this.initialPicked,
    required this.initialScope,
    required this.openPicker,
    required this.onOperatorPicked,
    required this.onBackToBusinessAccounts,
  });

  final AuditedSupportActionsAdminGateway gateway;
  final RolesHierarchySessionsAdminGateway sessionsGateway;
  final String actorUserId;
  final bool editingEnabled;
  final bool canResetMfaFactors;
  final bool canIssuePairedErasure;
  final bool canExportAuditLog;
  final String? adminUid;
  final OperatorPickerResult? initialPicked;
  final AdminHierarchyScopeIntent? initialScope;
  final Future<OperatorPickerResult?> Function(
    BuildContext context,
    String? adminUid,
  )
  openPicker;
  final ValueChanged<OperatorPickerResult> onOperatorPicked;
  final VoidCallback? onBackToBusinessAccounts;

  @override
  State<_AuditedSupportActionsRouteShell> createState() =>
      _AuditedSupportActionsRouteShellState();
}

class _AuditedSupportActionsRouteShellState
    extends State<_AuditedSupportActionsRouteShell> {
  OperatorPickerResult? _picked;
  bool _pickerInflight = false;

  @override
  void initState() {
    super.initState();
    _picked = widget.initialPicked;
  }

  @override
  void didUpdateWidget(covariant _AuditedSupportActionsRouteShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePickerResult(widget.initialPicked, oldWidget.initialPicked) &&
        !_samePickerResult(widget.initialPicked, _picked)) {
      setState(() => _picked = widget.initialPicked);
    }
  }

  Future<void> _openPicker() async {
    if (_pickerInflight) return;
    _pickerInflight = true;
    try {
      final result = await widget.openPicker(context, widget.adminUid);
      if (!mounted) return;
      if (result != null) {
        setState(() => _picked = result);
        widget.onOperatorPicked(result);
      } else {
        setState(() {});
      }
    } finally {
      _pickerInflight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    if (picked == null) {
      return Container(
        key: const Key('admin_asa_no_operator_state'),
        color: AppColors.backgroundDeep,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Choose an operator',
                    style: AppTextStyles.display20(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Audit and support work is scoped to one operator. Choose '
                    'an operator once, then move between Team, Access, and '
                    'Audit without choosing again.',
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('admin_asa_open_picker'),
                    onPressed: _openPicker,
                    icon: const Icon(Icons.business_outlined, size: 16),
                    label: const Text('Choose operator'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return AuditedSupportActionsAdminScreen(
      key: ValueKey<String>('asa-${picked.operatorId}'),
      gateway: widget.gateway,
      sessionsGateway: widget.sessionsGateway,
      actorUserId: widget.actorUserId,
      pickedOperator: picked,
      editingEnabled: widget.editingEnabled,
      canResetMfaFactors: widget.canResetMfaFactors,
      canIssuePairedErasure: widget.canIssuePairedErasure,
      canExportAuditLog: widget.canExportAuditLog,
      hierarchyScope: widget.initialScope,
      onChangeOperator: _openPicker,
      onBackToBusinessAccounts: widget.onBackToBusinessAccounts,
    );
  }
}

Widget _buildDebugConsole(BuildContext context) {
  // 11A.5 - full-content reveal is gated on `super_admin`. `ff_support`
  // lands on the read-only meta view (no expand-to-full-content
  // affordance); the diff still renders so support can audit recent
  // request meta.
  final gateway = AdminConsoleServicesScope.debugConsoleGatewayOf(context);
  final hierarchyGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final supportLogFilter = AdminRouteHandoff.maybeOf(context)?.supportLogFilter;
  final supportLogScope = supportLogFilter?.effectiveHierarchyScope;
  final onBackToBusinessAccounts = supportLogFilter == null
      ? null
      : _backToBusinessAccounts(context);
  final initialFilter = RequestLogFilter(
    operatorId: supportLogFilter?.effectiveOperatorId,
    locationId: supportLogFilter?.effectiveLocationId,
  );
  if (source == null) {
    return DebugConsoleAdminScreen(
      gateway: gateway,
      hierarchyGateway: hierarchyGateway,
      hierarchyScope: supportLogScope,
      initialFilter: initialFilter,
      onBackToBusinessAccounts: onBackToBusinessAccounts,
    );
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = session != null && session.roles.contains('super_admin');
      return DebugConsoleAdminScreen(
        gateway: gateway,
        hierarchyGateway: hierarchyGateway,
        hierarchyScope: supportLogScope,
        editingEnabled: canEdit,
        initialFilter: initialFilter,
        onBackToBusinessAccounts: onBackToBusinessAccounts,
      );
    },
  );
}

/// Inherited services scope for the admin console. Production wires
/// the HTTP-backed [OperatorLocationAdminGateway] above the auth
/// gate; demo + widget tests fall back to a seeded in-memory
/// gateway so the click path runs without the Cloud Run admin proxy.
class AdminConsoleServicesScope extends InheritedWidget {
  const AdminConsoleServicesScope({
    super.key,
    required super.child,
    this.operatorLocationGateway,
    this.pricingTierGateway,
    this.corpusAdminGateway,
    this.integrationGateway,
    this.vendorConnectionsGateway,
    this.healthGateway,
    this.observabilityGateway,
    this.featureFlagsGateway,
    this.debugConsoleGateway,
    this.dataAccuracyAdminGateway,
    this.membersAdminGateway,
    this.rolesHierarchySessionsAdminGateway,
    this.auditedSupportActionsAdminGateway,
    this.adminAuthSource,
  });

  // HARD-B / HARD-E - the demo fallback gateways (`_defaultDemoGateway`,
  // `_defaultPricingDemoGateway`, `_defaultFeatureFlagsDemoGateway`,
  // etc.) used by the `*Of(context)` accessors below are reachable
  // only when `_kAdminDemoAuth == true`. That const lives in
  // `lib/main_admin.dart` and is computed from
  // `--dart-define=ADMIN_DEMO_AUTH=true` at compile time; its default
  // is `false`. Production builds MUST ship without this define (or
  // with `false`) so the seeded fixture `super.admin@forgeflow.test`
  // / `support@forgeflow.test` accounts cannot sign in against a
  // publicly-routed Cloud Run admin console. The release-build CI
  // assertion that pins this is owned by HARD-E
  // (`scripts/deploy_admin_console.ps1` `-DemoMode` switch + the CI
  // job that grep-asserts the build flags); the gate itself lives
  // here so any future `*Of(context)` fallback inherits the same
  // compile-time discipline.

  /// Production wires the HTTP-backed gateway here. Null falls back
  /// to the seeded in-memory demo gateway in [operatorLocationGatewayOf].
  /// Made nullable in 11A.2 so the demo / fallback path can still
  /// wrap with the scope (e.g. to plumb [adminAuthSource]) without
  /// fabricating a live gateway.
  final OperatorLocationAdminGateway? operatorLocationGateway;

  /// Phase 11A.2 - pricing tier admin gateway. Optional so existing
  /// production wiring can light it up incrementally; the default
  /// fallback is a seeded in-memory demo gateway shared with the
  /// walkthrough.
  final PricingTierAdminGateway? pricingTierGateway;

  /// Phase 11A.3a - corpus admin gateway. Optional for the same
  /// incremental-wiring reason. Default fallback is the seeded
  /// in-memory corpus demo gateway shared with the 11A.3a walkthrough.
  final CorpusAdminGateway? corpusAdminGateway;

  /// Phase 11A.4 - integration management admin gateway. Optional;
  /// the default fallback is a seeded in-memory gateway sharing the
  /// `kDemoMode` walkthrough fixtures.
  final IntegrationAdminGateway? integrationGateway;

  /// Slice 9 - per-location vendor lifecycle gateway. Kept separate
  /// from [integrationGateway], which owns global/platform provider
  /// status. Null intentionally leaves the location tile in a
  /// not-wired state instead of falling back to demo vendor data.
  final VendorConnectionsGateway? vendorConnectionsGateway;

  /// Phase 11A.UX.health (F.1) - proxy `/health` envelope gateway.
  /// Optional; the default fallback is the seeded in-memory demo
  /// envelope shared with the F.1 walkthrough.
  final HealthAdminGateway? healthGateway;

  /// Phase 11A.6 - observability dashboard gateway. Optional; the
  /// default fallback is the seeded in-memory demo envelope so the
  /// 11A.6 walkthrough renders without the Cloud Run admin proxy.
  /// The /health envelope is intentionally NOT consumed here - that
  /// surface lives behind [healthGateway] / the Health route.
  final ObservabilityAdminGateway? observabilityGateway;

  /// Phase 11A.7 - feature flags admin gateway. Optional; the default
  /// fallback is a seeded in-memory gateway with the launch flag
  /// catalog so the walkthrough exercises the toggle / DANGER paths
  /// without hitting Postgres.
  final FeatureFlagsAdminGateway? featureFlagsGateway;

  /// Phase 11A.5 - debug console admin gateway. Optional; the default
  /// fallback is a seeded in-memory gateway with the per-operator
  /// request log demo so the walkthrough exercises filters, search,
  /// live-tail, and the full-content opt-in paths without a backend.
  final DebugConsoleAdminGateway? debugConsoleGateway;

  /// Phase 8 spine-bridge Lane .C - data accuracy + polling/pricing
  /// admin gateway shared by Tab 1 and Tab 2. Optional; the default
  /// fallback is the seeded in-memory gateway used by the kDemoMode
  /// walkthrough.
  final DataAccuracyAdminGateway? dataAccuracyAdminGateway;

  /// Phase 11A.12 - cross-operator Members + Invites admin gateway.
  /// Optional; the default fallback is the seeded in-memory gateway
  /// used by the kDemoMode walkthrough.
  final MembersAdminGateway? membersAdminGateway;

  /// Phase 11A.13 - Roles + Hierarchy + Sessions inspect admin
  /// gateway. Optional; the default fallback is the seeded in-memory
  /// gateway used by the kDemoMode walkthrough.
  final RolesHierarchySessionsAdminGateway? rolesHierarchySessionsAdminGateway;

  /// Phase 11A.14 - cross-operator Audited support actions admin
  /// gateway. Optional; the default fallback is the seeded in-memory
  /// gateway used by the kDemoMode walkthrough.
  final AuditedSupportActionsAdminGateway? auditedSupportActionsAdminGateway;

  /// Phase 11A.2 - admin auth source. Optional for the same
  /// incremental-wiring reason. The Pricing route reads this to
  /// compute `editingEnabled` from the signed-in session's roles
  /// (only `super_admin` may mutate caps; `ff_support` lands on the
  /// read-only branch). When null, the route defaults to live edit
  /// affordances (test path).
  final AdminAuthSource? adminAuthSource;

  static OperatorLocationAdminGateway operatorLocationGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.operatorLocationGateway ?? _defaultDemoGateway;
  }

  static PricingTierAdminGateway pricingTierGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.pricingTierGateway ?? _defaultPricingDemoGateway;
  }

  static CorpusAdminGateway corpusAdminGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.corpusAdminGateway ?? _defaultCorpusDemoGateway;
  }

  static IntegrationAdminGateway integrationGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.integrationGateway ?? _defaultIntegrationDemoGateway;
  }

  static VendorConnectionsGateway? vendorConnectionsGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.vendorConnectionsGateway;
  }

  static HealthAdminGateway healthGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.healthGateway ?? _defaultHealthDemoGateway;
  }

  static ObservabilityAdminGateway observabilityGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.observabilityGateway ?? _defaultObservabilityDemoGateway;
  }

  static FeatureFlagsAdminGateway featureFlagsGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.featureFlagsGateway ?? _defaultFeatureFlagsDemoGateway;
  }

  static DebugConsoleAdminGateway debugConsoleGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.debugConsoleGateway ?? _defaultDebugConsoleDemoGateway;
  }

  static DataAccuracyAdminGateway dataAccuracyAdminGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.dataAccuracyAdminGateway ?? _defaultDataAccuracyDemoGateway;
  }

  static MembersAdminGateway membersAdminGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.membersAdminGateway ?? _defaultMembersAdminDemoGateway;
  }

  static RolesHierarchySessionsAdminGateway
  rolesHierarchySessionsAdminGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.rolesHierarchySessionsAdminGateway ??
        _defaultRolesHierarchySessionsAdminDemoGateway;
  }

  static AuditedSupportActionsAdminGateway auditedSupportActionsAdminGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.auditedSupportActionsAdminGateway ??
        _defaultAuditedSupportActionsAdminDemoGateway;
  }

  static AdminAuthSource? adminAuthSourceOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.adminAuthSource;
  }

  @override
  bool updateShouldNotify(AdminConsoleServicesScope oldWidget) =>
      operatorLocationGateway != oldWidget.operatorLocationGateway ||
      pricingTierGateway != oldWidget.pricingTierGateway ||
      corpusAdminGateway != oldWidget.corpusAdminGateway ||
      integrationGateway != oldWidget.integrationGateway ||
      vendorConnectionsGateway != oldWidget.vendorConnectionsGateway ||
      healthGateway != oldWidget.healthGateway ||
      observabilityGateway != oldWidget.observabilityGateway ||
      featureFlagsGateway != oldWidget.featureFlagsGateway ||
      debugConsoleGateway != oldWidget.debugConsoleGateway ||
      dataAccuracyAdminGateway != oldWidget.dataAccuracyAdminGateway ||
      membersAdminGateway != oldWidget.membersAdminGateway ||
      rolesHierarchySessionsAdminGateway !=
          oldWidget.rolesHierarchySessionsAdminGateway ||
      auditedSupportActionsAdminGateway !=
          oldWidget.auditedSupportActionsAdminGateway ||
      adminAuthSource != oldWidget.adminAuthSource;
}

/// Demo gateway shared by walkthrough + admin shell when no
/// production scope is mounted. Seeded with two fixture operators
/// so the click path has something to show on first paint without
/// asking the F&F admin to manually run onboarding.
final OperatorLocationAdminGateway _defaultDemoGateway =
    InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        OperatorAdminBundle(
          operator: OperatorAdminRecord(
            operatorId: '00000000-0000-4000-8000-000000000001',
            businessName: 'Demo Diner Co.',
            ownerEmail: 'owner@demo-diner.test',
            subscriptionTier: 'launch',
            preferredCurrency: 'CAD',
            primaryLocationId: '00000000-0000-4000-8000-0000000000a1',
            suspendedAt: null,
            createdAt: DateTime.utc(2026, 1, 12, 14, 30),
            updatedAt: DateTime.utc(2026, 4, 1, 10, 0),
          ),
          locations: <LocationAdminRecord>[
            LocationAdminRecord(
              locationId: '00000000-0000-4000-8000-0000000000a1',
              operatorId: '00000000-0000-4000-8000-000000000001',
              name: 'Toronto Yorkville',
              address: '123 Main St, Toronto, ON',
              timezone: 'America/Toronto',
              businessDayRolloverHour: 4,
              createdAt: DateTime.utc(2026, 1, 12, 14, 30),
              updatedAt: DateTime.utc(2026, 1, 12, 14, 30),
            ),
            LocationAdminRecord(
              locationId: '00000000-0000-4000-8000-0000000000a2',
              operatorId: '00000000-0000-4000-8000-000000000001',
              name: 'Vancouver Robson',
              address: '456 Robson St, Vancouver, BC',
              timezone: 'America/Vancouver',
              businessDayRolloverHour: 4,
              createdAt: DateTime.utc(2026, 2, 1, 9, 0),
              updatedAt: DateTime.utc(2026, 2, 1, 9, 0),
            ),
          ],
        ),
        OperatorAdminBundle(
          operator: OperatorAdminRecord(
            operatorId: '00000000-0000-4000-8000-000000000002',
            businessName: 'Sunset Cafe Group',
            ownerEmail: 'owner@sunset-cafe.test',
            subscriptionTier: 'pilot',
            preferredCurrency: 'USD',
            primaryLocationId: '00000000-0000-4000-8000-0000000000b1',
            suspendedAt: null,
            createdAt: DateTime.utc(2026, 3, 5, 11, 0),
            updatedAt: DateTime.utc(2026, 4, 18, 12, 0),
          ),
          locations: <LocationAdminRecord>[
            LocationAdminRecord(
              locationId: '00000000-0000-4000-8000-0000000000b1',
              operatorId: '00000000-0000-4000-8000-000000000002',
              name: 'Brooklyn Williamsburg',
              address: '78 Bedford Ave, Brooklyn, NY',
              timezone: 'America/New_York',
              businessDayRolloverHour: 5,
              createdAt: DateTime.utc(2026, 3, 5, 11, 0),
              updatedAt: DateTime.utc(2026, 3, 5, 11, 0),
            ),
          ],
        ),
      ],
    );

/// 11A.2 fallback pricing gateway. Mirrors the two demo operators
/// from `_defaultDemoGateway` so the walkthrough can hop between
/// Operators and Pricing without a backing service. Pilot operator
/// starts with the locked Pilot template caps; the launch operator
/// has no caps yet so the walkthrough exercises "Apply template" too.
final PricingTierAdminGateway _defaultPricingDemoGateway =
    InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        PricingOperatorBundle(
          operatorId: '00000000-0000-4000-8000-000000000001',
          businessName: 'Demo Diner Co.',
          subscriptionTier: 'launch',
          preferredCurrency: 'CAD',
          primaryLocationId: '00000000-0000-4000-8000-0000000000a1',
          primaryLocationName: 'Toronto Yorkville',
          suspended: false,
          caps: <UsageCapRow>[],
        ),
        PricingOperatorBundle(
          operatorId: '00000000-0000-4000-8000-000000000002',
          businessName: 'Sunset Cafe Group',
          subscriptionTier: 'pilot',
          preferredCurrency: 'USD',
          primaryLocationId: '00000000-0000-4000-8000-0000000000b1',
          primaryLocationName: 'Brooklyn Williamsburg',
          suspended: false,
          caps: <UsageCapRow>[
            UsageCapRow(
              capId: '00000000-0000-4000-8000-0000000000c1',
              operatorId: '00000000-0000-4000-8000-000000000002',
              locationId: '00000000-0000-4000-8000-0000000000b1',
              usageClass: 'advisor_qa',
              monthlyCapUsd: 50.0,
              perInvocationCapUsd: 0.10,
              staffId: null,
              workflowId: null,
              createdBy: 'demo-super-admin',
              updatedBy: 'demo-super-admin',
              createdAt: DateTime.utc(2026, 3, 5, 11, 0),
              updatedAt: DateTime.utc(2026, 4, 18, 12, 0),
            ),
          ],
        ),
      ],
    );

/// 11A.3a fallback corpus admin gateway. Seeded with two demo
/// versions so the walkthrough has both a "current" and a "prior"
/// row to render. Demo chunks live entirely in memory; the seed
/// summary text doubles as the 11A.3a click-path script.
final CorpusAdminGateway _defaultCorpusDemoGateway = InMemoryCorpusAdminGateway(
  seed: <CorpusBundle>[
    CorpusBundle(
      version: CorpusVersionRef(
        versionId: '00000000-0000-4000-9000-000000000001',
        createdBy: 'demo-super-admin',
        createdAt: DateTime.utc(2026, 1, 14, 9, 0),
        summary: 'Initial methodology seed',
        rollbackOf: null,
        supersededAt: DateTime.utc(2026, 3, 1, 10, 0),
        chunkCount: 2,
      ),
      chunks: <ChunkPreview>[
        ChunkPreview(
          chunkId: 'methodology_seed.md#000',
          docId: 'methodology_seed.md',
          sourcePath: 'methodology_seed.md',
          headingPath: <String>['Forge & Flow Methodology'],
          snippet:
              'Forge & Flow advisor methodology. Source-truth, '
              'derived metrics, teaching summaries.',
          estimatedTokens: 64,
          riskLevel: 'standard',
          contentSha256: 'a' * 64,
          versionId: '00000000-0000-4000-9000-000000000001',
          active: false,
        ),
        ChunkPreview(
          chunkId: 'methodology_seed.md#001',
          docId: 'methodology_seed.md',
          sourcePath: 'methodology_seed.md',
          headingPath: <String>['Forge & Flow Methodology', 'Cycles'],
          snippet:
              'Sixty-day target cycles lock standards. Weekly plan '
              'snapshots compare actuals against the locked target.',
          estimatedTokens: 80,
          riskLevel: 'standard',
          contentSha256: 'b' * 64,
          versionId: '00000000-0000-4000-9000-000000000001',
          active: false,
        ),
      ],
    ),
    CorpusBundle(
      version: CorpusVersionRef(
        versionId: '00000000-0000-4000-9000-000000000002',
        createdBy: 'demo-super-admin',
        createdAt: DateTime.utc(2026, 3, 1, 10, 0),
        summary: 'Added daypart guidance',
        rollbackOf: null,
        supersededAt: null,
        chunkCount: 3,
      ),
      chunks: <ChunkPreview>[
        ChunkPreview(
          chunkId: 'methodology_seed.md#000',
          docId: 'methodology_seed.md',
          sourcePath: 'methodology_seed.md',
          headingPath: <String>['Forge & Flow Methodology'],
          snippet:
              'Forge & Flow advisor methodology. Source-truth, '
              'derived metrics, teaching summaries.',
          estimatedTokens: 64,
          riskLevel: 'standard',
          contentSha256: 'a' * 64,
          versionId: '00000000-0000-4000-9000-000000000002',
          active: true,
        ),
        ChunkPreview(
          chunkId: 'methodology_seed.md#001',
          docId: 'methodology_seed.md',
          sourcePath: 'methodology_seed.md',
          headingPath: <String>['Forge & Flow Methodology', 'Cycles'],
          snippet:
              'Sixty-day target cycles lock standards. Weekly plan '
              'snapshots compare actuals against the locked target.',
          estimatedTokens: 80,
          riskLevel: 'standard',
          contentSha256: 'b' * 64,
          versionId: '00000000-0000-4000-9000-000000000002',
          active: true,
        ),
        ChunkPreview(
          chunkId: 'methodology_seed.md#002',
          docId: 'methodology_seed.md',
          sourcePath: 'methodology_seed.md',
          headingPath: <String>['Forge & Flow Methodology', 'Daypart'],
          snippet:
              'Daypart guidance lives alongside whole-day truth, '
              'never replacing it. 10.5 introduces the daypart split.',
          estimatedTokens: 72,
          riskLevel: 'standard',
          contentSha256: 'c' * 64,
          versionId: '00000000-0000-4000-9000-000000000002',
          active: true,
        ),
      ],
    ),
  ],
  actorUserId: 'demo-super-admin',
);

/// 11A.4 fallback integration gateway. Seeds Anthropic + Voyage with
/// pre-rotated masked rows; Azure DB starts empty so the walkthrough
/// can exercise the "no row yet → first rotation" path. The KMS
/// stub is the same provider production would bind in pre-launch.
final IntegrationAdminGateway _defaultIntegrationDemoGateway =
    InMemoryIntegrationAdminGateway(
      actorUserId: 'demo-super-admin',
      seed: <ProviderKeyRow>[
        ProviderKeyRow(
          credentialId: '00000000-0000-4000-8000-0000000000d1',
          keyKind: ProviderKeyKind.anthropic,
          maskedValue: 'sk-a***Q9aB',
          kmsSecretName: 'kms://stub/seed-anthropic',
          createdBy: 'demo-super-admin',
          updatedBy: 'demo-super-admin',
          rotatedAt: DateTime.utc(2026, 4, 1, 14, 0),
        ),
        ProviderKeyRow(
          credentialId: '00000000-0000-4000-8000-0000000000d2',
          keyKind: ProviderKeyKind.voyage,
          maskedValue: 'pa-v***RtZx',
          kmsSecretName: 'kms://stub/seed-voyage',
          createdBy: 'demo-super-admin',
          updatedBy: 'demo-super-admin',
          rotatedAt: DateTime.utc(2026, 4, 5, 9, 30),
        ),
      ],
    );

/// F.1 fallback health gateway. Seeded with the demo envelope from
/// `health_admin_gateway.dart` so the walkthrough renders all three
/// tabs with realistic green/yellow signals and exercises the
/// dependencies strip without a live proxy.
final HealthAdminGateway _defaultHealthDemoGateway = InMemoryHealthAdminGateway(
  envelope: kHealthAdminDemoEnvelope,
);

/// 11A.6 fallback observability gateway. Seeded with the demo
/// envelope from `observability_admin_gateway.dart`; the click path
/// renders cost telemetry, dormancy, margin, cap events, graph, and
/// Cloud Run sections without the production cost / dormancy proxy
/// endpoints having to be live.
final ObservabilityAdminGateway _defaultObservabilityDemoGateway =
    InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );

/// 11A.7 fallback feature flags gateway. Seeds the launch flag
/// catalog so the demo walkthrough can exercise the toggle and
/// destructive-confirmation paths end-to-end. Mirrors the rows
/// landed by the launch migrations:
///
///   * `audit_logs_cutover_enabled` (destructive) - B.2 cutover flag.
///   * `kms_real_provider_<kind>_enabled` (destructive) - per-lane
///     KMS rollout gates.
///   * `advisor_enabled` (standard) - example launch flag for the
///     advisor surface.
final FeatureFlagsAdminGateway _defaultFeatureFlagsDemoGateway =
    InMemoryFeatureFlagsAdminGateway(
      actorUserId: 'demo-super-admin',
      seed: <FeatureFlagAdminRow>[
        FeatureFlagAdminRow(
          flagId: '00000000-0000-4000-8000-0000000000f1',
          flagName: 'audit_logs_cutover_enabled',
          operatorId: null,
          locationId: null,
          enabled: true,
          kind: kFeatureFlagKindDestructive,
          description:
              'Routes sign-in and admin changes into the permanent audit log. '
              'Turn off only for a rollback.',
          updatedBy: 'demo-super-admin',
          createdAt: DateTime.utc(2026, 5, 1, 10, 0),
          updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
        ),
        FeatureFlagAdminRow(
          flagId: '00000000-0000-4000-8000-0000000000f2',
          flagName: 'kms_real_provider_anthropic_enabled',
          operatorId: null,
          locationId: null,
          enabled: false,
          kind: kFeatureFlagKindDestructive,
          description:
              'Uses secure cloud storage for Anthropic service keys instead '
              'of demo storage.',
          updatedBy: 'demo-super-admin',
          createdAt: DateTime.utc(2026, 5, 2, 2, 0),
          updatedAt: DateTime.utc(2026, 5, 2, 2, 0),
        ),
        FeatureFlagAdminRow(
          flagId: '00000000-0000-4000-8000-0000000000f3',
          flagName: 'kms_real_provider_voyage_enabled',
          operatorId: null,
          locationId: null,
          enabled: false,
          kind: kFeatureFlagKindDestructive,
          description:
              'Uses secure cloud storage for Voyage service keys instead of '
              'demo storage.',
          updatedBy: 'demo-super-admin',
          createdAt: DateTime.utc(2026, 5, 2, 2, 0),
          updatedAt: DateTime.utc(2026, 5, 2, 2, 0),
        ),
        FeatureFlagAdminRow(
          flagId: '00000000-0000-4000-8000-0000000000f4',
          flagName: 'advisor_enabled',
          operatorId: null,
          locationId: null,
          enabled: true,
          kind: kFeatureFlagKindStandard,
          description:
              'Controls whether the advisor experience is available in the '
              'app.',
          updatedBy: 'demo-super-admin',
          createdAt: DateTime.utc(2026, 5, 1, 10, 0),
          updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
        ),
      ],
    );

/// 11A.5 fallback debug console gateway. Seeded with the per-operator
/// request log demo (mixed operators / usage_class / status / opt-ins)
/// so the walkthrough exercises filters, search, live-tail, and the
/// full-content opt-in paths without hitting the proxy.
final DebugConsoleAdminGateway _defaultDebugConsoleDemoGateway =
    InMemoryDebugConsoleAdminGateway(
      seed: kDebugConsoleDemoEntries,
      optInSeed: kDebugConsoleDemoOptIns,
    );

/// Phase 8 spine-bridge Lane .C fallback data accuracy + polling/pricing
/// admin gateway. Mirrors the two demo operators on `_defaultDemoGateway`
/// so the walkthrough hops between Operators / Data Accuracy / Polling
/// & Pricing without a backing service. Tier definitions are baked from
/// `kDemoStandardTierDefinition` / `kDemoPremiumTierDefinition` /
/// `kDemoCustomTierDefinition`. One illustrative tier change request
/// drives the Tab 2 Card 4 demo path.
final DataAccuracyAdminGateway _defaultDataAccuracyDemoGateway =
    InMemoryDataAccuracyAdminGateway(
      operatorLocations: const <OperatorLocationRef>[
        OperatorLocationRef(
          operatorId: '00000000-0000-4000-8000-000000000001',
          businessName: 'Demo Diner Co.',
          locationId: '00000000-0000-4000-8000-0000000000a1',
          locationName: 'Toronto Yorkville',
        ),
        OperatorLocationRef(
          operatorId: '00000000-0000-4000-8000-000000000001',
          businessName: 'Demo Diner Co.',
          locationId: '00000000-0000-4000-8000-0000000000a2',
          locationName: 'Vancouver Robson',
        ),
        OperatorLocationRef(
          operatorId: '00000000-0000-4000-8000-000000000002',
          businessName: 'Sunset Cafe Group',
          locationId: '00000000-0000-4000-8000-0000000000b1',
          locationName: 'Brooklyn Williamsburg',
        ),
      ],
      initialTierDefinitions: <PollingTierKey, TierDefinition>{
        PollingTierKey.standard: kDemoStandardTierDefinition(),
        PollingTierKey.premium: kDemoPremiumTierDefinition(),
        PollingTierKey.custom: kDemoCustomTierDefinition(),
      },
      initialChangeRequests: <TierChangeRequest>[
        TierChangeRequest(
          requestId: 'demo-change-request-1',
          operatorRef: const OperatorLocationRef(
            operatorId: '00000000-0000-4000-8000-000000000001',
            businessName: 'Demo Diner Co.',
            locationId: '00000000-0000-4000-8000-0000000000a1',
            locationName: 'Toronto Yorkville',
          ),
          currentTier: PollingTierKey.standard,
          requestedTier: PollingTierKey.premium,
          operatorNote:
              'We need tighter mid-service awareness on dinner volume.',
          submittedAt: DateTime.utc(2026, 5, 4, 14, 30),
          status: TierChangeRequestStatus.pending,
        ),
      ],
    );

/// Phase 11A.12 - cross-operator Members + Invites demo gateway.
/// Seeded from `kDemoMembersByOperator` / `kDemoInvitesByOperator`
/// (same demo identities the .C / 11A.1 walkthroughs use) so a F&F
/// admin can sign in, pick an operator, and exercise filter chips +
/// row actions + the invite flow without a live proxy.
final MembersAdminGateway _defaultMembersAdminDemoGateway =
    InMemoryMembersAdminGateway(
      membersByOperator: kDemoMembersByOperator(),
      invitesByOperator: kDemoInvitesByOperator(),
    );

/// Phase 11A.13 - Roles + Hierarchy + Sessions demo gateway. Reuses
/// the operators on the Members demo so the walkthrough can hop
/// straight from the Members surface into Roles / Hierarchy /
/// Sessions for the same operator.
final RolesHierarchySessionsAdminGateway
_defaultRolesHierarchySessionsAdminDemoGateway =
    InMemoryRolesHierarchySessionsAdminGateway(
      rolesByOperator: kDemoRolesByOperator(),
      orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      locationsByOperator: kDemoHierarchyLocationsByOperator(),
      sessionsByOperator: kDemoSessionsByOperator(),
    );

/// Phase 11A.14 - Audited support actions demo gateway. Seeded with
/// the audit-log entries + members fixture from
/// `kDemoAuditLogByOperator` / `kDemoSupportActionsMembersByOperator`
/// so the walkthrough can hop straight from any prior 11W / 11A
/// operator-scoped surface into the audit-log + support-actions
/// surface for the same operator.
final AuditedSupportActionsAdminGateway
_defaultAuditedSupportActionsAdminDemoGateway =
    InMemoryAuditedSupportActionsAdminGateway(
      auditLogByOperator: kDemoAuditLogByOperator(),
      membersByOperator: kDemoSupportActionsMembersByOperator(),
    );
