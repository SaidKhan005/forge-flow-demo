// Phase 8 (`8.transport.clover-pos`) — Production Clover POS HTTP client.
//
// Implements [CloverApiClient] against Clover's REST API v3 (documented
// at https://docs.clover.com/reference/orders, retrieval date
// 2026-05-03). Engineered so the lifecycle promotion to
// `sandbox_verified` / `production_credentialed` is a config swap, not a
// rewrite — every URL, header, and pagination semantic mirrors the
// docs. The companion test
// `test/integrations/pos/clover_pos_production_api_client_test.dart`
// pins:
//
//   * Path templating: `/v3/merchants/{mId}/orders` (list),
//     `/v3/merchants/{mId}/orders/{oId}` (single).
//   * Filter shape: `filter=modifiedTime>=<ms>&filter=modifiedTime<=<ms>`
//     (epoch milliseconds; Clover's documented inequality syntax).
//   * Pagination: offset + limit per
//     https://docs.clover.com/docs/working-with-list-endpoints. The
//     adapter caps `limit` at 1000 (Clover's documented hard cap); the
//     [CloverPosAdapter] already pages at 100 so this is a defensive
//     ceiling.
//   * Auth: bearer access token resolved from a [CloverAccessTokenSource]
//     (production injects an envelope-decryption hook; tests supply a
//     fixed token).
//   * Idempotency-Key on POST `/v3/apps/{aId}/webhooks` so retries do
//     not double-create.
//   * 429 handling: respects `Retry-After` (seconds, integer per RFC
//     7231) when present; otherwise an exponential schedule clamped at
//     `kCloverDefaultMaxBackoff`. The schedule terminates at
//     `kCloverDefaultMaxRetries` so a runaway vendor never wedges the
//     worker.
//   * Typed errors: every non-2xx status maps to a [CloverApiException]
//     subclass so the worker dispatcher can branch on
//     auth/timeout/transient/permanent without re-parsing strings.
//   * TIMESTAMPTZ preservation: every order JSON is returned verbatim;
//     the adapter / sink owns business-date projection.
//
// Hard rules carried from CLAUDE.md:
//
//   * HP #1 (transport-only): this file performs zero formula work.
//   * HP #4 (per-operator isolation): the client itself is stateless;
//     callers (the worker dispatcher) inject `(operator_id, location_id)`
//     when invoking the [CloverWebhookRegistry] / [CloverCredentialStore]
//     siblings — this client only sees opaque tokens + merchant ids.
//   * HP #7 (server-side secrets): the access-token source decrypts
//     `vendor_credentials.access_token_ciphertext` server-side; plaintext
//     tokens never leave the proxy boundary.
//   * No new pub deps: only `package:http` is used.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'clover_pos_adapter.dart';

/// Default maximum number of times the client retries a transient
/// failure (429 / 5xx / socket timeout) before surfacing the error to
/// the worker. The worker's per-job retry envelope catches the rest.
const int kCloverDefaultMaxRetries = 4;

/// Default maximum back-off between retries. Clover's docs do not pin
/// a ceiling, so we use a defensive 30s — long enough to ride out a
/// brief vendor spike, short enough that the worker still meets the
/// per-job SLA.
const Duration kCloverDefaultMaxBackoff = Duration(seconds: 30);

/// Default per-call HTTP deadline. Clover's docs do not publish a hard
/// SLA; 30s matches the framework's `kPostgresPerStatementTimeout` x 6
/// envelope (HARD-G observability lock) so a stuck call surfaces
/// rather than wedging the worker.
const Duration kCloverDefaultRequestTimeout = Duration(seconds: 30);

/// Hard cap Clover places on the `limit` query parameter for list
/// endpoints. The adapter pages at 100; this ceiling is defensive.
const int kCloverApiHardLimitCap = 1000;

/// Header name carrying the OAuth bearer token. Capitalised to match
/// the documented Clover example; HTTP itself is case-insensitive.
const String kCloverAuthorizationHeader = 'Authorization';

