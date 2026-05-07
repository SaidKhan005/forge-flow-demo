// Phase 8.transport.opentable-reservation — production OpenTable
// HTTP client.
//
// Concrete `OpenTableTransport` against the OpenTable Partner API.
// Until partnership clears (`docs/integrations/opentable/partnership_status.md`)
// the base URLs default to the documented-assumption endpoints
// captured in `documentedPerOpentableV1FieldMapping`; the
// `*.live.sandbox` slice swaps the defaults via the `baseUri` /
// `oauthBaseUri` constructor params (or the `OPENTABLE_API_BASE_URL` /
// `OPENTABLE_OAUTH_BASE_URL` Cloud Run env vars) when partner-issued
// endpoints arrive.
//
// CLAUDE.md alignment:
//
//   * Hard Promise #1 (pure transport swap): this client is wire-only.
//     Canonicalization stays in
//     `OpenTableReservationAdapter._canonicalize`; the transport
//     returns vendor-shape `Map<String, Object?>` rows so
//     time-zone-sensitive ISO-8601 strings (e.g. `reserved_at`,
//     `seated_at`) round-trip with their original UTC offset intact.
//     Per CLAUDE.md Time Guardrails ("Restaurant-local timing wins")
//     the offset MUST NOT be stripped on the way through the
//     transport — the adapter / sink decide whether to project the
//     instant or surface the local-zone string.
//   * Hard Promise #7 (server-side keys only): OAuth client_id /
//     client_secret are injected via [OpenTableCredentialStore] so the
//     production wiring binds them to the Cloud Run env / KMS-backed
//     proxy secret store. No BYO-key surface. The bearer access token
//     for inbound calls is supplied by the caller (the adapter pulls
//     it from the gateway, which reads
//     `vendor_credentials.credential_id` under `withTenant`).
//   * Hard Promise #4 (per-operator isolation): the transport itself
//     is stateless / tenant-agnostic; tenant context is the caller's
//     responsibility. The adapter wraps every call in
//     `OperatorScopedRepository.withTenant`.
//
// V1 lean cut 2 (`memory/project_v1_lean_cut_2_2026_05_03.md`)
// banned items refused by construction: no key-rotation surface, no
// 5-minute replay window, no graceful-drain hook, no parse-warnings
// columns, no DLQ UI, no advisory locks. The 429 retry budget is
// bounded so a stuck vendor cannot hold a Cloud Run worker.
//
// No new pub deps: built on `package:http` + `dart:convert` +
// `dart:math` (already pulled in transitively for ID generation).

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate, HttpException;
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'opentable_reservation_adapter.dart';

// ─── Defaults (assumption — verified in 8R.OT.live.sandbox) ──────────

/// Default partner-API base URI. Mirrors
/// `documentedPerOpentableV1FieldMapping['api_base_url_assumed']`.
const String kOpenTableDefaultApiBaseUri = 'https://platform.opentable.com';

/// Default OAuth base URI. Mirrors
/// `documentedPerOpentableV1FieldMapping['oauth_token_url_assumed']`'s
/// host.
const String kOpenTableDefaultOAuthBaseUri = 'https://oauth-pii.opentable.com';

/// Default OAuth token endpoint path under [kOpenTableDefaultOAuthBaseUri].
const String kOpenTableOAuthTokenPath = '/api/v2/oauth/token';

/// Default OAuth revoke endpoint path.
const String kOpenTableOAuthRevokePath = '/api/v2/oauth/revoke';

/// Default reservations search endpoint under the partner API base.
const String kOpenTableReservationsSearchPath = '/v1/reservations/search';

/// Default per-reservation detail endpoint (interpolates
/// `{reservation_id}`).
const String kOpenTableReservationDetailPathTemplate =
    '/v1/reservations/{reservation_id}';

/// Default webhook subscription endpoint.
const String kOpenTableWebhookSubscriptionsPath = '/v1/webhooks/subscriptions';

/// Default page size requested when walking
/// `/v1/reservations/search`.
const int kOpenTableDefaultPageSize = 100;

