// Phase 8 / Wave D `8.transport.lightspeed-lsk-pos` — production HTTP
// transport for the Lightspeed Restaurant K-Series POS adapter.
//
// What this file ships:
//
//   * [LightspeedLskAccessTokenResolver] — narrow seam the production
//     concretes use to resolve an opaque credential id (handed by the
//     gateway) into the plaintext access token bytes for one HTTP call.
//     Production wires this to `vendor_credentials_repository.dart`;
//     tests inject an in-memory map.
//
//   * [LightspeedLskProductionOrdersClient] — concrete
//     `LightspeedLskOrdersClient` that calls the documented K-Series
//     `GET /f/v2/business-location/{businessLocationId}/sales` endpoint.
//
//   * [LightspeedLskProductionOAuthClient] — concrete
//     `LightspeedLskOAuthClient` against the K-Series
//     `POST /oauth/token` (authorization_code + refresh_token) and
//     `POST /oauth/revoke` endpoints.
//
//   * [LightspeedLskProductionWebhookClient] — concrete
//     `LightspeedLskWebhookClient` against the K-Series
//     `PUT /o/wh/1/webhook` registration endpoint and the matching
//     `DELETE /o/wh/1/webhook/{subscriptionId}` unregister endpoint.
//
//   * [LightspeedLskTransportException] — typed error surface for HTTP
//     failures. Carries the HTTP status, vendor error code (when the
//     vendor body decodes as JSON), and a free-text message. The
//     adapter catches this at the framework boundary; surface
//     translation to operator-facing copy is the framework's job.
//
// Constraints honored:
//
//   * Uses `package:http` only. No new pub deps.
//   * Default base URI = `https://api.lsk.lightspeed.app` (production
//     K-Series root; cf.
//     `https://api-portal.lsk.lightspeed.app/quick-start/authentication/authorization-overview`).
//     Override by passing `baseUri` (e.g.
//     `https://api.trial.lsk.lightspeed.app` for sandbox).
//   * OAuth bearer header on every authenticated call. Plaintext
//     resolved per-request via [LightspeedLskAccessTokenResolver]; the
//     token bytes never persist in the client and are not logged.
//   * Pagination on the sales endpoint is cursor-based via
//     `nextPageToken`; the K-Series API also supports `pageSize`. The
//     orders client wraps both into the [LightspeedLskSalesPage]
//     contract the adapter consumes.
//   * 429 backoff: when the vendor returns 429 the client honors the
//     `Retry-After` header (seconds) up to a configurable maximum;
//     missing/zero/oversize values fall back to an exponential schedule
//     capped at [maxRetryDelay]. Total retry budget is capped at
//     [maxRetries].
//   * 401 on the orders + webhook calls is surfaced as a typed
//     [LightspeedLskTransportException] so the framework's OAuth
//     refresh cron path can react. The OAuth client never retries on
//     401 itself (the vendor's auth flow is single-shot).
//   * 5xx, network, and timeout errors are typed via
//     [LightspeedLskTransportException]; the adapter is allowed to
//     surface them as a transient failure and let the next poll retry.
//   * Every POST / PUT / DELETE carries an `Idempotency-Key` header.
//     The orders endpoint is GET-only, so the header is added only on
//     the OAuth + webhook write paths.
//   * Timestamp preservation: vendor sales bodies use ISO-8601 with
//     `Z` (UTC). The orders client returns the bodies as raw maps; the
//     adapter's `_projectCanonicalRecord` parses them with
//     `DateTime.parse(...).toUtc()` so the offset survives intact.
//
// Live verification deferred: the test suite drives a fake `http.Client`
// under happy + 401 + 429 + 500 + timeout + pagination + schema-roundtrip
// paths. Wiring into the runtime sync-worker is the
// `8.LSK.live.sandbox` slice's job.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'lightspeed_lsk_pos_adapter.dart';

/// Default production base URI for the Lightspeed K-Series API.
final Uri kLightspeedLskDefaultBaseUri = Uri.parse(kLightspeedLskProdBaseUrl);

/// Trial / sandbox base URI; pass to the production concretes via
/// `baseUri` when running against the sandbox tenant.
final Uri kLightspeedLskSandboxBaseUri = Uri.parse(kLightspeedLskSandboxBaseUrl);

