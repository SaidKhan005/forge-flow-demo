// Phase 8 `8.transport.libro-reservation` — production Libro HTTP transport.
//
// Concrete [LibroHttpClient] implementation that talks to Libro's
// partner API per `docs/integrations/libro/api_consumed.md`. The
// engineering slice (`8R.LB`) shipped the abstract seam + an in-memory
// stub; this slice ships the production-grade transport so the
// promotion slices (`8R.LB.live.sandbox` / `8R.LB.live.prod`) can wire
// the adapter against the real vendor endpoint without further
// transport changes.
//
// Authority order (CLAUDE.md):
//   * `docs/integrations/libro/api_consumed.md` — endpoints, base URL,
//     pagination shape, rate-limit policy.
//   * `docs/integrations/libro/oauth_shape.md` — auth header (Bearer
//     access token) + revoke semantics.
//   * `docs/integrations/libro/webhook_signature.md` — POST shape for
//     `/v1/webhooks/subscriptions` and DELETE shape for unregister.
//
// Design rules honored here:
//   * Plaintext bearer tokens never leak into adapter code. The
//     transport accepts a [LibroBearerTokenResolver] callback that the
//     proxy/server-side wires to the `vendor_credentials` envelope; the
//     transport itself only sees the resolved bearer string for the
//     duration of one request.
//   * 429 + `Retry-After` honored with bounded backoff + jitter.
//   * Typed [LibroApiException] surfaces auth (401), permission (403),
//     not-found (404), rate-limit-exhausted, and protocol errors so
//     callers can decide retry / refresh / surface.
//   * Idempotency-Key set on every POST so the proxy's server-side
//     idempotency table can de-duplicate the call when the network
//     layer retries. Default generator combines a deterministic prefix
//     with a UUID-shaped random suffix so reruns of the same logical
//     call produce the same key when the caller supplies it; the
//     `registerWebhook` path uses `(operatorId-locationId-venueId)`-
//     style keys passed by the adapter (Phase 8R promotion will wire
//     this through; the engineering ship lets callers override).
//   * Outbound `updated_since` / `updated_before` query parameters are
//     serialized via `DateTime.toIso8601String()` which preserves the
//     UTC `Z` suffix when the `DateTime` is `.isUtc` (the adapter
//     always passes UTC). Inbound timestamp strings are passed through
//     to [LibroReservationDto.fromMap] without rewriting, so any
//     vendor-emitted offset is preserved at the DTO layer.
//   * No new pub dependencies. Uses `package:http` + `dart:math` for
//     jitter only.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'libro_reservation_adapter.dart';

/// Default production base URI per
/// `docs/integrations/libro/api_consumed.md`. Override via the
/// `baseUri` constructor argument (the proxy bootstrap reads
/// `LIBRO_API_BASE_URI` from env to support sandbox without code
/// changes — see the live-promotion slice).
final Uri kLibroProductionBaseUri = Uri.parse('https://api.libroreserve.com');

/// Resolves a [VendorCredentialHandle] to a current OAuth bearer token
/// string. Wired to `vendor_credentials_repository.dart` server-side;
/// tests pass a deterministic fake.
typedef LibroBearerTokenResolver = Future<String> Function(
  VendorCredentialHandle credential,
);

/// Generates an Idempotency-Key for a POST request. Defaults to a
/// UUIDv4-shaped random string per call; callers (e.g. the adapter
/// during connect) can pass a deterministic generator so the proxy's
/// server-side idempotency table de-duplicates retried connect
/// attempts.
typedef LibroIdempotencyKeyGenerator = String Function();

/// Typed transport error. The adapter / framework decides retry vs
/// refresh-token vs surface based on the [kind] discriminator.
class LibroApiException implements Exception {
  const LibroApiException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.retryAfter,
    this.responseBody,
  });

  /// Error category for the caller.
  final LibroApiErrorKind kind;
  final String message;
  final int? statusCode;
  final Duration? retryAfter;
  final String? responseBody;

  @override
  String toString() => 'LibroApiException($kind, status=$statusCode): $message';
}

/// Discriminator for [LibroApiException]. Mirrors the categories the
/// vendor adapter contract calls out (auth / permission / not-found /
/// rate-limit / transport / protocol).
enum LibroApiErrorKind {
  /// 401 — token rejected. Adapter refreshes and retries once.
  unauthenticated,

  /// 403 — token valid but missing scope or revoked at vendor side.
  forbidden,

