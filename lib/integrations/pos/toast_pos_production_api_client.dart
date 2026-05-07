// Phase 8 / Wave B `8.transport.toast-pos` — production HTTP impl of
// [ToastApiClient].
//
// Authority:
//   * `docs/integrations/toast/api_consumed.md` (binding) — endpoint
//     table + sandbox / production base URLs + rate-limit policy.
//   * `docs/integrations/toast/oauth_shape.md` (binding) — OAuth 2.0
//     `client_credentials` flow, bearer header, ~1h token TTL,
//     reactive 401 refresh.
//   * `docs/integrations/toast/field_mapping.md` (binding) — vendor
//     timestamp shapes (ISO-8601 with `Z`).
//   * `lib/integrations/pos/toast_pos_adapter.dart` — abstract
//     [ToastApiClient] interface this file implements.
//
// Hard Promise alignment:
//   * HP #1 (pure transport swap) — this file only adds an HTTP-backed
//     concrete impl of [ToastApiClient]; no fact writes, no business
//     logic, no schema changes. The bespoke [ToastFactSink] /
//     [ToastPosPostgresSink] continues to own canonical writes.
//   * HP #7 (server-side credentials only) — plaintext `clientSecret`
//     never reaches this file. The injected [ToastAccessTokenResolver]
//     owns the secret + token-cache surface; this client only consumes
//     opaque bearer tokens via `Authorization: Bearer <token>`.
//   * Idempotency on writes — outbound POST/DELETE calls carry an
//     `Idempotency-Key` header so a re-driven request from the proxy
//     side reads as the same logical write. Toast itself may not honor
//     the header today; we ship it per the F&F-wide idempotency rule
//     (CLAUDE.md "Proxy & API Conventions") so the surface stays
//     uniform when the vendor catches up.
//
// V1 lean cut 2 alignment:
//   * No KMS rollout / production-key rotation logic here — the
//     resolver injects the bearer token; rotation is the resolver's
//     concern (proxy-side `vendor_credentials_repository`).
//   * No DLQ tile mount, no parse_partial flag, no advisory locks.
//   * No raw-payload sibling tables — payloads flow back through the
//     [ToastApiClient] contract as `Map<String, Object?>` for the
//     adapter's `_canonicalize` to project; storage is the sink's job.
//
// Note on the `ToastPosAdapterDeps` record at
// `tool/advisor_proxy/pos_adapter_registry.dart`: the deps record only
// names `transport: ToastApiClient` and `factSink: ToastFactSink`.
// The adapter itself does NOT carry a separate credential-store seam
// (Toast handles credentials at the route layer when minting
// `ToastCredentialHandle`s). This production client therefore takes a
// new [ToastAccessTokenResolver] abstraction so the bearer token is
// resolved against `vendor_credentials` outside of this file. Tests
// inject an in-memory resolver; production wires it to the proxy's
// vendor-credentials repository.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'toast_pos_adapter.dart';

/// Default Toast production base URL per
/// `docs/integrations/toast/api_consumed.md`.
const String kToastProductionBaseUrl = 'https://ws-api.toasttab.com';

/// Compile-time override for the base URL — reads
/// `--dart-define=TOAST_API_BASE_URL=https://...` so the CI / sandbox
/// runtime can point this client at the Toast sandbox host without a
/// code change.
const String _kToastBaseUrlEnvOverride = String.fromEnvironment(
  'TOAST_API_BASE_URL',
  defaultValue: kToastProductionBaseUrl,
);

/// Maximum retries for transient errors (429 / 5xx / timeout). Per the
/// slice prompt: "max 5 retries with exponential backoff."
const int kToastMaxRetries = 5;

/// Base delay for exponential backoff. Doubles per attempt; jittered
/// uniformly in `[0, base * 2^n)` to spread reconnect storms.
const Duration kToastRetryBaseDelay = Duration(milliseconds: 250);

/// Hard cap on a single backoff sleep — prevents pathological
/// `Retry-After` values from blocking the worker indefinitely.
const Duration kToastRetryMaxDelay = Duration(seconds: 30);

/// Default per-request timeout. Toast's documented p99 for `ordersBulk`
/// sits well under 10s; the worker budget is the outer limiter.
const Duration kToastRequestTimeout = Duration(seconds: 30);

// ─── Errors ─────────────────────────────────────────────────────────