/// Header name carrying the per-call idempotency key on POST
/// `/v3/apps/{aId}/webhooks`. Documented at
/// https://docs.clover.com/docs/idempotency.
const String kCloverIdempotencyHeader = 'Idempotency-Key';

/// Server-side resolver for a per-(operator, location) Clover bearer
/// token. Production injects a hook backed by
/// `vendor_credentials.access_token_ciphertext` (pgp_sym_decrypt server-
/// side); tests supply a fixed token. The hook is async because the
/// decryption path opens a tenant-scoped Postgres transaction.
typedef CloverAccessTokenSource = Future<String> Function();

/// App-level OAuth bearer used to manage app-scoped resources (the
/// webhook subscription endpoint sits under `/v3/apps/{aId}/webhooks`,
/// not `/v3/merchants/{mId}/...`). Production injects a Cloud Run env
/// var; tests pass a fixed string. The function is sync because the
/// app token has no per-tenant variance.
typedef CloverAppTokenSource = String Function();

/// Server-side resolver for the Clover app id used in
/// `/v3/apps/{aId}/webhooks` paths. Production reads
/// `process.env.CLOVER_APP_ID`; tests pass `'app-id'`.
typedef CloverAppIdSource = String Function();

/// Retry-after-aware sleeper. Tests inject a virtual scheduler.
typedef CloverSleeper = Future<void> Function(Duration);

/// Production HTTP-backed [CloverApiClient].
///
/// One instance per worker process is fine — the client is stateless
/// across calls; only the injected token sources carry tenant context.
class CloverPosProductionApiClient implements CloverApiClient {
  CloverPosProductionApiClient({
    required http.Client httpClient,
    required CloverAccessTokenSource merchantTokenSource,
    required CloverAppTokenSource appTokenSource,
    required CloverAppIdSource appIdSource,
    Uri? baseUri,
    int maxRetries = kCloverDefaultMaxRetries,
    Duration maxBackoff = kCloverDefaultMaxBackoff,
    Duration requestTimeout = kCloverDefaultRequestTimeout,
    CloverSleeper? sleep,
    Random? random,
  })  : _httpClient = httpClient,
        _merchantTokenSource = merchantTokenSource,
        _appTokenSource = appTokenSource,
        _appIdSource = appIdSource,
        _baseUri = baseUri ?? Uri.parse(kCloverProductionBaseUrl),
        _maxRetries = maxRetries,
        _maxBackoff = maxBackoff,
        _requestTimeout = requestTimeout,
        _sleep = sleep ?? _defaultSleeper,
        _random = random ?? Random();

  /// Convenience constructor for the documented Clover sandbox host.
  /// Used by `8.CL.live.sandbox`.
  factory CloverPosProductionApiClient.sandbox({
    required http.Client httpClient,
    required CloverAccessTokenSource merchantTokenSource,
    required CloverAppTokenSource appTokenSource,
    required CloverAppIdSource appIdSource,
    int maxRetries = kCloverDefaultMaxRetries,
    Duration maxBackoff = kCloverDefaultMaxBackoff,
    Duration requestTimeout = kCloverDefaultRequestTimeout,
    CloverSleeper? sleep,
    Random? random,
  }) =>
      CloverPosProductionApiClient(
        httpClient: httpClient,
        merchantTokenSource: merchantTokenSource,
        appTokenSource: appTokenSource,
        appIdSource: appIdSource,
        baseUri: Uri.parse(kCloverSandboxBaseUrl),
        maxRetries: maxRetries,
        maxBackoff: maxBackoff,
        requestTimeout: requestTimeout,
        sleep: sleep,
        random: random,
      );

  final http.Client _httpClient;
  final CloverAccessTokenSource _merchantTokenSource;
  final CloverAppTokenSource _appTokenSource;
  final CloverAppIdSource _appIdSource;
  final Uri _baseUri;
  final int _maxRetries;
  final Duration _maxBackoff;
  final Duration _requestTimeout;
  final CloverSleeper _sleep;
  final Random _random;

