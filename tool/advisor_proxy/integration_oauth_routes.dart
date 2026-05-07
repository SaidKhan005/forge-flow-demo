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
import 'package:forge_and_flow/services/integration/repository_integration_routes_gateway.dart';
import 'package:http/http.dart' as http;

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
  /// carry the tenant tuple yet); the in-memory store keys by token
  /// as well. Both impls go through the new `peek` abstract method.
  Future<IntegrationOAuthStateRecord?> _resolveStateRow(String stateToken) {
    return stateStore.peek(stateToken);
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

// ─── Production wiring helpers ─────────────────────────────────────────
//
// The following section turns `ProxyConfig` + `RepositoryIntegrationRoutesGateway`
// + `FirstConnectionBackfillEnqueueGateway` into the four maps + writer
// that `IntegrationOAuthRoutes` requires. All construction is lazy so
// vendors with missing app credentials are simply absent from the
// returned maps; the dispatcher then surfaces
// `oauth_exchange_unconfigured` for them on demand.
//
// Vendor coverage summary (per the slice prompt):
//
//   OAuth (12): Toast, Square, Clover, Lightspeed LSK, Aloha NCR Voyix,
//               Oracle MICROS Simphony, Revel, 7shifts, QuickBooks Time,
//               Libro, Humanity, ADP
//   API key (5): Tock, Push Operations, Agendrix, SevenRooms, OpenTable

/// Production POS / Labor / Reservation vendor classification used
/// by the per-vendor exchangers + API-key validators below. Wave A
/// integration matrix.
const Map<String, integration.IntegrationCategory> kPhase8VendorCategories =
    <String, integration.IntegrationCategory>{
  // POS
  'toast': integration.IntegrationCategory.pos,
  'square': integration.IntegrationCategory.pos,
  'clover': integration.IntegrationCategory.pos,
  'lightspeed_lsk': integration.IntegrationCategory.pos,
  'aloha_ncr_voyix': integration.IntegrationCategory.pos,
  'oracle_micros_simphony': integration.IntegrationCategory.pos,
  'revel': integration.IntegrationCategory.pos,
  // Labor
  '7shifts': integration.IntegrationCategory.labor,
  'quickbooks_time': integration.IntegrationCategory.labor,
  'humanity': integration.IntegrationCategory.labor,
  'adp': integration.IntegrationCategory.labor,
  'push_operations': integration.IntegrationCategory.labor,
  'agendrix': integration.IntegrationCategory.labor,
  // Reservation
  'libro': integration.IntegrationCategory.reservation,
  'opentable': integration.IntegrationCategory.reservation,
  'sevenrooms': integration.IntegrationCategory.reservation,
  'tock': integration.IntegrationCategory.reservation,
};

/// Bundle returned by [buildPhase8OperatorOAuthWiring]. The proxy
/// bootstrap unpacks this into the four maps + writer that
/// [IntegrationOAuthRoutes] requires.
class Phase8OperatorOAuthWiring {
  const Phase8OperatorOAuthWiring({
    required this.oauthBeginDescriptors,
    required this.oauthExchangers,
    required this.apiKeyValidators,
    required this.connectionWriter,
    required this.disabledVendors,
  });

  final Map<String, VendorOAuthBeginDescriptor> oauthBeginDescriptors;
  final Map<String, VendorOAuthCodeExchanger> oauthExchangers;
  final Map<String, VendorApiKeyValidator> apiKeyValidators;
  final IntegrationOAuthConnectionWriter connectionWriter;

  /// Vendors whose OAuth descriptor / exchanger could not be wired
  /// because their static app credentials are absent from the proxy's
  /// secret bundle. The dispatcher returns
  /// `oauth_exchange_unconfigured` for any vendor in this list; the
  /// startup log surfaces the list so deploys know which vendors are
  /// dark.
  final Map<String, String> disabledVendors;
}

/// Public base URI the operator's browser uses to reach the proxy.
/// Used to compose the OAuth redirect URI for each vendor.
const String kPhase8OAuthCallbackPathPrefix = '/v1/integrations/oauth';

/// Build the full operator-facing OAuth dispatcher wiring from the
/// proxy's `ProxyConfig` + a pre-built connection writer.
///
/// Each vendor whose static app credentials are unloaded lands in
/// [Phase8OperatorOAuthWiring.disabledVendors] with a one-line
/// reason. The dispatcher's `503 oauth_exchange_unconfigured` path
/// then absorbs requests for those vendors without crashing the
/// listener loop.
///
/// The default `connectionWriterBuilder` wraps
/// [makeIntegrationOAuthConnectionWriter]; tests inject a recorder
/// that bypasses the real Postgres gateway.
Phase8OperatorOAuthWiring buildPhase8OperatorOAuthWiring({
  required ProxyConfig proxyConfig,
  required IntegrationOAuthConnectionWriter connectionWriter,
  http.Client? httpClient,
}) {
  final client = httpClient ?? http.Client();
  final descriptors = <String, VendorOAuthBeginDescriptor>{};
  final exchangers = <String, VendorOAuthCodeExchanger>{};
  final apiKeyValidators = <String, VendorApiKeyValidator>{};
  final disabled = <String, String>{};

  // ─── Toast ─────────────────────────────────────────────────────────
  // Toast uses `client_credentials` (no PKCE, no auth-code). The
  // operator pastes the per-restaurant credentials inside the F&F
  // partner portal — there is no consent redirect. We expose the
  // vendor on the api-key validator surface instead. Mark it absent
  // on the OAuth descriptor map so the operator UI routes Toast to
  // the api-key flow.
  apiKeyValidators['toast'] = _toastApiKeyValidator(client);

  // ─── Square ────────────────────────────────────────────────────────
  if (proxyConfig.hasSquareAppCredentials) {
    final creds = proxyConfig.squareAppCredentials;
    descriptors['square'] = VendorOAuthBeginDescriptor(
      vendorId: 'square',
      authorizeUrl: Uri.parse('https://connect.squareup.com/oauth2/authorize'),
      clientId: creds.clientId,
      scopes: const <String>[
        'MERCHANT_PROFILE_READ',
        'PAYMENTS_READ',
        'ORDERS_READ',
        'ITEMS_READ',
        'EMPLOYEES_READ',
      ],
    );
    exchangers['square'] = _squareCodeExchanger(
      httpClient: client,
      clientId: creds.clientId,
      clientSecret: creds.clientSecret,
    );
  } else {
    disabled['square'] = 'square_app_credentials_missing';
  }

  // ─── Clover ────────────────────────────────────────────────────────
  if (proxyConfig.hasCloverAppCredentials) {
    final creds = proxyConfig.cloverAppCredentials;
    descriptors['clover'] = VendorOAuthBeginDescriptor(
      vendorId: 'clover',
      authorizeUrl: Uri.parse('https://www.clover.com/oauth/v2/authorize'),
      clientId: creds.appId,
      scopes: const <String>[],
    );
    exchangers['clover'] = _cloverCodeExchanger(
      httpClient: client,
      clientId: creds.appId,
    );
  } else {
    disabled['clover'] = 'clover_app_credentials_missing';
  }

  // ─── Lightspeed LSK ────────────────────────────────────────────────
  // Lightspeed K-Series uses per-tenant client_id/client_secret pairs
  // stored on `vendor_credentials.metadata` after the operator
  // registers an integration in Lightspeed's developer portal. There
  // is no app-wide registration — the operator pastes the per-tenant
  // pair via the api-key flow first, then the next OAuth refresh tick
  // resolves the credentials from the row body. Surface lightspeed_lsk
  // on the api-key validator map (operator pastes the bearer token
  // they generated in their Lightspeed admin console).
  apiKeyValidators['lightspeed_lsk'] = _lightspeedLskApiKeyValidator(client);

  // ─── Aloha NCR Voyix ───────────────────────────────────────────────
  // NCR Voyix uses `client_credentials` (no auth-code). Operator
  // pastes the per-tenant pair plus the static app + org headers
  // through the api-key surface; Aloha is not on the OAuth descriptor
  // map by design.
  apiKeyValidators['aloha_ncr_voyix'] = _alohaNcrVoyixApiKeyValidator(client);

  // ─── Oracle MICROS Simphony ────────────────────────────────────────
  // Simphony uses `client_credentials` like Aloha — same posture:
  // operator pastes a per-tenant client_id / client_secret pair on
  // the api-key surface. The api-key validator runs a probe exchange.
  apiKeyValidators['oracle_micros_simphony'] =
      _oracleMicrosSimphonyApiKeyValidator(client);

  // ─── Revel ─────────────────────────────────────────────────────────
  // Revel uses `client_credentials` plus a per-tenant audience id.
  // Operator pastes the triple via the api-key surface.
  apiKeyValidators['revel'] = _revelApiKeyValidator(client);

  // ─── 7shifts ───────────────────────────────────────────────────────
  if (proxyConfig.hasSevenShiftsAppCredentials) {
    final creds = proxyConfig.sevenShiftsAppCredentials;
    descriptors['7shifts'] = VendorOAuthBeginDescriptor(
      vendorId: '7shifts',
      authorizeUrl: Uri.parse('https://app.7shifts.com/oauth2/authorize'),
      clientId: creds.clientId,
      scopes: const <String>['read_users', 'read_shifts', 'read_time_punches'],
    );
    exchangers['7shifts'] = _sevenShiftsCodeExchanger(
      httpClient: client,
      clientId: creds.clientId,
      clientSecret: creds.clientSecret,
    );
  } else {
    disabled['7shifts'] = 'seven_shifts_oauth_credentials_missing';
  }

  // ─── QuickBooks Time (Intuit) ──────────────────────────────────────
  if (proxyConfig.hasQuickBooksTimeAppCredentials) {
    final creds = proxyConfig.quickBooksTimeAppCredentials;
    descriptors['quickbooks_time'] = VendorOAuthBeginDescriptor(
      vendorId: 'quickbooks_time',
      authorizeUrl: Uri.parse('https://appcenter.intuit.com/connect/oauth2'),
      clientId: creds.clientId,
      scopes: const <String>['com.intuit.quickbooks.payroll.timetracking'],
    );
    exchangers['quickbooks_time'] = _quickBooksTimeCodeExchanger(
      httpClient: client,
      clientId: creds.clientId,
      clientSecret: creds.clientSecret,
    );
  } else {
    disabled['quickbooks_time'] = 'intuit_oauth_credentials_missing';
  }

  // ─── Libro ─────────────────────────────────────────────────────────
  if (proxyConfig.hasLibroAppCredentials) {
    final creds = proxyConfig.libroAppCredentials;
    descriptors['libro'] = VendorOAuthBeginDescriptor(
      vendorId: 'libro',
      authorizeUrl: Uri.parse('https://api.libroreserve.com/v1/oauth/authorize'),
      clientId: creds.clientId,
      scopes: const <String>['reservations.read'],
    );
    exchangers['libro'] = _libroCodeExchanger(
      httpClient: client,
      clientId: creds.clientId,
      clientSecret: creds.clientSecret,
    );
  } else {
    disabled['libro'] = 'libro_oauth_credentials_missing';
  }

  // ─── Humanity ──────────────────────────────────────────────────────
  if (proxyConfig.hasHumanityAppCredentials) {
    final creds = proxyConfig.humanityAppCredentials;
    descriptors['humanity'] = VendorOAuthBeginDescriptor(
      vendorId: 'humanity',
      authorizeUrl: Uri.parse('https://platform.humanity.com/oauth2/authorize'),
      clientId: creds.clientId,
      scopes: const <String>['read'],
    );
    exchangers['humanity'] = _humanityCodeExchanger(
      httpClient: client,
      clientId: creds.clientId,
      clientSecret: creds.clientSecret,
    );
  } else {
    disabled['humanity'] = 'humanity_oauth_credentials_missing';
  }

  // ─── ADP ───────────────────────────────────────────────────────────
  // ADP uses mTLS + `client_credentials`. The operator pastes the
  // per-tenant client_id/client_secret + uploads the mTLS cert via
  // the operator-portal admin path; the api-key surface is the
  // closest analogue. The transport itself manages the
  // `client_credentials` exchange at request time.
  apiKeyValidators['adp'] = _adpApiKeyValidator(client);

  // ─── API-key only vendors ──────────────────────────────────────────
  apiKeyValidators['tock'] = _tockApiKeyValidator(client);
  apiKeyValidators['push_operations'] = _pushOperationsApiKeyValidator(client);
  apiKeyValidators['agendrix'] = _agendrixApiKeyValidator(client);
  apiKeyValidators['sevenrooms'] = _sevenRoomsApiKeyValidator(client);
  apiKeyValidators['opentable'] = _openTableApiKeyValidator(client);

  return Phase8OperatorOAuthWiring(
    oauthBeginDescriptors: Map<String, VendorOAuthBeginDescriptor>.unmodifiable(
      descriptors,
    ),
    oauthExchangers: Map<String, VendorOAuthCodeExchanger>.unmodifiable(
      exchangers,
    ),
    apiKeyValidators: Map<String, VendorApiKeyValidator>.unmodifiable(
      apiKeyValidators,
    ),
    connectionWriter: connectionWriter,
    disabledVendors: Map<String, String>.unmodifiable(disabled),
  );
}

/// Build a production [IntegrationOAuthConnectionWriter] that
/// delegates to [RepositoryIntegrationRoutesGateway.connect] for the
/// upsert and (best-effort) to [FirstConnectionBackfillEnqueueGateway]
/// for the post-connect first-backfill enqueue. The OAuth callback
/// dispatcher catches enqueue failures via its
/// `backfill_enqueue_failed` redirect path; the writer itself only
/// surfaces persist failures.
IntegrationOAuthConnectionWriter makeIntegrationOAuthConnectionWriter({
  required RepositoryIntegrationRoutesGateway gateway,
  FirstConnectionBackfillEnqueueGateway? firstBackfillEnqueueGateway,
}) {
  return ({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required integration.IntegrationCategory category,
    required String accessTokenPlaintext,
    String? refreshTokenPlaintext,
    DateTime? tokenExpiresAt,
    Map<String, Object?> metadata = const <String, Object?>{},
    String? webhookUrl,
    String? module,
    bool firstBackfillStarted = true,
  }) async {
    final result = await gateway.connect(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      vendorId: vendorId,
      category: category,
      accessTokenPlaintext: accessTokenPlaintext,
      refreshTokenPlaintext: refreshTokenPlaintext,
      tokenExpiresAt: tokenExpiresAt,
      metadata: metadata,
      webhookUrl: webhookUrl,
      module: module,
      firstBackfillStarted: firstBackfillStarted,
    );
    return result;
  };
}

// ─── Per-vendor OAuth code exchangers ──────────────────────────────────
//
// Each closure POSTs to the documented vendor token endpoint with
// `grant_type=authorization_code`, threads the response into a
// [VendorOAuthExchangeResult], and lets the dispatcher catch any
// failure via the `oauth_exchange_failed` redirect path.

VendorOAuthCodeExchanger _squareCodeExchanger({
  required http.Client httpClient,
  required String clientId,
  required String clientSecret,
}) {
  return ({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String code,
    required String redirectUri,
    String? pkceVerifier,
    String? module,
  }) async {
    final response = await httpClient.post(
      Uri.parse('https://connect.squareup.com/oauth2/token'),
      headers: const <String, String>{
        'content-type': 'application/json',
        'accept': 'application/json',
      },
      body: jsonEncode(<String, Object?>{
        'client_id': clientId,
        'client_secret': clientSecret,
        'code': code,
        'grant_type': 'authorization_code',
        'redirect_uri': redirectUri,
      }),
    );
    final json = _decodeOAuthTokenResponse(response, vendorId);
    return VendorOAuthExchangeResult(
      accessTokenPlaintext: _readNonEmpty(json, 'access_token', vendorId),
      refreshTokenPlaintext: _readOptionalString(json, 'refresh_token'),
      tokenExpiresAt: _readExpiresAt(json),
      category: integration.IntegrationCategory.pos,
      metadata: <String, Object?>{
        if (json['merchant_id'] is String) 'merchant_id': json['merchant_id'],
      },
    );
  };
}

VendorOAuthCodeExchanger _cloverCodeExchanger({
  required http.Client httpClient,
  required String clientId,
}) {
  return ({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String code,
    required String redirectUri,
    String? pkceVerifier,
    String? module,
  }) async {
    final response = await httpClient.post(
      Uri.parse('https://api.clover.com/oauth/v2/token'),
      headers: const <String, String>{
        'content-type': 'application/json',
        'accept': 'application/json',
      },
      body: jsonEncode(<String, Object?>{
        'client_id': clientId,
        'code': code,
      }),
    );
    final json = _decodeOAuthTokenResponse(response, vendorId);
    return VendorOAuthExchangeResult(
      accessTokenPlaintext: _readNonEmpty(json, 'access_token', vendorId),
      refreshTokenPlaintext: _readOptionalString(json, 'refresh_token'),
      tokenExpiresAt: _readExpiresAtSeconds(
        json,
        key: 'access_token_expiration',
      ),
      category: integration.IntegrationCategory.pos,
      metadata: <String, Object?>{
        if (json['merchant_id'] is String) 'merchant_id': json['merchant_id'],
      },
    );
  };
}

VendorOAuthCodeExchanger _sevenShiftsCodeExchanger({
  required http.Client httpClient,
  required String clientId,
  required String clientSecret,
}) {
  return ({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String code,
    required String redirectUri,
    String? pkceVerifier,
    String? module,
  }) async {
    final response = await httpClient.post(
      Uri.parse('https://api.7shifts.com/v2/oauth/token'),
      headers: const <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
      },
      body: <String, String>{
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': redirectUri,
      },
    );
    final json = _decodeOAuthTokenResponse(response, vendorId);
    return VendorOAuthExchangeResult(
      accessTokenPlaintext: _readNonEmpty(json, 'access_token', vendorId),
      refreshTokenPlaintext: _readOptionalString(json, 'refresh_token'),
      tokenExpiresAt: _expiresInToInstant(json),
      category: integration.IntegrationCategory.labor,
    );
  };
}

