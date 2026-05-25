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
import '../auth/permission_keys.dart';
import '../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../theme/scope_icons.dart';
import 'admin_auth_gate.dart';
import 'admin_capability_gate.dart';
import 'admin_console_style.dart';
import 'admin_destructive_gate.dart';
import 'admin_route_handoff.dart';
import 'admin_route_model.dart';
import 'models/corpus_admin_models.dart';
import 'models/debug_console_admin_models.dart';
import 'models/feature_flags_admin_models.dart';
import 'models/integration_admin_models.dart';
import 'models/operator_location_admin_models.dart';
import 'models/pricing_tier_admin_models.dart';
import 'screens/admin_notification_preferences_screen.dart';
import 'screens/admin_timing_setup_screen.dart';
import 'screens/corpus_admin_screen.dart';
import 'screens/debug_console_admin_screen.dart';
import 'screens/default_role_catalog_admin_screen.dart';
import 'screens/feature_flags_admin_screen.dart';
import 'screens/health_admin_screen.dart';
import 'screens/integration_admin_screen.dart';
import 'screens/members_admin_screen.dart';
import 'screens/my_account_admin_screen.dart';
import 'screens/observability_admin_screen.dart';
import 'screens/operator_location_admin_screen.dart';
import 'screens/operator_picker_screen.dart';
import 'screens/audited_support_actions_admin_screen.dart';
import 'screens/per_location_data_accuracy_screen.dart';
import 'screens/polling_and_pricing_admin_screen.dart';
import 'screens/pricing_tier_admin_screen.dart';
import 'screens/roles_hierarchy_sessions_admin_screen.dart';
import 'screens/support_operator_view_admin_screen.dart';
import 'screens/vendor_applicability_admin_screen.dart';
import 'screens/vendor_connections/vendor_connections_admin_mount.dart';
import 'services/admin_account_gateway.dart';
import 'services/admin_audit_chain_anchors_gateway.dart';
import 'services/admin_business_timing_profiles_gateway.dart';
import 'services/admin_business_timing_resolution_gateway.dart';
import 'services/admin_business_timing_resolution_projection.dart';
import 'services/admin_notification_preferences_gateway.dart';
import 'services/admin_security_gateway.dart';
import 'services/admin_sessions_gateway.dart';
import 'services/audit_log_admin_rootnode_builder.dart';
import 'services/audited_support_actions_admin_gateway.dart';
import 'services/corpus_admin_gateway.dart';
import 'services/data_accuracy_admin_gateway.dart';
import 'services/debug_console_admin_gateway.dart';
import 'services/default_role_catalog_admin_gateway.dart';
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
import 'services/vendor_applicability_admin_gateway.dart';
import 'widgets/admin_setup_workspace.dart';
import 'widgets/corpus_upload_dialog.dart';
import '../domain/models/data_accuracy_settings.dart';
import '../domain/models/forge_flow_polling_tier_assignment.dart';
import '../domain/models/inheritance_tree_node.dart';

// AdminRoute + AdminRouteSection moved to admin_route_model.dart to keep
// this frozen-ceiling route table shrinking; re-exported so importers
// that referenced the model types through this file stay unchanged.
export 'admin_route_model.dart';

// Demo / fallback gateway defaults live in a part file to keep this route
// table under its size ceiling (size-lint slim-down, 2026-05-24).
part 'admin_routes_demo_gateways_part.dart';

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

/// Shared admin super-admin editing-gate predicate. Returns true iff
/// [session] is non-null AND carries the `super_admin` role. DRYs the
/// copy-pasted `session != null && session.roles.contains(...)`
/// editing-decision sites and aliases the catalog constant
/// ([PermissionKeys.roleSuperAdmin] is byte-equal to the literal
/// `'super_admin'`), so this is behaviour-preserving. The UI
/// affordance is advisory only - the proxy `PermissionResolver`
/// re-checks every write server-side.
bool _isAdminSuperAdmin(AdminAuthSession? session) =>
    session != null && session.roles.contains(PermissionKeys.roleSuperAdmin);

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

/// Lane B B2.2 — Default Role catalog admin editor route ID. F&F
/// internal-only surface that lists every published version of the
/// `default_role_catalog_versions` table, lets a `super_admin` author
/// a draft, and publishes a new version via the B2.1 admin gateway.
/// `ff_support` lands on the read-only branch.
const String kAdminDefaultRoleCatalogRouteId = 'default-role-catalog';

/// Canonical Observability route ID (Phase 11A.6). The Observability
/// surface is the cost-telemetry / dormancy / margin / cap-event /
/// graph / Cloud-Run dashboard. The /health envelope viewer is owned
/// by [kAdminHealthRouteId] and is intentionally a different route.
const String kAdminObservabilityRouteId = 'observability';

/// Phase 8 spine-bridge Lane .C - Data Accuracy admin tab (Tab 1).
const String kAdminDataAccuracyRouteId = 'data-accuracy';

/// B10.2 - Vendor applicability admin editor route ID.
const String kAdminVendorApplicabilityRouteId = 'vendor-applicability';

/// Phase 8 spine-bridge Lane .C - Polling & Pricing admin tab (Tab 2).
const String kAdminPollingPricingRouteId = 'polling-pricing';

/// Hidden setup route for per-location vendor lifecycle controls launched
/// from Business Accounts.
const String kAdminVendorIntegrationsRouteId = 'vendor-integrations';

/// Hidden setup route for business/org-unit/location timing review launched
/// from Business Accounts.
const String kAdminTimingSetupRouteId = 'timing-setup';

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

/// Wave 2 W-4 — Admin "My Account" parity surface. Mirrors the
/// customer operator-web `MyAccountScreen` for the admin actor
/// (`super_admin` / `ff_support`). Read-only today (no admin gateway
/// for MFA / sessions mutations); future slices can light up the
/// mutate paths once those gateways exist.
const String kAdminMyAccountRouteId = 'my-account';

/// X-G71 (cross-surface parity register, audit
/// `docs/_audits/cross_surface_parity_v1/cross_surface_parity_audit_2026_05_16.md`
/// section 0b) — admin notification-preferences parity surface.
/// Mirrors the customer operator-web Notifications editor for the
/// admin actor (`super_admin` / `ff_support`). Wired to the SAME
/// existing `/v1/operator/notification-preferences` route through
/// `AdminNotificationPreferencesGateway`; no new proxy/backend route.
const String kAdminNotificationPreferencesRouteId = 'notification-preferences';

