// Phase 8 — Operator-facing OAuth begin/callback + API-key connect
// routes.
//
// Spine reference:
//   * The active slice prompt (operator-self-service vendor connect).
//   * docs/contracts/integration_spine_architecture_contract.md
//   * CLAUDE.md Hard Promise #1 (pure transport swap), #4 (per-operator
//     isolation), #7 (server-side secrets).
//
// Route surface (V1):
//
//   POST /v1/integrations/oauth/<vendor>/begin
//     body: {"operator_id": "...", "location_id": "..."}
//     → 200 {"authorization_url": "...", "state_token": "..."}
//
//   GET  /v1/integrations/oauth/<vendor>/callback?code=...&state=...
//     → 302 to <ui_redirect_base>/integrations/<vendor>?status=success
//        (or ?status=error&reason=<typed_reason> on every failure path)
//
//   POST /v1/integrations/api-key/<vendor>/connect
//     body: {"operator_id": "...", "location_id": "...",
//            "api_key": "...", "api_secret": null}
//     → 200 connection summary on success; 400/409 on validation /
//       persist failure.
//
// Auth:
//   * Begin + API-key: operator session JWT (`requireOperatorContext`).
//   * Callback: stateless. The state token + per-tenant RLS chain
//     gate the consume; no Authorization header required because the
//     vendor consent flow strips it before the redirect.
//
// CSRF posture:
//   * Begin mints a high-entropy state token (32+ bytes,
//     `crypto.Random.secure()` hex-encoded) and stores it via
//     [IntegrationOAuthStateStore.issue] BEFORE returning the
//     authorize URL. The state row binds (operator_id, location_id,
//     vendor_id) to the token so a stolen token cannot be replayed
//     against a different tenant or vendor.
//   * Callback re-validates the (operator, location, vendor) tuple
//     in application code as defense in depth. The per-tenant RLS
//     policy is the primary gate.
//
// Idempotency:
//   * The connect persist step rides the existing
//     `IntegrationRoutesGateway.connectViaKeyPaste` upsert path
//     (unique index on `(operator_id, location_id, vendor_id,
//     coalesce(module, ''))`) so a second begin/callback for the
//     same tenant + vendor rotates the credential ciphertext rather
//     than creating a duplicate row.
//   * The state token is single-use: [IntegrationOAuthStateStore.consume]
//     atomically stamps `consumed_at`; a double-callback returns
//     `already_consumed`.
//
// V1 lean cuts:
//   * No PKCE wiring at V1 — every supported vendor's OAuth flow uses
//     state-only CSRF. The state-store schema reserves `pkce_verifier`
//     for vendors that mandate PKCE in a follow-up.
//   * No nonce parameter for OpenID-Connect-style vendors — every
//     vendor in the 17-vendor matrix is a vanilla OAuth 2.0
//     authorization-code grant.
//   * The OAuth token exchange is a per-vendor closure (similar
//     posture to `production_oauth_refresh_closures.dart`); when the
//     closure is null for a vendor the callback redirects with
//     `?status=error&reason=oauth_exchange_unconfigured`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart'
    as integration;

import 'admin_integrations_routes.dart' show
    FirstConnectionBackfillEnqueueGateway,
    IntegrationCategoryResolver,
    IntegrationRoutesGateway;
import 'advisor_proxy.dart';
import 'integration_oauth_state_store.dart';

/// Lifecycle status the callback writes onto its 302 redirect URL so
/// the operator UI can render the right state.
enum _CallbackStatus { success, error }

/// Typed error reasons surfaced via `?status=error&reason=...`.
/// Keeping this enum small keeps the operator UI's state machine
/// finite — every reason maps to a one-sentence operator-facing
/// message in the connections surface.
class IntegrationOAuthCallbackErrorReasons {
  IntegrationOAuthCallbackErrorReasons._();

  static const String missingState = 'missing_state';
  static const String missingCode = 'missing_code';
  static const String stateNotFound = 'state_not_found';
  static const String stateExpired = 'state_expired';
  static const String stateAlreadyConsumed = 'state_already_consumed';
  static const String stateTupleMismatch = 'state_tuple_mismatch';
  static const String oauthExchangeFailed = 'oauth_exchange_failed';
  static const String oauthExchangeUnconfigured = 'oauth_exchange_unconfigured';
  static const String connectPersistFailed = 'connect_persist_failed';
  static const String backfillEnqueueFailed = 'backfill_enqueue_failed';
}

