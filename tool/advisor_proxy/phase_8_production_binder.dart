// Phase 8 framework — production binder for the inbound integration
// chain.
//
// Constructs `Phase80IntegrationRoutesBindingsHolder` once at boot and
// installs it on `Phase80IntegrationRoutes.globalBindings` so the
// marked region in `main.dart` lights up after this completes.
//
// The binder ties together pieces that landed in earlier slices:
//
//   * `VendorCredentialBroker` (PR #238)        — per-tenant OAuth/key
//                                                  resolution.
//   * Per-vendor adapter factory closures      — built by the shared
//                                                  builder in
//                                                  `phase_8_vendor_integration_factories.dart`
//                                                  (PR #268). The same
//                                                  builder is reused by
//                                                  the first-connect
//                                                  backfill worker.
//   * Production OAuth refresh closures
//     (PR #247)                                — vendor-specific
//                                                  token-rotation
//                                                  HTTP shapes.
//   * 17 vendor production transports (Wave 0).
//   * 17 Postgres canonical sinks.
//   * `RepositoryIntegrationRoutesGateway` (PR #246).
//   * `RepositoryInboundWebhookGateway`        — DB-backed
//                                                  inbound-webhook
//                                                  storage / dedup /
//                                                  audit.
//   * `InboundWebhookHandler`                  — per-vendor adapter
//                                                  factory dispatch
//                                                  (PR #240).
//   * `PerTenantLocationConfigResolver`        — per-(operator,
//                                                  location) timezone /
//                                                  rollover hour /
//                                                  webhook URL (PR #246).
//   * `ProxyProductionBindings` exposing
//     `tenantTransactionWrapper` +
//     `pgcryptoEnvelopeKey` + the integration
//     admin actor seams (PR #260).
//   * `ProxyConfig.alohaNcrVoyixCredentials` /
//     `squareAppCredentials` /
//     `cloverAppCredentials` /
//     `humanityAppCredentials` /
//     `quickBooksTimeAppCredentials` /
//     `sevenShiftsAppCredentials` /
//     `libroAppCredentials`                    — typed vendor app
//                                                  credentials (PR #260
//                                                  + Amendment B).
//
// CLAUDE.md alignment:
//
//   * Hard Promise #1 (transport-only) — every adapter writes existing
//     SQLite/Postgres canonical tables only; the binder does not change
//     business logic.
//   * Hard Promise #4 (per-operator isolation) — every credential
//     resolution / fact write rides `OperatorScopedRepository.withTenant`
//     so the per-tenant `SET LOCAL` chain injects.
//   * Hard Promise #7 (server-side keys) — every secret is loaded into
//     [ProxyConfig] at boot; vendor app credentials and the pgcrypto
//     envelope key never leave Cloud Run.
//
// Demo mode: when the proxy is started with `--define=kDemoMode=true`,
// [bindPhase8IntegrationsForProduction] short-circuits with a single
// info line — `Phase80IntegrationRoutes.globalBindings` stays null and
// the marked region in `main.dart` falls through to the existing
// dispatcher.

import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:forge_and_flow/domain/canonical_day_order.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/domain/services/business_date_resolver.dart';
import 'package:forge_and_flow/domain/services/daypart_bucketer.dart';
import 'package:forge_and_flow/domain/services/target_snapshot_builder.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_policy.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_shift_record_writer.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/open_shift_snapshots_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/_common/admin_actor_resolver_bridge.dart'
    as bridge;
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_post_commit_projector.dart';
import 'package:forge_and_flow/services/integration/iana_timezone_converter.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_signing_secret_cache.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/open_shift_snapshot_projector.dart';
import 'package:forge_and_flow/services/integration/per_tenant_location_config_resolver.dart';
import 'package:forge_and_flow/services/integration/projecting_canonical_sink.dart';
import 'package:forge_and_flow/services/integration/repository_inbound_webhook_gateway.dart';
import 'package:forge_and_flow/services/integration/repository_integration_routes_gateway.dart';

import 'admin_integrations_routes.dart';
import 'advisor_proxy.dart';
import 'phase_8_vendor_integration_factories.dart';
import 'proxy_bootstrap.dart';

// Re-export the constants + types moved into
// `phase_8_vendor_integration_factories.dart` so existing callers
// importing them through this binder file keep working.
export 'phase_8_vendor_integration_factories.dart'
    show
        Phase8VendorIntegrationFactories,
        buildPhase8VendorIntegrationFactoriesFromCredentials,
        kPhase8DefaultWebhookPublicBaseUri,
        kPhase8WebhookPublicBaseUriEnvName;