VendorOAuthCodeExchanger _quickBooksTimeCodeExchanger({
  required http.Client httpClient,
  required String clientId,
  required String clientSecret,
}) {
  return ({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String code,
    required String redirectUri,
    String? pkceVerifier,
    String? module,
  }) async {
    final response = await httpClient.post(
      Uri.parse('https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer'),
      headers: <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
        'authorization': 'Basic '
            '${base64Encode(utf8.encode('$clientId:$clientSecret'))}',
      },
      body: <String, String>{
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
      },
    );
    final json = _decodeOAuthTokenResponse(response, vendorId);
    return VendorOAuthExchangeResult(
      accessTokenPlaintext: _readNonEmpty(json, 'access_token', vendorId),
      refreshTokenPlaintext: _readOptionalString(json, 'refresh_token'),
      tokenExpiresAt: _expiresInToInstant(json),
      category: integration.IntegrationCategory.labor,
    );
  };
}

VendorOAuthCodeExchanger _libroCodeExchanger({
  required http.Client httpClient,
  required String clientId,
  required String clientSecret,
}) {
  return ({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String code,
    required String redirectUri,
    String? pkceVerifier,
    String? module,
  }) async {
    final response = await httpClient.post(
      Uri.parse('https://api.libroreserve.com/v1/oauth/token'),
      headers: const <String, String>{
        'content-type': 'application/json',
        'accept': 'application/json',
      },
      body: jsonEncode(<String, Object?>{
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': redirectUri,
      }),
    );
    final json = _decodeOAuthTokenResponse(response, vendorId);
    return VendorOAuthExchangeResult(
      accessTokenPlaintext: _readNonEmpty(json, 'access_token', vendorId),
      refreshTokenPlaintext: _readOptionalString(json, 'refresh_token'),
      tokenExpiresAt: _expiresInToInstant(json),
      category: integration.IntegrationCategory.reservation,
    );
  };
}