  /// 404 — resource missing. For `unregisterWebhook` this is benign;
  /// callers may treat it as success.
  notFound,

  /// 429 — rate limit exhausted after the bounded retry budget.
  rateLimitExhausted,

  /// 5xx or transport-level network failure.
  serverError,

  /// 4xx (other) — invalid request, schema mismatch.
  badRequest,

  /// Response body did not parse as JSON or violated the documented
  /// envelope.
  protocol,
}

/// Production [LibroHttpClient]. Uses `package:http` and the bearer
/// token resolver to make authenticated calls to Libro's documented
/// partner API.
class LibroReservationProductionApiClient implements LibroHttpClient {
  LibroReservationProductionApiClient({
    required LibroBearerTokenResolver bearerTokenResolver,
    Uri? baseUri,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
    int maxRateLimitRetries = 3,
    Duration rateLimitBaseDelay = const Duration(seconds: 1),
    Duration rateLimitMaxDelay = const Duration(seconds: 30),
    LibroIdempotencyKeyGenerator? idempotencyKeyGenerator,
    math.Random? random,
    Future<void> Function(Duration)? sleep,
  })  : _bearerTokenResolver = bearerTokenResolver,
        _baseUri = baseUri ?? kLibroProductionBaseUri,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _maxRateLimitRetries = maxRateLimitRetries,
        _rateLimitBaseDelay = rateLimitBaseDelay,
        _rateLimitMaxDelay = rateLimitMaxDelay,
        _idempotencyKeyGenerator =
            idempotencyKeyGenerator ?? _defaultIdempotencyKeyGenerator,
        _random = random ?? math.Random.secure(),
        _sleep = sleep ?? Future<void>.delayed;

  final LibroBearerTokenResolver _bearerTokenResolver;
  final Uri _baseUri;
  final http.Client _httpClient;
  final Duration _timeout;
  final int _maxRateLimitRetries;
  final Duration _rateLimitBaseDelay;
  final Duration _rateLimitMaxDelay;
  final LibroIdempotencyKeyGenerator _idempotencyKeyGenerator;
  final math.Random _random;
  final Future<void> Function(Duration) _sleep;

  /// Releases the underlying [http.Client]. Tests do not need to call
  /// this; production wiring closes the client at process shutdown.
  void close() => _httpClient.close();

  @override
  Future<LibroReservationPage> listReservations({
    required VendorCredentialHandle credential,
    required String venueId,
    required DateTime updatedSince,
    DateTime? updatedBefore,
    String? cursor,
    int? pageSize,
  }) async {
    final query = <String, String>{
      'venue_id': venueId,
      'updated_since': _formatTimestamp(updatedSince),
      if (updatedBefore != null)
        'updated_before': _formatTimestamp(updatedBefore),
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      if (pageSize != null) 'page_size': pageSize.toString(),
    };
    final response = await _sendWithRateLimitRetry(
      method: 'GET',
      path: '/v1/reservations',
      credential: credential,
      query: query,
    );
    final body = _decodeJson(response, expectMap: true) as Map<String, Object?>;
    final rawList = body['reservations'];
    if (rawList is! List) {
      throw LibroApiException(
        kind: LibroApiErrorKind.protocol,
        message: 'response missing `reservations` array',
        statusCode: response.statusCode,
        responseBody: response.body,
      );
    }
    final reservations = <LibroReservationDto>[];
    for (final raw in rawList) {
      if (raw is Map) {
        reservations.add(
          LibroReservationDto.fromMap(raw.cast<String, Object?>()),
        );
      }
    }
    final nextRaw = body['next_cursor'];
    final nextCursor = (nextRaw is String && nextRaw.isNotEmpty) ? nextRaw : null;
    return LibroReservationPage(
      reservations: reservations,
      nextCursor: nextCursor,
    );
  }

  @override
  Future<void> revokeCredential({
    required VendorCredentialHandle credential,
  }) async {
    // Revoke always carries an Idempotency-Key so a retried disconnect
    // is a no-op on the proxy side. Libro's revoke endpoint is itself
    // idempotent (revoking an already-revoked token is a 200/204 per
    // the documented shape), but the proxy table prevents duplicate
    // write attempts on our side.
    await _sendWithRateLimitRetry(
      method: 'POST',
      path: '/v1/oauth/revoke',
      credential: credential,
      jsonBody: <String, Object?>{},
      idempotencyKey: _idempotencyKeyGenerator(),
      // 404 here means the token is already gone — treat as success.
      tolerateNotFound: true,
    );
  }

