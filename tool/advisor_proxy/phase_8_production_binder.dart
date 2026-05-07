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
//   * Per-vendor credential bridges (PR #238)  — adapt the broker to
//                                                  each vendor's
//                                                  resolver/store seam.
//   * Production OAuth refresh closures
//     (PR #247)                                — vendor-specific
//                                                  token-rotation
//                                                  HTTP shapes (Toast,
//                                                  Square, Clover,
//                                                  Lightspeed LSK,
//                                                  Aloha NCR Voyix,
//                                                  Oracle MICROS
//                                                  Simphony, Revel,
//                                                  7shifts, QuickBooks
//                                                  Time, Libro,
//                                                  Humanity).
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
//     `cloverAppCredentials`                   — typed vendor app
//                                                  credentials (PR #260).
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

import 'package:forge_and_flow/infrastructure/persistence/postgres/adp_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/agendrix_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/aloha_ncr_voyix_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/clover_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/humanity_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/libro_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/push_operations_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/revel_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/seven_shifts_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/square_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart';
import 'package:forge_and_flow/integrations/_common/admin_actor_resolver_bridge.dart'
    as bridge;
import 'package:forge_and_flow/integrations/_common/production_oauth_refresh_closures.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
// Vendor id constants are deliberately re-declared in both the
// credential bridge files (used by the broker calls) and the adapter
// files (used by the registry / capability profiles). To avoid Dart
// `ambiguous_import` errors we hide the duplicate symbol on the
// adapter-side import where the credential-bridge name is already
// pulled in. The bridge-side const is the one used as the broker
// `vendor_id`; the adapter-side const may differ for legacy reasons
// (notably `seven_shifts_credential_bridge.dart` declares
// `kSevenShiftsVendorId='7shifts'` while the adapter declares the same
// symbol with value `'seven_shifts'`). The framework dispatcher uses
// the URL-path string (always `'seven_shifts'`); the bridge uses
// whatever the credential row stores.
import 'package:forge_and_flow/integrations/labor/adp_credential_bridge.dart';
import 'package:forge_and_flow/integrations/labor/adp_labor_adapter.dart'
    hide kAdpVendorId;
import 'package:forge_and_flow/integrations/labor/adp_labor_production_api_client.dart';
import 'package:forge_and_flow/integrations/labor/adp_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/labor/agendrix_credential_bridge.dart';
import 'package:forge_and_flow/integrations/labor/agendrix_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/agendrix_labor_production_api_client.dart';
import 'package:forge_and_flow/integrations/labor/agendrix_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/labor/humanity_credential_bridge.dart';
import 'package:forge_and_flow/integrations/labor/humanity_labor_adapter.dart'
    hide kHumanityVendorId;
import 'package:forge_and_flow/integrations/labor/humanity_labor_production_api_client.dart';
import 'package:forge_and_flow/integrations/labor/humanity_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/labor/push_operations_credential_bridge.dart';
import 'package:forge_and_flow/integrations/labor/push_operations_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/push_operations_labor_production_api_client.dart';
import 'package:forge_and_flow/integrations/labor/push_operations_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/labor/quickbooks_time_credential_bridge.dart';
import 'package:forge_and_flow/integrations/labor/quickbooks_time_labor_adapter.dart'
    hide kQuickBooksTimeVendorId;
import 'package:forge_and_flow/integrations/labor/quickbooks_time_labor_production_api_client.dart';
import 'package:forge_and_flow/integrations/labor/quickbooks_time_webhook_signature_verifier.dart';
// 7shifts: the bridge file's `kSevenShiftsVendorId='7shifts'` differs
// from the adapter file's `kSevenShiftsVendorId='seven_shifts'`. We
// import the bridge under a prefix and hide the symbol from the
// adapter; the binder uses the literal `'seven_shifts'` for factory
// keys and signature verifiers (the URL-path vendor id) and the
// bridge's `'7shifts'` for broker `vendor_credentials` rows.
import 'package:forge_and_flow/integrations/labor/seven_shifts_credential_bridge.dart'
    as seven_shifts_bridge;
import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_production_api_client.dart';
import 'package:forge_and_flow/integrations/labor/seven_shifts_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_credential_bridge.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_adapter.dart'
    hide kAlohaNcrVoyixVendorId;
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_production_api_client.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/pos/clover_credential_bridge.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_postgres_credential_store.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_production_api_client.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_webhook_registry.dart';
import 'package:forge_and_flow/integrations/pos/clover_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_credential_bridge.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_production_api_client.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/pos/revel_credential_bridge.dart';
import 'package:forge_and_flow/integrations/pos/revel_pos_adapter.dart'
    hide kRevelVendorId;