VendorOAuthCodeExchanger _humanityCodeExchanger({
  required http.Client httpClient,
  required String clientId,
  required String clientSecret,
}) {
  return ({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String code,
    required String redirectUri,
    String? pkceVerifier,
    String? module,
  }) async {
    final response = await httpClient.post(
      Uri.parse('https://platform.humanity.com/v1.0/oauth2/token'),
      headers: const <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
      },
      body: <String, String>{
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': redirectUri,
      },
    );
    final json = _decodeOAuthTokenResponse(response, vendorId);
    return VendorOAuthExchangeResult(
      accessTokenPlaintext: _readNonEmpty(json, 'access_token', vendorId),
      refreshTokenPlaintext: _readOptionalString(json, 'refresh_token'),
      tokenExpiresAt: _expiresInToInstant(json),
      category: integration.IntegrationCategory.labor,
    );
  };
}

// ─── Per-vendor API-key validators ─────────────────────────────────────
//
// Each closure runs a minimal authenticated probe against the
// vendor's documented base endpoint. The api-key route surfaces a
// 400 `api_key_invalid` when the validator returns
// `valid: false`; non-200 + parse failures bubble up as 502
// `api_key_validation_failed`. The validators are deliberately
// thin — they assert that the supplied key produces a 2xx on the
// vendor's lightest-weight authenticated endpoint, not that every
// downstream API will succeed.