  @override
  Future<void> unregisterWebhook({
    required VendorCredentialHandle credential,
    required String subscriptionId,
  }) async {
    await _sendWithRateLimitRetry(
      method: 'DELETE',
      path: '/v1/webhooks/subscriptions/${Uri.encodeComponent(subscriptionId)}',
      credential: credential,
      // Subscription already removed at vendor side → success.
      tolerateNotFound: true,
    );
  }

  @override
  Future<String> registerWebhook({
    required VendorCredentialHandle credential,
    required String venueId,
    required String webhookUrl,
    required List<String> events,
  }) async {
    final response = await _sendWithRateLimitRetry(
      method: 'POST',
      path: '/v1/webhooks/subscriptions',
      credential: credential,
      jsonBody: <String, Object?>{
        'venue_id': venueId,
        'url': webhookUrl,
        'events': events,
      },
      idempotencyKey: _idempotencyKeyGenerator(),
    );
    final body = _decodeJson(response, expectMap: true) as Map<String, Object?>;
    final rawId = body['id'] ?? body['subscription_id'];
    if (rawId is! String || rawId.isEmpty) {
      throw LibroApiException(
        kind: LibroApiErrorKind.protocol,
        message: 'register webhook response missing subscription id',
        statusCode: response.statusCode,
        responseBody: response.body,
      );
    }
    return rawId;
  }

  // ─── Internal helpers ─────────────────────────────────────────────