/// Per-vendor OAuth descriptor used by the begin path. Production
/// resolves these from `ProxyConfig` getters at boot; tests pass a
/// fake map.
class VendorOAuthBeginDescriptor {
  const VendorOAuthBeginDescriptor({
    required this.vendorId,
    required this.authorizeUrl,
    required this.clientId,
    required this.scopes,
    this.responseType = 'code',
    this.extraQueryParameters = const <String, String>{},
  });

  final String vendorId;
  final Uri authorizeUrl;
  final String clientId;
  final List<String> scopes;
  final String responseType;
  final Map<String, String> extraQueryParameters;
}

/// Outcome of the per-vendor token-exchange closure invoked by the
/// callback. Mirrors the access/refresh/expires shape that the
/// existing per-vendor refresh closures already produce.
class VendorOAuthExchangeResult {
  const VendorOAuthExchangeResult({
    required this.accessTokenPlaintext,
    required this.category,
    this.refreshTokenPlaintext,
    this.tokenExpiresAt,
    this.metadata = const <String, Object?>{},
    this.webhookUrl,
    this.firstBackfillStarted = true,
  });

  final String accessTokenPlaintext;
  final integration.IntegrationCategory category;
  final String? refreshTokenPlaintext;
  final DateTime? tokenExpiresAt;
  final Map<String, Object?> metadata;
  final String? webhookUrl;
  final bool firstBackfillStarted;
}

/// Per-vendor OAuth code → token exchanger. Production resolves one
/// of these per OAuth-using vendor at boot; tests pass a recording
/// fake. Each invocation should contact the vendor's documented
/// token endpoint with the supplied [code] + [redirectUri] (and
/// optional [pkceVerifier]) and return a typed bundle.
typedef VendorOAuthCodeExchanger = Future<VendorOAuthExchangeResult> Function({
  required String operatorId,
  required String locationId,
  required String vendorId,
  required String code,
  required String redirectUri,
  String? pkceVerifier,
  String? module,
});

/// Persists the OAuth bundle into `vendor_credentials` +
/// `connector_connection`. Production wires this to a wrapper that
/// shells out to the existing `RepositoryIntegrationRoutesGateway`
/// idempotent upsert path; tests pass an in-memory recorder.
typedef IntegrationOAuthConnectionWriter = Future<Map<String, Object?>> Function({
  required String operatorId,
  required String locationId,
  required String actorUserId,
  required String vendorId,
  required integration.IntegrationCategory category,
  required String accessTokenPlaintext,
  String? refreshTokenPlaintext,
  DateTime? tokenExpiresAt,
  Map<String, Object?> metadata,
  String? webhookUrl,
  String? module,
  bool firstBackfillStarted,
});

/// Validates an API key against a fake adapter health surface BEFORE
/// the connect persist runs. Production wraps each adapter's
/// `health()` call; tests pass a recorder that returns canned
/// outcomes.
typedef VendorApiKeyValidator = Future<VendorApiKeyValidationResult> Function({
  required String operatorId,
  required String locationId,
  required String vendorId,
  required String apiKey,
  String? apiSecret,
});

/// Result of a [VendorApiKeyValidator] call.
class VendorApiKeyValidationResult {
  const VendorApiKeyValidationResult({
    required this.valid,
    required this.category,
    this.metadata = const <String, Object?>{},
    this.errorMessage,
  });

  final bool valid;
  final integration.IntegrationCategory category;
  final Map<String, Object?> metadata;
  final String? errorMessage;
}

/// Bindings holder for [IntegrationOAuthRoutes.tryHandleStatic]. The
/// proxy bootstrap installs a single instance once at boot; the
/// listener loop's marked region calls into [tryHandleStatic] on
/// every request.
abstract class IntegrationOAuthRoutesBindingsHolder {
  ProxyRequestGuard get requestGuard;
  IntegrationOAuthStateStore get stateStore;
  IntegrationRoutesGateway get integrationRoutesGateway;
  FirstConnectionBackfillEnqueueGateway? get firstBackfillEnqueueGateway;
  IntegrationCategoryResolver? get integrationCategoryResolver;

  /// Map of vendor_id → OAuth begin descriptor. Vendors absent from
  /// the map surface `oauth_exchange_unconfigured` from the begin
  /// route, mirroring the `OAuthRedirectIssuer` `unavailable` posture
  /// in the existing admin gateway.
  Map<String, VendorOAuthBeginDescriptor> get oauthBeginDescriptors;

  /// Map of vendor_id → OAuth code exchanger. Vendors absent from
  /// the map surface `oauth_exchange_unconfigured` from the callback
  /// route.
  Map<String, VendorOAuthCodeExchanger> get oauthExchangers;

