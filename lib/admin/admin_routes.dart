// Phase 11A.0 - Admin route table.
//
// The admin console is a multi-surface back-office. 11A.0 lights up
// the empty Home route only; later 11A.x slices fill in the rest.
// Keeping the route catalog in a single typed list lets the shell
// nav render placeholders for the surfaces that aren't online yet
// without scattering `if (slice >= X)` flags across the UI.
//
// 11A.1 - the Operators route flips from placeholder to live; its
// builder reads the [OperatorLocationAdminGateway] from
// [AdminConsoleServicesScope] so production can bind the HTTP
// gateway without rewriting the route catalog. The default
// fallback is an in-memory demo gateway preloaded with two
// fixtures so the kDemoMode walkthrough click path runs without
// the Cloud Run admin proxy.

import 'package:flutter/material.dart';

import 'admin_auth_gate.dart';
import 'models/corpus_admin_models.dart';
import 'models/feature_flags_admin_models.dart';
import 'models/integration_admin_models.dart';
import 'models/operator_location_admin_models.dart';
import 'models/pricing_tier_admin_models.dart';
import 'screens/admin_home_screen.dart';
import 'screens/corpus_admin_screen.dart';
import 'screens/feature_flags_admin_screen.dart';
import 'screens/health_admin_screen.dart';
import 'screens/integration_admin_screen.dart';
import 'screens/operator_location_admin_screen.dart';
import 'screens/operator_picker_screen.dart';
import 'screens/pricing_tier_admin_screen.dart';
import 'services/corpus_admin_gateway.dart';
import 'services/feature_flags_admin_gateway.dart';
import 'services/health_admin_gateway.dart';
import 'services/integration_admin_gateway.dart';
import 'services/operator_location_admin_gateway.dart';
import 'services/pricing_tier_admin_gateway.dart';