/// Page size cap the K-Series sales endpoint honors per
/// `https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales`.
/// The adapter's default backfill page size (50) is well under the cap
/// and matches the vendor's recommended pagination size.
const int kLightspeedLskMaxPageSize = 200;

/// Resolves an opaque credential id (the [LightspeedLskGateway] hands
/// the adapter) into a plaintext bearer token for one HTTP call.
///
/// Production wires this to `vendor_credentials_repository.dart`'s
/// system-scoped reader; tests inject an in-memory map. The token
/// bytes never persist in the client and never enter logs.
abstract class LightspeedLskAccessTokenResolver {
  Future<String> resolveAccessToken(String credentialId);

  /// OAuth refresh path: resolve the refresh-token credential id into
  /// the plaintext refresh token. Default implementation reuses
  /// [resolveAccessToken] so callers that store both behind the same
  /// id (the F&F default) need not override.
  Future<String> resolveRefreshToken(String refreshTokenCredentialId) =>
      resolveAccessToken(refreshTokenCredentialId);
}

/// Trivial in-memory resolver for tests. Production never instantiates
/// this — the runtime injects the Postgres-backed reader.
class InMemoryLightspeedLskAccessTokenResolver
    implements LightspeedLskAccessTokenResolver {
  InMemoryLightspeedLskAccessTokenResolver(this.tokens);

  final Map<String, String> tokens;

  @override
  Future<String> resolveAccessToken(String credentialId) async {
    final token = tokens[credentialId];
    if (token == null) {
      throw StateError(
        'lightspeed_lsk: no access token cached for '
        'credential_id=$credentialId',
      );
    }
    return token;
  }

  @override
  Future<String> resolveRefreshToken(String refreshTokenCredentialId) =>
      resolveAccessToken(refreshTokenCredentialId);
}

/// Generates Idempotency-Key values for write requests. Production
/// callers pass a UUID v4 generator; tests pin a deterministic value.
typedef LightspeedLskIdempotencyKeyGenerator = String Function();

/// OAuth client id + secret for the F&F service principal registered
/// with Lightspeed. The production runtime loads these from the GCP
/// Secret Manager / KMS-backed env at startup; tests pass throwaway
/// strings.
class LightspeedLskOAuthClientCredentials {
  const LightspeedLskOAuthClientCredentials({
    required this.clientId,
    required this.clientSecret,
    required this.redirectUri,
  });

  final String clientId;
  final String clientSecret;
  final Uri redirectUri;
}

/// Typed transport exception. The adapter's framework wrapper catches
/// this and routes through the existing connector-sync-log path; the
/// caller can branch on [statusCode] to distinguish auth (401) from
/// transient (429 / 5xx / timeout) from terminal (4xx other).
class LightspeedLskTransportException implements Exception {
  LightspeedLskTransportException({
    required this.message,
    this.statusCode,
    this.vendorErrorCode,
    this.cause,
  });

  factory LightspeedLskTransportException.timeout(Duration after) =>
      LightspeedLskTransportException(
        message: 'lightspeed_lsk: request timed out after '
            '${after.inMilliseconds}ms',
        statusCode: null,
      );

  factory LightspeedLskTransportException.network(Object cause) =>
      LightspeedLskTransportException(
        message: 'lightspeed_lsk: network error (${cause.runtimeType})',
        cause: cause,
      );

  factory LightspeedLskTransportException.fromResponse(
    http.Response response, {
    String? vendorErrorCode,
  }) {
    return LightspeedLskTransportException(
      message: 'lightspeed_lsk: HTTP ${response.statusCode} '
          '${_truncate(response.body, 240)}',
      statusCode: response.statusCode,
      vendorErrorCode: vendorErrorCode,
    );
  }

  final String message;
  final int? statusCode;
  final String? vendorErrorCode;
  final Object? cause;

  /// `true` for 401 / 403 — the operator's grant is invalid; the
  /// framework should surface a reconnect prompt.
  bool get isUnauthorized =>
      statusCode == 401 || statusCode == 403;

  /// `true` for 429 / 5xx / network / timeout — the framework retries.
  bool get isTransient =>
      statusCode == null ||
      statusCode == 429 ||
      (statusCode != null && statusCode! >= 500 && statusCode! < 600);

  @override
  String toString() => 'LightspeedLskTransportException('
      'status=$statusCode, vendor=$vendorErrorCode, msg=$message)';

