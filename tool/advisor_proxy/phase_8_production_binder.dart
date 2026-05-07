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
import 'package:forge_and_flow/infrastructure/persistence/postgres/lightspeed_lsk_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/push_operations_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/revel_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/seven_shifts_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/sevenrooms_reservation_postgres_sink.dart';
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
import 'package:forge_and_flow/integrations/pos/lightspeed_lsk_credential_bridge.dart'
    hide kLightspeedLskVendorId;
import 'package:forge_and_flow/integrations/pos/lightspeed_lsk_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/lightspeed_lsk_pos_production_api_client.dart';
import 'package:forge_and_flow/integrations/pos/lightspeed_lsk_webhook_signature_verifier.dart';
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
import 'package:forge_and_flow/integrations/reservation/sevenrooms_credential_bridge.dart'
    hide kSevenRoomsVendorId;
import 'package:forge_and_flow/integrations/reservation/sevenrooms_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_reservation_production_api_client.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_webhook_signature_verifier.dart';
import 'package:forge_and_flow/integrations/reservation/tock_credential_bridge.dart';
import 'package:forge_and_flow/integrations/reservation/tock_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/tock_reservation_production_api_client.dart';
import 'package:forge_and_flow/integrations/reservation/tock_webhook_signature_verifier.dart'
    hide kTockVendorId;
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/per_tenant_location_config_resolver.dart';
import 'package:forge_and_flow/services/integration/repository_inbound_webhook_gateway.dart';
import 'package:forge_and_flow/services/integration/repository_integration_routes_gateway.dart';

import 'admin_integrations_routes.dart';
import 'advisor_proxy.dart';
import 'proxy_bootstrap.dart';

