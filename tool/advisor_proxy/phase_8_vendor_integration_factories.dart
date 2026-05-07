// Phase 8 framework — per-vendor adapter factory builder.
//
// Single source of truth for the per-vendor `(operatorId, locationId) ->
// adapter` closures the proxy binder
// (`phase_8_production_binder.dart`) installs into
// `Phase80IntegrationRoutes.globalBindings` AND the first-connect
// backfill worker (`tool/first_connect_backfill_worker/main.dart`)
// uses to dispatch claimed jobs.
//
// This file is split out of `phase_8_production_binder.dart` so the
// backfill worker can pull in the builder without dragging
// `proxy_bootstrap.dart` (and its admin-pool / Firebase / LLM
// machinery) into the worker compilation graph. The binder itself
// re-exports the symbols it needs and remains the only callsite that
// reaches into `proxy_bootstrap.dart`.
//
// Amendment A (async adapter factories) + Amendment B (typed app
// credentials + `publicBaseUri`) are observed inline:
//
//   * Every per-vendor closure is `Future<...>`-returning (matches
//     `Future<PosAdapter> Function({required String operatorId,
//     required String locationId})` etc.). Closures are bound through
//     an explicit `as PosAdapterFactory` / `as LaborAdapterFactory` /
//     `as ReservationAdapterFactory` cast at the assignment site —
//     Dart's contextual inference would otherwise pick the concrete
//     adapter subtype as the closure's `Future<T>` parameter, and
//     `Future<T>` is invariant.
//   * Optional vendors (Aloha / Square / Clover / Humanity /
//     QuickBooks Time / 7shifts / Libro) take typed `*AppCredentials`
//     records as nullable parameters; `null` means the binder elected
//     to skip them and the vendor lands on the `disabledVendors`
//     warn-list.
//   * The `webhookPublicBaseUri` parameter is a typed [Uri] sourced
//     from `ProxyConfig.publicBaseUri`; the binder threads it through
//     here so factories that compose `/v1/webhooks/...` callback URLs
//     (Clover, Square, Lightspeed LSK, SevenRooms) all see the same
//     value.
//
// CLAUDE.md alignment:
//
//   * Hard Promise #1 (transport-only) — every adapter writes existing
//     SQLite/Postgres canonical tables only.
//   * Hard Promise #4 (per-operator isolation) — every credential
//     resolution / fact write rides `OperatorScopedRepository.withTenant`.
//   * Hard Promise #7 (server-side keys) — vendor app credentials and
//     the pgcrypto envelope key never leave the process.

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
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart';
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

import 'advisor_proxy.dart'
    show
        CloverAppCredentials,
        HumanityAppCredentials,
        LibroAppCredentials,
        QuickBooksTimeAppCredentials,
        SevenShiftsAppCredentials,
        SquareAppCredentials;

/// Default public base URI the framework presents to vendors as the
/// inbound webhook host. Retained as a documentation-only reference of
/// the canonical production hostname; the binder no longer reads it.
/// Phase 8's typed-app-credentials amendment moved the public base URI
/// to the required `PUBLIC_BASE_URI` env var surfaced through
/// `ProxyConfig.publicBaseUri`. Kept here (rather than inside the
/// binder) so callers that don't pull `proxy_bootstrap` in — notably
/// the first-connect backfill worker — can still resolve the same
/// default when they construct their own `Uri` for tests.
const String kPhase8DefaultWebhookPublicBaseUri = 'https://api.forgeflow.app';

/// Env var name a caller may consult for an explicit override of
/// [kPhase8DefaultWebhookPublicBaseUri]. The proxy binder no longer
/// reads it (the typed `ProxyConfig.publicBaseUri` is the canonical
/// surface); the first-connect backfill worker keeps it as a fallback
/// so tests can stub a value without booting the full proxy config
/// loader.
const String kPhase8WebhookPublicBaseUriEnvName = 'FF_WEBHOOK_PUBLIC_BASE_URI';

/// Bundle returned by [buildPhase8VendorIntegrationFactoriesFromCredentials].
/// Holds the per-vendor adapter factory maps, signature verifiers, and
/// the disabled-vendor warn list assembled from the same vendor-by-
/// vendor branches the binder uses to wire the proxy. Both
/// `bindPhase8IntegrationsForProduction` (which assigns the result to
/// the framework `globalBindings`) and the first-connect backfill
/// worker (which only needs the maps) call the same builder so the
/// per-vendor wiring stays single-sourced.
class Phase8VendorIntegrationFactories {
  const Phase8VendorIntegrationFactories({
    required this.posAdapterFactories,
    required this.laborAdapterFactories,
    required this.reservationAdapterFactories,
    required this.signatureVerifiers,
    required this.disabledVendors,
  });