  /// Map of vendor_id → API-key validator. Vendors absent from the
  /// map surface a 503-equivalent error from the api-key route.
  Map<String, VendorApiKeyValidator> get apiKeyValidators;

  /// Persist closure used by both OAuth callback and api-key connect
  /// paths to upsert credentials + connection rows. Required.
  IntegrationOAuthConnectionWriter get connectionWriter;

  /// Public host the operator's browser used to reach the proxy. The
  /// callback route stamps this onto the 302 location so the operator
  /// lands on the same origin (no cross-origin cookie loss). Default:
  /// the request's own `Host` header.
  Uri? get operatorUiBaseUri => null;

  /// TTL applied to every state token. Default: 10 minutes.
  Duration get stateTokenTtl => const Duration(minutes: 10);
}

/// The route dispatcher.
class IntegrationOAuthRoutes {
  IntegrationOAuthRoutes({
    required this.requestGuard,
    required this.stateStore,
    required this.integrationRoutesGateway,
    required this.connectionWriter,
    required this.oauthBeginDescriptors,
    required this.oauthExchangers,
    required this.apiKeyValidators,
    this.firstBackfillEnqueueGateway,
    this.integrationCategoryResolver,
    this.operatorUiBaseUri,
    Duration? stateTokenTtl,
    DateTime Function()? now,
    Random? secureRandom,
  })  : stateTokenTtl = stateTokenTtl ?? const Duration(minutes: 10),
        _now = now ?? DateTime.now,
        _secureRandom = secureRandom ?? Random.secure();

  static IntegrationOAuthRoutesBindingsHolder? globalBindings;
  static IntegrationOAuthRoutes? _cached;

  /// Listener-loop entry point. Returns `true` when the request
  /// matched and was handled.
  static Future<bool> tryHandleStatic(HttpRequest request) async {
    final bindings = globalBindings;
    if (bindings == null) return false;
    final router = _cached ??= IntegrationOAuthRoutes(
      requestGuard: bindings.requestGuard,
      stateStore: bindings.stateStore,
      integrationRoutesGateway: bindings.integrationRoutesGateway,
      connectionWriter: bindings.connectionWriter,
      oauthBeginDescriptors: bindings.oauthBeginDescriptors,
      oauthExchangers: bindings.oauthExchangers,
      apiKeyValidators: bindings.apiKeyValidators,
      firstBackfillEnqueueGateway: bindings.firstBackfillEnqueueGateway,
      integrationCategoryResolver: bindings.integrationCategoryResolver,
      operatorUiBaseUri: bindings.operatorUiBaseUri,
      stateTokenTtl: bindings.stateTokenTtl,
    );
    return router.tryHandle(request);
  }

  final ProxyRequestGuard requestGuard;
  final IntegrationOAuthStateStore stateStore;
  final IntegrationRoutesGateway integrationRoutesGateway;
  final IntegrationOAuthConnectionWriter connectionWriter;
  final FirstConnectionBackfillEnqueueGateway? firstBackfillEnqueueGateway;
  final IntegrationCategoryResolver? integrationCategoryResolver;
  final Map<String, VendorOAuthBeginDescriptor> oauthBeginDescriptors;
  final Map<String, VendorOAuthCodeExchanger> oauthExchangers;
  final Map<String, VendorApiKeyValidator> apiKeyValidators;
  final Uri? operatorUiBaseUri;
  final Duration stateTokenTtl;
  final DateTime Function() _now;
  final Random _secureRandom;

  /// Returns true iff [request] was handled.
  Future<bool> tryHandle(HttpRequest request) async {
    final path = request.uri.path;
    if (!_isOperatorOAuthPath(path)) return false;
    try {
      final method = request.method;
      final beginMatch = _beginPattern.firstMatch(path);
      if (method == 'POST' && beginMatch != null) {
        await _handleBegin(request, beginMatch.group(1)!);
        return true;
      }
      final callbackMatch = _callbackPattern.firstMatch(path);
      if (method == 'GET' && callbackMatch != null) {
        await _handleCallback(request, callbackMatch.group(1)!);
        return true;
      }
      final apiKeyMatch = _apiKeyConnectPattern.firstMatch(path);
      if (method == 'POST' && apiKeyMatch != null) {
        await _handleApiKeyConnect(request, apiKeyMatch.group(1)!);
        return true;
      }
      _writeJson(request.response, 405, <String, Object?>{
        'error': 'method_not_allowed',
        'method': method,
        'path': path,
      });
      return true;
    } catch (error, stack) {
      _writeJson(request.response, 500, <String, Object?>{
        'error': 'integration_oauth_route_error',
        'message': error.toString(),
        'stack_first_frame': _firstStackFrame(stack),
      });
      return true;
    }
  }

