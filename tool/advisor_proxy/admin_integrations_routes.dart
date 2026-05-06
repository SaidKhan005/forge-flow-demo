// Phase 8.0 — Cloud Run admin + webhook routes for the inbound
// integration framework.
//
// Hosts:
//
//   * GET  /v1/admin/operators/:operator_id/locations/:location_id/integrations
//   * POST /v1/admin/integrations/oauth/{vendor}/start
//   * GET  /v1/admin/integrations/oauth/{vendor}/callback
//   * POST /v1/admin/integrations/{vendor}/connect-key
//   * POST /v1/admin/integrations/{vendor}/test-connection
//   * POST /v1/admin/integrations/{vendor}/disconnect
//   * GET  /v1/admin/integrations/{vendor}/logs
//   * POST /v1/webhooks/{vendor}/{operator_id}/{location_id}
//
// All admin writes are idempotent via the existing `proxy_requests`
// table (HARD-H), keyed on the `Idempotency-Key` request header.
// Permission gate: every /v1/admin/integrations/* and /v1/webhooks/*
// route requires `integrations.configure`. `location_manager` is
// denied at the role-permission layer; the gate translates that into
// 403.
//
// The router is intentionally self-contained: `tryHandle` returns
// `false` when the request does not match any Phase 8.0 path so the
// caller (main.dart marked region) can fall through to the existing
// `routeRequest` dispatcher untouched.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart'
    as integration;

/// Inbound idempotency / routing surface for the proxy. Production
/// wires a Postgres-backed gateway; tests pass a fake.
abstract class IntegrationRoutesGateway {
  /// Read the per-(operator, location) bundle: connector_connection
  /// rows + demo_mode_state + last_sync_at telemetry.
  Future<Map<String, Object?>> listForLocation({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  });

  /// Start the OAuth flow for [vendorId]. Returns a `redirect_url`
  /// the caller's browser should follow; production stamps an
  /// HMAC-signed `state` token tied to (operator, location, vendor).
  Future<Map<String, Object?>> startOAuth({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    String? module,
  });

  /// Handle the OAuth callback. Verifies the `state` token, exchanges
  /// the code for a token envelope, persists into `vendor_credentials`,
  /// inserts a `connector_connection` row.
  Future<Map<String, Object?>> handleOAuthCallback({
    required String vendorId,
    required Map<String, String> queryParameters,
  });

  /// Persist a key-paste credential.
  Future<Map<String, Object?>> connectViaKeyPaste({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String apiKey,
    String? username,
    String? module,
  });

  /// Heavy on-demand sample-pull diagnostic.
  Future<Map<String, Object?>> testConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
  });

  /// Wipe credentials, stop sync, optionally unregister webhook.
  /// Watermark is preserved so reconnect resumes from cursor.
  Future<Map<String, Object?>> disconnect({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String reason,
  });

  /// Sync log viewer.
  Future<List<Map<String, Object?>>> listSyncLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  });

  /// Permission gate. Implementations route through the existing
  /// `ProxyAdminPermissionGuard` so revocation flows through cache
  /// invalidation correctly.
  Future<bool> hasIntegrationsConfigurePermission({
    required String operatorId,
    required String userId,
  });
}

/// Lane 1 seam for creating durable first-connection backfill work after
/// credentials and `connector_connection` have already been persisted.
abstract class FirstConnectionBackfillEnqueueGateway {
  Future<FirstConnectionBackfillJob> enqueueFirstBackfill({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String vendorId,
    required integration.IntegrationCategory category,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? actorUserId,
  });
}

typedef IntegrationCategoryResolver =
    integration.IntegrationCategory? Function(
      String vendorId,
      Map<String, Object?> connectResult,
    );

/// Authenticated context resolved from the inbound JWT.
class AdminActorContext {
  const AdminActorContext({
    required this.operatorId,
    required this.locationId,
    required this.userId,
  });

  final String operatorId;
  final String locationId;
  final String userId;
}