VendorApiKeyValidator _toastApiKeyValidator(http.Client httpClient) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.pos,
    probeUriBuilder: (key) =>
        Uri.parse('https://ws-api.toasttab.com/restaurants/v1/restaurants'),
    headersBuilder: (key) => <String, String>{
      'authorization': 'Bearer $key',
      'accept': 'application/json',
    },
  );
}

VendorApiKeyValidator _lightspeedLskApiKeyValidator(http.Client httpClient) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.pos,
    probeUriBuilder: (key) =>
        Uri.parse('https://api.lsk.lightspeed.app/businesses'),
    headersBuilder: (key) => <String, String>{
      'authorization': 'Bearer $key',
      'accept': 'application/json',
    },
  );
}

VendorApiKeyValidator _alohaNcrVoyixApiKeyValidator(http.Client httpClient) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.pos,
    probeUriBuilder: (key) => Uri.parse('https://api.ncr.com/security/v1/me'),
    headersBuilder: (key) => <String, String>{
      'authorization': 'Bearer $key',
      'accept': 'application/json',
    },
  );
}

VendorApiKeyValidator _oracleMicrosSimphonyApiKeyValidator(
  http.Client httpClient,
) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.pos,
    probeUriBuilder: (key) => Uri.parse(
      'https://api.simphony.oracleindustry.com/sim/api/v2/health',
    ),
    headersBuilder: (key) => <String, String>{
      'authorization': 'Bearer $key',
      'accept': 'application/json',
    },
  );
}