  static String _truncate(String value, int max) =>
      value.length <= max ? value : '${value.substring(0, max)}...';
}

// ─── Shared HTTP helpers ──────────────────────────────────────────────

/// Encapsulates the retry / backoff loop. Lives at the file scope so
/// every concrete (orders / oauth / webhook) shares the same policy
/// without inheritance gymnastics.
class _LightspeedLskRetryPolicy {
  _LightspeedLskRetryPolicy({
    required this.maxRetries,
    required this.initialDelay,
    required this.maxRetryDelay,
    Future<void> Function(Duration)? sleeper,
    math.Random? random,
  })  : _sleeper = sleeper ?? Future<void>.delayed,
        _random = random ?? math.Random();

  final int maxRetries;
  final Duration initialDelay;
  final Duration maxRetryDelay;
  final Future<void> Function(Duration) _sleeper;
  final math.Random _random;

  /// Compute the wait duration before the next retry attempt.
  /// [retryAfterHeader] (when set + parseable) wins; otherwise an
  /// exponential schedule with full jitter, capped at [maxRetryDelay].
  Duration backoffFor(int attempt, String? retryAfterHeader) {
    final fromHeader = _parseRetryAfterSeconds(retryAfterHeader);
    if (fromHeader != null) {
      final clamped = fromHeader > maxRetryDelay ? maxRetryDelay : fromHeader;
      return clamped;
    }
    final base =
        initialDelay.inMilliseconds * math.pow(2, attempt).toInt();
    final cap = maxRetryDelay.inMilliseconds;
    final ceiling = base > cap ? cap : base;
    final jittered = _random.nextInt(ceiling + 1);
    return Duration(milliseconds: jittered);
  }

  Future<void> sleep(Duration delay) => _sleeper(delay);

  static Duration? _parseRetryAfterSeconds(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final asInt = int.tryParse(header.trim());
    if (asInt == null || asInt < 0) return null;
    if (asInt > 600) return const Duration(seconds: 600);
    return Duration(seconds: asInt);
  }
}

/// Decode JSON or surface a typed error. Lives at file scope so every
/// concrete shares the same parser.
Map<String, Object?> _decodeJsonObject(String body) {
  if (body.trim().isEmpty) return const <String, Object?>{};
  final decoded = jsonDecode(body);
  if (decoded is Map) {
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }
  throw LightspeedLskTransportException(
    message: 'lightspeed_lsk: response body was not a JSON object',
  );
}

String? _readVendorErrorCode(Map<String, Object?> body) {
  final raw = body['error'] ??
      body['error_code'] ??
      body['errorCode'] ??
      body['code'];
  return raw is String ? raw : null;
}

// ─── Orders client ────────────────────────────────────────────────────

/// Production HTTP client for the K-Series sales endpoint. Implements
/// the [LightspeedLskOrdersClient] seam against
/// `GET /f/v2/business-location/{businessLocationId}/sales`.
class LightspeedLskProductionOrdersClient implements LightspeedLskOrdersClient {
  LightspeedLskProductionOrdersClient({
    required this.tokenResolver,
    Uri? baseUri,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 4,
    Duration initialBackoff = const Duration(milliseconds: 500),
    Duration maxBackoff = const Duration(seconds: 30),
    Future<void> Function(Duration)? sleeper,
    math.Random? random,
  })  : _baseUri = baseUri ?? kLightspeedLskDefaultBaseUri,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _retry = _LightspeedLskRetryPolicy(
          maxRetries: maxRetries,
          initialDelay: initialBackoff,
          maxRetryDelay: maxBackoff,
          sleeper: sleeper,
          random: random,
        );

  final LightspeedLskAccessTokenResolver tokenResolver;
  final Uri _baseUri;
  final http.Client _httpClient;
  final Duration _timeout;
  final _LightspeedLskRetryPolicy _retry;