import 'package:forge_and_flow/integrations/pos/revel_pos_production_api_client.dart';
import 'package:forge_and_flow/integrations/pos/revel_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/pos/square_credential_bridge.dart';
import 'package:forge_and_flow/integrations/pos/square_pos_adapter.dart'
    hide kSquareVendorId;
import 'package:forge_and_flow/integrations/pos/square_pos_production_api_client.dart';
import 'package:forge_and_flow/integrations/pos/square_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/pos/toast_credential_bridge.dart';
import 'package:forge_and_flow/integrations/pos/toast_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/toast_pos_production_api_client.dart';
import 'package:forge_and_flow/integrations/pos/toast_webhook_signature_verifier.dart'
    hide kToastVendorId;
import 'package:forge_and_flow/integrations/reservation/libro_credential_bridge.dart';
import 'package:forge_and_flow/integrations/reservation/libro_reservation_adapter.dart'
    hide kLibroVendorId;
import 'package:forge_and_flow/integrations/reservation/libro_reservation_production_api_client.dart';
import 'package:forge_and_flow/integrations/reservation/libro_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_credential_bridge.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_reservation_adapter.dart'
    hide kOpenTableVendorId;
import 'package:forge_and_flow/integrations/reservation/opentable_reservation_production_api_client.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_credential_bridge.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/reservation/tock_credential_bridge.dart';
import 'package:forge_and_flow/integrations/reservation/tock_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/tock_reservation_production_api_client.dart';
import 'package:forge_and_flow/integrations/reservation/tock_webhook_signature_verifier.dart'
    hide kTockVendorId;
import 'package:forge_and_flow/services/integration/canonical_fact_post_commit_projector.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/per_tenant_location_config_resolver.dart';
import 'package:forge_and_flow/services/integration/projecting_canonical_sink.dart';
import 'package:forge_and_flow/services/integration/repository_inbound_webhook_gateway.dart';
import 'package:forge_and_flow/services/integration/repository_integration_routes_gateway.dart';

import 'admin_integrations_routes.dart';
import 'advisor_proxy.dart';
import 'proxy_bootstrap.dart';

/// Default public base URI the framework presents to vendors as the
/// inbound webhook host. Mirrors the convention already used in
/// `lib/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart`
/// and `lib/services/integration/per_tenant_location_config_resolver.dart`
/// docs. Override at boot via the `FF_WEBHOOK_PUBLIC_BASE_URI` env var.
const String kPhase8DefaultWebhookPublicBaseUri = 'https://api.forgeflow.app';

/// Env var name the binder consults for an explicit override of
/// [kPhase8DefaultWebhookPublicBaseUri]. Cloud Run deployments that
/// expose the proxy under a custom hostname set this; the default
/// suffices for the canonical production deploy.
const String kPhase8WebhookPublicBaseUriEnvName =
    'FF_WEBHOOK_PUBLIC_BASE_URI';