/// The admin route table. Order is the side-nav order.
const List<AdminRoute> kAdminRoutes = <AdminRoute>[
  AdminRoute(
    id: kAdminOperatorsRouteId,
    title: 'Business accounts',
    path: '/operators',
    // canonical business icon (mirrors scopeIcon(business)); const literal because kAdminRoutes is const
    icon: Icons.apartment_outlined,
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
    subtitle:
        'This surface is for F&F admins only. Operators cannot see it. Review AI plans and usage limits.',
    builder: _buildPricing,
  ),
  AdminRoute(
    id: kAdminCorpusRouteId,
    title: 'Knowledge base',
    path: '/corpus',
    icon: Icons.menu_book_outlined,
    section: AdminRouteSection.ai,
    subtitle:
        'This surface is for F&F admins only. Operators cannot see it. Publish advisor knowledge content.',
    builder: _buildCorpus,
  ),
  AdminRoute(
    id: kAdminIntegrationsRouteId,
    title: 'Connected services',
    path: '/integrations',
    icon: Icons.extension_outlined,
    section: AdminRouteSection.serviceSetup,
    subtitle:
        'Review global provider health and platform service keys; operator edits live on Operator Web.',
    builder: _buildIntegrations,
  ),
  AdminRoute(
    id: kAdminHealthRouteId,
    title: 'System health',
    path: '/health',
    icon: Icons.monitor_heart_outlined,
    section: AdminRouteSection.systemMonitoring,
    subtitle:
        'This surface is for F&F admins only. Operators cannot see it. Run read-only system checks.',
    builder: _buildHealth,
  ),
  AdminRoute(
    id: kAdminFeatureFlagsRouteId,
    title: 'Launch controls',
    path: '/feature-flags',
    icon: Icons.flag_outlined,
    section: AdminRouteSection.serviceSetup,
    subtitle:
        'This surface is for F&F admins only. Operators cannot see it. Control staged features.',
    builder: _buildFeatureFlags,
  ),
  AdminRoute(
    id: kAdminDefaultRoleCatalogRouteId,
    title: 'Default roles',
    path: '/default-roles',
    icon: Icons.shield_outlined,
    section: AdminRouteSection.serviceSetup,
    subtitle:
        'This surface is for F&F admins only. Operators cannot see it. '
        'Edit the starter role catalog every business begins with.',
    builder: _buildDefaultRoleCatalog,
  ),
  AdminRoute(
    id: kAdminDebugConsoleRouteId,
    title: 'Support logs',
    path: '/debug',
    icon: Icons.bug_report_outlined,
    section: AdminRouteSection.systemMonitoring,
    subtitle:
        'This surface is for F&F admins only. Operators cannot see it. Inspect support-safe request details.',
    builder: _buildDebugConsole,
  ),
  AdminRoute(
    id: kAdminObservabilityRouteId,
    title: 'AI Metrics',
    path: '/observability',
    icon: Icons.insights_outlined,
    section: AdminRouteSection.ai,
    subtitle:
        'This surface is for F&F admins only. Operators cannot see it. Review advisor usage, cost, and model activity.',
    builder: _buildObservability,
  ),
  AdminRoute(
    id: kAdminDataAccuracyRouteId,
    title:
        'Data accuracy', // UX-parity Slice C: operator-web nav label (screen header unchanged).
    path: '/data-accuracy',
    icon: Icons.fact_check_outlined,
    section: AdminRouteSection.operations,
    subtitle:
        'Review effective covers, wages, and walk-ins by location; super admins can apply audited location repairs.',
    builder: _buildDataAccuracy,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
  AdminRoute(
    id: kAdminVendorApplicabilityRouteId,
    title: 'Vendor Applicability',
    path: '/vendor-applicability',
    icon: Icons.fact_check_outlined,
    section: AdminRouteSection.operations,
    subtitle:
        'This surface is for F&F admins only - choose which vendors can power wage, covers, and polling settings.',
    builder: _buildVendorApplicability,
  ),
  AdminRoute(
    id: kAdminPollingPricingRouteId,
    title: 'Polling Setup',
    path: '/polling-pricing',
    icon: Icons.payments_outlined,
    section: AdminRouteSection.operations,
    subtitle:
        'This surface is for F&F admins only. Operators cannot see it. Operator Web reads the published tier status.',
    builder: _buildPollingPricing,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
  AdminRoute(
    id: kAdminVendorIntegrationsRouteId,
    title: 'Vendor integrations',
    path: '/admin/vendor-integrations',
    icon: Icons.link_outlined,
    section: AdminRouteSection.operations,
    subtitle:
        'Review location-scoped vendor connections; super admins can connect, test, disconnect, and inspect logs.',
    builder: _buildVendorIntegrations,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
  AdminRoute(
    id: kAdminTimingSetupRouteId,
    title: 'Timing',
    path: '/admin/timing',
    icon: Icons.schedule_outlined,
    section: AdminRouteSection.operations,
    subtitle:
        'Review effective timezone, business day, and service periods. Normal timing edits stay in Operator Web; super admin repair routes are server-side.',
    builder: _buildTimingSetup,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
  AdminRoute(
    id: kAdminMembersRouteId,
    title: 'Team members', // UX-parity Slice C: operator-web nav label.
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
    title: 'Roles & permissions', // UX-parity Slice C: operator-web nav label.
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
    title: 'Audit log', // UX-parity Slice C: operator-web nav label.
    path: '/admin/audited-support-actions',
    icon: Icons.security_outlined,
    section: AdminRouteSection.operations,
    subtitle:
        'Review audit history and gated support actions for one operator.',
    builder: _buildAuditedSupportActions,
    visibleInNav: false,
    navAnchorRouteId: kAdminOperatorsRouteId,
  ),
  AdminRoute(
    id: kAdminMyAccountRouteId,
    title: 'My account',
    path: '/admin/my-account',
    icon: Icons.person_outline,
    section: AdminRouteSection.account,
    subtitle:
        'Review your admin sign-in details, two-factor sign-in status, '
        'and current session.',
    builder: _buildMyAccount,
  ),
  AdminRoute(
    id: kAdminNotificationPreferencesRouteId,
    title: 'Notifications',
    path: '/admin/notification-preferences',
    icon: Icons.notifications_outlined,
    section: AdminRouteSection.account,
    subtitle:
        'Pick how Forge & Flow lets you know about important events for '
        'your admin sign-in.',
    builder: _buildAdminNotificationPreferences,
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
      // Fix #4 / S4 (G42): READ-ONLY admin business-timing resolution
      // gateway threaded into the per-location Timing dialog so the
      // displayed timezone / business-day / week-start / service
      // periods are the REAL resolved EffectiveBusinessTimingProfile.
      timingResolutionGateway:
          AdminConsoleServicesScope.timingResolutionGatewayOf(context),
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
      onOpenIntegrationsScope: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminVendorIntegrationsRouteId,
                  hierarchyScope: scope,
                ),
              );
            },
      onOpenTimingScope: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminTimingSetupRouteId,
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
      // A DELIBERATE business / org-unit / location pick in the left scope
      // tree emits a hierarchyScope intent (staying on the operators route,
      // so no navigation). The shell flips its "business chosen" latch on a
      // hierarchyScope-carrying intent, activating the per-business sidebar
      // cluster. The on-load seed (`onSelectOperatorScope`) carries only an
      // operatorLocationScope, so it never activates the cluster.
      onChooseBusinessScope: handoff == null
          ? null
          : (scope) {
              handoff.onSelectRoute(
                AdminRouteIntent(
                  routeId: kAdminOperatorsRouteId,
                  hierarchyScope: scope,
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
      final canEdit = _isAdminSuperAdmin(session);
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

Widget _buildScopedAdminWorkspace({
  required BuildContext context,
  required String routeId,
  required String functionTitle,
  required String description,
  required AdminSetupWorkspaceBuilder functionBuilder,
  bool allowAllBusinessesScope = false,
  WidgetBuilder? allBusinessesBuilder,
}) {
  final handoff = AdminRouteHandoff.maybeOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final hierarchyGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  return AdminSetupWorkspace(
    functionTitle: functionTitle,
    description: description,
    operatorGateway: operatorGateway,
    hierarchyGateway: hierarchyGateway,
    initialScope: handoff?.effectiveHierarchyScope,
    onBackToBusinessAccounts: _backToBusinessAccounts(context),
    onScopeChanged: handoff == null
        ? null
        : (scope) => handoff.onSelectRoute(
            AdminRouteIntent(routeId: routeId, hierarchyScope: scope),
          ),
    functionBuilder: functionBuilder,
    allowAllBusinessesScope: allowAllBusinessesScope,
    allBusinessesBuilder: allBusinessesBuilder,
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
  final initialScope = handoff?.effectiveHierarchyScope;
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
      initialScope: initialScope,
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
        initialScope: initialScope,
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
    required this.initialScope,
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
  final AdminHierarchyScopeIntent? initialScope;
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
      return AdminConsoleEmptyState(
        key: const Key('admin_support_operator_view_no_scope_state'),
        icon: scopeIcon(kind: ScopeEntityKind.business),
        title: 'Choose a business',
        message:
            'Support work starts with one business and one location scope. '
            'After that, People, Access, Security, Audit, and Vendors stay '
            'in the same workspace.',
        action: FilledButton.icon(
          key: const Key('admin_support_operator_view_open_picker'),
          onPressed: _openPicker,
          icon: Icon(scopeIcon(kind: ScopeEntityKind.business), size: 16),
          label: const Text('Choose business'),
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
  // Plans & Limits V1 (Phase 1) reads spend / margin / cap-breach
  // figures from the existing observability gateway (read-only). In
  // demo this returns the seeded envelope keyed by the same demo
  // operators; no new backend route is added.
  final observabilityGateway = AdminConsoleServicesScope.observabilityGatewayOf(
    context,
  );
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  return _buildScopedAdminWorkspace(
    context: context,
    routeId: kAdminPricingRouteId,
    functionTitle: 'Plans and limits',
    description: 'Review plan status and usage limits.',
    functionBuilder: (context, selectedScope, selection) {
      if (source == null) {
        return PricingTierAdminScreen(
          gateway: gateway,
          observabilityGateway: observabilityGateway,
          hierarchyScope: selectedScope,
          scopeLocationIds: selection.locationIds,
        );
      }
      return StreamBuilder<AdminAuthState>(
        stream: source.stream,
        initialData: source.current,
        builder: (context, snapshot) {
          final session = adminSessionOf(snapshot.data);
          // UX-parity Slice E1 — key-first Pricing gate; see [adminCanEdit].
          final canEdit = adminCanEdit(
            session,
            requiredKey: PermissionKeys.adminPricingTierEdit,
          );
          return PricingTierAdminScreen(
            gateway: gateway,
            observabilityGateway: observabilityGateway,
            editingEnabled: canEdit,
            hierarchyScope: selectedScope,
            scopeLocationIds: selection.locationIds,
          );
        },
      );
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
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  return _buildScopedAdminWorkspace(
    context: context,
    routeId: kAdminCorpusRouteId,
    functionTitle: 'Knowledge Base',
    description: 'Review knowledge content and relationship review.',
    functionBuilder: (context, selectedScope, selection) {
      final targetOperatorId = selectedScope.operatorId;
      final targetLocationId = selectedScope.locationId;
      // B1 — wire the real file-picker dialog as the upload picker.
      // Production (source != null) and demo (source == null) both use
      // [showCorpusUploadDialog]; the dialog internally renders a
      // "Use sample file" affordance when `kDemoMode` is true so the
      // demo walkthrough click-path runs without a real file on disk.
      // The old paste-markdown `_defaultDemoPicker` in the screen remains
      // as a fallback but is no longer reached from this wiring.
      final CorpusUploadPicker uploadPicker = showCorpusUploadDialog;
      if (source == null) {
        return CorpusAdminScreen(
          gateway: gateway,
          uploadPicker: uploadPicker,
          targetOperatorId: targetOperatorId,
          targetLocationId: targetLocationId,
        );
      }
      return StreamBuilder<AdminAuthState>(
        stream: source.stream,
        initialData: source.current,
        builder: (context, snapshot) {
          final session = adminSessionOf(snapshot.data);
          final canEdit = _isAdminSuperAdmin(session);
          return CorpusAdminScreen(
            gateway: gateway,
            editingEnabled: canEdit,
            uploadPicker: uploadPicker,
            targetOperatorId: targetOperatorId,
            targetLocationId: targetLocationId,
          );
        },
      );
    },
  );
}

Widget _buildIntegrations(BuildContext context) {
  final gateway = AdminConsoleServicesScope.integrationGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  Widget buildScreen({required bool canEdit}) {
    return IntegrationAdminScreen(
      key: const ValueKey<String>('integrations-platform'),
      gateway: gateway,
      editingEnabled: canEdit,
    );
  }

  if (source == null) {
    return buildScreen(canEdit: true);
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final session = adminSessionOf(snapshot.data);
      final canEdit = _isAdminSuperAdmin(session);
      return buildScreen(canEdit: canEdit);
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
  return _buildScopedAdminWorkspace(
    context: context,
    routeId: kAdminObservabilityRouteId,
    functionTitle: 'AI Metrics',
    description: 'Review AI cost, usage, reliability, and hosting signals.',
    functionBuilder: (context, selectedScope, selection) =>
        ObservabilityAdminScreen(
          key: ValueKey<String>('observability-${selectedScope.cacheKey}'),
          gateway: gateway,
          hierarchyScope: selectedScope,
          scopeLocationIds: selection.locationIds,
        ),
    // super_admin / ff_support can pick the platform-wide aggregate
    // (operator_id = null). The screen already reads cross-business when
    // its hierarchy scope is null, so the all-businesses builder simply
    // omits the scope.
    allowAllBusinessesScope: true,
    allBusinessesBuilder: (context) => ObservabilityAdminScreen(
      key: const ValueKey<String>('observability-all-businesses'),
      gateway: gateway,
    ),
  );
}

Widget _buildFeatureFlags(BuildContext context) {
  final gateway = AdminConsoleServicesScope.featureFlagsGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  return _buildScopedAdminWorkspace(
    context: context,
    routeId: kAdminFeatureFlagsRouteId,
    functionTitle: 'Launch controls',
    description:
        'Turn rollout controls on or off with audit-backed confirmation.',
    functionBuilder: (context, selectedScope, selection) {
      Widget buildScreen({required bool canEdit}) {
        return FeatureFlagsAdminScreen(
          key: ValueKey<String>('feature-flags-${selectedScope.cacheKey}'),
          gateway: gateway,
          editingEnabled: canEdit,
          hierarchyScope: selectedScope,
          scopeLocationIds: selection.locationIds,
        );
      }

      if (source == null) {
        return buildScreen(canEdit: true);
      }
      return StreamBuilder<AdminAuthState>(
        stream: source.stream,
        initialData: source.current,
        builder: (context, snapshot) {
          final session = adminSessionOf(snapshot.data);
          final canEdit = _isAdminSuperAdmin(session);
          return buildScreen(canEdit: canEdit);
        },
      );
    },
  );
}

/// Lane B B2.2 — Default Role catalog admin editor route builder.
/// Reads the gateway from [AdminConsoleServicesScope]; demo + widget
/// tests fall back to the seeded in-memory gateway.
///
/// Wave 2 RP-9 (2026-05-14): the edit affordance is now gated by the
/// catalog-registered permission key
/// `PermissionKeys.teamRolesDefaultCatalogEdit` (super_admin only),
/// and the read branch by
/// `PermissionKeys.teamRolesDefaultCatalogView` (super_admin +
/// ff_support). The admin console's `AdminAuthSession` only carries
/// role claims at the gate layer, so the role-tier sets
/// `kDefaultRoleCatalogScreenEditRoles` /
/// `kDefaultRoleCatalogScreenViewRoles` in the screen file are the
/// defense-in-depth fallback that maps the role claim to the
/// permission decision until a `PermissionResolver` is threaded in.
/// The proxy enforces the same gate server-side via
/// `kDefaultRoleCatalogAdminWriteRoles`.
Widget _buildDefaultRoleCatalog(BuildContext context) {
  final gateway = AdminConsoleServicesScope.defaultRoleCatalogAdminGatewayOf(
    context,
  );
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  Widget buildScreen({required bool canEdit}) {
    return DefaultRoleCatalogAdminScreen(
      gateway: gateway,
      editingEnabled: canEdit,
    );
  }

  if (source == null) {
    return buildScreen(canEdit: true);
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      // Wave 2 RP-9 / UX-parity Slice E2 — role-tier check stays
      // AUTHORITATIVE; the live permissions snapshot feeds in only as
      // the advisory `actorHasEditKeyHint` (see [adminEditKeyHint]).
      final session = adminSessionOf(snapshot.data);
      final canEdit =
          session != null &&
          defaultRoleCatalogScreenCanEdit(
            actorRoles: session.roles,
            actorHasEditKeyHint: adminEditKeyHint(
              session,
              PermissionKeys.teamRolesDefaultCatalogEdit,
            ),
          );
      return buildScreen(canEdit: canEdit);
    },
  );
}

Widget _buildVendorApplicability(BuildContext context) {
  final gateway = AdminConsoleServicesScope.vendorApplicabilityGatewayOf(
    context,
  );
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  if (source == null) {
    return VendorApplicabilityAdminScreen(gateway: gateway);
  }
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      final session = state is AdminAuthAuthenticated ? state.session : null;
      final canEdit = _isAdminSuperAdmin(session);
      return VendorApplicabilityAdminScreen(
        gateway: gateway,
        editingEnabled: canEdit,
      );
    },
  );
}

Widget _buildDataAccuracy(BuildContext context) {
  final gateway = AdminConsoleServicesScope.dataAccuracyAdminGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final hierarchyGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final initialScope = handoff?.effectiveHierarchyScope;
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);

  Widget buildFunction(
    BuildContext context,
    AdminHierarchyScopeIntent selectedScope,
    AdminSetupWorkspaceSelection selection,
  ) {
    final operatorScope = selectedScope.toOperatorLocationScope();
    if (source == null) {
      return PerLocationDataAccuracyScreen(
        key: ValueKey<String>('data-accuracy-${selectedScope.cacheKey}'),
        gateway: gateway,
        actorUserId: 'demo-super-admin',
        initialScope: operatorScope,
        initialHierarchyScope: selectedScope,
        scopeLocationIds: selection.locationIds,
        onBackToBusinessAccounts: onBackToBusinessAccounts,
        showPageHeader: false,
        showScopeControls: false,
      );
    }
    return StreamBuilder<AdminAuthState>(
      stream: source.stream,
      initialData: source.current,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final session = state is AdminAuthAuthenticated ? state.session : null;
        final canEdit = _isAdminSuperAdmin(session);
        return PerLocationDataAccuracyScreen(
          key: ValueKey<String>('data-accuracy-${selectedScope.cacheKey}'),
          gateway: gateway,
          actorUserId: session?.uid ?? 'unknown',
          editingEnabled: canEdit,
          initialScope: operatorScope,
          initialHierarchyScope: selectedScope,
          scopeLocationIds: selection.locationIds,
          onBackToBusinessAccounts: onBackToBusinessAccounts,
          showPageHeader: false,
          showScopeControls: false,
        );
      },
    );
  }

  return AdminSetupWorkspace(
    functionTitle: 'Covers and Wage Data Accuracy',
    showWorkspaceHeader: false,
    description: 'Review covers, wage data, vendor filters, and audit history.',
    operatorGateway: operatorGateway,
    hierarchyGateway: hierarchyGateway,
    initialScope: initialScope,
    onBackToBusinessAccounts: onBackToBusinessAccounts,
    onScopeChanged: handoff == null
        ? null
        : (scope) => handoff.onSelectRoute(
            AdminRouteIntent(
              routeId: kAdminDataAccuracyRouteId,
              hierarchyScope: scope,
            ),
          ),
    functionBuilder: buildFunction,
  );
}

Widget _buildPollingPricing(BuildContext context) {
  final gateway = AdminConsoleServicesScope.dataAccuracyAdminGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final hierarchyGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final initialScope = handoff?.effectiveHierarchyScope;
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);

  Widget buildFunction(
    BuildContext context,
    AdminHierarchyScopeIntent selectedScope,
    AdminSetupWorkspaceSelection selection,
  ) {
    final operatorScope = selectedScope.toOperatorLocationScope();
    if (source == null) {
      return PollingAndPricingAdminScreen(
        gateway: gateway,
        actorUserId: 'demo-super-admin',
        initialScope: operatorScope,
        initialHierarchyScope: selectedScope,
        scopeLocationIds: selection.locationIds,
        showPageHeader: false,
        showScopeControls: false,
      );
    }
    return StreamBuilder<AdminAuthState>(
      stream: source.stream,
      initialData: source.current,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final session = state is AdminAuthAuthenticated ? state.session : null;
        final canEdit = _isAdminSuperAdmin(session);
        return PollingAndPricingAdminScreen(
          gateway: gateway,
          actorUserId: session?.uid ?? 'unknown',
          editingEnabled: canEdit,
          initialScope: operatorScope,
          initialHierarchyScope: selectedScope,
          scopeLocationIds: selection.locationIds,
          showPageHeader: false,
          showScopeControls: false,
        );
      },
    );
  }

  return AdminSetupWorkspace(
    functionTitle: 'Polling Setup',
    description:
        'Choose the hierarchy scope, assign vendor polling tiers, and estimate operating cost.',
    operatorGateway: operatorGateway,
    hierarchyGateway: hierarchyGateway,
    initialScope: initialScope,
    onBackToBusinessAccounts: onBackToBusinessAccounts,
    onScopeChanged: handoff == null
        ? null
        : (scope) => handoff.onSelectRoute(
            AdminRouteIntent(
              routeId: kAdminPollingPricingRouteId,
              hierarchyScope: scope,
            ),
          ),
    functionBuilder: buildFunction,
  );
}

Widget _buildVendorIntegrations(BuildContext context) {
  final gateway = AdminConsoleServicesScope.vendorConnectionsGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final hierarchyGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final initialScope = handoff?.effectiveHierarchyScope;
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);

  Widget buildFunction(
    BuildContext context,
    AdminHierarchyScopeIntent selectedScope,
    AdminSetupWorkspaceSelection selection,
  ) {
    Widget buildMount({required bool canMutate}) {
      return VendorConnectionsAdminMount(
        operatorId: selectedScope.operatorId,
        locationId: selectedScope.locationId,
        locationName: selectedScope.locationName,
        selectedScope: selectedScope,
        gateway: gateway,
        canMutate: canMutate,
        embedded: true,
        onBackToBusinessAccounts: onBackToBusinessAccounts,
      );
    }

    if (source == null) {
      return buildMount(canMutate: true);
    }
    return StreamBuilder<AdminAuthState>(
      stream: source.stream,
      initialData: source.current,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final session = state is AdminAuthAuthenticated ? state.session : null;
        final canEdit = _isAdminSuperAdmin(session);
        return buildMount(canMutate: canEdit);
      },
    );
  }

  return AdminSetupWorkspace(
    functionTitle: 'Vendor integrations',
    showWorkspaceHeader: false,
    description:
        'Select a location, then connect, test, disconnect, and review vendor setup.',
    operatorGateway: operatorGateway,
    hierarchyGateway: hierarchyGateway,
    initialScope: initialScope,
    onBackToBusinessAccounts: onBackToBusinessAccounts,
    onScopeChanged: handoff == null
        ? null
        : (scope) => handoff.onSelectRoute(
            AdminRouteIntent(
              routeId: kAdminVendorIntegrationsRouteId,
              hierarchyScope: scope,
            ),
          ),
    functionBuilder: buildFunction,
  );
}

Widget _buildTimingSetup(BuildContext context) {
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final hierarchyGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final initialScope = handoff?.effectiveHierarchyScope;
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);

  Widget buildFunction(
    BuildContext context,
    AdminHierarchyScopeIntent selectedScope,
    AdminSetupWorkspaceSelection selection,
  ) {
    Widget buildScreen({required bool canEdit}) {
      return AdminTimingSetupScreen(
        key: ValueKey<String>('timing-${selectedScope.cacheKey}'),
        operatorGateway: operatorGateway,
        selectedScope: selectedScope,
        scopeLocationIds: selection.locationIds,
        editingEnabled: canEdit,
        // Fix #4 / S4 (G41): READ-ONLY admin business-timing
        // resolution gateway so the secondary effective-timing summary
        // shows the REAL resolved EffectiveBusinessTimingProfile.
        timingResolutionGateway:
            AdminConsoleServicesScope.timingResolutionGatewayOf(context),
        // Timing-editable parity: admin cross-tenant PROFILE WRITE
        // gateway driving the editor's create / patch on Save.
        timingProfilesGateway:
            AdminConsoleServicesScope.timingProfilesGatewayOf(context),
        onBackToBusinessAccounts: onBackToBusinessAccounts,
      );
    }

    if (source == null) {
      return buildScreen(canEdit: true);
    }
    return StreamBuilder<AdminAuthState>(
      stream: source.stream,
      initialData: source.current,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final session = state is AdminAuthAuthenticated ? state.session : null;
        final canEdit = _isAdminSuperAdmin(session);
        return buildScreen(canEdit: canEdit);
      },
    );
  }

  return AdminSetupWorkspace(
    functionTitle: 'Timing',
    showWorkspaceHeader: false,
    description:
        'Edit timezone, business day, week start, and service periods.',
    operatorGateway: operatorGateway,
    hierarchyGateway: hierarchyGateway,
    initialScope: initialScope,
    onBackToBusinessAccounts: onBackToBusinessAccounts,
    onScopeChanged: handoff == null
        ? null
        : (scope) => handoff.onSelectRoute(
            AdminRouteIntent(
              routeId: kAdminTimingSetupRouteId,
              hierarchyScope: scope,
            ),
          ),
    functionBuilder: buildFunction,
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
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);

  Widget buildFunction(
    BuildContext context,
    AdminHierarchyScopeIntent selectedScope,
    AdminSetupWorkspaceSelection selection,
  ) {
    final picked = _pickerResultFromScope(
      selectedScope.toOperatorLocationScope(),
      allowBusinessScope: true,
    )!;
    VoidCallback? openAccess;
    if (handoff != null) {
      openAccess = () => handoff.onSelectRoute(
        AdminRouteIntent(
          routeId: kAdminRolesHierarchySessionsRouteId,
          hierarchyScope: selectedScope,
        ),
      );
    }

    Widget buildScreen({
      required String actorUserId,
      required bool canEdit,
      required bool canEditSeededRoles,
    }) {
      return MembersAdminScreen(
        key: ValueKey<String>('members-${selectedScope.cacheKey}'),
        gateway: gateway,
        rolesGateway: rolesGateway,
        actorUserId: actorUserId,
        pickedOperator: picked,
        editingEnabled: canEdit,
        canEditSeededRoles: canEditSeededRoles,
        initialScope: selectedScope,
        onOpenAccess: openAccess,
        onBackToBusinessAccounts: onBackToBusinessAccounts,
      );
    }

    if (source == null) {
      return buildScreen(
        actorUserId: 'demo-super-admin',
        canEdit: true,
        canEditSeededRoles: false,
      );
    }
    return StreamBuilder<AdminAuthState>(
      stream: source.stream,
      initialData: source.current,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final session = state is AdminAuthAuthenticated ? state.session : null;
        final canEdit = _isAdminSuperAdmin(session);
        return buildScreen(
          actorUserId: session?.uid ?? 'unknown',
          canEdit: canEdit,
          canEditSeededRoles: adminCanEditDestructive(
            session,
            requiredKey: PermissionKeys.adminRolesEditSeeded,
            mfaFresh: _isAdminMfaFresh(session),
          ),
        );
      },
    );
  }

  return AdminSetupWorkspace(
    functionTitle: 'Team members',
    showWorkspaceHeader: false,
    description:
        'Manage members, invites, role assignments, and access policy.',
    operatorGateway: operatorGateway,
    hierarchyGateway: rolesGateway,
    initialScope: initialScope,
    onBackToBusinessAccounts: onBackToBusinessAccounts,
    onScopeChanged: handoff == null
        ? null
        : (scope) => handoff.onSelectRoute(
            AdminRouteIntent(
              routeId: kAdminMembersRouteId,
              hierarchyScope: scope,
            ),
          ),
    functionBuilder: buildFunction,
  );
}

