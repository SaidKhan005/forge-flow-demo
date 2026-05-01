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
import 'models/integration_admin_models.dart';
import 'models/operator_location_admin_models.dart';
import 'models/pricing_tier_admin_models.dart';
import 'screens/admin_home_screen.dart';
import 'screens/corpus_admin_screen.dart';
import 'screens/integration_admin_screen.dart';
import 'screens/operator_location_admin_screen.dart';
import 'screens/pricing_tier_admin_screen.dart';
import 'services/corpus_admin_gateway.dart';
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

Widget _buildCorpus(BuildContext context) {
  final gateway = AdminConsoleServicesScope.corpusAdminGatewayOf(context);
  final source = AdminConsoleServicesScope.adminAuthSourceOf(context);
  if (source == null) {
    // No source wired (test path) — default to live edit affordances.
    return CorpusAdminScreen(gateway: gateway);
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
    this.adminAuthSource,
  });

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