/// `dart-define` flag that gates demo mode. Mirrors the dart-define
/// handshake used elsewhere in the runtime
/// (`services/app_data_status_service.dart`).
const bool _kDemoMode = bool.fromEnvironment('kDemoMode');

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
/// When provided alongside [canonicalFactPeriodResolver] +
/// [canonicalRestaurantIdResolver], the binder wraps each vendor
/// canonical sink with a [ProjectingCanonicalSink] so a successful
/// `appendSyncLog` commit signal projects the buffered facts. When
/// any of these three is null, the binder skips the wrapping with a
/// structured info line — the upstream caller has not yet surfaced a
/// production-wired projector.
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
      fields: <String, Object?>{
        'reason': 'already_bound',
      },
    );
    return;
  }
  if (_kDemoMode) {
    log(
      LogSeverity.info,
      'startup.phase_8_binder.skipped',
      fields: <String, Object?>{
        'reason': 'demo_mode',
      },
    );
    _alreadyBound = true;
    return;
  }

  final env = environmentOverride ?? Platform.environment;
  final webhookPublicBaseUri = Uri.parse(
    env[kPhase8WebhookPublicBaseUriEnvName] ??
        kPhase8DefaultWebhookPublicBaseUri,
  );

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

  // Step 4 — Build per-vendor adapter factory closures, signature
  // verifiers, and the disable-warn list. The disable-warn list
  // mirrors PR #260's optional-vendor pattern: a vendor whose static
  // app credentials (Aloha / Square / Clover) are missing, or whose
  // adapter requires async per-tenant location config that the binder
  // cannot warm at boot time, is skipped with a structured warning so
  // the proxy still binds.
  final disabledVendors = <String, String>{};

  final posAdapterFactories = <String, PosAdapterFactory>{};
  final laborAdapterFactories = <String, LaborAdapterFactory>{};
  final reservationAdapterFactories = <String, ReservationAdapterFactory>{};
  final signatureVerifiers = <String, VendorWebhookSignatureVerifier>{};

  // Step 4.5 — Per-vendor projecting canonical sinks. Wraps each
  // vendor's [CanonicalSink] view so a successful canonical fact
  // commit drains `open_shift_snapshots` / `closed_shift_aggregates`
  // projection through [CanonicalFactPostCommitProjector]. When the
  // caller has not yet surfaced a projector + resolvers, the wrapping
  // is skipped (a single info line records the gap). Vendor adapter
  // Deps records continue to receive the underlying vendor-specific
  // sink type (e.g. `ToastFactSink`) — a follow-up lane widens those
  // Deps types so the wrapped [CanonicalSink] view is the consumed
  // surface; today the wrappers are reachable through
  // [phase8ProjectingSinksByVendor] for downstream worker dispatch
  // wiring.
  final projectingSinksByVendor = <String, ProjectingCanonicalSink>{};
  final bool projectorWiringActive = canonicalFactPostCommitProjector != null &&
      canonicalFactPeriodResolver != null &&
      canonicalRestaurantIdResolver != null;
  ProjectingCanonicalSink wrap({
    required String vendorId,
    required IntegrationCategory category,
    required CanonicalSink underlying,
  }) {
    final wrapped = ProjectingCanonicalSink(
      underlying: underlying,
      projector: canonicalFactPostCommitProjector!,
      category: category,
      vendorId: vendorId,
      periodResolver: canonicalFactPeriodResolver!,
      restaurantIdResolver: canonicalRestaurantIdResolver!,
    );
    projectingSinksByVendor[vendorId] = wrapped;
    return wrapped;
  }

  // ─── POS — Toast (PR #247 refresh closure) ──────────────────────────
  final toastSink = ToastPosPostgresSink(
    productionBindings.tenantTransactionWrapper,
  );
  if (projectorWiringActive) {
    wrap(
      vendorId: kToastVendorId,
      category: IntegrationCategory.pos,
      underlying: toastSink,
    );
  }
  final toastRefresh = makeToastOauthRefreshClosure(
    httpClient: sharedHttpClient,
  );
  posAdapterFactories[kToastVendorId] = ({
    required String operatorId,
    required String locationId,
  }) {
    final tokenResolver = ToastBrokerAccessTokenResolver(
      broker: broker,
      operatorId: operatorId,
      locationId: locationId,
      oauthExchange: toastRefresh,
    );
    final transport = ToastPosProductionApiClient(
      httpClient: sharedHttpClient,
      tokenResolver: tokenResolver,
    );
    return ToastPosAdapter(transport: transport, factSink: toastSink);
  };
  signatureVerifiers[kToastVendorId] = const ToastWebhookSignatureVerifier();

  // ─── POS — Aloha NCR Voyix (optional static app credentials) ───────
  final alohaSink = AlohaNcrVoyixPostgresSink(
    productionBindings.tenantTransactionWrapper,
  );
  if (projectorWiringActive) {
    wrap(
      vendorId: kAlohaNcrVoyixVendorId,
      category: IntegrationCategory.pos,
      underlying: alohaSink,
    );
  }
  if (proxyConfig.hasAlohaNcrVoyixCredentials) {
    final alohaCreds = proxyConfig.alohaNcrVoyixCredentials;
    final alohaRefresh = makeAlohaNcrVoyixOauthRefreshClosure(
      httpClient: sharedHttpClient,
    );
    posAdapterFactories[kAlohaNcrVoyixVendorId] = ({
      required String operatorId,
      required String locationId,
    }) {
      final credentialStore = makeAlohaNcrVoyixCredentialStore(
        broker: broker,
        operatorId: operatorId,
        locationId: locationId,
        oauthRefresh: alohaRefresh,
      );
      final transport = AlohaNcrVoyixPosProductionApiClient(
        credentialStore: credentialStore,
        oauthCredentials: alohaCreds,
        httpClient: sharedHttpClient,
      );
      return AlohaNcrVoyixPosAdapter(
        transport: transport,
        factSink: alohaSink,
      );
    };
    signatureVerifiers[kAlohaNcrVoyixVendorId] =
        const AlohaNcrVoyixWebhookSignatureVerifier();
  } else {
    disabledVendors[kAlohaNcrVoyixVendorId] = 'aloha_ncr_voyix_credentials_missing';
  }

  // ─── POS — Clover (optional static app credentials) ────────────────
  if (proxyConfig.hasCloverAppCredentials) {
    final cloverSink = CloverPostgresSink(
      productionBindings.tenantTransactionWrapper,
    );
    if (projectorWiringActive) {
      wrap(
        vendorId: kCloverVendorId,
        category: IntegrationCategory.pos,
        underlying: cloverSink,
      );
    }
    final cloverCredStore = CloverPosPostgresCredentialStore(
      productionBindings.tenantTransactionWrapper,
    );
    final cloverAppCredentials = proxyConfig.cloverAppCredentials;
    final cloverRefresh = makeCloverOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: cloverAppCredentials.appId,
    );
    final appTokenSource = makeStaticCloverAppTokenSource(
      cloverAppCredentials.appToken,
    );
    final appIdSource = makeStaticCloverAppIdSource(
      cloverAppCredentials.appId,
    );
    posAdapterFactories[kCloverVendorId] = ({
      required String operatorId,
      required String locationId,
    }) {
      final merchantTokenSource = makeCloverAccessTokenSource(
        broker: broker,
        operatorId: operatorId,
        locationId: locationId,
        oauthRefresh: cloverRefresh,
      );
      final transport = CloverPosProductionApiClient(
        httpClient: sharedHttpClient,
        merchantTokenSource: merchantTokenSource,
        appTokenSource: appTokenSource,
        appIdSource: appIdSource,
      );
      final webhookRegistry = CloverPosWebhookRegistry(
        productionBindings.tenantTransactionWrapper,
        api: transport,
        callbackUrlSource: () => webhookPublicBaseUri
            .resolve('/v1/webhooks/$kCloverVendorId/$operatorId/$locationId')
            .toString(),
      );
      return CloverPosAdapter(
        api: transport,
        factWriter: cloverSink,
        watermarkStore: cloverSink,
        webhookRegistry: webhookRegistry,
        credentials: cloverCredStore,
      );
    };
    signatureVerifiers[kCloverVendorId] = const CloverWebhookSignatureVerifier();
  } else {
    disabledVendors[kCloverVendorId] = 'clover_app_credentials_missing';
  }

  // ─── POS — Lightspeed LSK ──────────────────────────────────────────
  // Lightspeed's adapter takes per-tenant timezone + rollover-hour +
  // webhookUrl values from `PerTenantLocationConfigResolver`, which is
  // async. The factory typedef is sync, so we mark Lightspeed
  // disabled-with-warn for the binder; the per-tenant lane wires
  // Lightspeed via the sync worker dispatch path
  // (`tool/integration_sync_worker/dispatch.dart`) which IS async and
  // can resolve location config before constructing the adapter.
  // Inbound webhooks for Lightspeed therefore land at the gateway-only
  // surface (verifier + idempotency + binding cross-check) until the
  // factory typedef gains an async variant.
  disabledVendors['lightspeed_lsk'] =
      'lightspeed_lsk_async_location_config_required';

  // ─── POS — Oracle MICROS Simphony ──────────────────────────────────
  final oracleSink = OracleMicrosSimphonyPostgresSink(
    productionBindings.tenantTransactionWrapper,
  );
  if (projectorWiringActive) {
    wrap(
      vendorId: kOracleMicrosSimphonyVendorId,
      category: IntegrationCategory.pos,
      underlying: oracleSink,
    );
  }
  final simphonyExchange = makeOracleMicrosSimphonyOauthExchangeClosure(
    httpClient: sharedHttpClient,
  );
  // The Simphony token store is operator/location-agnostic; it accepts
  // them per-call. One instance shared across factories is fine.
  final simphonyTokenStore = OracleMicrosSimphonyBrokerTokenStore(
    broker: broker,
    oauthExchange: simphonyExchange,
  );
  posAdapterFactories[kOracleMicrosSimphonyVendorId] = ({
    required String operatorId,
    required String locationId,
  }) {
    final transport = OracleMicrosSimphonyProductionApiClient(
      httpClient: sharedHttpClient,
      tokenStore: simphonyTokenStore,
      credential: const SimphonyVendorCredentialHandle(
        // The adapter does not surface a credential id distinct from
        // the (operator, location, vendor) triple — the broker keys on
        // that triple internally.
        credentialId: '',
      ),
    );
    return OracleMicrosSimphonyPosAdapter(
      apiClient: transport,
      canonicalSink: oracleSink,
    );
  };
  signatureVerifiers[kOracleMicrosSimphonyVendorId] =
      const OracleMicrosSimphonyWebhookSignatureVerifier();

  // ─── POS — Revel ───────────────────────────────────────────────────
  final revelSink = RevelPosPostgresSink(
    productionBindings.tenantTransactionWrapper,
  );
  if (projectorWiringActive) {
    wrap(
      vendorId: kRevelVendorId,
      category: IntegrationCategory.pos,
      underlying: revelSink,
    );
  }
  posAdapterFactories[kRevelVendorId] = ({
    required String operatorId,
    required String locationId,
  }) {
    final transport = RevelProductionApiClient(
      deps: RevelProductionApiClientDeps(
        httpClient: sharedHttpClient,
      ),
    );
    return RevelPosAdapter(
      transport: transport,
      gateway: revelSink,
    );
  };
  signatureVerifiers[kRevelVendorId] = const RevelWebhookSignatureVerifier();

  // ─── POS — Square (optional static app credentials) ────────────────
  if (proxyConfig.hasSquareAppCredentials) {
    final squareSink = SquarePosPostgresSink(
      productionBindings.tenantTransactionWrapper,
    );
    if (projectorWiringActive) {
      wrap(
        vendorId: kSquareVendorId,
        category: IntegrationCategory.pos,
        underlying: squareSink,
      );
    }
    final squareAppCreds = proxyConfig.squareAppCredentials;
    final squareRefresh = makeSquareOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: squareAppCreds.clientId,
      clientSecret: squareAppCreds.clientSecret,
    );
    posAdapterFactories[kSquareVendorId] = ({
      required String operatorId,
      required String locationId,
    }) {
      final credentialResolver = SquareBrokerCredentialResolver(
        broker: broker,
        operatorId: operatorId,
        locationId: locationId,
        oauthRefresh: squareRefresh,
        clientId: squareAppCreds.clientId,
        clientSecret: squareAppCreds.clientSecret,
      );
      final transport = SquarePosProductionApiClient(
        credentials: credentialResolver,
        httpClient: sharedHttpClient,
      );
      return SquarePosAdapter(
        apiClient: transport,
        factWriter: squareSink,
        watermarkStore: squareSink,
        notificationUrlForConnection: ({
          required String operatorId,
          required String locationId,
        }) async {
          // Square's notification URL is the per-(operator, location)
          // webhook callback; the adapter uses this to register the
          // subscription with Square. The per-tenant location resolver
          // composes the canonical
          // `/v1/webhooks/<vendor>/<operatorId>/<locationId>` shape
          // off [webhookPublicBaseUri].
          final config = await locationConfigResolver.resolve(
            operatorId: operatorId,
            locationId: locationId,
            vendorId: kSquareVendorId,
          );
          return config.webhookBaseUri.toString();
        },
      );
    };
    signatureVerifiers[kSquareVendorId] = const SquareWebhookSignatureVerifier();
  } else {
    disabledVendors[kSquareVendorId] = 'square_app_credentials_missing';
  }

  // ─── Labor — ADP ───────────────────────────────────────────────────
  final adpSink = AdpPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  if (projectorWiringActive) {
    wrap(
      vendorId: kAdpVendorId,
      category: IntegrationCategory.labor,
      underlying: adpSink,
    );
  }
  laborAdapterFactories[kAdpVendorId] = ({
    required String operatorId,
    required String locationId,
  }) {
    final credentialsProvider = makeAdpCredentialsProvider(
      broker: broker,
      operatorId: operatorId,
      locationId: locationId,
    );
    final subscriptionSecretProvider = makeAdpSubscriptionSecretProvider(
      broker: broker,
      operatorId: operatorId,
      locationId: locationId,
    );
    final transport = AdpLaborProductionApiClient(
      credentialsProvider: credentialsProvider,
      subscriptionSecretProvider: subscriptionSecretProvider,
      httpClient: sharedHttpClient,
    );
    return AdpLaborAdapter(
      transport: transport,
      gateway: adpSink,
    );
  };
  signatureVerifiers[kAdpVendorId] = const AdpWebhookSignatureVerifier();

  // ─── Labor — Agendrix ──────────────────────────────────────────────
  final agendrixSink = AgendrixPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  if (projectorWiringActive) {
    wrap(
      vendorId: agendrixVendorId,
      category: IntegrationCategory.labor,
      underlying: agendrixSink,
    );
  }
  final agendrixCredentialStore = AgendrixBrokerCredentialStore(broker: broker);
  laborAdapterFactories[agendrixVendorId] = ({
    required String operatorId,
    required String locationId,
  }) {
    final transport = AgendrixProductionApiClient(
      credentialStore: agendrixCredentialStore,
      httpClient: sharedHttpClient,
    );
    return AgendrixLaborAdapter(
      apiClient: transport,
      canonicalSink: agendrixSink,
    );
  };
  signatureVerifiers[agendrixVendorId] =
      const AgendrixWebhookSignatureVerifier();

  // ─── Labor — Humanity ──────────────────────────────────────────────
  final humanitySink = HumanityPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  if (projectorWiringActive) {
    wrap(
      vendorId: kHumanityVendorId,
      category: IntegrationCategory.labor,
      underlying: humanitySink,
    );
  }
  // Humanity uses an app-wide OAuth client_id / client_secret pair the
  // proxy bootstrap has not yet surfaced as typed records (PR #260
  // covered Aloha / Square / Clover). Until those secrets land, the
  // refresh closure resolves the pair from the per-tenant credential
  // bundle (where bridges may also persist app-wide values during the
  // staging shape). We thread null-safe blanks; the closure throws
  // VendorRefreshFailed at refresh time when the bundle does not
  // surface them, which the framework surfaces as a reconnect prompt.
  laborAdapterFactories[kHumanityVendorId] = ({
    required String operatorId,
    required String locationId,
  }) {
    final humanityRefresh = makeHumanityOauthRefreshClosure(
      httpClient: sharedHttpClient,
      // Humanity bridges thread the app-wide pair via metadata until a
      // typed ProxyConfig accessor lands.
      clientId: '',
      clientSecret: '',
    );
    // Construct a per-tenant bridge so refresh + revoke paths run with
    // the right (operator, location) tuple wired in.
    HumanityBrokerCredentialBridge(
      broker: broker,
      operatorId: operatorId,
      locationId: locationId,
      oauthRefresh: humanityRefresh,
    );
    final transport = HumanityLaborProductionApiClient(
      httpClient: sharedHttpClient,
    );
    return HumanityLaborAdapter(
      httpClient: transport,
      gateway: humanitySink,
    );
  };
  signatureVerifiers[kHumanityVendorId] =
      const HumanityWebhookSignatureVerifier();

  // ─── Labor — Push Operations ───────────────────────────────────────
  final pushOpsSink = PushOperationsPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  if (projectorWiringActive) {
    wrap(
      vendorId: pushOperationsVendorId,
      category: IntegrationCategory.labor,
      underlying: pushOpsSink,
    );
  }
  final pushOpsBearerResolver = makePushOperationsBearerResolver(broker: broker);
  laborAdapterFactories[pushOperationsVendorId] = ({
    required String operatorId,
    required String locationId,
  }) {
    final transport = PushOperationsLaborProductionApiClient(
      bearerResolver: pushOpsBearerResolver,
      httpClient: sharedHttpClient,
    );
    return PushOperationsLaborAdapter(
      apiClient: transport,
      canonicalSink: pushOpsSink,
    );
  };
  signatureVerifiers[pushOperationsVendorId] =
      const PushOperationsWebhookSignatureVerifier();

  // ─── Labor — QuickBooks Time ───────────────────────────────────────
  final qbtSink = QuickBooksTimePostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  if (projectorWiringActive) {
    wrap(
      vendorId: kQuickBooksTimeVendorId,
      category: IntegrationCategory.labor,
      underlying: qbtSink,
    );
  }
  // QuickBooks Time uses an app-wide Intuit client_id / client_secret
  // pair the bootstrap has not yet surfaced as a typed record. We
  // currently thread null-safe blanks; the refresh closure throws on
  // refresh until those secrets are loaded. Optional vendor warn-list
  // surfaces the missing pair at boot.
  final qbtClientId =
      env['INTUIT_OAUTH_CLIENT_ID'] ?? env['QBT_OAUTH_CLIENT_ID'] ?? '';
  final qbtClientSecret =
      env['INTUIT_OAUTH_CLIENT_SECRET'] ?? env['QBT_OAUTH_CLIENT_SECRET'] ?? '';
  if (qbtClientId.isEmpty || qbtClientSecret.isEmpty) {
    disabledVendors[kQuickBooksTimeVendorId] = 'intuit_oauth_credentials_missing';
  } else {
    final qbtRefresh = makeQuickBooksTimeOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: qbtClientId,
      clientSecret: qbtClientSecret,
    );
    final qbtOauthCreds = StaticQuickBooksTimeBrokerOauthClientCredentials(
      clientId: qbtClientId,
      clientSecret: qbtClientSecret,
    );
    laborAdapterFactories[kQuickBooksTimeVendorId] = ({
      required String operatorId,
      required String locationId,
    }) {
      final credStore = QuickBooksTimeBrokerCredentialStore(
        broker: broker,
        operatorId: operatorId,
        locationId: locationId,
        oauthRefresh: qbtRefresh,
      );
      final transport = QuickBooksTimeLaborProductionApiClient(
        QuickBooksTimeProductionApiClientDeps(
          credentials: credStore,
          oauthCredentials: qbtOauthCreds,
          httpClient: sharedHttpClient,
        ),
      );
      return QuickBooksTimeLaborAdapter(
        transport: transport,
        gateway: qbtSink,
      );
    };
    signatureVerifiers[kQuickBooksTimeVendorId] =
        const QuickBooksTimeWebhookSignatureVerifier();
  }

  // ─── Labor — 7shifts ───────────────────────────────────────────────
  final sevenShiftsSink = SevenShiftsPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  if (projectorWiringActive) {
    wrap(
      vendorId: 'seven_shifts',
      category: IntegrationCategory.labor,
      underlying: sevenShiftsSink,
    );
  }
  // 7shifts uses an app-wide partner registration. Until the typed
  // ProxyConfig accessor lands, env reads are the staging shape.
  final sevenShiftsClientId = env['SEVEN_SHIFTS_OAUTH_CLIENT_ID'] ?? '';
  final sevenShiftsClientSecret = env['SEVEN_SHIFTS_OAUTH_CLIENT_SECRET'] ?? '';
  if (sevenShiftsClientId.isEmpty || sevenShiftsClientSecret.isEmpty) {
    disabledVendors['seven_shifts'] = 'seven_shifts_oauth_credentials_missing';
  } else {
    final sevenShiftsRefresh = makeSevenShiftsOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: sevenShiftsClientId,
      clientSecret: sevenShiftsClientSecret,
    );
    laborAdapterFactories['seven_shifts'] = ({
      required String operatorId,
      required String locationId,
    }) {
      final accessTokenProvider =
          seven_shifts_bridge.makeSevenShiftsAccessTokenProvider(
        broker: broker,
        operatorId: operatorId,
        locationId: locationId,
        oauthRefresh: sevenShiftsRefresh,
      );
      final transport = SevenShiftsApiClient(
        deps: SevenShiftsApiClientDeps(
          accessTokenProvider: accessTokenProvider,
          httpClient: sharedHttpClient,
        ),
      );
      return SevenShiftsLaborAdapter(
        transport: transport,
        gateway: sevenShiftsSink,
      );
    };
    signatureVerifiers['seven_shifts'] =
        const SevenShiftsWebhookSignatureVerifier();
  }

  // ─── Reservation — Libro ───────────────────────────────────────────
  final libroSink = LibroPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  // Libro / OpenTable / Tock / SevenRooms expose their CanonicalSink
  // surface as a private view inside the sink file (e.g.
  // `_LibroCanonicalSinkView`); the public sink class implements only
  // the vendor gateway. Until those views surface as public getters,
  // the projecting wrapper cannot front them. Out of scope for this
  // wire-in lane (vendor sink files are read-only here).
  final libroClientId = env['LIBRO_OAUTH_CLIENT_ID'] ?? '';
  final libroClientSecret = env['LIBRO_OAUTH_CLIENT_SECRET'] ?? '';
  if (libroClientId.isEmpty || libroClientSecret.isEmpty) {
    disabledVendors[kLibroVendorId] = 'libro_oauth_credentials_missing';
  } else {
    final libroRefresh = makeLibroOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: libroClientId,
      clientSecret: libroClientSecret,
    );
    reservationAdapterFactories[kLibroVendorId] = ({
      required String operatorId,
      required String locationId,
    }) {
      final bearerResolver = makeLibroBearerTokenResolver(
        broker: broker,
        operatorId: operatorId,
        locationId: locationId,
        oauthRefresh: libroRefresh,
      );
      final transport = LibroReservationProductionApiClient(
        bearerTokenResolver: bearerResolver,
        httpClient: sharedHttpClient,
      );
      return LibroReservationAdapter(
        gateway: libroSink,
        httpClient: transport,
        timezoneConverter: LibroIanaConverter(),
      );
    };
    signatureVerifiers[kLibroVendorId] = const LibroWebhookSignatureVerifier();
  }

  // ─── Reservation — OpenTable ───────────────────────────────────────
  final opentableSink = OpenTableReservationPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  // OpenTable's CanonicalSink view is internal (see Libro note above).
  reservationAdapterFactories[kOpenTableVendorId] = ({
    required String operatorId,
    required String locationId,
  }) {
    final credentialStore = OpenTableBrokerCredentialStore(
      broker: broker,
      operatorId: operatorId,
      locationId: locationId,
    );
    final transport = OpenTableReservationProductionApiClient(
      httpClient: sharedHttpClient,
      credentialStore: credentialStore,
    );
    return OpenTableReservationAdapter(
      transport: transport,
      gateway: opentableSink,
    );
  };
  signatureVerifiers[kOpenTableVendorId] =
      const OpenTableWebhookSignatureVerifier();

  // ─── Reservation — SevenRooms ──────────────────────────────────────
  // SevenRooms requires async per-(operator, location) location config
  // (timezone, rollover hour, webhook URL) at adapter construction
  // time, but the factory typedef is sync. Mark disabled-with-warn
  // until the framework gains an async factory variant. Webhook
  // ingestion still flows through the gateway-only path (verifier +
  // idempotency + binding cross-check); SevenRooms uses manualPaste so
  // it never auto-registers in any case.
  disabledVendors[kSevenRoomsVendorId] =
      'sevenrooms_async_location_config_required';
  signatureVerifiers[kSevenRoomsVendorId] =
      const SevenRoomsWebhookSignatureVerifier();

  // ─── Reservation — Tock ────────────────────────────────────────────
  final tockSink = TockReservationPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  // Tock's CanonicalSink view is internal (see Libro note above).
  reservationAdapterFactories[kTockVendorId] = ({
    required String operatorId,
    required String locationId,
  }) {
    final resolver = TockBrokerCredentialResolver(
      broker: broker,
      operatorId: operatorId,
      locationId: locationId,
    );
    final transport = TockReservationProductionApiClient(
      credentialResolver: resolver,
      httpClient: sharedHttpClient,
    );
    return TockReservationAdapter(
      transport: transport,
      factSink: tockSink,
    );
  };
  signatureVerifiers[kTockVendorId] = const TockWebhookSignatureVerifier();

  // Step 5 — InboundWebhookHandler.
  final webhookHandler = InboundWebhookHandler(
    gateway: inboundWebhookGateway,
    posAdapterFactories: posAdapterFactories,
    laborAdapterFactories: laborAdapterFactories,
    reservationAdapterFactories: reservationAdapterFactories,
    signatureVerifiers: signatureVerifiers,
    bindingExtractor: WebhookBindingExtractor(),
  );

  // Step 6 — Adapt the tool-side admin actor types into the lib-side
  // bridge seam. Both adapters are private to this binder file.
  final adminActorJwtVerifier =
      _ToolToLibActorJwtVerifierAdapter(proxyJwtVerifier);
  final adminActorUserResolver = _ToolToLibActorUserResolverAdapter(
    productionBindings.integrationAdminActorResolver,
  );

  // Step 7 — Bindings holder + global install.
  final bindings = _Phase8BindingsHolder(
    gateway: _RepositoryToToolGatewayAdapter(integrationRoutesGateway),
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
  );
  Phase80IntegrationRoutes.globalBindings = bindings;
  _alreadyBound = true;

  log(
    LogSeverity.info,
    'startup.phase_8_binder.installed',
    fields: <String, Object?>{
      'webhook_public_base_uri': webhookPublicBaseUri.toString(),
      'pos_factories_wired': posAdapterFactories.keys.toList()..sort(),
      'labor_factories_wired': laborAdapterFactories.keys.toList()..sort(),
      'reservation_factories_wired':
          reservationAdapterFactories.keys.toList()..sort(),
      'signature_verifiers_wired': signatureVerifiers.keys.toList()..sort(),
      'disabled_vendors': disabledVendors,
      'projector_wiring_active': projectorWiringActive,
      'projecting_sinks_wired': projectingSinksByVendor.keys.toList()..sort(),
    },
  );

  // The wrapped sinks are reachable via the binder's module-level
  // accessor [phase8ProjectingSinksByVendor] for downstream worker
  // dispatch wiring. See file-header on `wrap` for the rationale.
  _phase8ProjectingSinksByVendor
    ..clear()
    ..addAll(projectingSinksByVendor);
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