/// `dart-define` flag that gates demo mode. Mirrors the dart-define
/// handshake used elsewhere in the runtime
/// (`services/app_data_status_service.dart`).
const bool _kDemoMode = bool.fromEnvironment('kDemoMode');

/// Env var that disables the inbound-webhook signing-secret cache at
/// boot. Set to "true" / "1" / "yes" to fall back to the pre-cache
/// dispatch behaviour (every webhook hits Postgres + pgcrypto). The
/// rollout plan in the 2026-05-09 webhook-signature triage Section
/// 5.7 uses this to revert without a redeploy if the cache misbehaves
/// in production. Default (unset / any other value) leaves the cache
/// enabled.
const String kInboundWebhookSigningSecretCacheDisableEnvName =
    'PHASE_8_DISABLE_SIGNING_SECRET_CACHE';

bool _isSigningSecretCacheDisabled() {
  final raw = Platform
      .environment[kInboundWebhookSigningSecretCacheDisableEnvName]
      ?.trim()
      .toLowerCase();
  if (raw == null || raw.isEmpty) return false;
  return raw == 'true' || raw == '1' || raw == 'yes' || raw == 'y';
}

bool _alreadyBound = false;

/// Wire the Phase 8 inbound integration chain at boot.
///
/// [proxyJwtVerifier] is the same composite verifier the proxy's
/// request guard installs in `main.dart` (Firebase + service principal).
/// The lib-side actor resolver bridge consults it to extract claims
/// from the inbound `Authorization: Bearer ...` header before looking
/// up the Postgres user UUID.
///
/// [canonicalFactPostCommitProjector] is the projector that drains
/// `open_shift_snapshots` / `closed_shift_aggregates` from the
/// just-written canonical facts after each successful sink commit.
/// Tests may inject it alongside [canonicalFactPeriodResolver] +
/// [canonicalRestaurantIdResolver]. Production boot builds the same
/// triple from Postgres repository seams by default. The factories
/// then build a [ProjectingCanonicalSink] wrapper for each vendor sink
/// that directly implements [CanonicalSink] (the 13 of 17 with a uniform
/// canonical surface; Libro / OpenTable / Tock / SevenRooms expose a
/// view-based surface that requires per-tenant context). The wrapped
/// sinks are surfaced through
/// `factories.projectingSinksByVendor` for downstream `.spine-bridge`
/// sync worker dispatch.
///
/// Idempotent — a second call is a no-op. Demo mode (`kDemoMode=true`)
/// skips the binder entirely with a single info line.
Future<void> bindPhase8IntegrationsForProduction(
  ProxyProductionBindings productionBindings,
  ProxyConfig proxyConfig, {
  required ProxyJwtVerifier proxyJwtVerifier,
  http.Client? httpClient,
  Map<String, String>? environmentOverride,
  CanonicalFactPostCommitProjector? canonicalFactPostCommitProjector,
  CanonicalFactPeriodResolver? canonicalFactPeriodResolver,
  CanonicalRestaurantIdResolver? canonicalRestaurantIdResolver,
}) async {
  if (_alreadyBound) {
    log(
      LogSeverity.info,
      'startup.phase_8_binder.skipped',
      fields: <String, Object?>{'reason': 'already_bound'},
    );
    return;
  }
  if (_kDemoMode) {
    log(
      LogSeverity.info,
      'startup.phase_8_binder.skipped',
      fields: <String, Object?>{'reason': 'demo_mode'},
    );
    _alreadyBound = true;
    return;
  }

  // Per the typed-app-credentials amendment (Amendment B), the public
  // base URI is a typed [Uri] surfaced through [ProxyConfig.publicBaseUri]
  // (sourced from the required `PUBLIC_BASE_URI` env var). The
  // [environmentOverride] parameter is retained on the public binder
  // signature for backwards-compat with callers that pre-date the
  // typed-record migration; it is no longer consulted because every
  // remaining vendor read flows through `proxyConfig.has*AppCredentials`
  // / `proxyConfig.*AppCredentials` accessors.
  final webhookPublicBaseUri = proxyConfig.publicBaseUri;

  // Step 1 — Vendor credential broker.
  final broker = VendorCredentialBroker(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
    pgcryptoEnvelopeKey: productionBindings.pgcryptoEnvelopeKey,
  );

  // Step 2 — Per-(operator, location) runtime-config resolver.
  final locationConfigResolver = PerTenantLocationConfigResolver(
    productionBindings.tenantTransactionWrapper,
    webhookPublicBaseUri: webhookPublicBaseUri,
  );

  // Step 3 — Gateways shared by the admin + webhook surfaces.
  final integrationRoutesGateway = RepositoryIntegrationRoutesGateway(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
    permissionGuard: productionBindings.adminPermissionGuard,
    credentialEnvelopeKey: productionBindings.pgcryptoEnvelopeKey,
  );
  final inboundWebhookGateway = RepositoryInboundWebhookGateway(
    productionBindings.tenantTransactionWrapper,
    pgcryptoEnvelopeKey: productionBindings.pgcryptoEnvelopeKey,
  );

  // Shared HTTP client. Production callers may override; tests inject a
  // MockClient here so transport calls are intercepted without binding
  // the real HTTP stack.
  final sharedHttpClient = httpClient ?? http.Client();
  final projectorWiring = _resolveProjectorWiring(
    productionBindings.tenantTransactionWrapper,
    canonicalFactPostCommitProjector: canonicalFactPostCommitProjector,
    canonicalFactPeriodResolver: canonicalFactPeriodResolver,
    canonicalRestaurantIdResolver: canonicalRestaurantIdResolver,
  );

  // Step 4 — Per-vendor adapter factory closures, signature verifiers,
  // and the disable-warn list. Single source of truth for the per-
  // vendor wiring lives in
  // `phase_8_vendor_integration_factories.dart` so the first-connect
  // backfill worker can reuse the same builder without dragging
  // `proxy_bootstrap.dart` into its compile graph.
  final factories = buildPhase8VendorIntegrationFactoriesFromCredentials(
    tenantTransactionWrapper: productionBindings.tenantTransactionWrapper,
    broker: broker,
    locationConfigResolver: locationConfigResolver,
    sharedHttpClient: sharedHttpClient,
    webhookPublicBaseUri: webhookPublicBaseUri,
    alohaNcrVoyixCredentials: proxyConfig.hasAlohaNcrVoyixCredentials
        ? proxyConfig.alohaNcrVoyixCredentials
        : null,
    squareAppCredentials: proxyConfig.hasSquareAppCredentials
        ? proxyConfig.squareAppCredentials
        : null,
    cloverAppCredentials: proxyConfig.hasCloverAppCredentials
        ? proxyConfig.cloverAppCredentials
        : null,
    humanityAppCredentials: proxyConfig.hasHumanityAppCredentials
        ? proxyConfig.humanityAppCredentials
        : null,
    quickBooksTimeAppCredentials: proxyConfig.hasQuickBooksTimeAppCredentials
        ? proxyConfig.quickBooksTimeAppCredentials
        : null,
    sevenShiftsAppCredentials: proxyConfig.hasSevenShiftsAppCredentials
        ? proxyConfig.sevenShiftsAppCredentials
        : null,
    libroAppCredentials: proxyConfig.hasLibroAppCredentials
        ? proxyConfig.libroAppCredentials
        : null,
    canonicalFactPostCommitProjector: projectorWiring.projector,
    canonicalFactPeriodResolver: projectorWiring.periodResolver,
    canonicalRestaurantIdResolver: projectorWiring.restaurantIdResolver,
  );
  final posAdapterFactories = factories.posAdapterFactories;
  final laborAdapterFactories = factories.laborAdapterFactories;
  final reservationAdapterFactories = factories.reservationAdapterFactories;
  final signatureVerifiers = factories.signatureVerifiers;
  final disabledVendors = factories.disabledVendors;
  final projectingSinks = factories.projectingSinksByVendor;

  // Step 5 — InboundWebhookHandler.
  //
  // P0 fix (2026-05-09 webhook signature triage Section 5.E):
  // construct an in-memory [SigningSecretCache] so a webhook flood
  // does not amplify into N pgcrypto-decrypt round-trips against
  // `vendor_credentials.webhook_signing_secret_ciphertext`. The cache
  // is gated by [kInboundWebhookSigningSecretCacheDisableEnvName]
  // ("PHASE_8_DISABLE_SIGNING_SECRET_CACHE") so the rollout per
  // triage Section 5.7 can disable it without redeploying. Setting
  // the env to "true" / "1" / "yes" disables the cache; the handler
  // then falls back to the pre-cache behaviour (every dispatch hits
  // the gateway).
  final signingSecretCacheDisabled = _isSigningSecretCacheDisabled();
  final signingSecretCache = signingSecretCacheDisabled
      ? null
      : InMemorySigningSecretCache();
  log(
    LogSeverity.info,
    'startup.phase_8_signing_secret_cache',
    fields: <String, Object?>{
      'disabled': signingSecretCacheDisabled,
      'ttl_seconds': signingSecretCacheDisabled
          ? null
          : kSigningSecretCacheDefaultTtl.inSeconds,
      'per_operator_cap': signingSecretCacheDisabled
          ? null
          : kSigningSecretCachePerOperatorCap,
    },
  );
  final webhookHandler = InboundWebhookHandler(
    gateway: inboundWebhookGateway,
    posAdapterFactories: posAdapterFactories,
    laborAdapterFactories: laborAdapterFactories,
    reservationAdapterFactories: reservationAdapterFactories,
    signatureVerifiers: signatureVerifiers,
    bindingExtractor: WebhookBindingExtractor(),
    signingSecretCache: signingSecretCache,
  );

  // Step 6 — Adapt the tool-side admin actor types into the lib-side
  // bridge seam. Both adapters are private to this binder file.
  final adminActorJwtVerifier = _ToolToLibActorJwtVerifierAdapter(
    proxyJwtVerifier,
  );
  final adminActorUserResolver = _ToolToLibActorUserResolverAdapter(
    productionBindings.integrationAdminActorResolver,
  );

  // Step 7 — Bindings holder + global install.
  final bindings = _Phase8BindingsHolder(
    gateway: RepositoryToToolGatewayAdapter(integrationRoutesGateway),
    actorResolver: (HttpRequest request) async {
      final libContext = await bridge.resolveAdminActorFromHttpRequest(
        request,
        jwtVerifier: adminActorJwtVerifier,
        lookupResolver: adminActorUserResolver,
      );
      if (libContext == null) return null;
      return AdminActorContext(
        operatorId: libContext.operatorId,
        locationId: libContext.locationId,
        userId: libContext.userId,
      );
    },
    webhookHandler: webhookHandler,
    firstBackfillEnqueueGateway:
        productionBindings.firstConnectionBackfillEnqueueGateway,
    integrationCategoryResolver: productionBindings.integrationCategoryResolver,
    adminRequestIdempotencyStore:
        productionBindings.adminRequestIdempotencyStore,
  );
  Phase80IntegrationRoutes.globalBindings = bindings;
  _alreadyBound = true;
  _phase8ProjectingSinksByVendor
    ..clear()
    ..addAll(projectingSinks);

  log(
    LogSeverity.info,
    'startup.phase_8_binder.installed',
    fields: <String, Object?>{
      'webhook_public_base_uri': webhookPublicBaseUri.toString(),
      'pos_factories_wired': posAdapterFactories.keys.toList()..sort(),
      'labor_factories_wired': laborAdapterFactories.keys.toList()..sort(),
      'reservation_factories_wired': reservationAdapterFactories.keys.toList()
        ..sort(),
      'signature_verifiers_wired': signatureVerifiers.keys.toList()..sort(),
      'disabled_vendors': disabledVendors,
      'projector_wiring_active': projectorWiring.isActive,
      'projector_wiring_source': projectorWiring.source,
      'projecting_sinks_wired': projectingSinks.keys.toList()..sort(),
    },
  );
}