/// One entry in the admin route catalog.
@immutable
class AdminRoute {
  const AdminRoute({
    required this.id,
    required this.title,
    required this.path,
    required this.icon,
    required this.builder,
    this.subtitle,
    this.placeholder = false,
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

  /// Optional one-line description for the empty-state body when the
  /// route is opened ahead of its slice landing.
  final String? subtitle;

  /// True when the route is a placeholder for a slice that hasn't
  /// landed yet. The shell renders a "coming in 11A.x" empty state
  /// instead of [builder] so the nav structure is visible from
  /// 11A.0 without exposing scaffolding.
  final bool placeholder;

  /// Builds the route surface. For [placeholder] routes the shell
  /// substitutes a branded "coming soon" panel; for live routes the
  /// builder runs.
  final Widget Function(BuildContext context) builder;
}

/// Canonical admin home route ID. Tests + the shell key off this so
/// renaming the title can't accidentally drop the home surface.
const String kAdminHomeRouteId = 'home';

/// Canonical Operators route ID (11A.1).
const String kAdminOperatorsRouteId = 'operators';

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

/// Canonical operator-picker route ID (11A.3a follow-up). The picker
/// is reached via Navigator.push from the Corpus admin "Pick operator"
/// button — it is intentionally NOT in [kAdminRoutes] (no side-nav
/// item) because its purpose is "internal helper of the Corpus
/// surface," not a standalone admin destination. The constant exists
/// so audit logs and route observers have a stable name to refer to
/// the modal target.
const String kAdminOperatorPickerRouteId = 'operator-picker';

/// The admin route table. Order is the side-nav order. 11A.1 promotes
/// `operators` from placeholder to live; the rest are deliberately
/// marked `placeholder` so the surface area is visible to operators
/// walking the shell without leaking incomplete UX.
const List<AdminRoute> kAdminRoutes = <AdminRoute>[
  AdminRoute(
    id: kAdminHomeRouteId,
    title: 'Home',
    path: '/',
    icon: Icons.home_outlined,
    subtitle: 'Operations console - landing surface.',
    builder: _buildHome,
  ),
  AdminRoute(
    id: kAdminOperatorsRouteId,
    title: 'Operators',
    path: '/operators',
    icon: Icons.business_outlined,
    subtitle: 'Operator + location CRUD.',
    builder: _buildOperators,
  ),
  AdminRoute(
    id: kAdminPricingRouteId,
    title: 'Pricing',
    path: '/pricing',
    icon: Icons.tune_outlined,
    subtitle: 'Tier templates and per-(operator, location, usage_class) caps.',
    builder: _buildPricing,
  ),
  AdminRoute(
    id: kAdminCorpusRouteId,
    title: 'Corpus',
    path: '/corpus',
    icon: Icons.menu_book_outlined,
    subtitle: 'Markdown corpus upload, preview, commit, rollback.',
    builder: _buildCorpus,
  ),
  AdminRoute(
    id: kAdminIntegrationsRouteId,
    title: 'Integrations',
    path: '/integrations',
    icon: Icons.extension_outlined,
    subtitle: 'Provider key rotation + connector status.',
    builder: _buildIntegrations,
  ),
  AdminRoute(
    id: kAdminHealthRouteId,
    title: 'Health',
    path: '/health',
    icon: Icons.monitor_heart_outlined,
    subtitle:
        'Read-only view of the proxy /health envelope (Retrieval / Proxy / Infra).',
    builder: _buildHealth,
  ),
  AdminRoute(
    id: kAdminFeatureFlagsRouteId,
    title: 'Feature Flags',
    path: '/feature-flags',
    icon: Icons.flag_outlined,
    subtitle: 'Toggle launch flags without redeploying.',
    builder: _buildFeatureFlags,
  ),
  AdminRoute(
    id: 'debug',
    title: 'Debug',
    path: '/debug',
    icon: Icons.bug_report_outlined,
    subtitle: 'Per-operator debug console lands in 11A.5.',
    placeholder: true,
    builder: _placeholderBuilder,
  ),
  AdminRoute(
    id: 'observability',
    title: 'Observability',
    path: '/observability',
    icon: Icons.insights_outlined,
    subtitle: 'System health + cost dashboard lands in 11A.6.',
    placeholder: true,
    builder: _placeholderBuilder,
  ),
];

Widget _buildHome(BuildContext context) => const AdminHomeScreen();

Widget _buildOperators(BuildContext context) {
  final gateway = AdminConsoleServicesScope.operatorLocationGatewayOf(context);
  return OperatorLocationAdminScreen(gateway: gateway);
}

Widget _buildPricing(BuildContext context) {
  final gateway = AdminConsoleServicesScope.pricingTierGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  if (source == null) {
    // No source wired (typical widget-test path) — default to live
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
      return PricingTierAdminScreen(
        gateway: gateway,
        editingEnabled: canEdit,
      );
    },
  );
}

/// Phase 11A.3b — demo-mode tenant the Graph candidates tab targets
/// when the in-memory demo gateway is mounted. The IDs match the
/// kDemoMode tenant seed in [_defaultDemoGateway] below so the
/// 11A.3b walkthrough writes against the same demo operator the
/// rest of the admin shell reads.
///
/// Live mode (HTTP gateway) deliberately leaves both null until the
/// operator-picker slice ships — the screen disables the Graph
/// candidates commit button with a banner in that case so a
/// super_admin cannot accidentally write graph approvals against
/// the demo IDs (which do not exist as real tenants in production).
const String kCorpusAdminDemoTargetOperatorId =
    '00000000-0000-4000-8000-000000000001';
const String kCorpusAdminDemoTargetLocationId =
    '00000000-0000-4000-8000-0000000000a1';

Widget _buildCorpus(BuildContext context) {
  final gateway = AdminConsoleServicesScope.corpusAdminGatewayOf(context);
  final operatorGateway =
      AdminConsoleServicesScope.operatorLocationGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  // Demo mode (in-memory gateway) targets the seeded demo tenant.
  // Live mode (HTTP gateway, or any non-in-memory binding) leaves
  // the targets null so the Graph candidates commit button starts
  // disabled. The "Pick operator" button on that surface opens
  // [OperatorPickerScreen] via [_openOperatorPickerFromContext]; once
  // the admin confirms a pair, the corpus screen state takes over
  // and the commit button enables.
  final isDemoGateway = gateway is InMemoryCorpusAdminGateway;
  final demoTargetOperatorId =
      isDemoGateway ? kCorpusAdminDemoTargetOperatorId : null;
  final demoTargetLocationId =
      isDemoGateway ? kCorpusAdminDemoTargetLocationId : null;
  Future<OperatorPickerResult?> openPicker(BuildContext routeContext) {
    final state = source?.current;
    final adminUid =
        state is AdminAuthAuthenticated ? state.session.uid : null;
    return Navigator.of(routeContext).push<OperatorPickerResult?>(
      MaterialPageRoute<OperatorPickerResult?>(
        settings: const RouteSettings(name: '/operator-picker'),
        builder: (_) => OperatorPickerScreen(
          gateway: operatorGateway,
          adminUid: adminUid,
        ),
      ),
    );
  }

  if (source == null) {
    // No source wired (test path) — default to live edit affordances.
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
      return IntegrationAdminScreen(
        gateway: gateway,
        editingEnabled: canEdit,
      );
    },
  );
}