// Legacy shell retained for backwards-compatible deep-link handoff while
// the primary IA moves members admin into scoped setup tiles; mirrors
// the same pattern as _buildSupportOperatorView above.
// ignore: unused_element
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
      return AdminConsoleEmptyState(
        key: const Key('admin_members_no_operator_state'),
        icon: scopeIcon(kind: ScopeEntityKind.business),
        maxWidth: 420,
        title: 'Choose an operator',
        message:
            'Team work is scoped to one operator. Choose an operator once, '
            'then move between Team, Access, and Audit without choosing again.',
        action: FilledButton.icon(
          key: const Key('admin_members_open_picker'),
          onPressed: _openPicker,
          icon: Icon(scopeIcon(kind: ScopeEntityKind.business), size: 16),
          label: const Text('Choose operator'),
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
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);

  Widget buildFunction(
    BuildContext context,
    AdminHierarchyScopeIntent selectedScope,
    AdminSetupWorkspaceSelection selection,
  ) {
    final picked = _pickerResultFromScope(
      selectedScope.toOperatorLocationScope(),
      allowBusinessScope: true,
    )!;

    Widget buildScreen({
      required String actorUserId,
      required bool canEdit,
      required bool canEditSeededRoles,
    }) {
      return RolesHierarchySessionsAdminScreen(
        key: ValueKey<String>('rhs-${selectedScope.cacheKey}'),
        gateway: gateway,
        actorUserId: actorUserId,
        pickedOperator: picked,
        editingEnabled: canEdit,
        canEditSeededRoles: canEditSeededRoles,
        initialScope: selectedScope,
        onBackToBusinessAccounts: onBackToBusinessAccounts,
      );
    }

    if (source == null) {
      return buildScreen(
        actorUserId: 'demo-super-admin',
        canEdit: true,
        canEditSeededRoles: false,
      );
    }
    return StreamBuilder<AdminAuthState>(
      stream: source.stream,
      initialData: source.current,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final session = state is AdminAuthAuthenticated ? state.session : null;
        final canEdit = _isAdminSuperAdmin(session);
        return buildScreen(
          actorUserId: session?.uid ?? 'unknown',
          canEdit: canEdit,
          canEditSeededRoles: adminCanEditDestructive(
            session,
            requiredKey: PermissionKeys.adminRolesEditSeeded,
            mfaFresh: _isAdminMfaFresh(session),
          ),
        );
      },
    );
  }

  return AdminSetupWorkspace(
    functionTitle: 'Roles & permissions',
    showWorkspaceHeader: false,
    description:
        'Review hierarchy, roles, permission policy, and active sessions.',
    operatorGateway: operatorGateway,
    hierarchyGateway: gateway,
    initialScope: initialScope,
    onBackToBusinessAccounts: onBackToBusinessAccounts,
    onScopeChanged: handoff == null
        ? null
        : (scope) => handoff.onSelectRoute(
            AdminRouteIntent(
              routeId: kAdminRolesHierarchySessionsRouteId,
              hierarchyScope: scope,
            ),
          ),
    functionBuilder: buildFunction,
  );
}