/// Module-level snapshot of the projecting canonical sinks the binder
/// constructed on its most recent run. Empty before the first call to
/// [bindPhase8IntegrationsForProduction] or when the caller did not
/// surface a [CanonicalFactPostCommitProjector] + resolver pair.
///
/// Downstream consumers (the production backfill worker; the per-vendor
/// poll worker) read this map to obtain the [ProjectingCanonicalSink]
/// view of each vendor's canonical write surface so a successful
/// commit-signal `appendSyncLog` projects the just-written facts.
Map<String, ProjectingCanonicalSink> get phase8ProjectingSinksByVendor =>
    Map<String, ProjectingCanonicalSink>.unmodifiable(
      _phase8ProjectingSinksByVendor,
    );

final Map<String, ProjectingCanonicalSink> _phase8ProjectingSinksByVendor =
    <String, ProjectingCanonicalSink>{};

/// Test helper. Production never invokes this; tests call it between
/// cases so each can assert against a freshly-installed holder.
void resetPhase8BinderForTests() {
  _alreadyBound = false;
  Phase80IntegrationRoutes.globalBindings = null;
  _phase8ProjectingSinksByVendor.clear();
}

_ProjectorWiring _resolveProjectorWiring(
  TenantTransactionWrapper tenantWrapper, {
  required CanonicalFactPostCommitProjector? canonicalFactPostCommitProjector,
  required CanonicalFactPeriodResolver? canonicalFactPeriodResolver,
  required CanonicalRestaurantIdResolver? canonicalRestaurantIdResolver,
}) {
  final anyExplicit =
      canonicalFactPostCommitProjector != null ||
      canonicalFactPeriodResolver != null ||
      canonicalRestaurantIdResolver != null;
  final allExplicit =
      canonicalFactPostCommitProjector != null &&
      canonicalFactPeriodResolver != null &&
      canonicalRestaurantIdResolver != null;
  if (allExplicit) {
    return _ProjectorWiring.active(
      source: 'explicit',
      projector: canonicalFactPostCommitProjector,
      periodResolver: canonicalFactPeriodResolver,
      restaurantIdResolver: canonicalRestaurantIdResolver,
    );
  }
  if (anyExplicit) {
    log(
      LogSeverity.warning,
      'startup.phase_8_projector_wiring.skipped',
      fields: <String, Object?>{
        'reason': 'partial_explicit_projector_dependencies',
        'has_projector': canonicalFactPostCommitProjector != null,
        'has_period_resolver': canonicalFactPeriodResolver != null,
        'has_restaurant_id_resolver': canonicalRestaurantIdResolver != null,
      },
    );
    return const _ProjectorWiring.inactive(source: 'partial_explicit_skipped');
  }
  return _buildDefaultProjectorWiring(tenantWrapper);
}