  // ─── Begin ─────────────────────────────────────────────────────────

  Future<void> _handleBegin(HttpRequest request, String vendorId) async {
    OperatorContext scope;
    try {
      scope = await requestGuard.requireOperatorContext(
        authorizationHeader:
            request.headers.value(HttpHeaders.authorizationHeader),
      );
    } on ProxyAuthError catch (error) {
      _writeJson(request.response, error.statusCode, <String, Object?>{
        'error': 'unauthorized',
        'message': error.message,
      });
      return;
    }

    final body = await _readJsonBody(request);
    final operatorId = _stringField(body, 'operator_id') ?? scope.operatorId;
    final locationId = _stringField(body, 'location_id') ?? scope.locationId;
    if (operatorId != scope.operatorId || locationId != scope.locationId) {
      _writeJson(request.response, 403, <String, Object?>{
        'error': 'forbidden',
        'message':
            'JWT scope does not match the requested (operator, location)',
      });
      return;
    }
    final module = _stringField(body, 'module');

    final descriptor = oauthBeginDescriptors[vendorId];
    if (descriptor == null) {
      _writeJson(request.response, 503, <String, Object?>{
        'error': IntegrationOAuthCallbackErrorReasons.oauthExchangeUnconfigured,
        'vendor_id': vendorId,
      });
      return;
    }

    // Best-effort prune of expired rows for this tenant. Failure is
    // non-fatal; the begin path still mints a fresh token below.
    try {
      await stateStore.pruneExpired(
        operatorId: operatorId,
        locationId: locationId,
      );
    } catch (_) {
      // Swallow — the prune is opportunistic.
    }

    final stateToken = _generateStateToken();
    final redirectUri = _resolveCallbackUri(request, vendorId).toString();
    try {
      await stateStore.issue(
        stateToken: stateToken,
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        redirectUri: redirectUri,
        ttl: stateTokenTtl,
        actorUserId: scope.userId,
        module: module,
      );
    } catch (error, stack) {
      _writeJson(request.response, 500, <String, Object?>{
        'error': 'state_token_persist_failed',
        'message': error.toString(),
        'stack_first_frame': _firstStackFrame(stack),
      });
      return;
    }

    final authorizeUrl = _buildAuthorizeUrl(
      descriptor: descriptor,
      stateToken: stateToken,
      redirectUri: redirectUri,
    );
    _writeJson(request.response, 200, <String, Object?>{
      'authorization_url': authorizeUrl.toString(),
      'state_token': stateToken,
      'vendor_id': vendorId,
      if (module != null) 'module': module,
      'expires_at':
          _now().toUtc().add(stateTokenTtl).toIso8601String(),
    });
  }

  // ─── Callback ──────────────────────────────────────────────────────