  @override
  Future<LightspeedLskSalesPage> fetchSalesPage({
    required String accessTokenCredentialId,
    required String businessId,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required int pageSize,
    String? cursorToken,
  }) async {
    final boundedPageSize = pageSize.clamp(1, kLightspeedLskMaxPageSize);
    final query = <String, String>{
      'pageSize': boundedPageSize.toString(),
      'fromDate': windowStartUtc.toUtc().toIso8601String(),
      'toDate': windowEndUtc.toUtc().toIso8601String(),
      if (cursorToken != null && cursorToken.isNotEmpty)
        'pageToken': cursorToken,
    };
    final body = await _getJson(
      pathSegments: <String>[
        'f',
        'v2',
        'business-location',
        businessId,
        'sales',
      ],
      query: query,
      accessTokenCredentialId: accessTokenCredentialId,
    );
    final salesRaw = body['sales'];
    final sales = <Map<String, Object?>>[];
    if (salesRaw is List) {
      for (final entry in salesRaw) {
        if (entry is Map) {
          sales.add(entry.map((k, v) => MapEntry(k.toString(), v)));
        }
      }
    }
    final nextRaw = body['nextPageToken'] ?? body['next_page_token'];
    final next = (nextRaw is String && nextRaw.isNotEmpty) ? nextRaw : null;
    return LightspeedLskSalesPage(sales: sales, nextPageToken: next);
  }

  @override
  Future<Map<String, Object?>> fetchSampleOrder({
    required String accessTokenCredentialId,
    required String businessId,
  }) async {
    // Pick the most recent sale by asking for one row at the most
    // recent page. The vendor's documented sales endpoint orders by
    // `timeOfOpening` desc when `pageSize=1` and no `pageToken` is set.
    final page = await fetchSalesPage(
      accessTokenCredentialId: accessTokenCredentialId,
      businessId: businessId,
      windowStartUtc:
          DateTime.now().toUtc().subtract(const Duration(days: 30)),
      windowEndUtc: DateTime.now().toUtc(),
      pageSize: 1,
    );
    if (page.sales.isEmpty) {
      throw LightspeedLskTransportException(
        message: 'lightspeed_lsk: no sample sale available in the '
            'last 30 days for businessId=$businessId',
        statusCode: 404,
      );
    }
    return page.sales.first;
  }

  Future<Map<String, Object?>> _getJson({
    required List<String> pathSegments,
    required Map<String, String> query,
    required String accessTokenCredentialId,
  }) async {
    final uri = _resolveUri(pathSegments, query);
    var attempt = 0;
    while (true) {
      late final http.Response response;
      try {
        final token =
            await tokenResolver.resolveAccessToken(accessTokenCredentialId);
        final request = http.Request('GET', uri);
        request.headers.addAll(<String, String>{
          'accept': 'application/json',
          'authorization': 'Bearer $token',
        });
        final streamed = await _httpClient.send(request).timeout(_timeout);
        final raw = await streamed.stream.bytesToString().timeout(_timeout);
        response = http.Response(raw, streamed.statusCode,
            headers: streamed.headers);
      } on TimeoutException {
        if (attempt >= _retry.maxRetries) {
          throw LightspeedLskTransportException.timeout(_timeout);
        }
        await _retry.sleep(_retry.backoffFor(attempt, null));
        attempt += 1;
        continue;
      } on http.ClientException catch (cause) {
        if (attempt >= _retry.maxRetries) {
          throw LightspeedLskTransportException.network(cause);
        }
        await _retry.sleep(_retry.backoffFor(attempt, null));
        attempt += 1;
        continue;
      }

      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        return _decodeJsonObject(response.body);
      }
      if (status == 429 ||
          (status >= 500 && status < 600)) {
        if (attempt >= _retry.maxRetries) {
          final body = _safeDecode(response.body);
          throw LightspeedLskTransportException.fromResponse(
            response,
            vendorErrorCode: _readVendorErrorCode(body),
          );
        }
        final delay = _retry.backoffFor(
          attempt,
          response.headers['retry-after'],
        );
        await _retry.sleep(delay);
        attempt += 1;
        continue;
      }
      // Terminal: 4xx other than 429 (auth failures, schema errors).
      final body = _safeDecode(response.body);
      throw LightspeedLskTransportException.fromResponse(
        response,
        vendorErrorCode: _readVendorErrorCode(body),
      );
    }
  }

  Uri _resolveUri(List<String> pathSegments, Map<String, String> query) {
    final basePath = _baseUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final composed = <String>[...basePath, ...pathSegments];
    final resolved = _baseUri.replace(pathSegments: composed);
    if (query.isEmpty) return resolved;
    return resolved.replace(queryParameters: <String, String>{
      ...resolved.queryParameters,
      ...query,
    });
  }

  static Map<String, Object?> _safeDecode(String body) {
    try {
      return _decodeJsonObject(body);
    } catch (_) {
      return const <String, Object?>{};
    }
  }
}