_ProjectorWiring _buildDefaultProjectorWiring(
  TenantTransactionWrapper tenantWrapper,
) {
  final timingRepository = BusinessTimingProfilesRepository(tenantWrapper);
  final timingSource = PostgresOpenShiftTimingProfileSource(timingRepository);
  final periodResolver = _ProductionCanonicalFactPeriodResolver(
    timingSource: timingSource,
  );
  final projector = CanonicalFactPostCommitProjector(
    closedAggregator: ExistingClosedShiftPostCommitAggregator(
      CanonicalFactToClosedShiftInputAggregator(tenantWrapper),
    ),
    targetSnapshotResolver: _ActiveTargetClosedShiftTargetSnapshotResolver(
      ActiveTargetProfileRepository(tenantWrapper),
    ),
    closedWriter: ExistingClosedShiftPostCommitWriter(
      PostgresShiftRecordWriter(tenantWrapper),
    ),
    openProjector: ExistingOpenShiftPostCommitProjector(
      OpenShiftSnapshotProjector(
        timingSource: timingSource,
        snapshotWriter: PostgresOpenShiftSnapshotWriter(
          repository: OpenShiftSnapshotsRepository(tenantWrapper),
        ),
      ),
    ),
  );
  return _ProjectorWiring.active(
    source: 'production_default',
    projector: projector,
    periodResolver: periodResolver.resolve,
    restaurantIdResolver: _locationIdAsRestaurantId,
  );
}