Widget _buildHealth(BuildContext context) {
  // F.1 — read-only for both `super_admin` and `ff_support`. The
  // gateway is the only injection point; there is no editingEnabled
  // flag because the surface has no mutate affordances.
  final gateway = AdminConsoleServicesScope.healthGatewayOf(context);
  return HealthAdminScreen(gateway: gateway);
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
      return FeatureFlagsAdminScreen(
        gateway: gateway,
        editingEnabled: canEdit,
      );
    },
  );
}

Widget _placeholderBuilder(BuildContext context) {
  // 11A.0 placeholder body. The shell wraps this with the branded
  // empty-state surface using the route's [subtitle], so this builder
  // never actually renders.
  return const SizedBox.shrink();
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
    this.healthGateway,
    this.featureFlagsGateway,
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

  /// Phase 11A.2 — pricing tier admin gateway. Optional so existing
  /// production wiring can light it up incrementally; the default
  /// fallback is a seeded in-memory demo gateway shared with the
  /// walkthrough.
  final PricingTierAdminGateway? pricingTierGateway;

  /// Phase 11A.3a — corpus admin gateway. Optional for the same
  /// incremental-wiring reason. Default fallback is the seeded
  /// in-memory corpus demo gateway shared with the 11A.3a walkthrough.
  final CorpusAdminGateway? corpusAdminGateway;

  /// Phase 11A.4 — integration management admin gateway. Optional;
  /// the default fallback is a seeded in-memory gateway sharing the
  /// `kDemoMode` walkthrough fixtures.
  final IntegrationAdminGateway? integrationGateway;

  /// Phase 11A.UX.health (F.1) — proxy `/health` envelope gateway.
  /// Optional; the default fallback is the seeded in-memory demo
  /// envelope shared with the F.1 walkthrough.
  final HealthAdminGateway? healthGateway;

  /// Phase 11A.7 — feature flags admin gateway. Optional; the default
  /// fallback is a seeded in-memory gateway with the launch flag
  /// catalog so the walkthrough exercises the toggle / DANGER paths
  /// without hitting Postgres.
  final FeatureFlagsAdminGateway? featureFlagsGateway;

  /// Phase 11A.2 — admin auth source. Optional for the same
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

  static HealthAdminGateway healthGatewayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.healthGateway ?? _defaultHealthDemoGateway;
  }

  static FeatureFlagsAdminGateway featureFlagsGatewayOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AdminConsoleServicesScope>();
    return scope?.featureFlagsGateway ?? _defaultFeatureFlagsDemoGateway;
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
      healthGateway != oldWidget.healthGateway ||
      featureFlagsGateway != oldWidget.featureFlagsGateway ||
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
          suspended: false,
          caps: <UsageCapRow>[],
        ),
        PricingOperatorBundle(
          operatorId: '00000000-0000-4000-8000-000000000002',
          businessName: 'Sunset Cafe Group',
          subscriptionTier: 'pilot',
          preferredCurrency: 'USD',
          primaryLocationId: '00000000-0000-4000-8000-0000000000b1',
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
final CorpusAdminGateway _defaultCorpusDemoGateway =
    InMemoryCorpusAdminGateway(
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
final HealthAdminGateway _defaultHealthDemoGateway =
    InMemoryHealthAdminGateway(envelope: kHealthAdminDemoEnvelope);

/// 11A.7 fallback feature flags gateway. Seeds the launch flag
/// catalog so the demo walkthrough can exercise the toggle and
/// destructive-confirmation paths end-to-end. Mirrors the rows
/// landed by the launch migrations:
///
///   * `audit_logs_cutover_enabled` (destructive) — B.2 cutover flag.
///   * `kms_real_provider_<kind>_enabled` (destructive) — per-lane
///     KMS rollout gates.
///   * `advisor_enabled` (standard) — example launch flag for the
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
              'B.2 fan-out gate: routes auth events into the hash-chained '
              'audit_logs chain. Toggle off only as a one-shot rollback.',
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
              '11A.4c per-lane KMS rollout gate. Off = stub provider; '
              'on = GCP Secret Manager + Cloud Run revision push.',
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
              '11A.4c per-lane KMS rollout gate (Voyage embeddings).',
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
              '11b advisor surface kill switch. Off = advisor returns '
              "501 'feature_unavailable' across the app.",
          updatedBy: 'demo-super-admin',
          createdAt: DateTime.utc(2026, 5, 1, 10, 0),
          updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
        ),
      ],
    );