/// Default 429 retry policy: exponential backoff capped at 5 attempts
/// with a 30-second ceiling per sleep so a stuck vendor cannot hold a
/// Cloud Run worker indefinitely. The first sleep is 500ms; each
/// subsequent doubles, with a small jitter floor.
const int kOpenTableDefaultMaxRateLimitRetries = 5;
const Duration kOpenTableDefaultRateLimitBaseDelay = Duration(milliseconds: 500);
const Duration kOpenTableDefaultRateLimitMaxDelay = Duration(seconds: 30);

/// Default per-request timeout. Mirrors the admin-gateway timeout
/// (`kAdminHttpRequestTimeout`) so a wedged TCP socket trips a
/// `TimeoutException` rather than blocking the worker.
const Duration kOpenTableDefaultRequestTimeout = Duration(seconds: 30);

// ─── Credential injection ────────────────────────────────────────────

/// OAuth credential bundle injected into [OpenTableReservationProductionApiClient].
///
/// Production wires these to the proxy-side KMS-backed secret store
/// (per Hard Promise #7); tests pin literal strings.
abstract class OpenTableCredentialStore {
  /// OAuth `client_id` for the F&F partner application.
  Future<String> readClientId();

  /// OAuth `client_secret` for the F&F partner application.
  Future<String> readClientSecret();
}

/// Trivial in-memory credential store used by tests + non-prod
/// runtimes. Production binds [OpenTableCredentialStore] to the
/// proxy's secret-resolver so the secret material never lives in app
/// memory longer than the request.
class StaticOpenTableCredentialStore implements OpenTableCredentialStore {
  StaticOpenTableCredentialStore({
    required String clientId,
    required String clientSecret,
  })  : _clientId = clientId,
        _clientSecret = clientSecret;

  final String _clientId;
  final String _clientSecret;

  @override
  Future<String> readClientId() async => _clientId;

  @override
  Future<String> readClientSecret() async => _clientSecret;
}

// ─── Typed errors ────────────────────────────────────────────────────

/// Base type for transport failures. The adapter / framework switches
/// on subtype to drive the right `connector_sync_log.event_kind`.
abstract class OpenTableTransportException implements Exception {
  const OpenTableTransportException({
    required this.method,
    required this.uri,
    required this.statusCode,
    required this.message,
  });

  final String method;
  final Uri uri;
  final int? statusCode;
  final String message;

  @override
  String toString() =>
      'OpenTableTransportException($method $uri statusCode=$statusCode: $message)';
}

/// 401 / 403 from the partner API. The adapter typically reacts by
/// flipping the connector to `disconnected` and forcing a reconnect.
class OpenTableAuthException extends OpenTableTransportException {
  const OpenTableAuthException({
    required super.method,
    required super.uri,
    required super.statusCode,
    required super.message,
  });

  @override
  String toString() =>
      'OpenTableAuthException($method $uri statusCode=$statusCode: $message)';
}

/// 429 surfaced after the rate-limit retry budget is exhausted.
class OpenTableRateLimitedException extends OpenTableTransportException {
  const OpenTableRateLimitedException({
    required super.method,
    required super.uri,
    required this.attempts,
    required super.message,
  })  : super(statusCode: 429);

  final int attempts;

  @override
  String toString() =>
      'OpenTableRateLimitedException($method $uri attempts=$attempts: $message)';
}

/// Catch-all 4xx / 5xx outside auth + rate-limit semantics.
class OpenTableHttpException extends OpenTableTransportException {
  const OpenTableHttpException({
    required super.method,
    required super.uri,
    required super.statusCode,
    required super.message,
    this.responseBody,
  });

  final String? responseBody;

  @override
  String toString() =>
      'OpenTableHttpException($method $uri statusCode=$statusCode: $message)';
}

/// Request did not produce a valid JSON envelope (parse error, empty
/// body where one is required, malformed shape).
class OpenTableMalformedResponseException extends OpenTableTransportException {
  const OpenTableMalformedResponseException({
    required super.method,
    required super.uri,
    required super.statusCode,
    required super.message,
    this.responseBody,
  });