/// Resolves an admin actor from an inbound `Authorization` header.
typedef AdminActorResolver =
    Future<AdminActorContext?> Function(HttpRequest request);

/// Bindings holder so the marked-region call in main.dart can stay
/// a one-liner. Production main.dart sets these once at startup;
/// tests construct a router directly via the public constructor.
abstract class Phase80IntegrationRoutesBindingsHolder {
  IntegrationRoutesGateway get gateway;
  AdminActorResolver get actorResolver;
  InboundWebhookHandler get webhookHandler;
  FirstConnectionBackfillEnqueueGateway? get firstBackfillEnqueueGateway =>
      null;
  IntegrationCategoryResolver? get integrationCategoryResolver => null;
}

/// Phase 8.0 router. Top-level entry point is [tryHandle].
class Phase80IntegrationRoutes {
  Phase80IntegrationRoutes({
    required this.gateway,
    required this.actorResolver,
    required this.webhookHandler,
    this.firstBackfillEnqueueGateway,
    this.integrationCategoryResolver,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Lazy-cached router built on first dispatch from the global
  /// [globalBindings] holder. The marked region in main.dart sets
  /// the holder during startup; subsequent dispatches reuse the
  /// cached router so dependency construction does not run per
  /// request.
  static Phase80IntegrationRoutes? _cached;
  static Phase80IntegrationRoutesBindingsHolder? globalBindings;

  /// One-liner dispatch surface used by the main.dart marked
  /// region. Returns `true` when the request matched; the caller
  /// short-circuits the existing dispatcher in that case.
  static Future<bool> tryHandleStatic(HttpRequest request) async {
    final bindings = globalBindings;
    if (bindings == null) return false;
    final router = _cached ??= Phase80IntegrationRoutes(
      gateway: bindings.gateway,
      actorResolver: bindings.actorResolver,
      webhookHandler: bindings.webhookHandler,
      firstBackfillEnqueueGateway: bindings.firstBackfillEnqueueGateway,
      integrationCategoryResolver: bindings.integrationCategoryResolver,
    );
    return router.tryHandle(request);
  }

  final IntegrationRoutesGateway gateway;
  final AdminActorResolver actorResolver;
  final InboundWebhookHandler webhookHandler;
  final FirstConnectionBackfillEnqueueGateway? firstBackfillEnqueueGateway;
  final IntegrationCategoryResolver? integrationCategoryResolver;
  // Reserved for future per-request log timestamp injection.
  // ignore: unused_field
  final DateTime Function() _now;

  /// Returns `true` when [request] matched and was handled. Returns
  /// `false` when the path is not a Phase 8.0 path; the caller
  /// should then fall through to the existing dispatcher.
  Future<bool> tryHandle(HttpRequest request) async {
    final path = request.uri.path;
    if (!_isPhase80Path(path)) return false;
    try {
      if (path.startsWith('/v1/webhooks/')) {
        await _handleWebhook(request);
        return true;
      }
      await _handleAdmin(request);
      return true;
    } catch (error, stack) {
      // Defensive: the marked-region call site does not catch our
      // throws, so any uncaught exception here would propagate to
      // the listener loop. Return a 500 with the error stringified
      // so the main loop's structured log captures the right field.
      _writeJson(request.response, 500, <String, Object?>{
        'error': 'phase_8_0_route_error',
        'message': error.toString(),
        'stack_first_frame': _firstStackFrame(stack),
      });
      return true;
    }
  }

  Future<void> _handleAdmin(HttpRequest request) async {
    final actor = await actorResolver(request);
    if (actor == null) {
      _writeJson(request.response, 401, <String, Object?>{
        'error': 'unauthorized',
      });
      return;
    }

    final permitted = await gateway.hasIntegrationsConfigurePermission(
      operatorId: actor.operatorId,
      userId: actor.userId,
    );
    if (!permitted) {
      _writeJson(request.response, 403, <String, Object?>{
        'error': 'forbidden',
        'message':
            'integrations.configure required (location_manager and other roles '
            'without this key cannot configure vendor connections).',
      });
      return;
    }

    final method = request.method;
    final path = request.uri.path;

    // GET /v1/admin/operators/:operator_id/locations/:location_id/integrations
    final locationListMatch = _locationIntegrationsListPattern.firstMatch(path);
    if (method == 'GET' && locationListMatch != null) {
      final operatorId = locationListMatch.group(1)!;
      final locationId = locationListMatch.group(2)!;
      if (!_actorScopeOk(
        actor: actor,
        operatorId: operatorId,
        locationId: locationId,
        response: request.response,
      )) {
        return;
      }
      final bundle = await gateway.listForLocation(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actor.userId,
      );
      _writeJson(request.response, 200, bundle);
      return;
    }

    // POST /v1/admin/integrations/oauth/{vendor}/start
    final oauthStartMatch = _oauthStartPattern.firstMatch(path);
    if (method == 'POST' && oauthStartMatch != null) {
      final vendorId = oauthStartMatch.group(1)!;
      final body = await _readJsonBody(request);
      final operatorId = _stringField(body, 'operator_id') ?? actor.operatorId;
      final locationId = _stringField(body, 'location_id') ?? actor.locationId;
      if (!_actorScopeOk(
        actor: actor,
        operatorId: operatorId,
        locationId: locationId,
        response: request.response,
      )) {
        return;
      }
      final result = await gateway.startOAuth(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actor.userId,
        vendorId: vendorId,
        module: _stringField(body, 'module'),
      );
      _writeJson(request.response, 200, result);
      return;
    }

    // GET /v1/admin/integrations/oauth/{vendor}/callback
    final oauthCallbackMatch = _oauthCallbackPattern.firstMatch(path);
    if (method == 'GET' && oauthCallbackMatch != null) {
      final vendorId = oauthCallbackMatch.group(1)!;
      final result = await gateway.handleOAuthCallback(
        vendorId: vendorId,
        queryParameters: request.uri.queryParameters,
      );
      final response = await _withFirstBackfillStatus(
        connectResult: result,
        vendorId: vendorId,
      );
      _writeJson(request.response, 200, response);
      return;
    }

    // POST /v1/admin/integrations/{vendor}/connect-key
    final connectKeyMatch = _connectKeyPattern.firstMatch(path);
    if (method == 'POST' && connectKeyMatch != null) {
      final vendorId = connectKeyMatch.group(1)!;
      final body = await _readJsonBody(request);
      final operatorId = _stringField(body, 'operator_id') ?? actor.operatorId;
      final locationId = _stringField(body, 'location_id') ?? actor.locationId;
      if (!_actorScopeOk(
        actor: actor,
        operatorId: operatorId,
        locationId: locationId,
        response: request.response,
      )) {
        return;
      }
      final apiKey = _stringField(body, 'api_key');
      if (apiKey == null) {
        _writeJson(request.response, 400, <String, Object?>{
          'error': 'missing_api_key',
        });
        return;
      }
      final result = await gateway.connectViaKeyPaste(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actor.userId,
        vendorId: vendorId,
        apiKey: apiKey,
        username: _stringField(body, 'username'),
        module: _stringField(body, 'module'),
      );
      final response = await _withFirstBackfillStatus(
        connectResult: result,
        vendorId: vendorId,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actor.userId,
      );
      _writeJson(request.response, 200, response);
      return;
    }

    // POST /v1/admin/integrations/{vendor}/test-connection
    final testMatch = _testConnectionPattern.firstMatch(path);
    if (method == 'POST' && testMatch != null) {
      final vendorId = testMatch.group(1)!;
      final body = await _readJsonBody(request);
      final operatorId = _stringField(body, 'operator_id') ?? actor.operatorId;
      final locationId = _stringField(body, 'location_id') ?? actor.locationId;
      if (!_actorScopeOk(
        actor: actor,
        operatorId: operatorId,
        locationId: locationId,
        response: request.response,
      )) {
        return;
      }
      final result = await gateway.testConnection(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actor.userId,
        vendorId: vendorId,
      );
      _writeJson(request.response, 200, result);
      return;
    }

    // POST /v1/admin/integrations/{vendor}/disconnect
    final disconnectMatch = _disconnectPattern.firstMatch(path);
    if (method == 'POST' && disconnectMatch != null) {
      final vendorId = disconnectMatch.group(1)!;
      final body = await _readJsonBody(request);
      final operatorId = _stringField(body, 'operator_id') ?? actor.operatorId;
      final locationId = _stringField(body, 'location_id') ?? actor.locationId;
      if (!_actorScopeOk(
        actor: actor,
        operatorId: operatorId,
        locationId: locationId,
        response: request.response,
      )) {
        return;
      }
      final result = await gateway.disconnect(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actor.userId,
        vendorId: vendorId,
        reason: _stringField(body, 'reason') ?? 'operator_action',
      );
      _writeJson(request.response, 200, result);
      return;
    }

    // GET /v1/admin/integrations/{vendor}/logs
    final logsMatch = _logsPattern.firstMatch(path);
    if (method == 'GET' && logsMatch != null) {
      final vendorId = logsMatch.group(1)!;
      final qp = request.uri.queryParameters;
      final operatorId = qp['operator_id'] ?? actor.operatorId;
      final locationId = qp['location_id'] ?? actor.locationId;
      if (!_actorScopeOk(
        actor: actor,
        operatorId: operatorId,
        locationId: locationId,
        response: request.response,
      )) {
        return;
      }
      final logs = await gateway.listSyncLogs(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        limit: int.tryParse(qp['limit'] ?? '') ?? 100,
      );
      _writeJson(request.response, 200, <String, Object?>{'logs': logs});
      return;
    }

    _writeJson(request.response, 404, <String, Object?>{
      'error': 'not_found',
      'method': method,
      'path': path,
    });
  }

  Future<void> _handleWebhook(HttpRequest request) async {
    final path = request.uri.path;
    final match = _webhookPattern.firstMatch(path);
    if (match == null) {
      _writeJson(request.response, 404, <String, Object?>{
        'error': 'not_found',
      });
      return;
    }
    final vendorId = match.group(1)!;
    final operatorId = match.group(2)!;
    final locationId = match.group(3)!;

    if (request.method != 'POST') {
      _writeJson(request.response, 405, <String, Object?>{
        'error': 'method_not_allowed',
      });
      return;
    }

    // Preserve raw bytes for HMAC verification — JSON re-serialization
    // breaks vendor signatures.
    final rawBytes = <int>[];
    await for (final chunk in request) {
      rawBytes.addAll(chunk);
    }
    final rawBody = Uint8List.fromList(rawBytes);
    Map<String, Object?> payload = const <String, Object?>{};
    try {
      final decoded = jsonDecode(utf8.decode(rawBody));
      if (decoded is Map<String, Object?>) {
        payload = decoded;
      } else if (decoded is Map) {
        payload = decoded.map(
          (key, value) => MapEntry<String, Object?>(key.toString(), value),
        );
      }
    } catch (_) {
      // Malformed JSON — the handler will dead-letter via parse_error
      // path. The framework still hashes the raw body for idempotency.
    }

    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(',');
    });

    final result = await webhookHandler.dispatch(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      rawBody: rawBody,
      payload: payload,
      headers: headers,
    );
    _writeJson(request.response, result.statusCode, result.toJson());
  }