String _locationIdAsRestaurantId({
  required String operatorId,
  required String locationId,
}) => locationId;

class _ProjectorWiring {
  const _ProjectorWiring.inactive({required this.source})
    : projector = null,
      periodResolver = null,
      restaurantIdResolver = null;

  const _ProjectorWiring.active({
    required this.source,
    required this.projector,
    required this.periodResolver,
    required this.restaurantIdResolver,
  });

  final String source;
  final CanonicalFactPostCommitProjector? projector;
  final CanonicalFactPeriodResolver? periodResolver;
  final CanonicalRestaurantIdResolver? restaurantIdResolver;

  bool get isActive =>
      projector != null &&
      periodResolver != null &&
      restaurantIdResolver != null;
}

class _ProductionCanonicalFactPeriodResolver {
  _ProductionCanonicalFactPeriodResolver({
    required OpenShiftTimingProfileSource timingSource,
    IanaTimezoneConverter? timezoneConverter,
    DateTime Function()? clock,
  }) : _timingSource = timingSource,
       _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared,
       _clock = clock ?? DateTime.now;

  final OpenShiftTimingProfileSource _timingSource;
  final IanaTimezoneConverter _timezoneConverter;
  final DateTime Function() _clock;

  Future<CanonicalFactCommittedPeriod?> resolve({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required String vendorId,
    required String connectionId,
    required Map<String, Object?> canonicalFact,
  }) async {
    final fact = _parseOpenShiftFact(canonicalFact);
    if (fact == null) return null;
    final explicitBusinessDate = _stringFromFact(canonicalFact, const <String>[
      'business_date',
      'businessDate',
    ]);
    final seedBusinessDate = explicitBusinessDate ?? _isoDate(fact.occurredAt);
    var timing = await _timingSource.resolveForBusinessDate(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: seedBusinessDate,
    );
    if (timing == null) return null;

    final businessDate =
        explicitBusinessDate ?? _businessDateFor(fact.occurredAt, timing);
    if (businessDate != seedBusinessDate) {
      final dateSpecificTiming = await _timingSource.resolveForBusinessDate(
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
      );
      if (dateSpecificTiming == null) return null;
      timing = dateSpecificTiming;
    }

    final servicePeriodDefinition = _resolveServicePeriod(
      fact: fact,
      canonicalFact: canonicalFact,
      timing: timing,
    );
    if (servicePeriodDefinition == null) return null;
    final weekStartDate = WeeklyPlanSnapshotPolicy.weekStartForDate(
      businessDate,
      weekStartDay: timing.weekStartDay,
    );
    final weekEndDate = WeeklyPlanSnapshotPolicy.weekEndForDate(
      businessDate,
      weekStartDay: timing.weekStartDay,
    );

    return CanonicalFactCommittedPeriod(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: locationId,
      businessDate: businessDate,
      weekId: WeeklyPlanSnapshotPolicy.weekKeyFromSpan(
        weekStartDate,
        weekEndDate,
      ),
      dayLabel: _dayLabelFor(businessDate),
      servicePeriodKey: servicePeriodDefinition.id,
      servicePeriodDefinition: servicePeriodDefinition,
      state: _stateFor(
        businessDate: businessDate,
        definition: servicePeriodDefinition,
        timing: timing,
      ),
      businessTimingProfileId: timing.businessTimingProfileId,
      businessTimingProfileVersionId: timing.businessTimingProfileVersionId,
    );
  }