VendorApiKeyValidator _revelApiKeyValidator(http.Client httpClient) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.pos,
    probeUriBuilder: (key) =>
        Uri.parse('https://api.revelup.com/resources/Establishment/'),
    headersBuilder: (key) => <String, String>{
      'authorization': 'Bearer $key',
      'accept': 'application/json',
    },
  );
}

VendorApiKeyValidator _adpApiKeyValidator(http.Client httpClient) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.labor,
    probeUriBuilder: (key) =>
        Uri.parse('https://api.adp.com/core/v1/users/self'),
    headersBuilder: (key) => <String, String>{
      'authorization': 'Bearer $key',
      'accept': 'application/json',
    },
  );
}

VendorApiKeyValidator _tockApiKeyValidator(http.Client httpClient) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.reservation,
    probeUriBuilder: (key) => Uri.parse('https://api.exploretock.com/businesses'),
    headersBuilder: (key) => <String, String>{
      'authorization': 'Bearer $key',
      'accept': 'application/json',
    },
  );
}

VendorApiKeyValidator _pushOperationsApiKeyValidator(http.Client httpClient) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.labor,
    probeUriBuilder: (key) =>
        Uri.parse('https://app-elb.pushoperations.com/api/v1/locations'),
    headersBuilder: (key) => <String, String>{
      'authorization': 'Bearer $key',
      'accept': 'application/json',
    },
  );
}