  /// Returns `true` when the request's (operator, location) matches
  /// the actor context. On mismatch, writes a 403 directly and
  /// returns `false` so the caller can early-return without
  /// double-writing the response.
  bool _actorScopeOk({
    required AdminActorContext actor,
    required String operatorId,
    required String locationId,
    required HttpResponse response,
  }) {
    if (operatorId == actor.operatorId && locationId == actor.locationId) {
      return true;
    }
    // forge_admin actors flow through `runAsSystem` and pass the
    // operator/location explicitly; the resolver fills the actor's
    // own context with the requested operator/location for that
    // path. If they ever differ here, the request is suspect.
    _writeJson(response, 403, <String, Object?>{
      'error': 'forbidden',
      'message': 'actor scope does not match requested (operator, location)',
    });
    return false;
  }

  bool _isPhase80Path(String path) {
    return path.startsWith('/v1/webhooks/') ||
        _locationIntegrationsListPattern.hasMatch(path) ||
        _oauthStartPattern.hasMatch(path) ||
        _oauthCallbackPattern.hasMatch(path) ||
        _connectKeyPattern.hasMatch(path) ||
        _testConnectionPattern.hasMatch(path) ||
        _disconnectPattern.hasMatch(path) ||
        _logsPattern.hasMatch(path);
  }