// Legacy roles/hierarchy/sessions builder retained for backwards-compatible
// deep-link handoff while the primary IA folds these capabilities into
// scoped setup tiles.
// ignore: unused_element
Widget _buildRolesHierarchySessionsLegacy(BuildContext context) {
  final gateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final initialScope = handoff?.effectiveHierarchyScope;
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);
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
      initialScope: initialScope,
      openPicker: openPicker,
      onOperatorPicked: rememberPickedOperator,
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
        initialScope: initialScope,
        openPicker: openPicker,
        onOperatorPicked: rememberPickedOperator,
        onBackToBusinessAccounts: onBackToBusinessAccounts,
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
    required this.initialScope,
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
  final AdminHierarchyScopeIntent? initialScope;
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
      return AdminConsoleEmptyState(
        key: const Key('admin_rhs_no_operator_state'),
        icon: scopeIcon(kind: ScopeEntityKind.business),
        maxWidth: 420,
        title: 'Choose an operator',
        message:
            'Access work is scoped to one operator. Choose an operator once, '
            'then move between Team, Access, and Audit without choosing again.',
        action: FilledButton.icon(
          key: const Key('admin_rhs_open_picker'),
          onPressed: _openPicker,
          icon: Icon(scopeIcon(kind: ScopeEntityKind.business), size: 16),
          label: const Text('Choose operator'),
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
      initialScope: widget.initialScope,
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
  // Admin audit-integrity badge — READ-ONLY anchor gateway. Null in
  // demo / share-preview / widget tests → the badge renders the neutral
  // "unknown" state and the screen still renders.
  final anchorsGateway = AdminConsoleServicesScope.auditChainAnchorsGatewayOf(
    context,
  );
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final initialScope = handoff?.effectiveHierarchyScope;
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);

  Widget buildFunction(
    BuildContext context,
    AdminHierarchyScopeIntent selectedScope,
    AdminSetupWorkspaceSelection selection,
  ) {
    final picked = _pickerResultFromScope(
      selectedScope.toOperatorLocationScope(),
      allowBusinessScope: true,
    )!;

    Widget buildScreen({
      required String actorUserId,
      required bool canEdit,
      required bool canResetMfaFactors,
      required bool canIssuePairedErasure,
      required bool canExportAuditLog,
    }) {
      // GAP B3 — fold the org-units + locations the EXISTING
      // RolesHierarchySessionsAdminGateway already exposes (the same
      // gateway the Roles/Hierarchy admin tab uses) into the shared
      // InheritanceTree scope picker. No new proxy route, no new
      // gateway method. While the tree loads (or if it fails / is
      // empty) the screen mounts with a null rootNode and keeps the
      // existing read-only scope banner — graceful degradation, no
      // regression to that path.
      return FutureBuilder<InheritanceTreeNode?>(
        key: ValueKey<String>('asa-scope-tree-${picked.operatorId}'),
        future: _loadAuditedSupportActionsScopeTree(
          sessionsGateway,
          picked.operatorId,
        ),
        builder: (context, scopeSnapshot) {
          return AuditedSupportActionsAdminScreen(
            key: ValueKey<String>('asa-${selectedScope.cacheKey}'),
            gateway: gateway,
            sessionsGateway: sessionsGateway,
            anchorsGateway: anchorsGateway,
            actorUserId: actorUserId,
            pickedOperator: picked,
            editingEnabled: canEdit,
            canResetMfaFactors: canResetMfaFactors,
            canIssuePairedErasure: canIssuePairedErasure,
            canExportAuditLog: canExportAuditLog,
            hierarchyScope: selectedScope,
            auditScopeRootNode: scopeSnapshot.data,
            onBackToBusinessAccounts: onBackToBusinessAccounts,
          );
        },
      );
    }

    if (source == null) {
      return buildScreen(
        actorUserId: 'demo-super-admin',
        canEdit: true,
        canResetMfaFactors: false,
        canIssuePairedErasure: false,
        canExportAuditLog: false,
      );
    }
    return StreamBuilder<AdminAuthState>(
      stream: source.stream,
      initialData: source.current,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final session = state is AdminAuthAuthenticated ? state.session : null;
        final canEdit = _isAdminSuperAdmin(session);
        final fresh = _isAdminMfaFresh(session);
        // Slice E4 — destructive audited-support gates keyed per-action.
        bool can(String key) =>
            adminCanEditDestructive(session, requiredKey: key, mfaFresh: fresh);
        return buildScreen(
          actorUserId: session?.uid ?? 'unknown',
          canEdit: canEdit,
          canResetMfaFactors: can(PermissionKeys.adminUsersResetMfaFactors),
          canIssuePairedErasure: can(PermissionKeys.adminUsersErasePii),
          canExportAuditLog: can(PermissionKeys.adminAuditLogExport),
        );
      },
    );
  }

  return AdminSetupWorkspace(
    functionTitle: 'Audit log',
    showWorkspaceHeader: false,
    description:
        'Review audit history, active sessions, and guarded support actions.',
    operatorGateway: operatorGateway,
    hierarchyGateway: sessionsGateway,
    initialScope: initialScope,
    onBackToBusinessAccounts: onBackToBusinessAccounts,
    onScopeChanged: handoff == null
        ? null
        : (scope) => handoff.onSelectRoute(
            AdminRouteIntent(
              routeId: kAdminAuditedSupportActionsRouteId,
              hierarchyScope: scope,
            ),
          ),
    functionBuilder: buildFunction,
  );
}