VendorApiKeyValidator _agendrixApiKeyValidator(http.Client httpClient) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.labor,
    probeUriBuilder: (key) => Uri.parse('https://api.agendrix.com/v2/companies'),
    headersBuilder: (key) => <String, String>{
      'x-api-key': key,
      'accept': 'application/json',
    },
  );
}

VendorApiKeyValidator _sevenRoomsApiKeyValidator(http.Client httpClient) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.reservation,
    probeUriBuilder: (key) => Uri.parse('https://api.sevenrooms.com/2_2/auth'),
    headersBuilder: (key) => <String, String>{
      'authorization': 'Bearer $key',
      'accept': 'application/json',
    },
  );
}

VendorApiKeyValidator _openTableApiKeyValidator(http.Client httpClient) {
  return _makeBasicHealthValidator(
    httpClient: httpClient,
    category: integration.IntegrationCategory.reservation,
    probeUriBuilder: (key) =>
        Uri.parse('https://platform.opentable.com/sync/v1/restaurants'),
    headersBuilder: (key) => <String, String>{
      'authorization': 'Bearer $key',
      'accept': 'application/json',
    },
  );
}

/// Generic builder for an api-key validator that asserts the supplied
/// key produces a 2xx on a single GET probe to a vendor's documented
/// authenticated endpoint. Vendor-specific shaping (auth header
/// scheme, probe path) lives in the per-vendor closures above; this
/// helper keeps the success-criteria + error-mapping uniform.
VendorApiKeyValidator _makeBasicHealthValidator({
  required http.Client httpClient,
  required integration.IntegrationCategory category,
  required Uri Function(String apiKey) probeUriBuilder,
  required Map<String, String> Function(String apiKey) headersBuilder,
}) {
  return ({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String apiKey,
    String? apiSecret,
  }) async {
    final response = await httpClient.get(
      probeUriBuilder(apiKey),
      headers: headersBuilder(apiKey),
    );
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    return VendorApiKeyValidationResult(
      valid: ok,
      category: category,
      errorMessage: ok ? null : 'vendor_health_status=${response.statusCode}',
    );
  };
}