  Future<Map<String, Object?>> _withFirstBackfillStatus({
    required Map<String, Object?> connectResult,
    required String vendorId,
    String? operatorId,
    String? locationId,
    String? actorUserId,
  }) async {
    final adapterStarted =
        _boolField(connectResult, 'firstBackfillStarted') ??
        _boolField(connectResult, 'first_backfill_started') ??
        false;
    if (!adapterStarted) {
      return <String, Object?>{
        ...connectResult,
        'first_backfill_status': 'not_enqueued',
        'first_backfill': const <String, Object?>{
          'status': 'not_enqueued',
          'reason': 'adapter_reported_first_backfill_not_started',
        },
      };
    }

    final enqueueGateway = firstBackfillEnqueueGateway;
    if (enqueueGateway == null) {
      return <String, Object?>{
        ...connectResult,
        'first_backfill_status': 'unavailable',
        'first_backfill': const <String, Object?>{
          'status': 'unavailable',
          'reason': 'first_backfill_enqueue_gateway_not_configured',
        },
      };
    }

    final resolvedOperatorId =
        operatorId ??
        _stringFromResultAny(connectResult, const <String>[
          'operator_id',
          'operatorId',
        ]);
    final resolvedLocationId =
        locationId ??
        _stringFromResultAny(connectResult, const <String>[
          'location_id',
          'locationId',
        ]);
    final connectionId = _stringFromResultAny(connectResult, const <String>[
      'connection_id',
      'connectionId',
    ]);
    final category =
        _categoryFromResult(connectResult) ??
        integrationCategoryResolver?.call(vendorId, connectResult);

    if (resolvedOperatorId == null ||
        resolvedLocationId == null ||
        connectionId == null ||
        category == null) {
      return <String, Object?>{
        ...connectResult,
        'first_backfill_status': 'unavailable',
        'first_backfill': const <String, Object?>{
          'status': 'unavailable',
          'reason': 'connect_response_missing_backfill_metadata',
        },
      };
    }

    final windowEnd =
        _timestampFromResultAny(connectResult, const <String>[
          'connected_at',
          'connectedAt',
        ]) ??
        _timestampFromResultAny(connectResult, const <String>[
          'created_at',
          'createdAt',
        ]) ??
        _timestampFromResultAny(connectResult, const <String>[
          'updated_at',
          'updatedAt',
        ]) ??
        _now().toUtc();
    final window = FirstConnectionBackfillWindow.lastSixtyDays(windowEnd);
    final job = await enqueueGateway.enqueueFirstBackfill(
      operatorId: resolvedOperatorId,
      locationId: resolvedLocationId,
      connectionId: connectionId,
      vendorId: vendorId,
      category: category,
      windowStart: window.windowStart,
      windowEnd: window.windowEnd,
      actorUserId:
          actorUserId ??
          _stringFromResultAny(connectResult, const <String>[
            'actor_user_id',
            'actorUserId',
          ]),
    );

    return <String, Object?>{
      ...connectResult,
      'first_backfill_status': 'enqueued',
      'first_backfill': <String, Object?>{
        'status': 'enqueued',
        'job': _jobToJson(job),
      },
    };
  }