  final String? responseBody;

  @override
  String toString() =>
      'OpenTableMalformedResponseException($method $uri statusCode=$statusCode: $message)';
}

// ─── Production HTTP client ──────────────────────────────────────────

/// Production OpenTable [OpenTableTransport].
///
/// Wires every transport seam against the OpenTable Partner API:
///
///   * OAuth bearer flow (authorization-code on first connect; rotating
///     refresh on cron tick) backed by [OpenTableCredentialStore].
///   * Cursor-based pagination on `/v1/reservations/search`.
///   * Bounded exponential backoff on HTTP 429.
///   * Typed errors so the adapter can react without parsing strings.
///   * `Idempotency-Key` header on every state-mutating POST / DELETE
///     so the proxy + the partner API can dedupe retries.
///   * Time-zone-preserving record envelopes: vendor ISO-8601 strings
///     (`reserved_at`, `modified_at`, and any `seated_at` /
///     `cancelled_at` if present) round-trip intact so the canonical
///     fact write keeps the restaurant-local offset per CLAUDE.md
///     Time Guardrails.
class OpenTableReservationProductionApiClient implements OpenTableTransport {
  OpenTableReservationProductionApiClient({
    required http.Client httpClient,
    required OpenTableCredentialStore credentialStore,
    Uri? baseUri,
    Uri? oauthBaseUri,
    int pageSize = kOpenTableDefaultPageSize,
    int maxRateLimitRetries = kOpenTableDefaultMaxRateLimitRetries,
    Duration rateLimitBaseDelay = kOpenTableDefaultRateLimitBaseDelay,
    Duration rateLimitMaxDelay = kOpenTableDefaultRateLimitMaxDelay,
    Duration requestTimeout = kOpenTableDefaultRequestTimeout,
    Future<void> Function(Duration)? sleep,
    String Function()? idempotencyKeyMinter,
    DateTime Function()? now,
  })  : _httpClient = httpClient,
        _credentialStore = credentialStore,
        _baseUri = baseUri ?? Uri.parse(kOpenTableDefaultApiBaseUri),
        _oauthBaseUri =
            oauthBaseUri ?? Uri.parse(kOpenTableDefaultOAuthBaseUri),
        _pageSize = pageSize,
        _maxRateLimitRetries = maxRateLimitRetries,
        _rateLimitBaseDelay = rateLimitBaseDelay,
        _rateLimitMaxDelay = rateLimitMaxDelay,
        _requestTimeout = requestTimeout,
        _sleep = sleep ?? Future.delayed,
        _idempotencyKeyMinter =
            idempotencyKeyMinter ?? _defaultIdempotencyKeyMinter,
        _now = now ?? DateTime.now;

  final http.Client _httpClient;
  final OpenTableCredentialStore _credentialStore;
  final Uri _baseUri;
  final Uri _oauthBaseUri;
  final int _pageSize;
  final int _maxRateLimitRetries;
  final Duration _rateLimitBaseDelay;
  final Duration _rateLimitMaxDelay;
  final Duration _requestTimeout;
  final Future<void> Function(Duration) _sleep;
  final String Function() _idempotencyKeyMinter;
  final DateTime Function() _now;

  /// Construct a client whose base URIs come from the Cloud Run
  /// environment, falling back to the documented-assumption defaults.
  /// The platform layer calls this from the worker bootstrap so a
  /// single env-var override flips the partner endpoint without a
  /// rebuild.
  factory OpenTableReservationProductionApiClient.fromEnvironment({
    required http.Client httpClient,
    required OpenTableCredentialStore credentialStore,
    required Map<String, String> environment,
  }) {
    final apiOverride = environment['OPENTABLE_API_BASE_URL'];
    final oauthOverride = environment['OPENTABLE_OAUTH_BASE_URL'];
    return OpenTableReservationProductionApiClient(
      httpClient: httpClient,
      credentialStore: credentialStore,
      baseUri: apiOverride != null && apiOverride.isNotEmpty
          ? Uri.parse(apiOverride)
          : null,
      oauthBaseUri: oauthOverride != null && oauthOverride.isNotEmpty
          ? Uri.parse(oauthOverride)
          : null,
    );
  }