  OpenShiftCanonicalFact? _parseOpenShiftFact(
    Map<String, Object?> canonicalFact,
  ) {
    try {
      return OpenShiftCanonicalFact.fromMap(canonicalFact);
    } on Object {
      return null;
    }
  }

  ServicePeriodDefinition? _resolveServicePeriod({
    required OpenShiftCanonicalFact fact,
    required Map<String, Object?> canonicalFact,
    required ResolvedOpenShiftTimingProfile timing,
  }) {
    final explicitKey = _stringFromFact(canonicalFact, const <String>[
      'service_period_key',
      'servicePeriodKey',
      'daypart',
    ]);
    if (explicitKey != null) {
      return _definitionByKey(timing.servicePeriods, explicitKey);
    }
    final bucketKey = _bucketKeyForFact(fact, timing);
    if (bucketKey == null) return null;
    return _definitionByKey(timing.servicePeriods, bucketKey);
  }

  String? _bucketKeyForFact(
    OpenShiftCanonicalFact fact,
    ResolvedOpenShiftTimingProfile timing,
  ) {
    final localStart = _timezoneConverter.toBusinessLocal(
      restaurantTimezone: timing.businessTimezone,
      instant: fact.occurredAt,
    );
    return switch (fact.kind) {
      OpenShiftCanonicalFactKind.pos => DaypartBucketer.bucketPosLine(
        BucketingPosLine(
          sourceId: fact.sourceEntityId,
          eventLocalTimestamp: localStart,
        ),
        timing.locationContext,
        timing.servicePeriods,
      ),
      OpenShiftCanonicalFactKind.reservation =>
        DaypartBucketer.bucketReservation(
          BucketingReservation(
            sourceId: fact.sourceEntityId,
            reservationLocalTimestamp: localStart,
          ),
          timing.locationContext,
          timing.servicePeriods,
        ),
      OpenShiftCanonicalFactKind.labor => _firstLaborBucket(
        fact,
        timing,
        localStart,
      ),
    };
  }

  String? _firstLaborBucket(
    OpenShiftCanonicalFact fact,
    ResolvedOpenShiftTimingProfile timing,
    DateTime localStart,
  ) {
    final localEnd = fact.endedAt == null
        ? localStart
        : _timezoneConverter.toBusinessLocal(
            restaurantTimezone: timing.businessTimezone,
            instant: fact.endedAt!,
          );
    final segments = DaypartBucketer.bucketLaborPunch(
      BucketingLaborPunch(
        sourceId: fact.sourceEntityId,
        clockedInLocal: localStart,
        clockedOutLocal: localEnd,
      ),
      timing.locationContext,
      timing.servicePeriods,
    );
    for (final segment in segments) {
      final key = segment.servicePeriodId;
      if (key != null) return key;
    }
    return null;
  }

  CanonicalFactPeriodState _stateFor({
    required String businessDate,
    required ServicePeriodDefinition definition,
    required ResolvedOpenShiftTimingProfile timing,
  }) {
    final nowLocal = _timezoneConverter.toBusinessLocal(
      restaurantTimezone: timing.businessTimezone,
      instant: _clock().toUtc(),
    );
    final periodEnd = _localBoundary(
      businessDate: businessDate,
      localTime: definition.endLocalTime,
      addDay: definition.rollsPastMidnight,
    );
    return nowLocal.isBefore(periodEnd)
        ? CanonicalFactPeriodState.openCurrent
        : CanonicalFactPeriodState.completed;
  }

  String _businessDateFor(
    DateTime instant,
    ResolvedOpenShiftTimingProfile timing,
  ) {
    return BusinessDateResolver.resolve(
      localTimestamp: _timezoneConverter.toBusinessLocal(
        restaurantTimezone: timing.businessTimezone,
        instant: instant,
      ),
      businessDayStartLocalTime: timing.businessDayStartLocalTime,
    );
  }