  static Map<String, Object?> _jobToJson(FirstConnectionBackfillJob job) =>
      <String, Object?>{
        'job_id': job.jobId,
        'operator_id': job.operatorId,
        'location_id': job.locationId,
        'connection_id': job.connectionId,
        'vendor_id': job.vendorId,
        'category': job.category.backfillWire,
        'window_start': job.windowStart.toIso8601String(),
        'window_end': job.windowEnd.toIso8601String(),
        'status': job.status.wire,
        'cursor_token': job.cursorToken,
        'attempt_count': job.attemptCount,
        'created_at': job.createdAt.toIso8601String(),
        'updated_at': job.updatedAt.toIso8601String(),
      };

  static final RegExp _locationIntegrationsListPattern = RegExp(
    r'^/v1/admin/operators/([0-9a-fA-F-]{36})/locations/([0-9a-fA-F-]{36})/integrations$',
  );
  static final RegExp _oauthStartPattern = RegExp(
    r'^/v1/admin/integrations/oauth/([a-z0-9_]+)/start$',
  );
  static final RegExp _oauthCallbackPattern = RegExp(
    r'^/v1/admin/integrations/oauth/([a-z0-9_]+)/callback$',
  );
  static final RegExp _connectKeyPattern = RegExp(
    r'^/v1/admin/integrations/([a-z0-9_]+)/connect-key$',
  );
  static final RegExp _testConnectionPattern = RegExp(
    r'^/v1/admin/integrations/([a-z0-9_]+)/test-connection$',
  );
  static final RegExp _disconnectPattern = RegExp(
    r'^/v1/admin/integrations/([a-z0-9_]+)/disconnect$',
  );
  static final RegExp _logsPattern = RegExp(
    r'^/v1/admin/integrations/([a-z0-9_]+)/logs$',
  );
  static final RegExp _webhookPattern = RegExp(
    r'^/v1/webhooks/([a-z0-9_]+)/([0-9a-fA-F-]{36})/([0-9a-fA-F-]{36})$',
  );