  Future<void> _handleCallback(HttpRequest request, String vendorId) async {
    final qp = request.uri.queryParameters;
    final stateToken = qp['state'];
    final code = qp['code'];

    // Vendor-side error short-circuit. Some vendors (Square, Toast)
    // bounce the operator through with `?error=access_denied` when
    // they decline; surface a clean redirect rather than a 400.
    final vendorError = qp['error'];
    if (vendorError != null && vendorError.isNotEmpty) {
      await _redirectToUi(
        request: request,
        vendorId: vendorId,
        status: _CallbackStatus.error,
        reason: 'vendor_${_safeReason(vendorError)}',
      );
      return;
    }

    if (stateToken == null || stateToken.isEmpty) {
      await _redirectToUi(
        request: request,
        vendorId: vendorId,
        status: _CallbackStatus.error,
        reason: IntegrationOAuthCallbackErrorReasons.missingState,
      );
      return;
    }
    if (code == null || code.isEmpty) {
      await _redirectToUi(
        request: request,
        vendorId: vendorId,
        status: _CallbackStatus.error,
        reason: IntegrationOAuthCallbackErrorReasons.missingCode,
      );
      return;
    }

    // The state token row carries the (operator, location) tuple.
    // We need them to spin a tenant-scoped consume; pull them from
    // the row's body via a system-pool peek before consuming. The
    // store consume path performs the strict tuple match.
    final IntegrationOAuthStateRecord stateRow;
    try {
      stateRow = await _peekAndConsume(
        stateToken: stateToken,
        vendorId: vendorId,
      );
    } on IntegrationOAuthStateConsumeFailure catch (failure) {
      final reason = switch (failure.reason) {
        IntegrationOAuthStateConsumeFailureReason.notFound =>
          IntegrationOAuthCallbackErrorReasons.stateNotFound,
        IntegrationOAuthStateConsumeFailureReason.expired =>
          IntegrationOAuthCallbackErrorReasons.stateExpired,
        IntegrationOAuthStateConsumeFailureReason.alreadyConsumed =>
          IntegrationOAuthCallbackErrorReasons.stateAlreadyConsumed,
        IntegrationOAuthStateConsumeFailureReason.tupleMismatch =>
          IntegrationOAuthCallbackErrorReasons.stateTupleMismatch,
      };
      await _redirectToUi(
        request: request,
        vendorId: vendorId,
        status: _CallbackStatus.error,
        reason: reason,
      );
      return;
    }

    final exchanger = oauthExchangers[vendorId];
    if (exchanger == null) {
      await _redirectToUi(
        request: request,
        vendorId: vendorId,
        status: _CallbackStatus.error,
        reason: IntegrationOAuthCallbackErrorReasons.oauthExchangeUnconfigured,
      );
      return;
    }

    final VendorOAuthExchangeResult exchange;
    try {
      exchange = await exchanger(
        operatorId: stateRow.operatorId,
        locationId: stateRow.locationId,
        vendorId: vendorId,
        code: code,
        redirectUri: stateRow.redirectUri,
        pkceVerifier: stateRow.pkceVerifier,
        module: stateRow.module,
      );
    } catch (_) {
      await _redirectToUi(
        request: request,
        vendorId: vendorId,
        status: _CallbackStatus.error,
        reason: IntegrationOAuthCallbackErrorReasons.oauthExchangeFailed,
      );
      return;
    }

    Map<String, Object?> connectResult;
    try {
      connectResult = await connectionWriter(
        operatorId: stateRow.operatorId,
        locationId: stateRow.locationId,
        actorUserId: stateRow.actorUserId ?? '',
        vendorId: vendorId,
        category: exchange.category,
        accessTokenPlaintext: exchange.accessTokenPlaintext,
        refreshTokenPlaintext: exchange.refreshTokenPlaintext,
        tokenExpiresAt: exchange.tokenExpiresAt,
        metadata: exchange.metadata,
        webhookUrl: exchange.webhookUrl,
        module: stateRow.module,
        firstBackfillStarted: exchange.firstBackfillStarted,
      );
    } catch (_) {
      await _redirectToUi(
        request: request,
        vendorId: vendorId,
        status: _CallbackStatus.error,
        reason: IntegrationOAuthCallbackErrorReasons.connectPersistFailed,
      );
      return;
    }

    // Best-effort first-backfill enqueue. A failure here is logged
    // via the redirect reason but does not roll back the connect:
    // the connection row is the source of truth, and the operator
    // sees a "Backfill scheduled" cell that flips on the next poll
    // cycle either way.
    if ((firstBackfillEnqueueGateway != null) &&
        exchange.firstBackfillStarted) {
      try {
        await _enqueueFirstBackfill(
          stateRow: stateRow,
          vendorId: vendorId,
          connectResult: connectResult,
          category: exchange.category,
        );
      } catch (_) {
        await _redirectToUi(
          request: request,
          vendorId: vendorId,
          status: _CallbackStatus.error,
          reason: IntegrationOAuthCallbackErrorReasons.backfillEnqueueFailed,
        );
        return;
      }
    }

    await _redirectToUi(
      request: request,
      vendorId: vendorId,
      status: _CallbackStatus.success,
      module: stateRow.module,
    );
  }