// ─── OAuth client ─────────────────────────────────────────────────────

/// Production HTTP client for the K-Series OAuth endpoints.
class LightspeedLskProductionOAuthClient implements LightspeedLskOAuthClient {
  LightspeedLskProductionOAuthClient({
    required this.clientCredentials,
    required this.tokenResolver,
    required this.persistTokens,
    required this.idempotencyKeyGenerator,
    required this.authorizationCodeFor,
    Uri? baseUri,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
    DateTime Function()? clock,
  })  : _baseUri = baseUri ?? kLightspeedLskDefaultBaseUri,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _clock = clock ?? DateTime.now;

  final LightspeedLskOAuthClientCredentials clientCredentials;
  final LightspeedLskAccessTokenResolver tokenResolver;
  final LightspeedLskIdempotencyKeyGenerator idempotencyKeyGenerator;

  /// Persists the new token pair returned by the vendor and yields the
  /// opaque credential ids the caller will hand back to the gateway.
  /// Production wires this to the credential-store writer; tests
  /// capture the call and return synthetic ids.
  final Future<({String accessTokenCredentialId, String refreshTokenCredentialId})>
      Function({
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAtUtc,
    required List<String> scopes,
  }) persistTokens;

  /// Resolves the OAuth `state` value the caller passed to `connect()`
  /// into the matching `code` parameter the vendor's authorization
  /// callback emitted. Production wires this to the proxy-side state
  /// store; tests inject a deterministic map.
  final Future<String> Function(String oauthState) authorizationCodeFor;

  final Uri _baseUri;
  final http.Client _httpClient;
  final Duration _timeout;
  final DateTime Function() _clock;

  @override
  Future<LightspeedLskTokenExchangeResult> completeAuthorization({
    required String oauthState,
  }) async {
    final code = await authorizationCodeFor(oauthState);
    final form = <String, String>{
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': clientCredentials.redirectUri.toString(),
      'client_id': clientCredentials.clientId,
      'client_secret': clientCredentials.clientSecret,
    };
    final body = await _postForm(
      pathSegments: const <String>['oauth', 'token'],
      form: form,
    );
    return _projectExchangeResult(body);
  }

  @override
  Future<LightspeedLskTokenExchangeResult> refresh({
    required String refreshTokenCredentialId,
  }) async {
    final refreshToken =
        await tokenResolver.resolveRefreshToken(refreshTokenCredentialId);
    final form = <String, String>{
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientCredentials.clientId,
      'client_secret': clientCredentials.clientSecret,
    };
    final body = await _postForm(
      pathSegments: const <String>['oauth', 'token'],
      form: form,
    );
    return _projectExchangeResult(body);
  }

  @override
  Future<void> revoke({required String accessTokenCredentialId}) async {
    final token =
        await tokenResolver.resolveAccessToken(accessTokenCredentialId);
    final form = <String, String>{
      'token': token,
      'client_id': clientCredentials.clientId,
      'client_secret': clientCredentials.clientSecret,
    };
    await _postForm(
      pathSegments: const <String>['oauth', 'revoke'],
      form: form,
      expectJsonResponse: false,
    );
  }