  static ServicePeriodDefinition? _definitionByKey(
    List<ServicePeriodDefinition> definitions,
    String key,
  ) {
    for (final definition in definitions) {
      if (definition.id == key) return definition;
    }
    return null;
  }
}

class _ActiveTargetClosedShiftTargetSnapshotResolver
    implements ClosedShiftTargetSnapshotResolver {
  const _ActiveTargetClosedShiftTargetSnapshotResolver(this._repository);

  final ActiveTargetProfileRepository _repository;

  @override
  Future<TargetSnapshot> resolveTargetSnapshot({
    required CanonicalFactPostCommitInput input,
    required CanonicalFactCommittedPeriod period,
    required AggregatorResult aggregateResult,
  }) async {
    final row = await _repository.loadActiveProfile(
      operatorId: input.operatorId,
      locationId: input.locationId,
      restaurantId: input.restaurantId,
      userId: input.userId,
    );
    if (row == null) {
      throw StateError(
        'active target profile missing for '
        '${input.operatorId}/${input.locationId}/${input.restaurantId}',
      );
    }
    final profile = _activeTargetProfileFromRow(row);
    return TargetSnapshotBuilder.fromActiveTargetProfile(
      profile,
      targetProfileVersionId: row.targetProfileVersionId,
      servicePeriodId: period.servicePeriodKey,
    );
  }
}

ActiveTargetProfile _activeTargetProfileFromRow(
  ActiveTargetProfilePostgresRow row,
) {
  return ActiveTargetProfile(
    targetProfileId: row.targetProfileId,
    restaurantId: row.restaurantId,
    targetCycleId: row.targetCycleId,
    targetProfileVersionId: row.targetProfileVersionId,
    sourceType: row.sourceType,
    targetCPLH: row.targetCplh,
    targetSPLH: row.targetSplh,
    targetPPA: row.targetPpa,
    fohWage: row.fohWage,
    bohWage: row.bohWage,
    opzFloorCPLH: row.opzFloorCplh,
    opzCeilingCPLH: row.opzCeilingCplh,
    theoreticalFohLaborPct: row.theoreticalFohLaborPct,
    theoreticalBohLaborPct: row.theoreticalBohLaborPct,
    theoreticalLaborPct: row.theoreticalLaborPct,
    builtAt: row.builtAt.toUtc().toIso8601String(),
    dayparts: <ActiveTargetProfileDaypart>[
      for (final daypart in row.dayparts)
        ActiveTargetProfileDaypart(
          servicePeriodId: daypart.servicePeriodId,
          daypartTargetCPLH: daypart.daypartTargetCplh,
          daypartTargetSPLH: daypart.daypartTargetSplh,
          daypartTargetPPA: daypart.daypartTargetPpa,
          daypartOpzFloorCPLH: daypart.daypartOpzFloorCplh,
          daypartOpzCeilingCPLH: daypart.daypartOpzCeilingCplh,
          verdict: daypart.verdict,
          verdictReason: daypart.verdictReason,
        ),
    ],
  );
}