/// GAP B3 — loads the org-units + locations the
/// [RolesHierarchySessionsAdminGateway] already exposes and folds them
/// into the shared audit-log scope-picker tree via the pure
/// [buildAuditLogAdminRootNode] helper. Returns `null` (read-only
/// scope-banner fallback) on any gateway error or when the operator
/// has no org units. No new proxy route, no new gateway method.
Future<InheritanceTreeNode?> _loadAuditedSupportActionsScopeTree(
  RolesHierarchySessionsAdminGateway gateway,
  String operatorId,
) async {
  try {
    final results = await Future.wait<Object>(<Future<Object>>[
      gateway.listOrgUnits(operatorId: operatorId),
      gateway.listHierarchyLocations(operatorId: operatorId),
    ]);
    final orgUnits = results[0] as List<OrgUnitAdminNode>;
    final locations = results[1] as List<HierarchyLocationLeaf>;
    return buildAuditLogAdminRootNode(orgUnits: orgUnits, locations: locations);
  } on Object {
    // Hierarchy load failed — degrade gracefully to the existing
    // read-only scope banner rather than blocking the audit surface.
    return null;
  }
}

// Legacy audited-support-actions builder retained for backwards-compatible
// deep-link handoff while the primary IA folds the audit surface into
// scoped setup tiles.
// ignore: unused_element
Widget _buildAuditedSupportActionsLegacy(BuildContext context) {
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
      return AdminConsoleEmptyState(
        key: const Key('admin_asa_no_operator_state'),
        icon: scopeIcon(kind: ScopeEntityKind.business),
        maxWidth: 420,
        title: 'Choose an operator',
        message:
            'Audit and support work is scoped to one operator. Choose an '
            'operator once, then move between Team, Access, and Audit without '
            'choosing again.',
        action: FilledButton.icon(
          key: const Key('admin_asa_open_picker'),
          onPressed: _openPicker,
          icon: Icon(scopeIcon(kind: ScopeEntityKind.business), size: 16),
          label: const Text('Choose operator'),
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
  final gateway = AdminConsoleServicesScope.debugConsoleGatewayOf(context);
  final hierarchyGateway =
      AdminConsoleServicesScope.rolesHierarchySessionsAdminGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  final handoff = AdminRouteHandoff.maybeOf(context);
  final operatorGateway = AdminConsoleServicesScope.operatorLocationGatewayOf(
    context,
  );
  final supportLogFilter = handoff?.supportLogFilter;
  final supportLogScope = supportLogFilter?.effectiveHierarchyScope;
  final initialScope = supportLogScope ?? handoff?.effectiveHierarchyScope;
  final onBackToBusinessAccounts = _backToBusinessAccounts(context);

  Widget buildFunction(
    BuildContext context,
    AdminHierarchyScopeIntent selectedScope,
    AdminSetupWorkspaceSelection selection,
  ) {
    final initialFilter = RequestLogFilter(
      operatorId: selectedScope.operatorId,
      locationId: selectedScope.locationId,
      locationIds: selectedScope.isOrgUnitScope
          ? selection.locationIds.toList(growable: false)
          : null,
    );
    if (source == null) {
      return DebugConsoleAdminScreen(
        gateway: gateway,
        hierarchyGateway: hierarchyGateway,
        hierarchyScope: selectedScope,
        initialFilter: initialFilter,
      );
    }
    return StreamBuilder<AdminAuthState>(
      stream: source.stream,
      initialData: source.current,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final session = state is AdminAuthAuthenticated ? state.session : null;
        final canEdit = _isAdminSuperAdmin(session);
        return DebugConsoleAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          hierarchyScope: selectedScope,
          editingEnabled: canEdit,
          initialFilter: initialFilter,
        );
      },
    );
  }

  return AdminSetupWorkspace(
    functionTitle: 'Support logs',
    description:
        'Review support-safe requests, relationship help, and account help.',
    operatorGateway: operatorGateway,
    hierarchyGateway: hierarchyGateway,
    initialScope: initialScope,
    onBackToBusinessAccounts: onBackToBusinessAccounts,
    onScopeChanged: handoff == null
        ? null
        : (scope) => handoff.onSelectRoute(
            AdminRouteIntent(
              routeId: kAdminDebugConsoleRouteId,
              hierarchyScope: scope,
              supportLogFilter: AdminSupportLogFilterIntent.fromHierarchyScope(
                scope,
              ),
            ),
          ),
    functionBuilder: buildFunction,
  );
}