  Future<LightspeedLskTokenExchangeResult> _projectExchangeResult(
    Map<String, Object?> body,
  ) async {
    final accessToken = body['access_token'];
    final refreshToken = body['refresh_token'];
    final expiresInRaw = body['expires_in'];
    final scopeRaw = body['scope'];
    final businessIdRaw = body['business_id'] ?? body['businessId'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw LightspeedLskTransportException(
        message:
            'lightspeed_lsk: token endpoint returned no access_token',
      );
    }
    if (refreshToken is! String || refreshToken.isEmpty) {
      throw LightspeedLskTransportException(
        message:
            'lightspeed_lsk: token endpoint returned no refresh_token',
      );
    }
    final expiresIn = expiresInRaw is num
        ? expiresInRaw.toInt()
        : (expiresInRaw is String
            ? int.tryParse(expiresInRaw) ?? 0
            : 0);
    final scopes = scopeRaw is String && scopeRaw.isNotEmpty
        ? scopeRaw.split(RegExp(r'\s+'))
        : const <String>[];
    final businessId = businessIdRaw is String ? businessIdRaw : '';
    final expiresAt = _clock().toUtc().add(Duration(seconds: expiresIn));
    final ids = await persistTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAtUtc: expiresAt,
      scopes: scopes,
    );
    return LightspeedLskTokenExchangeResult(
      businessId: businessId,
      accessTokenCredentialId: ids.accessTokenCredentialId,
      refreshTokenCredentialId: ids.refreshTokenCredentialId,
      tokenExpiresAtUtc: expiresAt,
      scopes: scopes,
    );
  }

  Future<Map<String, Object?>> _postForm({
    required List<String> pathSegments,
    required Map<String, String> form,
    bool expectJsonResponse = true,
  }) async {
    final uri = _resolveUri(pathSegments);
    final encoded = form.entries
        .map((entry) =>
            '${Uri.encodeQueryComponent(entry.key)}='
            '${Uri.encodeQueryComponent(entry.value)}')
        .join('&');
    late final http.Response response;
    try {
      final request = http.Request('POST', uri);
      request.headers.addAll(<String, String>{
        'accept': 'application/json',
        'content-type': 'application/x-www-form-urlencoded',
        'idempotency-key': idempotencyKeyGenerator(),
      });
      request.body = encoded;
      final streamed = await _httpClient.send(request).timeout(_timeout);
      final raw = await streamed.stream.bytesToString().timeout(_timeout);
      response = http.Response(raw, streamed.statusCode,
          headers: streamed.headers);
    } on TimeoutException {
      throw LightspeedLskTransportException.timeout(_timeout);
    } on http.ClientException catch (cause) {
      throw LightspeedLskTransportException.network(cause);
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (!expectJsonResponse) return const <String, Object?>{};
      return _decodeJsonObject(response.body);
    }
    final body = _safeDecode(response.body);
    throw LightspeedLskTransportException.fromResponse(
      response,
      vendorErrorCode: _readVendorErrorCode(body),
    );
  }

  Uri _resolveUri(List<String> pathSegments) {
    final basePath = _baseUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final composed = <String>[...basePath, ...pathSegments];
    return _baseUri.replace(pathSegments: composed);
  }

  static Map<String, Object?> _safeDecode(String body) {
    try {
      return _decodeJsonObject(body);
    } catch (_) {
      return const <String, Object?>{};
    }
  }
}

// ─── Webhook client ───────────────────────────────────────────────────