  // ─── OAuth ─────────────────────────────────────────────────────────

  @override
  Future<OpenTableTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  }) async {
    final clientId = await _credentialStore.readClientId();
    final clientSecret = await _credentialStore.readClientSecret();
    return _runOAuthTokenCall(
      formFields: <String, String>{
        'grant_type': 'authorization_code',
        'code': authorizationCode,
        'redirect_uri': redirectUri,
        'client_id': clientId,
        'client_secret': clientSecret,
      },
    );
  }

  @override
  Future<OpenTableTokenResponse> refresh({
    required String refreshToken,
  }) async {
    final clientId = await _credentialStore.readClientId();
    final clientSecret = await _credentialStore.readClientSecret();
    return _runOAuthTokenCall(
      formFields: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
        'client_secret': clientSecret,
      },
    );
  }

  @override
  Future<void> revoke({required String accessToken}) async {
    final clientId = await _credentialStore.readClientId();
    final clientSecret = await _credentialStore.readClientSecret();
    final uri = _oauthBaseUri.resolve(kOpenTableOAuthRevokePath);
    final request = http.Request('POST', uri)
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
        'Idempotency-Key': _idempotencyKeyMinter(),
      })
      ..bodyFields = <String, String>{
        'token': accessToken,
        'client_id': clientId,
        'client_secret': clientSecret,
      };
    // Best-effort revoke per the adapter's disconnect contract; vendor
    // outage MUST NOT block disconnect, but a 401 / 4xx still surfaces
    // as a typed exception so the adapter can log + continue.
    await _sendWithRetries(request);
  }

  Future<OpenTableTokenResponse> _runOAuthTokenCall({
    required Map<String, String> formFields,
  }) async {
    final uri = _oauthBaseUri.resolve(kOpenTableOAuthTokenPath);
    final request = http.Request('POST', uri)
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
        'Idempotency-Key': _idempotencyKeyMinter(),
      })
      ..bodyFields = formFields;
    final response = await _sendWithRetries(request);
    final body = _decodeJsonObject(
      method: 'POST',
      uri: uri,
      statusCode: response.statusCode,
      responseBody: response.body,
    );
    final accessToken = body['access_token'];
    final refreshToken = body['refresh_token'];
    final expiresIn = body['expires_in'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw OpenTableMalformedResponseException(
        method: 'POST',
        uri: uri,
        statusCode: response.statusCode,
        message: 'OAuth token response missing access_token',
        responseBody: response.body,
      );
    }
    if (refreshToken is! String || refreshToken.isEmpty) {
      throw OpenTableMalformedResponseException(
        method: 'POST',
        uri: uri,
        statusCode: response.statusCode,
        message: 'OAuth token response missing refresh_token',
        responseBody: response.body,
      );
    }
    final expiresAt = _resolveTokenExpiry(body['expires_at'], expiresIn);
    if (expiresAt == null) {
      throw OpenTableMalformedResponseException(
        method: 'POST',
        uri: uri,
        statusCode: response.statusCode,
        message:
            'OAuth token response missing expires_at / expires_in (cannot compute expiry)',
        responseBody: response.body,
      );
    }
    return OpenTableTokenResponse(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
    );
  }

  // ─── Reservation search + detail ───────────────────────────────────

  @override
  Future<OpenTableReservationsPage> listReservations({
    required String accessToken,
    required String restaurantId,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    final params = <String, String>{
      'modified_since': modifiedSince.toUtc().toIso8601String(),
      'modified_until': modifiedUntil.toUtc().toIso8601String(),
      'page_size': '$_pageSize',
    };
    if (restaurantId.isNotEmpty) {
      params['restaurant_id'] = restaurantId;
    }
    if (cursor != null && cursor.isNotEmpty) {
      params['cursor'] = cursor;
    }
    final uri = _baseUri.resolve(kOpenTableReservationsSearchPath).replace(
          queryParameters: params,
        );
    final request = http.Request('GET', uri)
      ..headers.addAll(<String, String>{
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
      });
    final response = await _sendWithRetries(request);
    final body = _decodeJsonObject(
      method: 'GET',
      uri: uri,
      statusCode: response.statusCode,
      responseBody: response.body,
    );
    final rawRecords = body['reservations'];
    if (rawRecords is! List) {
      throw OpenTableMalformedResponseException(
        method: 'GET',
        uri: uri,
        statusCode: response.statusCode,
        message: 'reservations array missing on search response',
        responseBody: response.body,
      );
    }
    final records = <Map<String, Object?>>[];
    DateTime? lastModified;
    for (final raw in rawRecords) {
      if (raw is! Map) continue;
      // CRITICAL: cast as-is. Do NOT toUtc()/restringify any
      // ISO-8601 timestamp fields — preserving the original offset
      // is the contract per CLAUDE.md Time Guardrails. The adapter +
      // sink decide the projection; the transport stays neutral.
      final record = raw.cast<String, Object?>();
      records.add(record);
      final modifiedAt = record['modified_at'];
      if (modifiedAt is String) {
        final parsed = DateTime.tryParse(modifiedAt);
        if (parsed != null &&
            (lastModified == null || parsed.isAfter(lastModified))) {
          lastModified = parsed;
        }
      }
    }
    final nextCursorRaw = body['next_cursor'];
    final nextCursor =
        (nextCursorRaw is String && nextCursorRaw.isNotEmpty) ? nextCursorRaw : null;
    return OpenTableReservationsPage(
      records: records,
      nextCursor: nextCursor,
      // Fall back to `modifiedSince` so the watermark advances
      // monotonically even on an empty page (mirrors the adapter's
      // existing `lastModifiedSeen ?? command.windowStart` invariant).
      lastModifiedSeen: lastModified ?? modifiedSince.toUtc(),
    );
  }

  @override
  Future<Map<String, Object?>> fetchReservation({
    required String accessToken,
    required String restaurantId,
    required String reservationId,
  }) async {
    final path = kOpenTableReservationDetailPathTemplate.replaceFirst(
      '{reservation_id}',
      Uri.encodeComponent(reservationId),
    );
    final params = <String, String>{};
    if (restaurantId.isNotEmpty) {
      params['restaurant_id'] = restaurantId;
    }
    final uri = _baseUri.resolve(path).replace(
          queryParameters: params.isEmpty ? null : params,
        );
    final request = http.Request('GET', uri)
      ..headers.addAll(<String, String>{
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
      });
    final response = await _sendWithRetries(request);
    final body = _decodeJsonObject(
      method: 'GET',
      uri: uri,
      statusCode: response.statusCode,
      responseBody: response.body,
    );
    final reservation = body['reservation'];
    if (reservation is Map) {
      // Do NOT touch any timestamp string — pass the vendor envelope
      // through with offsets intact.
      return reservation.cast<String, Object?>();
    }
    // Some partner endpoints return the bare envelope.
    return body;
  }

  @override
  Future<Map<String, Object?>> sampleReservation({
    required String accessToken,
    required String restaurantId,
  }) async {
    final params = <String, String>{
      'page_size': '1',
    };
    if (restaurantId.isNotEmpty) {
      params['restaurant_id'] = restaurantId;
    }
    final uri = _baseUri.resolve(kOpenTableReservationsSearchPath).replace(
          queryParameters: params,
        );
    final request = http.Request('GET', uri)
      ..headers.addAll(<String, String>{
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
      });
    final response = await _sendWithRetries(request);
    final body = _decodeJsonObject(
      method: 'GET',
      uri: uri,
      statusCode: response.statusCode,
      responseBody: response.body,
    );
    final reservations = body['reservations'];
    if (reservations is List && reservations.isNotEmpty) {
      final first = reservations.first;
      if (first is Map) {
        return first.cast<String, Object?>();
      }
    }
    return const <String, Object?>{};
  }

  // ─── Webhook subscription management ───────────────────────────────

  @override
  Future<String> registerWebhook({
    required String accessToken,
    required String restaurantId,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async {
    final uri = _baseUri.resolve(kOpenTableWebhookSubscriptionsPath);
    final body = <String, Object?>{
      'restaurant_id': restaurantId,
      'url': url,
      'events': events,
      'signing_secret': signingSecret,
    };
    final request = http.Request('POST', uri)
      ..headers.addAll(<String, String>{
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Idempotency-Key': _idempotencyKeyMinter(),
      })
      ..body = json.encode(body);
    final response = await _sendWithRetries(request);
    final decoded = _decodeJsonObject(
      method: 'POST',
      uri: uri,
      statusCode: response.statusCode,
      responseBody: response.body,
    );
    final subscriptionId = decoded['subscription_id'] ?? decoded['id'];
    if (subscriptionId is! String || subscriptionId.isEmpty) {
      throw OpenTableMalformedResponseException(
        method: 'POST',
        uri: uri,
        statusCode: response.statusCode,
        message:
            'webhook subscription response missing subscription_id / id',
        responseBody: response.body,
      );
    }
    return subscriptionId;
  }

  @override
  Future<void> unregisterWebhook({
    required String accessToken,
    required String restaurantId,
    required String subscriptionId,
  }) async {
    final uri = _baseUri.resolve(
      '$kOpenTableWebhookSubscriptionsPath/${Uri.encodeComponent(subscriptionId)}',
    );
    final request = http.Request('DELETE', uri)
      ..headers.addAll(<String, String>{
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
        'Idempotency-Key': _idempotencyKeyMinter(),
      });
    await _sendWithRetries(request);
  }

  // ─── Send + retry envelope ─────────────────────────────────────────

  /// Drive a single request through the 429 retry budget. 5xx + 401
  /// surface immediately as typed errors; 429 retries with exponential
  /// backoff capped by [_maxRateLimitRetries] and [_rateLimitMaxDelay].
  Future<http.Response> _sendWithRetries(http.BaseRequest request) async {
    var attempts = 0;
    while (true) {
      attempts += 1;
      final replay = await _cloneRequest(request);
      final response = await _sendOnce(replay);
      if (response.statusCode == 429) {
        if (attempts > _maxRateLimitRetries) {
          throw OpenTableRateLimitedException(
            method: request.method,
            uri: request.url,
            attempts: attempts,
            message:
                '429 from OpenTable after $attempts attempts; giving up',
          );
        }
        final delay = _resolveRetryDelay(
          response: response,
          attempt: attempts,
        );
        await _sleep(delay);
        continue;
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw OpenTableAuthException(
          method: request.method,
          uri: request.url,
          statusCode: response.statusCode,
          message:
              'OpenTable auth rejected (${response.statusCode}); reconnect required',
        );
      }
      if (response.statusCode >= 400) {
        throw OpenTableHttpException(
          method: request.method,
          uri: request.url,
          statusCode: response.statusCode,
          message:
              'OpenTable returned ${response.statusCode} on ${request.method} ${request.url.path}',
          responseBody: response.body,
        );
      }
      return response;
    }
  }

  Future<http.Response> _sendOnce(http.BaseRequest request) async {
    try {
      return await (() async {
        final streamed = await _httpClient.send(request);
        return http.Response.fromStream(streamed);
      })()
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw OpenTableHttpException(
        method: request.method,
        uri: request.url,
        statusCode: null,
        message:
            'OpenTable HTTP timeout after ${_requestTimeout.inSeconds}s',
      );
    }
  }

  /// Recreate a fresh request for each retry attempt — `http.BaseRequest`
  /// instances cannot be reused once sent.
  Future<http.BaseRequest> _cloneRequest(http.BaseRequest request) async {
    if (request is http.Request) {
      final clone = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      return clone;
    }
    // Fallback: best-effort clone of the URL + method + headers. The
    // production paths in this file use `http.Request` exclusively, so
    // this branch is defensive.
    final fallback = http.Request(request.method, request.url)
      ..headers.addAll(request.headers);
    return fallback;
  }

  /// Resolve the retry delay from a 429 response. Honors the
  /// `Retry-After` header (seconds OR HTTP-date), capped by
  /// [_rateLimitMaxDelay]; otherwise applies exponential backoff
  /// `_rateLimitBaseDelay * 2 ^ (attempt - 1)`.
  Duration _resolveRetryDelay({
    required http.Response response,
    required int attempt,
  }) {
    final header = response.headers['retry-after'];
    if (header != null && header.isNotEmpty) {
      final asSeconds = int.tryParse(header.trim());
      if (asSeconds != null && asSeconds > 0) {
        return _capDelay(Duration(seconds: asSeconds));
      }
      try {
        final asDate = HttpDate.parse(header);
        final waitMs = asDate.difference(_now().toUtc()).inMilliseconds;
        if (waitMs > 0) {
          return _capDelay(Duration(milliseconds: waitMs));
        }
      } on HttpException {
        // Fall through to exponential backoff.
      } on FormatException {
        // Fall through to exponential backoff.
      }
    }
    final exponent = math.min(attempt - 1, 16);
    final scaled = _rateLimitBaseDelay * math.pow(2, exponent).toDouble();
    return _capDelay(scaled);
  }

  Duration _capDelay(Duration candidate) {
    if (candidate <= Duration.zero) return Duration.zero;
    if (candidate > _rateLimitMaxDelay) return _rateLimitMaxDelay;
    return candidate;
  }

  // ─── JSON helpers ──────────────────────────────────────────────────

  Map<String, Object?> _decodeJsonObject({
    required String method,
    required Uri uri,
    required int statusCode,
    required String responseBody,
  }) {
    if (responseBody.isEmpty) {
      throw OpenTableMalformedResponseException(
        method: method,
        uri: uri,
        statusCode: statusCode,
        message: 'response body empty',
        responseBody: responseBody,
      );
    }
    try {
      final decoded = json.decode(responseBody);
      if (decoded is Map) {
        return decoded.cast<String, Object?>();
      }
      throw OpenTableMalformedResponseException(
        method: method,
        uri: uri,
        statusCode: statusCode,
        message: 'response body was not a JSON object',
        responseBody: responseBody,
      );
    } on FormatException catch (e) {
      throw OpenTableMalformedResponseException(
        method: method,
        uri: uri,
        statusCode: statusCode,
        message: 'response body was not valid JSON: ${e.message}',
        responseBody: responseBody,
      );
    }
  }

  /// Resolve the token expiry from the OAuth response. Prefers
  /// `expires_at` (ISO-8601) when present; falls back to `expires_in`
  /// seconds added to the current clock.
  DateTime? _resolveTokenExpiry(Object? expiresAtRaw, Object? expiresInRaw) {
    if (expiresAtRaw is String && expiresAtRaw.isNotEmpty) {
      final parsed = DateTime.tryParse(expiresAtRaw);
      if (parsed != null) return parsed.toUtc();
    }
    if (expiresInRaw is num) {
      final seconds = expiresInRaw.toInt();
      if (seconds > 0) {
        return _now().toUtc().add(Duration(seconds: seconds));
      }
    }
    return null;
  }
}

// ─── Default idempotency-key minter ──────────────────────────────────

/// RFC-4122-shaped UUID v4. Avoids a pub-dep on `uuid` per the
/// "no new pub deps" constraint; the format is sufficient for the
/// `Idempotency-Key` header (the partner API only requires uniqueness
/// per logical operation, not strict UUID semantics).
final math.Random _defaultIdempotencyRng = math.Random.secure();

String _defaultIdempotencyKeyMinter() {
  final bytes = List<int>.generate(16, (_) => _defaultIdempotencyRng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final s = bytes.map(hex).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}