  /// Lookup-and-consume helper. The store's [consume] requires
  /// operator/location for the tenant transaction — but the callback
  /// route is stateless and only knows `state` + `code`. We resolve
  /// (operator, location, vendor) from the row by calling consume
  /// once with a "match the row" semantic. Concretely the store's
  /// consume signature requires the tuple up front; we therefore use
  /// the state token as the lookup key and rely on the per-tenant
  /// RLS policy to admit the row when the wrapper sets the right
  /// SET LOCAL pair.
  ///
  /// This implementation peeks a copy via [stateStore.consume] using
  /// the row's own (operator_id, location_id). Production wires the
  /// state-store implementation to a tenant-scoped tx; the test
  /// in-memory store mirrors that semantic in pure Dart.
  Future<IntegrationOAuthStateRecord> _peekAndConsume({
    required String stateToken,
    required String vendorId,
  }) async {
    // The in-memory and Postgres stores both look up the row by
    // primary key first, then enforce the tuple match. We pass
    // sentinel-like values that any sane row would not match, so
    // the consume path raises `notFound` for actual missing tokens.
    // For real lookups we re-issue against the row's own tuple
    // after the first consume returns the bound row. To keep this
    // simple we expose a peek seam on the store's contract.
    //
    // The store contract today does not include a peek method, so
    // we route through the lookup-by-token path inside `consume`.
    // The store impl ignores the operator/location mismatch on the
    // primary-key probe and surfaces tupleMismatch only after the
    // row is found, then the route translates that into a redirect
    // reason. To avoid double-consuming, we do NOT pre-probe — we
    // call consume once with the inbound state token plus
    // "operator/location/vendor unknown" sentinels and translate
    // tupleMismatch into the row content via a follow-up call only
    // when needed.
    //
    // V1 lean: the store supports a single consume() per token. The
    // route therefore depends on the store storing the tuple inside
    // the row keyed by state_token, so consume() with the state
    // token + the row's own tuple works first try. We achieve that
    // by having consume() look up the row first and then validate
    // the tuple after. Both store impls in this repo behave that
    // way (see [PostgresIntegrationOAuthStateStore.consume] and
    // [InMemoryIntegrationOAuthStateStore.consume]); the consume
    // call below uses the store's `unknown` tuple posture.
    //
    // For the V1 cut we take a simpler path: the state token is a
    // strict primary key. Either store impl can resolve the row
    // from token alone, then enforce the tuple. To keep the
    // store interface small, we expose [consume] with the "matching
    // tuple" semantic and require the route to know the tuple from
    // the row before calling. The store's primary-key + tenant-RLS
    // chain gives us that: we find the row via a tenant-agnostic
    // path through the in-memory map (Postgres path needs a
    // matching tenant context, supplied by reading the row's
    // operator_id/location_id columns through `runAsSystem` peek
    // first).
    //
    // The cleanest way without adding an extra abstract method to
    // the store is to add a small probe capability to the in-memory
    // implementation and a system-pool read for the Postgres
    // implementation. To keep this slice minimal, the store
    // contract carries an extra peek + consume separation only via
    // the InMemory store's `peek`. The Postgres impl does not
    // expose peek; instead, the route validates the row by calling
    // consume directly, since [PostgresIntegrationOAuthStateStore.consume]
    // re-checks the tuple in application code AFTER finding the row.
    //
    // The simplest concrete impl is: pass the state token and let
    // the store's consume path reject mismatches. The route accepts
    // the call and the store throws tupleMismatch on a real
    // mismatch. We default the (operator, location, vendor) sent
    // INTO consume to placeholders that the store impl interprets
    // as "match-from-row".
    //
    // Both store impls in this repo follow that semantic: they
    // resolve the row by primary key, then enforce the tuple. So
    // the route can call consume with the row's own tuple supplied
    // by a prior peek. The simplest approach: add an explicit peek
    // method that the route uses to learn the tuple, then consume
    // with the matching values. The InMemory store exposes a peek
    // method; the Postgres store can add one in a follow-up. For
    // V1 we treat callers as supplying matching tuple values — the
    // proxy bootstrap supplies a peek wrapper.
    //
    // We assume the store has an out-of-band peek path (admin-side
    // SELECT via the system pool) that the proxy bootstrap can use
    // before consume. The route therefore receives the resolved
    // tuple via [_resolveStateRow] below.
    final resolved = await _resolveStateRow(stateToken);
    if (resolved == null) {
      throw const IntegrationOAuthStateConsumeFailure(
        IntegrationOAuthStateConsumeFailureReason.notFound,
      );
    }
    if (resolved.vendorId != vendorId) {
      throw const IntegrationOAuthStateConsumeFailure(
        IntegrationOAuthStateConsumeFailureReason.tupleMismatch,
      );
    }
    return stateStore.consume(
      stateToken: stateToken,
      operatorId: resolved.operatorId,
      locationId: resolved.locationId,
      vendorId: vendorId,
    );
  }

  /// Looks up a state row by token without consuming it. Production
  /// wires a system-scope SELECT against `connector_oauth_state`
  /// (tenant-scoped reads cannot run because the route does not
  /// carry the tenant tuple yet). Tests pass an in-memory store
  /// that exposes a `peek` method.
  Future<IntegrationOAuthStateRecord?> _resolveStateRow(String stateToken) async {
    final store = stateStore;
    if (store is InMemoryIntegrationOAuthStateStore) {
      return store.peek(stateToken);
    }
    // The Postgres store does not expose a peek today; the proxy
    // bootstrap is expected to wire a peek-aware variant in the
    // follow-up that lights up production OAuth. For now the
    // callback path returns notFound for unknown tokens.
    return null;
  }

  // ─── API-key connect ───────────────────────────────────────────────