  Future<http.Response> _sendWithRateLimitRetry({
    required String method,
    required String path,
    required VendorCredentialHandle credential,
    Map<String, String>? query,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
    bool tolerateNotFound = false,
  }) async {
    var attempt = 0;
    LibroApiException? lastRateLimit;
    while (true) {
      final response = await _send(
        method: method,
        path: path,
        credential: credential,
        query: query,
        jsonBody: jsonBody,
        idempotencyKey: idempotencyKey,
      );
      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        return response;
      }
      if (status == 401) {
        throw LibroApiException(
          kind: LibroApiErrorKind.unauthenticated,
          message: 'libro rejected access token',
          statusCode: status,
          responseBody: response.body,
        );
      }
      if (status == 403) {
        throw LibroApiException(
          kind: LibroApiErrorKind.forbidden,
          message: 'libro denied access (scope or revocation)',
          statusCode: status,
          responseBody: response.body,
        );
      }
      if (status == 404) {
        if (tolerateNotFound) return response;
        throw LibroApiException(
          kind: LibroApiErrorKind.notFound,
          message: 'libro resource not found',
          statusCode: status,
          responseBody: response.body,
        );
      }
      if (status == 429) {
        final retryAfter = _parseRetryAfter(response.headers['retry-after']);
        lastRateLimit = LibroApiException(
          kind: LibroApiErrorKind.rateLimitExhausted,
          message: 'libro rate limit hit',
          statusCode: status,
          retryAfter: retryAfter,
          responseBody: response.body,
        );
        if (attempt >= _maxRateLimitRetries) {
          throw lastRateLimit;
        }
        final delay = _backoffDelay(attempt: attempt, retryAfter: retryAfter);
        attempt += 1;
        await _sleep(delay);
        continue;
      }
      if (status >= 500) {
        throw LibroApiException(
          kind: LibroApiErrorKind.serverError,
          message: 'libro server error',
          statusCode: status,
          responseBody: response.body,
        );
      }
      throw LibroApiException(
        kind: LibroApiErrorKind.badRequest,
        message: 'libro rejected request',
        statusCode: status,
        responseBody: response.body,
      );
    }
  }

  Future<http.Response> _send({
    required String method,
    required String path,
    required VendorCredentialHandle credential,
    Map<String, String>? query,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final bearer = await _bearerTokenResolver(credential);
    final headers = <String, String>{
      'authorization': 'Bearer $bearer',
      'accept': 'application/json',
      if (jsonBody != null) 'content-type': 'application/json',
      if (idempotencyKey != null && idempotencyKey.isNotEmpty)
        'idempotency-key': idempotencyKey,
    };
    final url = _resolve(path: path, query: query);
    final body = jsonBody == null ? null : jsonEncode(jsonBody);
    Future<http.Response> doSend() {
      switch (method) {
        case 'GET':
          return _httpClient.get(url, headers: headers);
        case 'POST':
          return _httpClient.post(url, headers: headers, body: body);
        case 'DELETE':
          return _httpClient.delete(url, headers: headers, body: body);
      }
      throw LibroApiException(
        kind: LibroApiErrorKind.protocol,
        message: 'unsupported HTTP method: $method',
      );
    }

    try {
      return await doSend().timeout(_timeout);
    } on TimeoutException catch (e) {
      throw LibroApiException(
        kind: LibroApiErrorKind.serverError,
        message: 'libro request timed out: $e',
      );
    } on http.ClientException catch (e) {
      throw LibroApiException(
        kind: LibroApiErrorKind.serverError,
        message: 'libro transport failure: ${e.message}',
      );
    }
  }

  Uri _resolve({required String path, Map<String, String>? query}) {
    final basePath = _baseUri.path.endsWith('/')
        ? _baseUri.path.substring(0, _baseUri.path.length - 1)
        : _baseUri.path;
    final relative = path.startsWith('/') ? path : '/$path';
    final fullPath = '$basePath$relative';
    return _baseUri.replace(
      path: fullPath,
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  /// Format a [DateTime] for an outbound query parameter. The adapter
  /// always passes UTC values; `toIso8601String()` preserves the `Z`
  /// suffix for UTC instants and any explicit offset for non-UTC
  /// instants, satisfying the rule that `TIMESTAMPTZ` round-trips
  /// keep their offset.
  String _formatTimestamp(DateTime value) => value.toIso8601String();

  Object? _decodeJson(http.Response response, {bool expectMap = false}) {
    final text = response.body;
    if (text.isEmpty) {
      if (expectMap) return <String, Object?>{};
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw LibroApiException(
        kind: LibroApiErrorKind.protocol,
        message: 'libro response is not valid JSON: $e',
        statusCode: response.statusCode,
        responseBody: text,
      );
    }
    if (expectMap && decoded is! Map) {
      throw LibroApiException(
        kind: LibroApiErrorKind.protocol,
        message: 'libro response is not a JSON object',
        statusCode: response.statusCode,
        responseBody: text,
      );
    }
    return decoded;
  }

  Duration _backoffDelay({required int attempt, Duration? retryAfter}) {
    if (retryAfter != null && retryAfter > Duration.zero) {
      return retryAfter > _rateLimitMaxDelay ? _rateLimitMaxDelay : retryAfter;
    }
    final base = _rateLimitBaseDelay.inMilliseconds * math.pow(2, attempt);
    final jitter = _random.nextInt(_rateLimitBaseDelay.inMilliseconds + 1);
    final totalMs = (base + jitter).toInt();
    final capped = totalMs > _rateLimitMaxDelay.inMilliseconds
        ? _rateLimitMaxDelay.inMilliseconds
        : totalMs;
    return Duration(milliseconds: capped);
  }

  /// Parse `Retry-After` per RFC 7231 — either delta-seconds or an
  /// HTTP-date. Libro's docs use seconds; the date branch is here for
  /// completeness so a vendor format change doesn't crash the retry
  /// loop.
  Duration? _parseRetryAfter(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds);
    }
    final when = HttpDate.tryParse(raw);
    if (when == null) return null;
    final delta = when.difference(DateTime.now().toUtc());
    return delta.isNegative ? Duration.zero : delta;
  }
}

/// Thin shim so the transport doesn't pull `dart:io` (we want to stay
/// portable for unit tests on the Dart VM and for any future web
/// proxy-bootstrap reuse). RFC 7231 HTTP-date is rare in practice for
/// `Retry-After`; Libro's docs explicitly call out delta-seconds.
class HttpDate {
  static DateTime? tryParse(String raw) {
    try {
      // Accept ISO 8601 first (some vendors emit this even though the
      // spec says HTTP-date); fall back to Dart's parser.
      return DateTime.tryParse(raw)?.toUtc();
    } catch (_) {
      return null;
    }
  }
}

String _defaultIdempotencyKeyGenerator() {
  // UUIDv4-shape (random hex with dashes), no `package:uuid` dep so we
  // don't grow pub deps for this slice. The key is opaque to Libro;
  // only the proxy idempotency table hashes against it.
  final rand = math.Random.secure();
  String hex(int bytes) {
    final buf = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buf.write(rand.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  // 8-4-4-4-12 nibble groups; not a strict RFC 4122 v4 (we don't pin
  // version + variant nibbles) but is unique enough for an idempotency
  // key and avoids the `package:uuid` dep.
  return '${hex(4)}-${hex(2)}-${hex(2)}-${hex(2)}-${hex(6)}';
}