  static Future<void> _defaultSleeper(Duration d) => Future<void>.delayed(d);

  Uri get baseUri => _baseUri;

  // ─── listOrders ───────────────────────────────────────────────────

  @override
  Future<CloverOrdersPage> listOrders({
    required String merchantId,
    required DateTime modifiedFrom,
    required DateTime modifiedTo,
    required int offset,
    required int limit,
  }) async {
    if (merchantId.isEmpty) {
      throw ArgumentError.value(merchantId, 'merchantId', 'must be non-empty');
    }
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must be >= 0');
    }
    if (limit <= 0 || limit > kCloverApiHardLimitCap) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be in (0, $kCloverApiHardLimitCap]',
      );
    }
    final fromMs = modifiedFrom.toUtc().millisecondsSinceEpoch;
    final toMs = modifiedTo.toUtc().millisecondsSinceEpoch;
    if (toMs < fromMs) {
      throw ArgumentError(
        'modifiedTo ($modifiedTo) precedes modifiedFrom ($modifiedFrom)',
      );
    }

    final uri = _baseUri.replace(
      path: '/v3/merchants/$merchantId/orders',
      queryParameters: <String, List<String>>{
        // Clover's documented "filter" parameter is repeated for each
        // inequality; the resulting query string looks like
        // `filter=modifiedTime>=123&filter=modifiedTime<=456`.
        'filter': <String>[
          'modifiedTime>=$fromMs',
          'modifiedTime<=$toMs',
        ],
        'offset': <String>['$offset'],
        'limit': <String>['$limit'],
      },
    );

    final body = await _executeJson(
      method: 'GET',
      uri: uri,
      tokenKind: _CloverTokenKind.merchant,
    );

    final elements = (body['elements'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map((e) => Map<String, Object?>.from(e))
        .toList(growable: false);

    // Clover does not echo a next-offset value; the worker decides the
    // chain is exhausted when the page comes back smaller than the
    // requested limit. Equality with `limit` keeps paging.
    final int? nextOffset =
        elements.length < limit ? null : offset + elements.length;

    return CloverOrdersPage(
      elements: elements,
      nextOffset: nextOffset,
    );
  }

  // ─── getOrder ─────────────────────────────────────────────────────

  @override
  Future<Map<String, Object?>> getOrder({
    required String merchantId,
    required String orderId,
  }) async {
    if (merchantId.isEmpty) {
      throw ArgumentError.value(merchantId, 'merchantId', 'must be non-empty');
    }
    if (orderId.isEmpty) {
      throw ArgumentError.value(orderId, 'orderId', 'must be non-empty');
    }

    final uri = _baseUri.replace(
      path: '/v3/merchants/$merchantId/orders/$orderId',
    );
    final body = await _executeJson(
      method: 'GET',
      uri: uri,
      tokenKind: _CloverTokenKind.merchant,
    );
    return body;
  }

  // ─── registerWebhook ─────────────────────────────────────────────

  @override
  Future<String> registerWebhook({
    required String merchantId,
    required String callbackUrl,
    required List<String> eventTypes,
  }) async {
    if (merchantId.isEmpty) {
      throw ArgumentError.value(merchantId, 'merchantId', 'must be non-empty');
    }
    if (callbackUrl.isEmpty) {
      throw ArgumentError.value(callbackUrl, 'callbackUrl', 'must be non-empty');
    }
    if (eventTypes.isEmpty) {
      throw ArgumentError.value(eventTypes, 'eventTypes', 'must be non-empty');
    }

    final appId = _appIdSource();
    if (appId.isEmpty) {
      throw StateError('Clover app id source returned empty value');
    }
    final uri = _baseUri.replace(path: '/v3/apps/$appId/webhooks');
    final payload = <String, Object?>{
      'merchantId': merchantId,
      'url': callbackUrl,
      'eventTypes': eventTypes,
    };

    // Idempotency key derives from `(merchantId, callbackUrl, sorted
    // eventTypes)` so a retry of the same logical subscribe call lands
    // the same key. A reconnect with a different callback URL gets a
    // fresh key — that's the desired semantic.
    final idempotencyKey = _idempotencyKeyFor(
      merchantId: merchantId,
      callbackUrl: callbackUrl,
      eventTypes: eventTypes,
    );

    final body = await _executeJson(
      method: 'POST',
      uri: uri,
      tokenKind: _CloverTokenKind.app,
      jsonBody: payload,
      extraHeaders: <String, String>{
        kCloverIdempotencyHeader: idempotencyKey,
      },
    );

    final id = body['id'];
    if (id is! String || id.isEmpty) {
      throw CloverApiResponseFormatException(
        'Clover webhook subscribe response missing string `id`: $body',
        uri: uri,
      );
    }
    return id;
  }

  // ─── unregisterWebhook ───────────────────────────────────────────

  @override
  Future<void> unregisterWebhook({
    required String merchantId,
    required String subscriptionId,
  }) async {
    if (merchantId.isEmpty) {
      throw ArgumentError.value(merchantId, 'merchantId', 'must be non-empty');
    }
    if (subscriptionId.isEmpty) {
      throw ArgumentError.value(
        subscriptionId,
        'subscriptionId',
        'must be non-empty',
      );
    }
    final appId = _appIdSource();
    if (appId.isEmpty) {
      throw StateError('Clover app id source returned empty value');
    }
    final uri = _baseUri.replace(
      path: '/v3/apps/$appId/webhooks/$subscriptionId',
    );
    await _executeJson(
      method: 'DELETE',
      uri: uri,
      tokenKind: _CloverTokenKind.app,
      acceptEmptyBody: true,
    );
  }

  // ─── shared executor ─────────────────────────────────────────────

  /// Executes [method] [uri] with retry/back-off and JSON decode. The
  /// returned map is empty when [acceptEmptyBody] and the response
  /// body is empty (DELETE typically returns 204 No Content).
  Future<Map<String, Object?>> _executeJson({
    required String method,
    required Uri uri,
    required _CloverTokenKind tokenKind,
    Map<String, Object?>? jsonBody,
    Map<String, String>? extraHeaders,
    bool acceptEmptyBody = false,
  }) async {
    var attempt = 0;
    while (true) {
      attempt += 1;
      final token = await _resolveToken(tokenKind);
      final headers = <String, String>{
        kCloverAuthorizationHeader: 'Bearer $token',
        'Accept': 'application/json',
        if (jsonBody != null) 'Content-Type': 'application/json',
        if (extraHeaders != null) ...extraHeaders,
      };

      http.Response response;
      try {
        switch (method) {
          case 'GET':
            response = await _httpClient
                .get(uri, headers: headers)
                .timeout(_requestTimeout);
            break;
          case 'POST':
            response = await _httpClient
                .post(
                  uri,
                  headers: headers,
                  body: jsonBody == null ? null : jsonEncode(jsonBody),
                )
                .timeout(_requestTimeout);
            break;
          case 'DELETE':
            response = await _httpClient
                .delete(uri, headers: headers)
                .timeout(_requestTimeout);
            break;
          default:
            throw ArgumentError.value(method, 'method', 'unsupported');
        }
      } on TimeoutException catch (e) {
        if (attempt > _maxRetries) {
          throw CloverApiTimeoutException(
            'Clover request timed out after $_requestTimeout',
            uri: uri,
            cause: e,
          );
        }
        await _sleep(_backoffFor(attempt, retryAfter: null));
        continue;
      } catch (e) {
        // Socket / DNS / TLS failures map to transient. The worker's
        // outer envelope decides whether to roll the job to `pending`.
        if (attempt > _maxRetries) {
          throw CloverApiTransportException(
            'Clover request transport error: $e',
            uri: uri,
            cause: e,
          );
        }
        await _sleep(_backoffFor(attempt, retryAfter: null));
        continue;
      }

      // 2xx — happy path.
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (acceptEmptyBody && response.body.isEmpty) {
          return const <String, Object?>{};
        }
        if (response.body.isEmpty) {
          throw CloverApiResponseFormatException(
            'Clover ${response.statusCode} response empty body',
            uri: uri,
          );
        }
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            return Map<String, Object?>.from(decoded);
          }
          throw CloverApiResponseFormatException(
            'Clover response not a JSON object: ${response.body}',
            uri: uri,
          );
        } on FormatException catch (e) {
          throw CloverApiResponseFormatException(
            'Clover response JSON decode failed: ${e.message}',
            uri: uri,
            cause: e,
          );
        }
      }

      // 401 / 403 — credentials are stale. Worker dispatcher flips the
      // connection to `error`; no retry.
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw CloverApiAuthException(
          'Clover ${response.statusCode} ${response.reasonPhrase ?? ''}',
          uri: uri,
          statusCode: response.statusCode,
          body: response.body,
        );
      }

      // 429 — honour Retry-After when present; otherwise back-off.
      if (response.statusCode == 429) {
        final retryAfter = _parseRetryAfter(response.headers['retry-after']);
        if (attempt > _maxRetries) {
          throw CloverApiRateLimitedException(
            'Clover 429 rate-limited after $attempt attempts',
            uri: uri,
            retryAfter: retryAfter,
            body: response.body,
          );
        }
        await _sleep(_backoffFor(attempt, retryAfter: retryAfter));
        continue;
      }

      // 5xx — transient; retry until budget exhausted.
      if (response.statusCode >= 500 && response.statusCode < 600) {
        if (attempt > _maxRetries) {
          throw CloverApiServerException(
            'Clover ${response.statusCode} after $attempt attempts',
            uri: uri,
            statusCode: response.statusCode,
            body: response.body,
          );
        }
        await _sleep(_backoffFor(attempt, retryAfter: null));
        continue;
      }

      // 4xx (other than 401/403/429) — permanent client error.
      throw CloverApiClientErrorException(
        'Clover ${response.statusCode} ${response.reasonPhrase ?? ''}',
        uri: uri,
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }

  Future<String> _resolveToken(_CloverTokenKind kind) async {
    switch (kind) {
      case _CloverTokenKind.merchant:
        final t = await _merchantTokenSource();
        if (t.isEmpty) {
          throw StateError('Clover merchant token source returned empty value');
        }
        return t;
      case _CloverTokenKind.app:
        final t = _appTokenSource();
        if (t.isEmpty) {
          throw StateError('Clover app token source returned empty value');
        }
        return t;
    }
  }

  /// Compute the wait between retry attempts. Honours `Retry-After`
  /// when supplied; otherwise uses an exponential schedule with full
  /// jitter clamped at [_maxBackoff].
  Duration _backoffFor(int attempt, {Duration? retryAfter}) {
    if (retryAfter != null) {
      return retryAfter > _maxBackoff ? _maxBackoff : retryAfter;
    }
    final base = pow(2, attempt - 1).toInt(); // 1, 2, 4, 8, ...
    final ceilMs = min(base * 250, _maxBackoff.inMilliseconds);
    final jitterMs = _random.nextInt(ceilMs <= 0 ? 1 : ceilMs);
    return Duration(milliseconds: jitterMs);
  }

  /// Parses an RFC 7231 `Retry-After` header. Clover's docs only
  /// describe the integer-seconds form; HTTP-date is accepted defensively.
  Duration? _parseRetryAfter(String? header) {
    if (header == null || header.isEmpty) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds);
    }
    try {
      final date = HttpDate.tryParseRfc1123(header);
      if (date == null) return null;
      final delta = date.difference(DateTime.now().toUtc());
      return delta.isNegative ? Duration.zero : delta;
    } catch (_) {
      return null;
    }
  }

  String _idempotencyKeyFor({
    required String merchantId,
    required String callbackUrl,
    required List<String> eventTypes,
  }) {
    final sorted = <String>[...eventTypes]..sort();
    final raw = 'clover:webhook:$merchantId|$callbackUrl|${sorted.join(',')}';
    return base64Url.encode(utf8.encode(raw)).replaceAll('=', '');
  }
}