/// Default public base URI the framework presents to vendors as the
/// inbound webhook host. Retained as a documentation-only reference
/// of the canonical production hostname; the binder no longer reads
/// it. Phase 8's typed-app-credentials amendment moved the public
/// base URI to the required [ProxySecretNames.publicBaseUri] env var
/// surfaced through [ProxyConfig.publicBaseUri].
const String kPhase8DefaultWebhookPublicBaseUri = 'https://api.forgeflow.app';

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
/// Idempotent — a second call is a no-op. Demo mode (`kDemoMode=true`)
/// skips the binder entirely with a single info line.
Future<void> bindPhase8IntegrationsForProduction(
  ProxyProductionBindings productionBindings,
  ProxyConfig proxyConfig, {
  required ProxyJwtVerifier proxyJwtVerifier,
  http.Client? httpClient,
  Map<String, String>? environmentOverride,
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

  // Per the typed-app-credentials amendment, the public base URI is a
  // typed [Uri] surfaced through [ProxyConfig.publicBaseUri] (sourced
  // from the required `PUBLIC_BASE_URI` env var). The
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

  // ─── POS — Toast (PR #247 refresh closure) ──────────────────────────
  final toastSink = ToastPosPostgresSink(
    productionBindings.tenantTransactionWrapper,
  );
  final toastRefresh = makeToastOauthRefreshClosure(
    httpClient: sharedHttpClient,
  );
  // Each per-vendor factory is bound through an explicit
  // `PosAdapterFactory` cast at the assignment site. Dart's contextual
  // inference would otherwise pick the concrete adapter subtype as the
  // closure's `Future<T>` parameter, and `Future<T>` is invariant — a
  // `Future<ToastPosAdapter> Function(...)` is NOT a subtype of
  // `Future<PosAdapter> Function(...)`. The cast widens the closure's
  // return type to the typedef's expected `Future<PosAdapter>`.
  posAdapterFactories[kToastVendorId] = ({
    required String operatorId,
    required String locationId,
  }) async {
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
  } as PosAdapterFactory;
  signatureVerifiers[kToastVendorId] = const ToastWebhookSignatureVerifier();

  // ─── POS — Aloha NCR Voyix (optional static app credentials) ───────
  final alohaSink = AlohaNcrVoyixPostgresSink(
    productionBindings.tenantTransactionWrapper,
  );
  if (proxyConfig.hasAlohaNcrVoyixCredentials) {
    final alohaCreds = proxyConfig.alohaNcrVoyixCredentials;
    final alohaRefresh = makeAlohaNcrVoyixOauthRefreshClosure(
      httpClient: sharedHttpClient,
    );
    posAdapterFactories[kAlohaNcrVoyixVendorId] = ({
      required String operatorId,
      required String locationId,
    }) async {
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
    } as PosAdapterFactory;
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
    }) async {
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
    } as PosAdapterFactory;
    signatureVerifiers[kCloverVendorId] = const CloverWebhookSignatureVerifier();
  } else {
    disabledVendors[kCloverVendorId] = 'clover_app_credentials_missing';
  }

  // ─── POS — Lightspeed LSK ──────────────────────────────────────────
  // Lightspeed's adapter takes per-tenant timezone + rollover-hour +
  // webhookUrl values from `PerTenantLocationConfigResolver`. With the
  // factory typedefs now async (PR for `8.framework.async-adapter-factories`),
  // the closure can `await` the resolver before constructing the
  // adapter. OAuth + webhook subscribe paths run only at connect /
  // disconnect time; the inbound-webhook handler only ever invokes
  // `handleWebhook`, which uses the gateway alone. The connect-time
  // clients are wired with binder-only stubs that throw with a clear
  // message so a regression that triggers them surfaces immediately;
  // the connect/disconnect hot path is wired separately by the admin-
  // routes binding (which materialises a fully-formed transport).
  final lightspeedLskSink = LightspeedLskPosPostgresSink(
    productionBindings.tenantTransactionWrapper,
  );
  final lightspeedLskRefresh = makeLightspeedLskOauthRefreshClosure(
    httpClient: sharedHttpClient,
  );
  posAdapterFactories[kLightspeedLskVendorId] = ({
    required String operatorId,
    required String locationId,
  }) async {
    final config = await locationConfigResolver.resolve(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kLightspeedLskVendorId,
    );
    final tokenResolver = LightspeedLskBrokerAccessTokenResolver(
      broker: broker,
      operatorId: operatorId,
      locationId: locationId,
      oauthRefresh: lightspeedLskRefresh,
    );
    final ordersClient = LightspeedLskProductionOrdersClient(
      tokenResolver: tokenResolver,
      httpClient: sharedHttpClient,
    );
    return LightspeedLskPosAdapter(
      gateway: lightspeedLskSink,
      oauthClient: const _UnboundLightspeedLskOAuthClient(),
      webhookClient: const _UnboundLightspeedLskWebhookClient(),
      ordersClient: ordersClient,
      restaurantTimezone: config.restaurantTimezone,
      businessDayRolloverHour: config.businessDayRolloverHour,
      webhookUrl: config.webhookBaseUri.toString(),
    );
  } as PosAdapterFactory;
  signatureVerifiers[kLightspeedLskVendorId] =
      const LightspeedLskWebhookSignatureVerifier();

  // ─── POS — Oracle MICROS Simphony ──────────────────────────────────
  final oracleSink = OracleMicrosSimphonyPostgresSink(
    productionBindings.tenantTransactionWrapper,
  );
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
  }) async {
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
  } as PosAdapterFactory;
  signatureVerifiers[kOracleMicrosSimphonyVendorId] =
      const OracleMicrosSimphonyWebhookSignatureVerifier();

  // ─── POS — Revel ───────────────────────────────────────────────────
  final revelSink = RevelPosPostgresSink(
    productionBindings.tenantTransactionWrapper,
  );
  posAdapterFactories[kRevelVendorId] = ({
    required String operatorId,
    required String locationId,
  }) async {
    final transport = RevelProductionApiClient(
      deps: RevelProductionApiClientDeps(
        httpClient: sharedHttpClient,
      ),
    );
    return RevelPosAdapter(
      transport: transport,
      gateway: revelSink,
    );
  } as PosAdapterFactory;
  signatureVerifiers[kRevelVendorId] = const RevelWebhookSignatureVerifier();

  // ─── POS — Square (optional static app credentials) ────────────────
  if (proxyConfig.hasSquareAppCredentials) {
    final squareSink = SquarePosPostgresSink(
      productionBindings.tenantTransactionWrapper,
    );
    final squareAppCreds = proxyConfig.squareAppCredentials;
    final squareRefresh = makeSquareOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: squareAppCreds.clientId,
      clientSecret: squareAppCreds.clientSecret,
    );
    posAdapterFactories[kSquareVendorId] = ({
      required String operatorId,
      required String locationId,
    }) async {
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
    } as PosAdapterFactory;
    signatureVerifiers[kSquareVendorId] = const SquareWebhookSignatureVerifier();
  } else {
    disabledVendors[kSquareVendorId] = 'square_app_credentials_missing';
  }

  // ─── Labor — ADP ───────────────────────────────────────────────────
  final adpSink = AdpPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  laborAdapterFactories[kAdpVendorId] = ({
    required String operatorId,
    required String locationId,
  }) async {
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
  } as LaborAdapterFactory;
  signatureVerifiers[kAdpVendorId] = const AdpWebhookSignatureVerifier();

  // ─── Labor — Agendrix ──────────────────────────────────────────────
  final agendrixSink = AgendrixPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  final agendrixCredentialStore = AgendrixBrokerCredentialStore(broker: broker);
  laborAdapterFactories[agendrixVendorId] = ({
    required String operatorId,
    required String locationId,
  }) async {
    final transport = AgendrixProductionApiClient(
      credentialStore: agendrixCredentialStore,
      httpClient: sharedHttpClient,
    );
    return AgendrixLaborAdapter(
      apiClient: transport,
      canonicalSink: agendrixSink,
    );
  } as LaborAdapterFactory;
  signatureVerifiers[agendrixVendorId] =
      const AgendrixWebhookSignatureVerifier();

  // ─── Labor — Humanity ──────────────────────────────────────────────
  final humanitySink = HumanityPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  // Humanity uses an app-wide OAuth client_id / client_secret pair
  // surfaced through [ProxyConfig.humanityAppCredentials]. Mirrors the
  // Aloha / Square / Clover warn-and-disable shape from PR #260: when
  // the typed record is absent at boot, the vendor lands on the
  // disabled-warn list and the per-tenant factory is NOT registered.
  if (!proxyConfig.hasHumanityAppCredentials) {
    disabledVendors[kHumanityVendorId] = 'humanity_oauth_credentials_missing';
  } else {
    final humanityCreds = proxyConfig.humanityAppCredentials;
    final humanityRefresh = makeHumanityOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: humanityCreds.clientId,
      clientSecret: humanityCreds.clientSecret,
    );
    laborAdapterFactories[kHumanityVendorId] = ({
      required String operatorId,
      required String locationId,
    }) async {
      // Construct a per-tenant bridge so refresh + revoke paths run
      // with the right (operator, location) tuple wired in.
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
    } as LaborAdapterFactory;
    signatureVerifiers[kHumanityVendorId] =
        const HumanityWebhookSignatureVerifier();
  }

  // ─── Labor — Push Operations ───────────────────────────────────────
  final pushOpsSink = PushOperationsPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  final pushOpsBearerResolver = makePushOperationsBearerResolver(broker: broker);
  laborAdapterFactories[pushOperationsVendorId] = ({
    required String operatorId,
    required String locationId,
  }) async {
    final transport = PushOperationsLaborProductionApiClient(
      bearerResolver: pushOpsBearerResolver,
      httpClient: sharedHttpClient,
    );
    return PushOperationsLaborAdapter(
      apiClient: transport,
      canonicalSink: pushOpsSink,
    );
  } as LaborAdapterFactory;
  signatureVerifiers[pushOperationsVendorId] =
      const PushOperationsWebhookSignatureVerifier();

  // ─── Labor — QuickBooks Time ───────────────────────────────────────
  final qbtSink = QuickBooksTimePostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  // QuickBooks Time uses an app-wide Intuit client_id / client_secret
  // pair surfaced through [ProxyConfig.quickBooksTimeAppCredentials].
  // Same warn-and-disable shape as the other optional vendors.
  if (!proxyConfig.hasQuickBooksTimeAppCredentials) {
    disabledVendors[kQuickBooksTimeVendorId] =
        'intuit_oauth_credentials_missing';
  } else {
    final qbtCreds = proxyConfig.quickBooksTimeAppCredentials;
    final qbtRefresh = makeQuickBooksTimeOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: qbtCreds.clientId,
      clientSecret: qbtCreds.clientSecret,
    );
    final qbtOauthCreds = StaticQuickBooksTimeBrokerOauthClientCredentials(
      clientId: qbtCreds.clientId,
      clientSecret: qbtCreds.clientSecret,
    );
    laborAdapterFactories[kQuickBooksTimeVendorId] = ({
      required String operatorId,
      required String locationId,
    }) async {
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
    } as LaborAdapterFactory;
    signatureVerifiers[kQuickBooksTimeVendorId] =
        const QuickBooksTimeWebhookSignatureVerifier();
  }

  // ─── Labor — 7shifts ───────────────────────────────────────────────
  final sevenShiftsSink = SevenShiftsPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  // 7shifts uses an app-wide partner registration surfaced through
  // [ProxyConfig.sevenShiftsAppCredentials]. Same warn-and-disable
  // shape as the other optional vendors.
  if (!proxyConfig.hasSevenShiftsAppCredentials) {
    disabledVendors['seven_shifts'] = 'seven_shifts_oauth_credentials_missing';
  } else {
    final sevenShiftsCreds = proxyConfig.sevenShiftsAppCredentials;
    final sevenShiftsRefresh = makeSevenShiftsOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: sevenShiftsCreds.clientId,
      clientSecret: sevenShiftsCreds.clientSecret,
    );
    laborAdapterFactories['seven_shifts'] = ({
      required String operatorId,
      required String locationId,
    }) async {
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
    } as LaborAdapterFactory;
    signatureVerifiers['seven_shifts'] =
        const SevenShiftsWebhookSignatureVerifier();
  }

  // ─── Reservation — Libro ───────────────────────────────────────────
  final libroSink = LibroPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  // Libro uses an app-wide registration surfaced through
  // [ProxyConfig.libroAppCredentials]. Same warn-and-disable shape as
  // the other optional vendors.
  if (!proxyConfig.hasLibroAppCredentials) {
    disabledVendors[kLibroVendorId] = 'libro_oauth_credentials_missing';
  } else {
    final libroCreds = proxyConfig.libroAppCredentials;
    final libroRefresh = makeLibroOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: libroCreds.clientId,
      clientSecret: libroCreds.clientSecret,
    );
    reservationAdapterFactories[kLibroVendorId] = ({
      required String operatorId,
      required String locationId,
    }) async {
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
    } as ReservationAdapterFactory;
    signatureVerifiers[kLibroVendorId] = const LibroWebhookSignatureVerifier();
  }

  // ─── Reservation — OpenTable ───────────────────────────────────────
  final opentableSink = OpenTableReservationPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  reservationAdapterFactories[kOpenTableVendorId] = ({
    required String operatorId,
    required String locationId,
  }) async {
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
  } as ReservationAdapterFactory;
  signatureVerifiers[kOpenTableVendorId] =
      const OpenTableWebhookSignatureVerifier();

  // ─── Reservation — SevenRooms ──────────────────────────────────────
  // SevenRooms requires async per-(operator, location) location config
  // (timezone, rollover hour, webhook URL) at adapter construction.
  // With async factories the closure can `await` the resolver before
  // building the adapter. SevenRooms is `manualPaste`, so the webhook
  // client must NEVER be invoked by the adapter — the production
  // webhook impl throws on subscribe and the adapter test asserts no
  // calls. Auth runs only at connect time, not on `handleWebhook`, so
  // we share the production transport surface across factory
  // invocations: each factory builds a fresh credential store keyed
  // on the live `(operator, location)` and threads it into a shared
  // `SevenRoomsTransportDeps`.
  final sevenRoomsSink = SevenRoomsReservationPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  reservationAdapterFactories[kSevenRoomsVendorId] = ({
    required String operatorId,
    required String locationId,
  }) async {
    final config = await locationConfigResolver.resolve(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: kSevenRoomsVendorId,
    );
    final credentialStore = SevenRoomsBrokerCredentialStore(
      broker: broker,
      operatorId: operatorId,
      locationId: locationId,
    );
    final transportDeps = SevenRoomsTransportDeps.shared(
      credentialStore: credentialStore,
      httpClient: sharedHttpClient,
    );
    final authClient = transportDeps.buildAuthClient();
    final reservationsClient = transportDeps.buildReservationsClient(
      // Production threads the per-operator credential id from the
      // live binding (looked up by the adapter at backfill / poll
      // time). For factory construction we pass an empty string; the
      // adapter looks up the binding before any API call so the
      // empty placeholder is never the value used on the wire.
      credentialIdForRequest: '',
    );
    return SevenRoomsReservationAdapter(
      gateway: sevenRoomsSink,
      authClient: authClient,
      webhookClient: const SevenRoomsWebhookProductionApiClient(),
      reservationsClient: reservationsClient,
      restaurantTimezone: config.restaurantTimezone,
      businessDayRolloverHour: config.businessDayRolloverHour,
      webhookUrl: config.webhookBaseUri.toString(),
    );
  } as ReservationAdapterFactory;
  signatureVerifiers[kSevenRoomsVendorId] =
      const SevenRoomsWebhookSignatureVerifier();

  // ─── Reservation — Tock ────────────────────────────────────────────
  final tockSink = TockReservationPostgresSink(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
  );
  reservationAdapterFactories[kTockVendorId] = ({
    required String operatorId,
    required String locationId,
  }) async {
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
  } as ReservationAdapterFactory;
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
    },
  );
}