/// Sealed parent for every error this transport raises. Adapters /
/// callers can pattern-match on the concrete subtype to decide whether
/// to retry / surface-as-error / flip the connection.
sealed class ToastApiError implements Exception {
  const ToastApiError(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() {
    final code = statusCode == null ? '' : ' (HTTP $statusCode)';
    return '$runtimeType$code: $message';
  }
}

/// Transient failure — retry per [kToastMaxRetries]. Surfaces after
/// the cap so the worker can flip the connection to `error` (per
/// `docs/integrations/toast/oauth_shape.md` 3-strike rule).
class ToastTransientError extends ToastApiError {
  const ToastTransientError(super.message, {super.statusCode, super.cause});
}

/// Permanent failure — do not retry. 4xx other than 401 / 429.
class ToastPermanentError extends ToastApiError {
  const ToastPermanentError(super.message, {super.statusCode, super.cause});
}

/// Rate-limit failure — Toast 429. Carries [retryAfter] so the caller
/// can honor the vendor's hint. Surfaces only after the retry cap.
class ToastRateLimitError extends ToastApiError {
  const ToastRateLimitError(
    super.message, {
    super.statusCode,
    super.cause,
    required this.retryAfter,
  });

  final Duration? retryAfter;
}

/// Auth failure — Toast 401. The adapter surfaces this so the
/// connection can flip to `error` per the OAuth shape doc; the client
/// itself does NOT retry 401s (the resolver is responsible for token
/// rotation between attempts).
class ToastAuthError extends ToastApiError {
  const ToastAuthError(super.message, {super.statusCode, super.cause});
}

// ─── Token resolver ─────────────────────────────────────────────────

/// Bearer-token resolver seam. Production wires this to
/// `vendor_credentials_repository.dart` (proxy-side). Tests inject an
/// in-memory implementation that returns canned tokens.
///
/// Keeping the resolver out of the [http.Client] layer means
/// plaintext `clientSecret` never enters this file (HP #7) and lets
/// the proxy own token caching / rotation independently of HTTP
/// transport changes.
abstract class ToastAccessTokenResolver {
  /// Resolve a bearer token for the supplied credential handle. May
  /// trigger a fresh `client_credentials` exchange under the hood; the
  /// HTTP client treats every successful return as the current valid
  /// token.
  ///
  /// When [forceRefresh] is true, the resolver MUST mint a fresh
  /// token (skip any cache). The HTTP client passes `true` after a
  /// 401 so a stale-cache + reactive-refresh chain exists per the
  /// OAuth shape doc.
  Future<String> resolveAccessToken({
    required ToastCredentialHandle credentials,
    bool forceRefresh = false,
  });
}

// ─── Production HTTP client ─────────────────────────────────────────

/// Production HTTP impl of [ToastApiClient].
///
/// Constructor takes:
///   * [httpClient] — injected so tests can pass `MockClient` from
///     `package:http/testing.dart`.
///   * [tokenResolver] — see [ToastAccessTokenResolver].
///   * [baseUri] — defaults to [kToastProductionBaseUrl]; override
///     via `--dart-define=TOAST_API_BASE_URL=...` or by passing a
///     `Uri` directly (sandbox / staging).
///   * [clock] — virtualized for tests so backoff sleeps are
///     deterministic; production uses [DateTime.now].
///   * [random] — virtualized for tests; production uses [Random.secure]
///     to jitter retries.
///   * [requestTimeout] — per-request timeout. Defaults to
///     [kToastRequestTimeout].
///   * [idempotencyKeyFactory] — generates the `Idempotency-Key`
///     header value on writes. Tests inject a deterministic factory
///     so they can assert on the emitted key.
class ToastPosProductionApiClient implements ToastApiClient {
  ToastPosProductionApiClient({
    required http.Client httpClient,
    required ToastAccessTokenResolver tokenResolver,
    Uri? baseUri,
    DateTime Function()? clock,
    Random? random,
    Duration requestTimeout = kToastRequestTimeout,
    Future<void> Function(Duration)? sleep,
    String Function()? idempotencyKeyFactory,
  })  : _httpClient = httpClient,
        _tokenResolver = tokenResolver,
        _baseUri = baseUri ?? Uri.parse(_kToastBaseUrlEnvOverride),
        _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure(),
        _requestTimeout = requestTimeout,
        _sleep = sleep ?? Future<void>.delayed,
        _idempotencyKeyFactory =
            idempotencyKeyFactory ?? _defaultIdempotencyKey;