String? _stringFromFact(Map<String, Object?> fact, List<String> keys) {
  for (final key in keys) {
    final value = fact[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return null;
}

String _isoDate(DateTime date) {
  final utc = date.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

String _dayLabelFor(String businessDate) {
  final weekday = DateTime.parse(businessDate).weekday;
  return CanonicalDayOrder.labels[weekday - 1];
}

DateTime _localBoundary({
  required String businessDate,
  required String localTime,
  required bool addDay,
}) {
  final date = DateTime.parse(businessDate);
  final parts = localTime.split(':');
  final hour = parts.isEmpty ? 0 : int.parse(parts[0]);
  final minute = parts.length < 2 ? 0 : int.parse(parts[1]);
  return DateTime(
    date.year,
    date.month,
    date.day,
    hour,
    minute,
  ).add(addDay ? const Duration(days: 1) : Duration.zero);
}

/// Internal bindings holder.
class _Phase8BindingsHolder implements Phase80IntegrationRoutesBindingsHolder {
  _Phase8BindingsHolder({
    required this.gateway,
    required this.actorResolver,
    required this.webhookHandler,
    required this.firstBackfillEnqueueGateway,
    required this.integrationCategoryResolver,
    required this.adminRequestIdempotencyStore,
  });

  @override
  final IntegrationRoutesGateway gateway;
  @override
  final AdminActorResolver actorResolver;
  @override
  final InboundWebhookHandler webhookHandler;
  @override
  final FirstConnectionBackfillEnqueueGateway firstBackfillEnqueueGateway;
  @override
  final IntegrationCategoryResolver? integrationCategoryResolver;
  @override
  final AdminRequestIdempotencyStore? adminRequestIdempotencyStore;
}

// ─── tool/lib seam adapters ────────────────────────────────────────────
//
// `lib/integrations/_common/admin_actor_resolver_bridge.dart` declares
// lib-side `AdminActorJwtVerifier` + `AdminActorUserResolver`
// abstractions that mirror the tool-side `ProxyJwtVerifier` and
// `IntegrationAdminActorResolver`. The bindings holder requires the
// lib-side shape; the production bindings expose the tool-side shape.
// These adapters bridge the two without changing either side's
// contracts.

class _ToolToLibActorJwtVerifierAdapter
    implements bridge.AdminActorJwtVerifier {
  _ToolToLibActorJwtVerifierAdapter(this._toolVerifier);

  final ProxyJwtVerifier _toolVerifier;

  @override
  Future<bridge.AdminActorJwtClaims> verify(String bearerToken) async {
    final claims = await _toolVerifier.verify(bearerToken);
    return bridge.AdminActorJwtClaims(
      firebaseUid: claims.firebaseUid,
      operatorId: claims.operatorId,
      locationId: claims.locationId,
    );
  }
}

class _ToolToLibActorUserResolverAdapter
    implements bridge.AdminActorUserResolver {
  _ToolToLibActorUserResolverAdapter(this._toolResolver);

  final IntegrationAdminActorResolver _toolResolver;

  @override
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  }) {
    return _toolResolver.resolveActorUserId(
      firebaseUid: firebaseUid,
      adminReason: adminReason,
    );
  }
}

/// Forwarding adapter that lifts the lib-side
/// `RepositoryIntegrationRoutesGateway` (which structurally matches but
/// does not extend the tool-side abstract) into the tool-side
/// `IntegrationRoutesGateway` shape `Phase80IntegrationRoutesBindingsHolder`
/// expects. The gateway is structurally identical — same method names,
/// parameter names, return types — so the adapter is one-line-per-method
/// pass-through.
///
/// Public so the operator-facing OAuth dispatcher (different gateway
/// instance, same shape) can reuse the adapter without duplicating
/// the pass-through methods.
RepositoryToToolGatewayAdapter wrapRepositoryGatewayForToolApi(
  RepositoryIntegrationRoutesGateway inner,
) {
  return RepositoryToToolGatewayAdapter(inner);
}

class RepositoryToToolGatewayAdapter implements IntegrationRoutesGateway {
  RepositoryToToolGatewayAdapter(this._inner);

  final RepositoryIntegrationRoutesGateway _inner;

  @override
  Future<Map<String, Object?>> listForLocation({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) => _inner.listForLocation(
    operatorId: operatorId,
    locationId: locationId,
    actorUserId: actorUserId,
  );

  @override
  Future<Map<String, Object?>> startOAuth({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    String? module,
  }) => _inner.startOAuth(
    operatorId: operatorId,
    locationId: locationId,
    actorUserId: actorUserId,
    vendorId: vendorId,
    module: module,
  );

  @override
  Future<Map<String, Object?>> handleOAuthCallback({
    required String vendorId,
    required Map<String, String> queryParameters,
  }) => _inner.handleOAuthCallback(
    vendorId: vendorId,
    queryParameters: queryParameters,
  );

  @override
  Future<Map<String, Object?>> connectViaKeyPaste({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String apiKey,
    String? username,
    String? module,
  }) => _inner.connectViaKeyPaste(
    operatorId: operatorId,
    locationId: locationId,
    actorUserId: actorUserId,
    vendorId: vendorId,
    apiKey: apiKey,
    username: username,
    module: module,
  );

  @override
  Future<Map<String, Object?>> testConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
  }) => _inner.testConnection(
    operatorId: operatorId,
    locationId: locationId,
    actorUserId: actorUserId,
    vendorId: vendorId,
  );

  @override
  Future<Map<String, Object?>> disconnect({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String reason,
  }) => _inner.disconnect(
    operatorId: operatorId,
    locationId: locationId,
    actorUserId: actorUserId,
    vendorId: vendorId,
    reason: reason,
  );

  @override
  Future<List<Map<String, Object?>>> listSyncLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) => _inner.listSyncLogs(
    operatorId: operatorId,
    locationId: locationId,
    vendorId: vendorId,
    limit: limit,
  );

  @override
  Future<bool> hasIntegrationsConfigurePermission({
    required String operatorId,
    required String userId,
  }) => _inner.hasIntegrationsConfigurePermission(
    operatorId: operatorId,
    userId: userId,
  );
}