/// Wave 2 W-4 — admin "My Account" parity surface builder. Streams the
/// admin session off [AdminConsoleServicesScope.adminAuthSource] so the
/// rendered identity card stays in sync with sign-in / sign-out events.
///
/// When the source is null (legacy demo wiring with no scope, or
/// widget-test harnesses that bypass the gate) we fall back to a
/// minimal "Sign in required" surface rather than fabricate a session.
Widget _buildMyAccount(BuildContext context) {
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  if (source == null) {
    return const _MyAccountUnauthenticatedFallback();
  }
  final accountGateway = AdminConsoleServicesScope.adminAccountGatewayOf(
    context,
  );
  final sessionsGateway = AdminConsoleServicesScope.adminSessionsGatewayOf(
    context,
  );
  final securityGateway = AdminConsoleServicesScope.adminSecurityGatewayOf(
    context,
  );
  final handoff = AdminRouteHandoff.maybeOf(context);
  return StreamBuilder<AdminAuthState>(
    stream: source.stream,
    initialData: source.current,
    builder: (context, snapshot) {
      final state = snapshot.data;
      if (state is AdminAuthAuthenticated) {
        return MyAccountAdminScreen(
          session: state.session,
          authSource: source,
          accountGateway: accountGateway,
          sessionsGateway: sessionsGateway,
          securityGateway: securityGateway,
          // "View audit log" opens the existing "Security, audit, and
          // sessions" surface (the admin analog of the ops business
          // audit log). It is per-business, so the admin picks a
          // business there; the admin's OWN sign-in/password/2FA
          // history stays in the Security card's "Recent sign-in
          // activity" above.
          onOpenAuditLog: handoff == null
              ? null
              : () => handoff.onSelectRoute(
                  AdminRouteIntent(routeId: kAdminAuditedSupportActionsRouteId),
                ),
        );
      }
      return const _MyAccountUnauthenticatedFallback();
    },
  );
}