  /// POS adapter factories keyed by vendor id (URL-path form).
  final Map<String, PosAdapterFactory> posAdapterFactories;

  /// Labor adapter factories keyed by vendor id (URL-path form).
  final Map<String, LaborAdapterFactory> laborAdapterFactories;

  /// Reservation adapter factories keyed by vendor id (URL-path form).
  final Map<String, ReservationAdapterFactory> reservationAdapterFactories;

  /// Webhook signature verifiers keyed by vendor id.
  final Map<String, VendorWebhookSignatureVerifier> signatureVerifiers;

  /// Vendors that the binder elected to skip with a structured reason.
  /// The first-connect backfill worker reuses this map to dead-letter
  /// claimed jobs whose vendor is not active in the current binder
  /// configuration (missing static app credentials, async-only location
  /// config, etc.) instead of throwing a stack-traced StateError.
  final Map<String, String> disabledVendors;
}

/// Build the per-vendor adapter factory closures, signature verifiers,
/// and disabled-vendor warn list shared between the proxy binder and
/// the first-connect backfill worker.
///
/// Optional static-app credentials are passed directly here (instead
/// of via a `ProxyConfig` accessor) so callers that don't construct
/// the full proxy bootstrap — notably the backfill worker — can call
/// the builder without dragging the rest of the proxy compilation
/// graph in. The `phase_8_production_binder.dart` wrapper threads the
/// bundles through `ProxyConfig.has<Vendor>AppCredentials`.
///
/// The disable-warn list mirrors PR #260's optional-vendor pattern: a
/// vendor whose static app credentials (Aloha / Square / Clover /
/// Humanity / QuickBooks Time / 7shifts / Libro) are missing is
/// skipped with a structured warning so the proxy still binds and the
/// worker can dead-letter the job with a clear reason.
Phase8VendorIntegrationFactories
    buildPhase8VendorIntegrationFactoriesFromCredentials({
  required TenantTransactionWrapper tenantTransactionWrapper,
  required VendorCredentialBroker broker,
  required PerTenantLocationConfigResolver locationConfigResolver,
  required http.Client sharedHttpClient,
  required Uri webhookPublicBaseUri,
  AlohaNcrVoyixOauthClientCredentials? alohaNcrVoyixCredentials,
  SquareAppCredentials? squareAppCredentials,
  CloverAppCredentials? cloverAppCredentials,
  HumanityAppCredentials? humanityAppCredentials,
  QuickBooksTimeAppCredentials? quickBooksTimeAppCredentials,
  SevenShiftsAppCredentials? sevenShiftsAppCredentials,
  LibroAppCredentials? libroAppCredentials,
}) {
  // The body uses `wrapper` as a short alias for the parameter so the
  // per-vendor branches read identically to the previous binder body
  // (where the wrapper came in as `productionBindings.tenantTransactionWrapper`).
  final wrapper = tenantTransactionWrapper;
  final disabledVendors = <String, String>{};
  final posAdapterFactories = <String, PosAdapterFactory>{};
  final laborAdapterFactories = <String, LaborAdapterFactory>{};
  final reservationAdapterFactories = <String, ReservationAdapterFactory>{};
  final signatureVerifiers = <String, VendorWebhookSignatureVerifier>{};

  // ─── POS — Toast (PR #247 refresh closure) ──────────────────────────
  final toastSink = ToastPosPostgresSink(wrapper);
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
  final alohaSink = AlohaNcrVoyixPostgresSink(wrapper);
  if (alohaNcrVoyixCredentials != null) {
    final alohaCreds = alohaNcrVoyixCredentials;
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
  if (cloverAppCredentials != null) {
    final cloverSink = CloverPostgresSink(wrapper);
    final cloverCredStore = CloverPosPostgresCredentialStore(wrapper);
    final cloverAppCreds = cloverAppCredentials;
    final cloverRefresh = makeCloverOauthRefreshClosure(
      httpClient: sharedHttpClient,
      clientId: cloverAppCreds.appId,
    );
    final appTokenSource = makeStaticCloverAppTokenSource(
      cloverAppCreds.appToken,
    );
    final appIdSource = makeStaticCloverAppIdSource(
      cloverAppCreds.appId,
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
        wrapper,
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
  // factory typedefs now async (Amendment A), the closure can `await`
  // the resolver before constructing the adapter. OAuth + webhook
  // subscribe paths run only at connect / disconnect time; the
  // inbound-webhook handler only ever invokes `handleWebhook`, which
  // uses the gateway alone. The connect-time clients are wired with
  // factory-only stubs that throw with a clear message so a regression
  // that triggers them surfaces immediately; the connect/disconnect
  // hot path is wired separately by the admin-routes binding (which
  // materialises a fully-formed transport).
  final lightspeedLskSink = LightspeedLskPosPostgresSink(wrapper);
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
  final oracleSink = OracleMicrosSimphonyPostgresSink(wrapper);
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
  final revelSink = RevelPosPostgresSink(wrapper);
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
  if (squareAppCredentials != null) {
    final squareSink = SquarePosPostgresSink(wrapper);
    final squareAppCreds = squareAppCredentials;
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
  final adpSink = AdpPostgresSink(tenantWrapper: wrapper);
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
  final agendrixSink = AgendrixPostgresSink(tenantWrapper: wrapper);
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

  // ─── Labor — Humanity (optional static app credentials) ────────────
  final humanitySink = HumanityPostgresSink(tenantWrapper: wrapper);
  // Humanity uses an app-wide OAuth client_id / client_secret pair
  // surfaced through `ProxyConfig.humanityAppCredentials`. Mirrors the
  // Aloha / Square / Clover warn-and-disable shape: when the typed
  // record is absent at boot, the vendor lands on the disabled-warn
  // list and the per-tenant factory is NOT registered.
  if (humanityAppCredentials == null) {
    disabledVendors[kHumanityVendorId] = 'humanity_oauth_credentials_missing';
  } else {
    final humanityCreds = humanityAppCredentials;
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
  final pushOpsSink = PushOperationsPostgresSink(tenantWrapper: wrapper);
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

  // ─── Labor — QuickBooks Time (optional static app credentials) ─────
  final qbtSink = QuickBooksTimePostgresSink(tenantWrapper: wrapper);
  // QuickBooks Time uses an app-wide Intuit client_id / client_secret
  // pair surfaced through `ProxyConfig.quickBooksTimeAppCredentials`.
  // Same warn-and-disable shape as the other optional vendors.
  if (quickBooksTimeAppCredentials == null) {
    disabledVendors[kQuickBooksTimeVendorId] =
        'intuit_oauth_credentials_missing';
  } else {
    final qbtCreds = quickBooksTimeAppCredentials;
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

  // ─── Labor — 7shifts (optional static app credentials) ─────────────
  final sevenShiftsSink = SevenShiftsPostgresSink(tenantWrapper: wrapper);
  // 7shifts uses an app-wide partner registration surfaced through
  // `ProxyConfig.sevenShiftsAppCredentials`. Same warn-and-disable
  // shape as the other optional vendors.
  if (sevenShiftsAppCredentials == null) {
    disabledVendors['seven_shifts'] = 'seven_shifts_oauth_credentials_missing';
  } else {
    final sevenShiftsCreds = sevenShiftsAppCredentials;
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

  // ─── Reservation — Libro (optional static app credentials) ─────────
  final libroSink = LibroPostgresSink(tenantWrapper: wrapper);
  // Libro uses an app-wide registration surfaced through
  // `ProxyConfig.libroAppCredentials`. Same warn-and-disable shape as
  // the other optional vendors.
  if (libroAppCredentials == null) {
    disabledVendors[kLibroVendorId] = 'libro_oauth_credentials_missing';
  } else {
    final libroCreds = libroAppCredentials;
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
  final opentableSink = OpenTableReservationPostgresSink(tenantWrapper: wrapper);
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
    tenantWrapper: wrapper,
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
  final tockSink = TockReservationPostgresSink(tenantWrapper: wrapper);
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

  return Phase8VendorIntegrationFactories(
    posAdapterFactories: posAdapterFactories,
    laborAdapterFactories: laborAdapterFactories,
    reservationAdapterFactories: reservationAdapterFactories,
    signatureVerifiers: signatureVerifiers,
    disabledVendors: disabledVendors,
  );
}

/// Builder-local stub for [LightspeedLskOAuthClient]. Lightspeed OAuth
/// flows (authorization-code + refresh + revoke) are exercised only
/// during connect / disconnect, not during inbound webhook dispatch
/// or a first-connection backfill (which only invokes
/// `handleWebhook` / `pollSince` paths). If a future wiring routes a
/// connect / disconnect through this adapter instance, this stub
/// fails fast with a typed [StateError] so the regression surfaces
/// immediately at the boundary instead of silently no-oping.
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

/// Builder-local stub for [LightspeedLskWebhookClient]. Lightspeed
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