/// Test helper. Production never invokes this; tests call it between
/// cases so each can assert against a freshly-installed holder.
void resetPhase8BinderForTests() {
  _alreadyBound = false;
  Phase80IntegrationRoutes.globalBindings = null;
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

/// Binder-local stub for [LightspeedLskOAuthClient]. Lightspeed OAuth
/// flows (authorization-code + refresh + revoke) are exercised only
/// during connect / disconnect, not during inbound webhook dispatch.
/// The per-tenant adapter factory in this binder is only consulted by
/// `InboundWebhookHandler.dispatch`, which calls `handleWebhook`. If a
/// future wiring routes a connect / disconnect through this adapter
/// instance, this stub fails fast with a typed `StateError` so the
/// regression surfaces immediately at the boundary instead of silently
/// no-oping.
class _UnboundLightspeedLskOAuthClient implements LightspeedLskOAuthClient {
  const _UnboundLightspeedLskOAuthClient();

  @override
  Future<LightspeedLskTokenExchangeResult> completeAuthorization({
    required String oauthState,
  }) {
    throw StateError(
      '_UnboundLightspeedLskOAuthClient.completeAuthorization MUST NOT be '
      'called from the inbound-webhook factory; the connect flow is wired '
      'separately by the admin-routes binding.',
    );
  }

  @override
  Future<LightspeedLskTokenExchangeResult> refresh({
    required String refreshTokenCredentialId,
  }) {
    throw StateError(
      '_UnboundLightspeedLskOAuthClient.refresh MUST NOT be called from the '
      'inbound-webhook factory; refresh runs from the OAuth refresh cron, '
      'which holds its own LightspeedLskOAuthClient.',
    );
  }

  @override
  Future<void> revoke({required String accessTokenCredentialId}) {
    throw StateError(
      '_UnboundLightspeedLskOAuthClient.revoke MUST NOT be called from the '
      'inbound-webhook factory; the disconnect flow is wired separately by '
      'the admin-routes binding.',
    );
  }
}

/// Binder-local stub for [LightspeedLskWebhookClient]. Lightspeed
/// webhook subscribe / unregister run only during connect / disconnect,
/// not on inbound webhook dispatch. Same rationale as
/// [_UnboundLightspeedLskOAuthClient].
class _UnboundLightspeedLskWebhookClient implements LightspeedLskWebhookClient {
  const _UnboundLightspeedLskWebhookClient();

  @override
  Future<LightspeedLskWebhookSubscription> subscribe({
    required String accessTokenCredentialId,
    required String webhookUrl,
    required String endpointId,
  }) {
    throw StateError(
      '_UnboundLightspeedLskWebhookClient.subscribe MUST NOT be called from '
      'the inbound-webhook factory; the connect flow is wired separately by '
      'the admin-routes binding.',
    );
  }

  @override
  Future<void> unregister({
    required String accessTokenCredentialId,
    required String subscriptionId,
  }) {
    throw StateError(
      '_UnboundLightspeedLskWebhookClient.unregister MUST NOT be called from '
      'the inbound-webhook factory; the disconnect flow is wired separately '
      'by the admin-routes binding.',
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