/// Production HTTP client for the K-Series webhook registration
/// endpoint. Implements `LightspeedLskWebhookClient` against the
/// vendor's `PUT /o/wh/1/webhook` (subscribe) and
/// `DELETE /o/wh/1/webhook/{subscriptionId}` (unregister) routes.
class LightspeedLskProductionWebhookClient
    implements LightspeedLskWebhookClient {
  LightspeedLskProductionWebhookClient({
    required this.tokenResolver,
    required this.persistSigningSecret,
    required this.idempotencyKeyGenerator,
    Uri? baseUri,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 4,
    Duration initialBackoff = const Duration(milliseconds: 500),
    Duration maxBackoff = const Duration(seconds: 30),
    Future<void> Function(Duration)? sleeper,
    math.Random? random,
  })  : _baseUri = baseUri ?? kLightspeedLskDefaultBaseUri,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _retry = _LightspeedLskRetryPolicy(
          maxRetries: maxRetries,
          initialDelay: initialBackoff,
          maxRetryDelay: maxBackoff,
          sleeper: sleeper,
          random: random,
        );

  final LightspeedLskAccessTokenResolver tokenResolver;
  final LightspeedLskIdempotencyKeyGenerator idempotencyKeyGenerator;

  /// Persist the vendor-provided signing secret. The vendor returns it
  /// once on the subscribe response; the production runtime hands the
  /// plaintext to the credential store and yields back an opaque id.
  final Future<String> Function({
    required String subscriptionId,
    required String signingSecret,
  }) persistSigningSecret;

  final Uri _baseUri;
  final http.Client _httpClient;
  final Duration _timeout;
  final _LightspeedLskRetryPolicy _retry;

  @override
  Future<LightspeedLskWebhookSubscription> subscribe({
    required String accessTokenCredentialId,
    required String webhookUrl,
    required String endpointId,
  }) async {
    final body = <String, Object?>{
      'endpointId': endpointId,
      'url': webhookUrl,
      'apiVersion': kLightspeedLskApiVersion,
    };
    final response = await _sendJson(
      method: 'PUT',
      pathSegments: const <String>['o', 'wh', '1', 'webhook'],
      jsonBody: body,
      accessTokenCredentialId: accessTokenCredentialId,
    );
    final subscriptionIdRaw = response['subscriptionId'] ??
        response['id'] ??
        response['subscription_id'];
    if (subscriptionIdRaw is! String || subscriptionIdRaw.isEmpty) {
      throw LightspeedLskTransportException(
        message:
            'lightspeed_lsk: webhook subscribe returned no subscriptionId',
      );
    }
    final secretRaw = response['signingSecret'] ??
        response['secret'] ??
        response['signing_secret'];
    if (secretRaw is! String || secretRaw.isEmpty) {
      throw LightspeedLskTransportException(
        message:
            'lightspeed_lsk: webhook subscribe returned no signingSecret',
      );
    }
    final credentialId = await persistSigningSecret(
      subscriptionId: subscriptionIdRaw,
      signingSecret: secretRaw,
    );
    return LightspeedLskWebhookSubscription(
      subscriptionId: subscriptionIdRaw,
      signingSecretCredentialId: credentialId,
    );
  }

  @override
  Future<void> unregister({
    required String accessTokenCredentialId,
    required String subscriptionId,
  }) async {
    await _sendJson(
      method: 'DELETE',
      pathSegments: <String>['o', 'wh', '1', 'webhook', subscriptionId],
      jsonBody: null,
      accessTokenCredentialId: accessTokenCredentialId,
    );
  }

  Future<Map<String, Object?>> _sendJson({
    required String method,
    required List<String> pathSegments,
    required Map<String, Object?>? jsonBody,
    required String accessTokenCredentialId,
  }) async {
    final uri = _resolveUri(pathSegments);
    var attempt = 0;
    while (true) {
      late final http.Response response;
      try {
        final token =
            await tokenResolver.resolveAccessToken(accessTokenCredentialId);
        final request = http.Request(method, uri);
        request.headers.addAll(<String, String>{
          'accept': 'application/json',
          'authorization': 'Bearer $token',
          'idempotency-key': idempotencyKeyGenerator(),
          if (jsonBody != null) 'content-type': 'application/json',
        });
        if (jsonBody != null) {
          request.body = jsonEncode(jsonBody);
        }
        final streamed = await _httpClient.send(request).timeout(_timeout);
        final raw = await streamed.stream.bytesToString().timeout(_timeout);
        response = http.Response(raw, streamed.statusCode,
            headers: streamed.headers);
      } on TimeoutException {
        if (attempt >= _retry.maxRetries) {
          throw LightspeedLskTransportException.timeout(_timeout);
        }
        await _retry.sleep(_retry.backoffFor(attempt, null));
        attempt += 1;
        continue;
      } on http.ClientException catch (cause) {
        if (attempt >= _retry.maxRetries) {
          throw LightspeedLskTransportException.network(cause);
        }
        await _retry.sleep(_retry.backoffFor(attempt, null));
        attempt += 1;
        continue;
      }

      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        if (response.body.trim().isEmpty) return const <String, Object?>{};
        return _decodeJsonObject(response.body);
      }
      if (status == 429 ||
          (status >= 500 && status < 600)) {
        if (attempt >= _retry.maxRetries) {
          final body = _safeDecode(response.body);
          throw LightspeedLskTransportException.fromResponse(
            response,
            vendorErrorCode: _readVendorErrorCode(body),
          );
        }
        final delay = _retry.backoffFor(
          attempt,
          response.headers['retry-after'],
        );
        await _retry.sleep(delay);
        attempt += 1;
        continue;
      }
      final body = _safeDecode(response.body);
      throw LightspeedLskTransportException.fromResponse(
        response,
        vendorErrorCode: _readVendorErrorCode(body),
      );
    }
  }

  Uri _resolveUri(List<String> pathSegments) {
    final basePath = _baseUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final composed = <String>[...basePath, ...pathSegments];
    return _baseUri.replace(pathSegments: composed);
  }

  static Map<String, Object?> _safeDecode(String body) {
    try {
      return _decodeJsonObject(body);
    } catch (_) {
      return const <String, Object?>{};
    }
  }
}