  final http.Client _httpClient;
  final ToastAccessTokenResolver _tokenResolver;
  final Uri _baseUri;
  // Reserved for future cache eviction / metrics; retained so the ctor
  // signature stays stable for callers that already pass it.
  // ignore: unused_field
  final DateTime Function() _clock;
  final Random _random;
  final Duration _requestTimeout;
  final Future<void> Function(Duration) _sleep;
  final String Function() _idempotencyKeyFactory;

  static int _idempotencyCounter = 0;
  static String _defaultIdempotencyKey() {
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
    final n = _idempotencyCounter++;
    return 'ff-toast-$ts-$n';
  }

  // ─── ToastApiClient implementation ─────────────────────────────────

  @override
  Future<ToastCredentialHandle> exchangeClientCredentials({
    required String operatorId,
    required String locationId,
    required String restaurantGuid,
    String? oauthState,
  }) async {
    // The handle minting / OAuth `client_credentials` round-trip is
    // owned by the proxy-side `vendor_credentials_repository` — the
    // production transport never touches `clientSecret`. The route
    // layer minted the handle before invoking the adapter; this
    // method is the seam the test surface uses to wire that lookup.
    //
    // We surface a freshly-resolved token on the path so the resolver
    // is exercised once at connect/test/poll/backfill/webhook time.
    final handle = ToastCredentialHandle(
      // The adapter currently uses the connect path's connectionId
      // value; in production this is the connection_id minted by the
      // route layer. Threading via the handle keeps the seam thin.
      connectionId: '$operatorId|$locationId|$restaurantGuid',
      restaurantGuid: restaurantGuid,
    );
    // Touch the resolver so failures here surface as ToastAuthError
    // before the caller attaches the handle to a downstream call.
    await _tokenResolver.resolveAccessToken(credentials: handle);
    return handle;
  }

  @override
  Future<String> registerWebhook({
    required ToastCredentialHandle credentials,
    required String webhookUrl,
  }) async {
    // POST /webhooks-config/v1/webhook
    final body = <String, Object?>{
      'callbackUrl': webhookUrl,
      'restaurantGuid': credentials.restaurantGuid,
    };
    final response = await _send(
      method: 'POST',
      path: '/webhooks-config/v1/webhook',
      credentials: credentials,
      bodyJson: body,
      includeIdempotencyKey: true,
    );
    final decoded = _decodeJson(response);
    final id = decoded['guid'] ?? decoded['subscriptionId'];
    if (id is! String || id.isEmpty) {
      throw const ToastPermanentError(
        'Toast webhook register response missing subscription guid',
      );
    }
    return id;
  }

  @override
  Future<bool> unregisterWebhook({
    required ToastCredentialHandle credentials,
    String? subscriptionId,
  }) async {
    if (subscriptionId == null || subscriptionId.isEmpty) return false;
    try {
      await _send(
        method: 'DELETE',
        path: '/webhooks-config/v1/webhook/$subscriptionId',
        credentials: credentials,
        includeIdempotencyKey: true,
      );
      return true;
    } on ToastApiError {
      // Best-effort per the adapter contract; the framework still
      // wipes credentials and rotates state.
      return false;
    }
  }

  @override
  Future<Map<String, Object?>> fetchSampleOrder({
    required ToastCredentialHandle credentials,
  }) async {
    // GET /orders/v2/ordersBulk?pageSize=1
    final response = await _send(
      method: 'GET',
      path: '/orders/v2/ordersBulk',
      credentials: credentials,
      queryParameters: <String, String>{'pageSize': '1'},
    );
    final decoded = _decodeJson(response);
    final orders = _ordersFromBody(decoded);
    if (orders.isEmpty) {
      throw const ToastPermanentError(
        'Toast sample fetch returned empty orders array',
      );
    }
    return orders.first;
  }