/// X-G71 — admin notification-preferences route builder. Reads the
/// gateway from [AdminConsoleServicesScope]; when null the screen
/// itself renders the honest read-only "saving turned off" posture
/// (mirrors the sibling admin screens' null-gateway fallback). No auth
/// session is needed because the gateway resolves the actor from the
/// verified bearer token server-side.
Widget _buildAdminNotificationPreferences(BuildContext context) {
  final gateway =
      AdminConsoleServicesScope.adminNotificationPreferencesGatewayOf(context);
  return AdminNotificationPreferencesScreen(gateway: gateway);
}

/// Calm placeholder rendered when the admin auth source has not
/// resolved an authenticated session. The shell only mounts the My
/// Account route on the authenticated branch, so this is intentionally
/// a defensive fallback — never the primary path.
class _MyAccountUnauthenticatedFallback extends StatelessWidget {
  const _MyAccountUnauthenticatedFallback();

  @override
  Widget build(BuildContext context) {
    return const AdminConsoleEmptyState(
      key: Key('admin_my_account_unauthenticated_fallback'),
      icon: Icons.person_outline,
      title: 'My account',
      message: 'Sign in to the admin console to see your account details.',
    );
  }
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
    this.defaultRoleCatalogAdminGateway,
    this.debugConsoleGateway,
    this.dataAccuracyAdminGateway,
    this.vendorApplicabilityGateway,
    this.membersAdminGateway,
    this.rolesHierarchySessionsAdminGateway,
    this.auditedSupportActionsAdminGateway,
    this.auditChainAnchorsGateway,
    this.adminAccountGateway,
    this.adminNotificationPreferencesGateway,
    this.adminSessionsGateway,
    this.adminSecurityGateway,
    this.timingResolutionGateway,
    this.timingProfilesGateway,
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

  /// Lane B B2.2 - Default Role catalog admin gateway. Optional; the
  /// default fallback is the seeded in-memory gateway shared with the
  /// demo walkthrough so the click path renders without the Cloud Run
  /// admin proxy.
  final DefaultRoleCatalogAdminGateway? defaultRoleCatalogAdminGateway;

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

  /// B10.2 vendor applicability admin gateway. Optional so demo /
  /// share-preview can fall back to an in-memory catalog.
  final VendorApplicabilityAdminGateway? vendorApplicabilityGateway;

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

  /// Admin audit-integrity badge — READ-ONLY admin/cross-tenant
  /// audit-chain-anchor gateway (consumes the admin route
  /// `GET /v1/admin/operators/:operatorId/audit-chain-anchors/latest`).
  /// Production binds the HTTP-backed
  /// [HttpAdminAuditChainAnchorsGateway] here; demo / share-preview /
  /// widget tests leave it null so the admin Audit screen's integrity
  /// badge renders the neutral "unknown" state (never crashes). Unlike
  /// the other admin gateways this accessor returns null rather than a
  /// seeded demo gateway, because the badge's honest no-gateway posture
  /// IS the unknown state.
  final AdminAuditChainAnchorsGateway? auditChainAnchorsGateway;

  /// Wave 2 W-3 — self-service admin account gateway. Production
  /// binds the HTTP-backed gateway here; demo / widget-test paths
  /// pass an `InMemoryAdminAccountGateway`. When null, the My Account
  /// Identity card renders in read-only mode (the W-4 posture).
  final AdminAccountGateway? adminAccountGateway;