  static Future<Map<String, Object?>> _readJsonBody(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
    }
    if (bytes.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry<String, Object?>(key.toString(), value),
      );
    }
    return const <String, Object?>{};
  }

  static String? _stringField(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  static String? _stringFromResult(Map<String, Object?> result, String key) {
    final direct = result[key];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();
    final connection = result['connection'];
    if (connection is Map) {
      final nested = connection[key];
      if (nested is String && nested.trim().isNotEmpty) return nested.trim();
    }
    return null;
  }

  static String? _stringFromResultAny(
    Map<String, Object?> result,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = _stringFromResult(result, key);
      if (value != null) return value;
    }
    return null;
  }

  static bool? _boolField(Map<String, Object?> result, String key) {
    final direct = result[key];
    if (direct is bool) return direct;
    final connection = result['connection'];
    if (connection is Map) {
      final nested = connection[key];
      if (nested is bool) return nested;
    }
    return null;
  }

  static DateTime? _timestampFromResult(
    Map<String, Object?> result,
    String key,
  ) {
    final direct = result[key];
    final parsedDirect = _timestampFromValue(direct);
    if (parsedDirect != null) return parsedDirect;
    final connection = result['connection'];
    if (connection is Map) return _timestampFromValue(connection[key]);
    return null;
  }

  static DateTime? _timestampFromResultAny(
    Map<String, Object?> result,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = _timestampFromResult(result, key);
      if (value != null) return value;
    }
    return null;
  }

  static DateTime? _timestampFromValue(Object? value) {
    if (value is DateTime) return value.toUtc();
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.parse(value).toUtc();
    }
    return null;
  }

  static integration.IntegrationCategory? _categoryFromResult(
    Map<String, Object?> result,
  ) {
    final raw =
        _stringFromResult(result, 'category') ??
        _stringFromResult(result, 'integrationCategory') ??
        _stringFromResult(result, 'integration_category');
    if (raw == null) return null;
    try {
      return FirstConnectionBackfillCategoryWire.fromWire(raw);
    } on ArgumentError {
      return null;
    }
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