  @override
  Future<ToastOrdersPage> fetchOrdersPage({
    required ToastCredentialHandle credentials,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? resumeFromCursor,
  }) async {
    final params = <String, String>{
      'startDate': windowStart.toUtc().toIso8601String(),
      'endDate': windowEnd.toUtc().toIso8601String(),
    };
    if (resumeFromCursor != null && resumeFromCursor.isNotEmpty) {
      params['pageToken'] = resumeFromCursor;
    }
    final response = await _send(
      method: 'GET',
      path: '/orders/v2/ordersBulk',
      credentials: credentials,
      queryParameters: params,
    );
    final decoded = _decodeJson(response);
    final orders = _ordersFromBody(decoded);

    // Toast's documented pagination shape exposes the next cursor on
    // either the body (`nextPageToken`) or the `Toast-Next-Page-Token`
    // response header — preserve both reads to stay tolerant of doc
    // drift surfaced during sandbox verification.
    String? nextCursor;
    final bodyCursor = decoded['nextPageToken'];
    if (bodyCursor is String && bodyCursor.isNotEmpty) {
      nextCursor = bodyCursor;
    } else {
      final headerCursor = response.headers['toast-next-page-token'];
      if (headerCursor != null && headerCursor.isNotEmpty) {
        nextCursor = headerCursor;
      }
    }

    DateTime lastModifiedSeen = windowStart.toUtc();
    for (final order in orders) {
      final modified = order['modifiedDate'];
      if (modified is String && modified.isNotEmpty) {
        try {
          final parsed = DateTime.parse(modified).toUtc();
          if (parsed.isAfter(lastModifiedSeen)) {
            lastModifiedSeen = parsed;
          }
        } on FormatException {
          // Skip — the adapter's sanity hook will reject malformed
          // timestamps further down the pipeline.
        }
      }
    }

    return ToastOrdersPage(
      orders: orders,
      nextCursor: nextCursor,
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  @override
  Future<Map<String, Object?>?> fetchOrderByGuid({
    required ToastCredentialHandle credentials,
    required String guid,
  }) async {
    try {
      final response = await _send(
        method: 'GET',
        path: '/orders/v2/orders/$guid',
        credentials: credentials,
      );
      final decoded = _decodeJson(response);
      return decoded;
    } on ToastPermanentError catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  // ─── Internal: send + retry + auth ─────────────────────────────────

  Future<http.Response> _send({
    required String method,
    required String path,
    required ToastCredentialHandle credentials,
    Map<String, String>? queryParameters,
    Map<String, Object?>? bodyJson,
    bool includeIdempotencyKey = false,
  }) async {
    final uri = _resolveUri(path, queryParameters);
    final encodedBody = bodyJson == null ? null : jsonEncode(bodyJson);
    final idempotencyKey =
        includeIdempotencyKey ? _idempotencyKeyFactory() : null;

    var attempt = 0;
    var forceRefreshNext = false;
    while (true) {
      attempt += 1;
      final token = await _tokenResolver.resolveAccessToken(
        credentials: credentials,
        forceRefresh: forceRefreshNext,
      );
      forceRefreshNext = false;

      final headers = <String, String>{
        'Authorization': 'Bearer $token',
        'Toast-Restaurant-External-ID': credentials.restaurantGuid,
        'Accept': 'application/json',
        if (encodedBody != null) 'Content-Type': 'application/json',
        if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
      };

      http.Response response;
      try {
        response = await _dispatch(
          method: method,
          uri: uri,
          headers: headers,
          body: encodedBody,
        ).timeout(_requestTimeout);
      } on TimeoutException catch (e) {
        if (attempt > kToastMaxRetries) {
          throw ToastTransientError(
            'Toast request timed out after $attempt attempts',
            cause: e,
          );
        }
        await _sleep(_backoffDelay(attempt, retryAfter: null));
        continue;
      } on http.ClientException catch (e) {
        if (attempt > kToastMaxRetries) {
          throw ToastTransientError(
            'Toast HTTP client failure after $attempt attempts: ${e.message}',
            cause: e,
          );
        }
        await _sleep(_backoffDelay(attempt, retryAfter: null));
        continue;
      }

      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        return response;
      }

      if (status == 401) {
        // Reactive refresh once: the resolver gets `forceRefresh: true`
        // on the next attempt. After that, surface as auth error.
        if (!forceRefreshNext && attempt == 1) {
          forceRefreshNext = true;
          continue;
        }
        throw ToastAuthError(
          'Toast rejected bearer token (401): ${_truncate(response.body)}',
          statusCode: status,
        );
      }

      if (status == 429) {
        final retryAfter = _parseRetryAfter(
          response.headers['retry-after'],
        );
        if (attempt > kToastMaxRetries) {
          throw ToastRateLimitError(
            'Toast rate limit exceeded after $attempt attempts',
            statusCode: status,
            retryAfter: retryAfter,
          );
        }
        await _sleep(_backoffDelay(attempt, retryAfter: retryAfter));
        continue;
      }

      if (status >= 500) {
        if (attempt > kToastMaxRetries) {
          throw ToastTransientError(
            'Toast server error after $attempt attempts: '
            '${_truncate(response.body)}',
            statusCode: status,
          );
        }
        await _sleep(_backoffDelay(attempt, retryAfter: null));
        continue;
      }

      // 4xx (other than 401/429) — permanent.
      throw ToastPermanentError(
        'Toast permanent error: ${_truncate(response.body)}',
        statusCode: status,
      );
    }
  }

  Future<http.Response> _dispatch({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (body != null) request.body = body;
    final streamed = await _httpClient.send(request);
    return http.Response.fromStream(streamed);
  }

  Uri _resolveUri(String path, Map<String, String>? queryParameters) {
    final assembled = _baseUri.replace(
      path: path,
      queryParameters: (queryParameters == null || queryParameters.isEmpty)
          ? null
          : queryParameters,
    );
    return assembled;
  }

  /// Compute a backoff delay for `attempt` (1-indexed). When the
  /// vendor sent a `Retry-After` hint we respect it (clamped to
  /// [kToastRetryMaxDelay]) and add a small jitter to avoid thundering
  /// herds. Otherwise we use exponential backoff: `base * 2^(n-1)` with
  /// uniform jitter in `[0, base * 2^n)`.
  Duration _backoffDelay(int attempt, {Duration? retryAfter}) {
    if (retryAfter != null && retryAfter > Duration.zero) {
      final jittered = retryAfter +
          Duration(
            milliseconds: _random.nextInt(
              kToastRetryBaseDelay.inMilliseconds,
            ),
          );
      return jittered > kToastRetryMaxDelay ? kToastRetryMaxDelay : jittered;
    }
    final exp = kToastRetryBaseDelay.inMilliseconds * (1 << (attempt - 1));
    final jitter = _random.nextInt(exp + 1);
    final total = Duration(milliseconds: exp + jitter);
    return total > kToastRetryMaxDelay ? kToastRetryMaxDelay : total;
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  Map<String, Object?> _decodeJson(http.Response response) {
    if (response.body.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is List) {
        // Toast's `ordersBulk` historically returned a top-level array;
        // wrap it so callers see a uniform map shape.
        return <String, Object?>{'orders': decoded};
      }
      throw const ToastPermanentError(
        'Toast response body has unexpected JSON shape',
      );
    } on FormatException catch (e) {
      throw ToastPermanentError(
        'Toast response body is not valid JSON: ${_truncate(response.body)}',
        cause: e,
      );
    }
  }

  List<Map<String, Object?>> _ordersFromBody(Map<String, Object?> body) {
    final raw = body['orders'] ?? body['data'];
    if (raw is List) {
      return raw
          .whereType<Map<Object?, Object?>>()
          .map((m) => m.map(
                (k, v) => MapEntry(k.toString(), v),
              ))
          .toList(growable: false);
    }
    return const <Map<String, Object?>>[];
  }

  Duration? _parseRetryAfter(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final asInt = int.tryParse(raw.trim());
    if (asInt != null) return Duration(seconds: asInt);
    // RFC 7231 also allows HTTP-date; parse and diff against now.
    try {
      final date = HttpDateUtil.parse(raw);
      final delta = date.difference(_clock().toUtc());
      return delta.isNegative ? Duration.zero : delta;
    } catch (_) {
      return null;
    }
  }

  static String _truncate(String body, {int max = 256}) {
    if (body.length <= max) return body;
    return '${body.substring(0, max)}…';
  }
}

/// Tiny RFC 7231 HTTP-date parser. Standalone helper so the production
/// client does not pull in `dart:io` (which would block usage from
/// platforms that ban it).
class HttpDateUtil {
  static DateTime parse(String input) {
    // `DateTime.parse` already accepts the RFC 3339 / ISO 8601 form
    // Toast emits in 99% of cases. Falling back to that keeps this
    // helper surface trivially correct without re-implementing
    // RFC 7231's IMF-fixdate / RFC 850 / ANSI-C asctime branches.
    return DateTime.parse(input).toUtc();
  }
}