  /// X-G71 (cross-surface parity register §0b) — admin self-service
  /// notification-preferences gateway. Production binds the HTTP-backed
  /// gateway here (same admin proxy base URI + Firebase ID-token bearer
  /// the sibling admin gateways use); demo / share-preview leave it
  /// null so the accessor falls back to the seeded in-memory gateway
  /// and the walkthrough renders the toggle click path without a
  /// backend (parity with [adminSessionsGateway] /
  /// [adminSecurityGateway]).
  final AdminNotificationPreferencesGateway?
  adminNotificationPreferencesGateway;

  /// Audit fix-first #2 (G1 + G2) — admin auth-session ledger +
  /// Active Sessions gateway. Production binds the HTTP-backed
  /// gateway here (the SAME instance the auth source uses as its
  /// sign-in/out ledger writer); demo / share-preview leave it null
  /// so the My Account Active Sessions card falls back to the seeded
  /// in-memory gateway and the walkthrough renders without a backend.
  final AdminSessionsGateway? adminSessionsGateway;

  /// Audit fix-first #7 (cross-surface parity finding G4) — admin
  /// self-service Security gateway (own MFA enroll/confirm/recover +
  /// password change). Production binds the HTTP-backed gateway here;
  /// demo / share-preview leave it null so the My Account Security
  /// card falls back to the seeded in-memory gateway and the
  /// walkthrough renders without a backend (parity with
  /// [adminSessionsGateway]).
  final AdminSecurityGateway? adminSecurityGateway;

  /// Fix #4 / S4 (G41 + G42) — READ-ONLY admin cross-tenant
  /// business-timing resolution gateway (consumes the S2 route
  /// `GET /v1/admin/operators/:operatorId/locations/:locationId/
  /// business-timing-resolution`). Production binds the HTTP-backed
  /// [HttpAdminBusinessTimingResolutionGateway] here; demo /
  /// share-preview / widget tests leave it null so the admin timing
  /// surfaces fall back to the seeded in-memory gateway and render
  /// without the Cloud Run admin proxy. This UI reads timing only;
  /// server-side super admin repair routes exist for profile writes.
  final AdminBusinessTimingResolutionGateway? timingResolutionGateway;

  /// Timing-editable parity — admin cross-tenant business-timing
  /// PROFILE WRITE gateway (create / patch). Production binds the
  /// HTTP-backed [HttpAdminBusinessTimingProfilesGateway] here; demo /
  /// share-preview / widget tests leave it null so the admin Timing
  /// editor falls back to the shared seeded
  /// [InMemoryAdminBusinessTimingProfilesGateway] and renders without
  /// the Cloud Run admin proxy (mirrors [timingResolutionGateway]'s
  /// optional-gateway + in-memory-fallback shape). Writes require a
  /// non-empty `admin_reason` + an idempotency key (the editor's reason
  /// dialog supplies the former; the server enforces both).
  final AdminBusinessTimingProfilesGateway? timingProfilesGateway;

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

  /// Fix #4 / S4 (G41 + G42) — resolve the READ-ONLY admin
  /// business-timing resolution gateway. Falls back to a shared
  /// seeded in-memory gateway (empty by default → the timing
  /// surfaces render their honest "no profile yet" state instead of
  /// fabricating values) when no production scope is mounted.
  static AdminBusinessTimingResolutionGateway timingResolutionGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.timingResolutionGateway ??
        _defaultTimingResolutionDemoGateway;
  }

  /// Timing-editable parity — resolve the admin business-timing PROFILE
  /// WRITE gateway. Falls back to a shared seeded in-memory gateway
  /// (empty by default, so the editor opens on the starter profile and
  /// the first save creates) when no production scope is mounted.
  /// Mirrors [timingResolutionGatewayOf]'s same-instance demo behavior.
  static AdminBusinessTimingProfilesGateway timingProfilesGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.timingProfilesGateway ?? _defaultTimingProfilesDemoGateway;
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

  static DefaultRoleCatalogAdminGateway defaultRoleCatalogAdminGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.defaultRoleCatalogAdminGateway ??
        _defaultRoleCatalogAdminDemoGateway;
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

  static VendorApplicabilityAdminGateway vendorApplicabilityGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.vendorApplicabilityGateway ??
        _defaultVendorApplicabilityDemoGateway;
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

  /// Admin audit-integrity badge — resolve the READ-ONLY admin
  /// audit-chain-anchor gateway. Returns null (no seeded demo
  /// fallback) when the scope was not provided one, so the badge
  /// renders the neutral "unknown" state in demo / share-preview /
  /// widget-test paths. The screen never crashes on a null gateway.
  static AdminAuditChainAnchorsGateway? auditChainAnchorsGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.auditChainAnchorsGateway;
  }

  static AdminAuthSource? adminAuthSourceOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.adminAuthSource;
  }

  /// Wave 2 W-3 — admin self-service account gateway accessor. Returns
  /// null when the scope wasn't provided one; the MyAccount route
  /// renders the W-4 read-only posture in that case.
  static AdminAccountGateway? adminAccountGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.adminAccountGateway;
  }

  /// X-G71 — admin self-service notification-preferences gateway
  /// accessor. Falls back to the seeded in-memory demo gateway so the
  /// kDemoMode / share-preview walkthrough renders the catalog + toggle
  /// click path without a backend (parity with the other `*Of(context)`
  /// demo-fallback accessors). The default gateway is seeded empty, so
  /// every row renders at its catalog default until the admin toggles
  /// it.
  static AdminNotificationPreferencesGateway
  adminNotificationPreferencesGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.adminNotificationPreferencesGateway ??
        _defaultAdminNotificationPreferencesDemoGateway;
  }

  /// Audit fix-first #2 (G2) — admin Active Sessions gateway
  /// accessor. Falls back to the seeded in-memory demo gateway so the
  /// kDemoMode / share-preview walkthrough renders the list + revoke +
  /// sign-out-everywhere surface without a backend (parity with the
  /// other `*Of(context)` demo-fallback accessors).
  static AdminSessionsGateway adminSessionsGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.adminSessionsGateway ?? _defaultAdminSessionsDemoGateway;
  }

  /// Audit fix-first #7 (G4) — admin self-service Security gateway
  /// accessor. Falls back to the seeded in-memory demo gateway so the
  /// kDemoMode / share-preview walkthrough renders the enroll +
  /// recover + password-change surface without a backend (parity with
  /// the other `*Of(context)` demo-fallback accessors).
  static AdminSecurityGateway adminSecurityGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.adminSecurityGateway ?? _defaultAdminSecurityDemoGateway;
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
      defaultRoleCatalogAdminGateway !=
          oldWidget.defaultRoleCatalogAdminGateway ||
      debugConsoleGateway != oldWidget.debugConsoleGateway ||
      dataAccuracyAdminGateway != oldWidget.dataAccuracyAdminGateway ||
      vendorApplicabilityGateway != oldWidget.vendorApplicabilityGateway ||
      membersAdminGateway != oldWidget.membersAdminGateway ||
      rolesHierarchySessionsAdminGateway !=
          oldWidget.rolesHierarchySessionsAdminGateway ||
      auditedSupportActionsAdminGateway !=
          oldWidget.auditedSupportActionsAdminGateway ||
      auditChainAnchorsGateway != oldWidget.auditChainAnchorsGateway ||
      adminAccountGateway != oldWidget.adminAccountGateway ||
      adminNotificationPreferencesGateway !=
          oldWidget.adminNotificationPreferencesGateway ||
      adminSessionsGateway != oldWidget.adminSessionsGateway ||
      adminSecurityGateway != oldWidget.adminSecurityGateway ||
      timingResolutionGateway != oldWidget.timingResolutionGateway ||
      timingProfilesGateway != oldWidget.timingProfilesGateway ||
      adminAuthSource != oldWidget.adminAuthSource;
}