enum _CloverTokenKind { merchant, app }

// ─── Typed errors ───────────────────────────────────────────────────

/// Base for every error this client surfaces. Sub-classes distinguish
/// auth / rate-limit / server / transport so the worker dispatcher can
/// branch without parsing strings.
abstract class CloverApiException implements Exception {
  CloverApiException(this.message, {required this.uri, this.cause});

  final String message;
  final Uri uri;
  final Object? cause;

  @override
  String toString() => '$runtimeType($uri): $message';
}

/// 401 / 403 — the merchant token / app token is stale. The worker
/// flips the connection to `error` with the OAuth refresh path next.
class CloverApiAuthException extends CloverApiException {
  CloverApiAuthException(
    super.message, {
    required super.uri,
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}

/// 429 — Clover rate-limited the request after the retry budget. The
/// worker rolls the job to `pending` so the cron picks it up later.
class CloverApiRateLimitedException extends CloverApiException {
  CloverApiRateLimitedException(
    super.message, {
    required super.uri,
    required this.retryAfter,
    required this.body,
  });

  final Duration? retryAfter;
  final String body;
}

/// 5xx — Clover side error. Same outcome as rate limited from the
/// worker's perspective; retained as a separate type for grading.
class CloverApiServerException extends CloverApiException {
  CloverApiServerException(
    super.message, {
    required super.uri,
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}

/// 4xx other than 401 / 403 / 429 — permanent client error (e.g. 400
/// malformed filter, 404 unknown merchant). The worker flips the job
/// to `failed` with a non-retryable verdict.
class CloverApiClientErrorException extends CloverApiException {
  CloverApiClientErrorException(
    super.message, {
    required super.uri,
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}

/// Per-call deadline elapsed.
class CloverApiTimeoutException extends CloverApiException {
  CloverApiTimeoutException(
    super.message, {
    required super.uri,
    super.cause,
  });
}

/// Socket / DNS / TLS error after the retry budget.
class CloverApiTransportException extends CloverApiException {
  CloverApiTransportException(
    super.message, {
    required super.uri,
    super.cause,
  });
}

/// Server returned non-JSON or a JSON shape that violates Clover's
/// documented contract.
class CloverApiResponseFormatException extends CloverApiException {
  CloverApiResponseFormatException(
    super.message, {
    required super.uri,
    super.cause,
  });
}

// ─── HttpDate helper ────────────────────────────────────────────────

/// Minimal RFC 1123 date parser. The framework already pulls in
/// `package:http`, but `HttpDate.parse` from `dart:io` is unavailable
/// on web. The Clover `Retry-After` header almost always uses the
/// integer-seconds form; the date form is accepted defensively here
/// without taking a `dart:io` dependency.
class HttpDate {
  HttpDate._();

  static DateTime? tryParseRfc1123(String value) {
    final pattern = RegExp(
      r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) '
      r'(\d{2}):(\d{2}):(\d{2}) GMT$',
    );
    final match = pattern.firstMatch(value.trim());
    if (match == null) return null;
    const months = <String, int>{
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12,
    };
    final day = int.tryParse(match.group(1)!);
    final month = months[match.group(2)!];
    final year = int.tryParse(match.group(3)!);
    final hour = int.tryParse(match.group(4)!);
    final minute = int.tryParse(match.group(5)!);
    final second = int.tryParse(match.group(6)!);
    if (day == null ||
        month == null ||
        year == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }
    return DateTime.utc(year, month, day, hour, minute, second);
  }
}