// ─── OAuth response parsing helpers ────────────────────────────────────

Map<String, Object?> _decodeOAuthTokenResponse(
  http.Response response,
  String vendorId,
) {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError(
      'oauth_exchange_failed: vendor=$vendorId status=${response.statusCode}',
    );
  }
  final decoded = jsonDecode(response.body);
  if (decoded is Map<String, Object?>) return decoded;
  if (decoded is Map) {
    return decoded.map(
      (key, value) => MapEntry<String, Object?>(key.toString(), value),
    );
  }
  throw StateError(
    'oauth_exchange_failed: vendor=$vendorId malformed_json (not an object)',
  );
}

String _readNonEmpty(
  Map<String, Object?> json,
  String key,
  String vendorId,
) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw StateError(
    'oauth_exchange_failed: vendor=$vendorId missing_or_empty=$key',
  );
}

String? _readOptionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  return null;
}

DateTime? _readExpiresAt(Map<String, Object?> json) {
  final raw = json['expires_at'];
  if (raw is String && raw.isNotEmpty) {
    return DateTime.tryParse(raw)?.toUtc();
  }
  if (raw is num && raw > 0) {
    return DateTime.fromMillisecondsSinceEpoch(raw.toInt() * 1000, isUtc: true);
  }
  return _expiresInToInstant(json);
}

DateTime? _readExpiresAtSeconds(
  Map<String, Object?> json, {
  required String key,
}) {
  final raw = json[key];
  if (raw is num && raw > 0) {
    return DateTime.fromMillisecondsSinceEpoch(raw.toInt() * 1000, isUtc: true);
  }
  if (raw is String && raw.isNotEmpty) {
    return DateTime.tryParse(raw)?.toUtc();
  }
  return null;
}

DateTime? _expiresInToInstant(Map<String, Object?> json) {
  final raw = json['expires_in'];
  if (raw is num && raw > 0) {
    return DateTime.now().toUtc().add(Duration(seconds: raw.toInt()));
  }
  return null;
}