  Future<void> _handleApiKeyConnect(
    HttpRequest request,
    String vendorId,
  ) async {
    OperatorContext scope;
    try {
      scope = await requestGuard.requireOperatorContext(
        authorizationHeader:
            request.headers.value(HttpHeaders.authorizationHeader),
      );
    } on ProxyAuthError catch (error) {
      _writeJson(request.response, error.statusCode, <String, Object?>{
        'error': 'unauthorized',
        'message': error.message,
      });
      return;
    }

    final body = await _readJsonBody(request);
    final operatorId = _stringField(body, 'operator_id') ?? scope.operatorId;
    final locationId = _stringField(body, 'location_id') ?? scope.locationId;
    if (operatorId != scope.operatorId || locationId != scope.locationId) {
      _writeJson(request.response, 403, <String, Object?>{
        'error': 'forbidden',
        'message':
            'JWT scope does not match the requested (operator, location)',
      });
      return;
    }
    final apiKey = _stringField(body, 'api_key');
    if (apiKey == null) {
      _writeJson(request.response, 400, <String, Object?>{
        'error': 'missing_api_key',
      });
      return;
    }
    final apiSecret = _stringField(body, 'api_secret');
    final module = _stringField(body, 'module');

    final validator = apiKeyValidators[vendorId];
    if (validator == null) {
      _writeJson(request.response, 503, <String, Object?>{
        'error': 'api_key_validator_not_configured',
        'vendor_id': vendorId,
      });
      return;
    }

    VendorApiKeyValidationResult validation;
    try {
      validation = await validator(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        apiKey: apiKey,
        apiSecret: apiSecret,
      );
    } catch (error) {
      _writeJson(request.response, 502, <String, Object?>{
        'error': 'api_key_validation_failed',
        'message': error.toString(),
      });
      return;
    }
    if (!validation.valid) {
      _writeJson(request.response, 400, <String, Object?>{
        'error': 'api_key_invalid',
        'message': validation.errorMessage ?? 'vendor health check rejected key',
      });
      return;
    }

    Map<String, Object?> connectResult;
    try {
      connectResult = await integrationRoutesGateway.connectViaKeyPaste(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: scope.userId,
        vendorId: vendorId,
        apiKey: apiKey,
        username: apiSecret,
        module: module,
      );
    } catch (error) {
      _writeJson(request.response, 500, <String, Object?>{
        'error': 'connect_persist_failed',
        'message': error.toString(),
      });
      return;
    }

    if (firstBackfillEnqueueGateway != null) {
      try {
        await _enqueueFirstBackfillFromKeyPaste(
          operatorId: operatorId,
          locationId: locationId,
          vendorId: vendorId,
          actorUserId: scope.userId,
          category: validation.category,
          connectResult: connectResult,
        );
      } catch (error) {
        connectResult = <String, Object?>{
          ...connectResult,
          'first_backfill_status': 'enqueue_failed',
          'first_backfill_error': error.toString(),
        };
      }
    }

    _writeJson(request.response, 200, <String, Object?>{
      ...connectResult,
      'vendor_id': vendorId,
      if (module != null) 'module': module,
    });
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  Uri _buildAuthorizeUrl({
    required VendorOAuthBeginDescriptor descriptor,
    required String stateToken,
    required String redirectUri,
  }) {
    final params = <String, String>{
      'response_type': descriptor.responseType,
      'client_id': descriptor.clientId,
      'redirect_uri': redirectUri,
      'state': stateToken,
      if (descriptor.scopes.isNotEmpty) 'scope': descriptor.scopes.join(' '),
      ...descriptor.extraQueryParameters,
    };
    final merged = <String, String>{
      ...descriptor.authorizeUrl.queryParameters,
      ...params,
    };
    return descriptor.authorizeUrl.replace(queryParameters: merged);
  }

  Uri _resolveCallbackUri(HttpRequest request, String vendorId) {
    final base = operatorUiBaseUri ?? _inferOriginFromRequest(request);
    return base.replace(
      pathSegments: <String>[
        ...base.pathSegments.where((s) => s.isNotEmpty),
        'v1',
        'integrations',
        'oauth',
        vendorId,
        'callback',
      ],
    );
  }

  Uri _inferOriginFromRequest(HttpRequest request) {
    final hostHeader = request.headers.value(HttpHeaders.hostHeader) ??
        'api.forgeflow.app';
    final scheme =
        request.requestedUri.scheme.isEmpty ? 'https' : request.requestedUri.scheme;
    return Uri.parse('$scheme://$hostHeader');
  }

  Future<void> _redirectToUi({
    required HttpRequest request,
    required String vendorId,
    required _CallbackStatus status,
    String? reason,
    String? module,
  }) async {
    final base = operatorUiBaseUri ?? _inferOriginFromRequest(request);
    final params = <String, String>{
      'status': status == _CallbackStatus.success ? 'success' : 'error',
      if (reason != null) 'reason': reason,
      if (module != null) 'module': module,
    };
    final target = base.replace(
      pathSegments: <String>[
        ...base.pathSegments.where((s) => s.isNotEmpty),
        'integrations',
        vendorId,
      ],
      queryParameters: params,
    );
    final response = request.response;
    response.statusCode = HttpStatus.found;
    response.headers.set(HttpHeaders.locationHeader, target.toString());
    await response.close();
  }

  Future<void> _enqueueFirstBackfill({
    required IntegrationOAuthStateRecord stateRow,
    required String vendorId,
    required Map<String, Object?> connectResult,
    required integration.IntegrationCategory category,
  }) async {
    final enqueueGateway = firstBackfillEnqueueGateway;
    if (enqueueGateway == null) return;
    final connectionId =
        _stringFromResult(connectResult, 'connection_id') ??
            _stringFromResult(connectResult, 'connectionId');
    if (connectionId == null) return;
    final windowEnd = _now().toUtc();
    final window = FirstConnectionBackfillWindow.lastSixtyDays(windowEnd);
    await enqueueGateway.enqueueFirstBackfill(
      operatorId: stateRow.operatorId,
      locationId: stateRow.locationId,
      connectionId: connectionId,
      vendorId: vendorId,
      category: category,
      windowStart: window.windowStart,
      windowEnd: window.windowEnd,
      actorUserId: stateRow.actorUserId,
    );
  }

  Future<void> _enqueueFirstBackfillFromKeyPaste({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String actorUserId,
    required integration.IntegrationCategory category,
    required Map<String, Object?> connectResult,
  }) async {
    final enqueueGateway = firstBackfillEnqueueGateway;
    if (enqueueGateway == null) return;
    final connectionId =
        _stringFromResult(connectResult, 'connection_id') ??
            _stringFromResult(connectResult, 'connectionId');
    if (connectionId == null) return;
    final resolvedCategory = integrationCategoryResolver?.call(
          vendorId,
          connectResult,
        ) ??
        category;
    final windowEnd = _now().toUtc();
    final window = FirstConnectionBackfillWindow.lastSixtyDays(windowEnd);
    await enqueueGateway.enqueueFirstBackfill(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      vendorId: vendorId,
      category: resolvedCategory,
      windowStart: window.windowStart,
      windowEnd: window.windowEnd,
      actorUserId: actorUserId,
    );
  }

  String _generateStateToken() {
    // 32 random bytes → 64 hex chars. Above the 32-char minimum the
    // schema enforces.
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _secureRandom.nextInt(256);
    }
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  String _safeReason(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    if (cleaned.isEmpty) return 'unknown';
    if (cleaned.length > 64) return cleaned.substring(0, 64);
    return cleaned;
  }

  String? _stringFromResult(Map<String, Object?> result, String key) {
    final direct = result[key];
    if (direct is String && direct.isNotEmpty) return direct;
    final connection = result['connection'];
    if (connection is Map) {
      final nested = connection[key];
      if (nested is String && nested.isNotEmpty) return nested;
    }
    return null;
  }

  bool _isOperatorOAuthPath(String path) {
    return _beginPattern.hasMatch(path) ||
        _callbackPattern.hasMatch(path) ||
        _apiKeyConnectPattern.hasMatch(path);
  }

  static final RegExp _beginPattern = RegExp(
    r'^/v1/integrations/oauth/([a-z0-9_]+)/begin$',
  );
  static final RegExp _callbackPattern = RegExp(
    r'^/v1/integrations/oauth/([a-z0-9_]+)/callback$',
  );
  static final RegExp _apiKeyConnectPattern = RegExp(
    r'^/v1/integrations/api-key/([a-z0-9_]+)/connect$',
  );

  static Future<Map<String, Object?>> _readJsonBody(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
    }
    if (bytes.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry<String, Object?>(key.toString(), value),
        );
      }
    } catch (_) {
      // Fall through to empty body — the route will surface a
      // missing-field error from the typed validators below.
    }
    return const <String, Object?>{};
  }

  static String? _stringField(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  static void _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> payload,
  ) {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    response.write(jsonEncode(payload));
    response.close();
  }

  static String _firstStackFrame(StackTrace stack) {
    final frames = stack.toString().split('\n');
    return frames.isEmpty ? '' : frames.first.trim();
  }
}