/// Internal bindings holder.
class _Phase8BindingsHolder
    implements Phase80IntegrationRoutesBindingsHolder {
  _Phase8BindingsHolder({
    required this.gateway,
    required this.actorResolver,
    required this.webhookHandler,
    required this.firstBackfillEnqueueGateway,
    required this.integrationCategoryResolver,
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

class _ToolToLibActorJwtVerifierAdapter implements bridge.AdminActorJwtVerifier {
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
class _RepositoryToToolGatewayAdapter implements IntegrationRoutesGateway {
  _RepositoryToToolGatewayAdapter(this._inner);

  final RepositoryIntegrationRoutesGateway _inner;

  @override
  Future<Map<String, Object?>> listForLocation({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) =>
      _inner.listForLocation(
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
  }) =>
      _inner.startOAuth(
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
  }) =>
      _inner.handleOAuthCallback(
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
  }) =>
      _inner.connectViaKeyPaste(
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
  }) =>
      _inner.testConnection(
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
  }) =>
      _inner.disconnect(
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
  }) =>
      _inner.listSyncLogs(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        limit: limit,
      );

  @override
  Future<bool> hasIntegrationsConfigurePermission({
    required String operatorId,
    required String userId,
  }) =>
      _inner.hasIntegrationsConfigurePermission(
        operatorId: operatorId,
        userId: userId,
      );
}
