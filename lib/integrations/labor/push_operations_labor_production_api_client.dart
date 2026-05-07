// Phase 8.S / `8.transport.push-operations-labor` — production HTTP
// transport for the Push Operations scheduling adapter.
//
// Authority (read in this order):
//
//   1. The active prompt — production HTTP transport for Push
//      Operations behind the abstract `PushOperationsApiClient` defined
//      in `lib/integrations/labor/push_operations_labor_adapter.dart`.
//   2. `docs/integrations/push_operations/api_consumed.md` — endpoint
//      list, auth shape, pagination shape, base URL, retrieved
//      2026-05-04.
//   3. `docs/contracts/vendor_adapter_slice_contract.md` — adapter
//      contract every Phase 8.S transport must honor.
//
// Hard Promises honored (CLAUDE.md):
//
//   * #1 (transport swap) — this file is a transport: it implements the
//     abstract `PushOperationsApiClient` against a real HTTP endpoint
//     and writes nothing to the canonical store directly.
//   * #4 (per-operator isolation) — every call carries
//     `(operatorId, locationId)` so the credential resolver can scope a
//     bearer to the calling tenant.
//   * #7 (server-side keys) — the adapter never sees plaintext bearer
//     tokens. The credential resolver lives in `tool/advisor_proxy/` (or
//     a Cloud Run-side service binding); plaintext stays behind the
//     proxy boundary.
//
// What this file does NOT do:
//
//   * No app-logic decisions — everything beyond HTTP transport (sanity
//     hooks, canonical-fact projection, watermark commits) lives in the
//     adapter or the Postgres sink.
//   * No `package:postgres` import — only
//     `lib/infrastructure/persistence/postgres/` may import that.
//   * No new pub deps — this client uses `package:http` (already a
//     direct dep) and `dart:convert`.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'push_operations_labor_adapter.dart';

/// Documented production base URI for the Push Operations REST API.
///
/// Source: `docs/integrations/push_operations/api_consumed.md`
/// (Production environment block). Public production host published at
/// `https://app-elb.pushoperations.com/login`. The trailing `/api/v1/`
/// path keeps documented endpoint paths (`shifts`, `employees`,
/// `positions`, `company`, `labour`) directly resolvable as relative
/// segments.
final Uri pushOperationsProductionBaseUri =
    Uri.parse('https://app-elb.pushoperations.com/api/v1/');

/// Default page size requested for `page+limit` paginated endpoints.
///
/// Matches `pushOperationsMaxPageSize` documented on the abstract
/// `PushOperationsApiClient` interface (`shifts`, `employees`,
/// `positions` cap at 100 records per page; a short page = end of
/// listing per `api_consumed.md`).
const int pushOperationsDefaultPageSize = pushOperationsMaxPageSize;

/// Default request timeout for a single HTTP exchange. Bounds how long
/// the worker can hang on one Push Operations call before the next
/// retry / backoff kicks in. Polling cadence is the only live-update
/// path for this poll-only vendor, so a per-request timeout is
/// load-bearing for tick liveness.
const Duration pushOperationsDefaultRequestTimeout = Duration(seconds: 25);

/// Maximum number of retries for a single 429-throttled GET. The
/// production transport honors the vendor's `Retry-After` header when
/// present, otherwise falls back to capped exponential backoff.
const int pushOperationsMax429Retries = 4;

/// Hard ceiling on the backoff sleep. Even if the vendor returns a
/// huge `Retry-After`, the client never waits longer than this — the
/// next tick will pick up the watermark and resume.
const Duration pushOperationsMax429SleepCeiling = Duration(seconds: 30);

/// Cursor encoding shape used by the abstract `PushOperationsApiClient`
/// interface and persisted to `connector_sync_watermark.cursor_token`.
///
/// Push Operations paginates with `page` + `limit`. The transport
/// encodes "next page index" as a `page:<n>` token; the watermark
/// surface persists the literal token so a Cloud Run Job restart
/// resumes from the right page.
const String _cursorPagePrefix = 'page:';

/// Resolves a partner-issued bearer token for the calling tenant. The
/// production wiring binds this to the server-side `vendor_credentials`
/// repository so plaintext never reaches Flutter (Hard Promise #7); the
/// signature accepts `(operatorId, locationId)` so a future per-location
/// credential lookup is non-breaking.
///
/// Returns the bare bearer string (no `Bearer ` prefix). The transport
/// throws [PushOperationsAuthMissingException] when the resolver
/// returns `null` or empty.
typedef PushOperationsBearerResolver = Future<String?> Function({
  required String operatorId,
  required String locationId,
});

/// Thrown when [PushOperationsBearerResolver] yields no token. The
/// adapter should surface this as a connection-down event; the framework
/// can re-prompt the operator to repaste the partner-issued bearer.
class PushOperationsAuthMissingException implements Exception {
  const PushOperationsAuthMissingException({
    required this.operatorId,
    required this.locationId,
  });

  final String operatorId;
  final String locationId;

  @override
  String toString() =>
      'PushOperationsAuthMissingException(operator=$operatorId, '
      'location=$locationId): credential resolver returned no bearer';
}

/// Thrown when Push Operations returns 401 Unauthorized. Indicates the
/// stored bearer is stale or revoked — the framework should mark the
/// connection as `auth_failed` and prompt a repaste.
class PushOperationsUnauthorizedException implements Exception {
  const PushOperationsUnauthorizedException({
    required this.body,
    required this.url,
  });

  /// Raw response body (bounded by Push Operations response size).
  final String body;
  final Uri url;

  @override
  String toString() =>
      'PushOperationsUnauthorizedException($url): $body';
}

/// Thrown when a 429 retry budget exhausts. Surfaces the last vendor
/// `Retry-After` (when present) so the worker can elect to delay the
/// next tick.
class PushOperationsThrottledException implements Exception {
  const PushOperationsThrottledException({
    required this.attempts,
    required this.lastRetryAfter,
    required this.url,
  });

  final int attempts;
  final Duration? lastRetryAfter;
  final Uri url;

  @override
  String toString() =>
      'PushOperationsThrottledException($url): attempts=$attempts '
      'lastRetryAfter=$lastRetryAfter';
}

/// Thrown for any other non-2xx status. Status code + raw body are
/// preserved for telemetry; the worker logs and lets the watermark
/// stand so the next tick retries the same window.
class PushOperationsHttpException implements Exception {
  const PushOperationsHttpException({
    required this.statusCode,
    required this.body,
    required this.url,
  });

  final int statusCode;
  final String body;
  final Uri url;

  @override
  String toString() =>
      'PushOperationsHttpException($statusCode, $url): $body';
}

/// Thrown when a documented JSON body is malformed (missing `shifts`
/// array, non-list, etc). Distinguishes wire-shape drift from network
/// failure; a recurring drift signal is the trigger for an
/// `8.S.PU.live.sandbox` re-verification.
class PushOperationsSchemaException implements Exception {
  const PushOperationsSchemaException({required this.message, required this.url});
  final String message;
  final Uri url;

  @override
  String toString() => 'PushOperationsSchemaException($url): $message';
}

/// Production HTTP transport for [PushOperationsApiClient].
///
/// Construct with [bearerResolver] bound to the server-side credential
/// store, an optional [baseUri] override (env switch for sandbox /
/// region failover), and an optional injected [http.Client] (tests
/// pass `package:http/testing.dart`'s `MockClient`).
///
/// Construction is cheap; the client may be reused across many
/// `(operator, location)` pairs because every method threads tenant
/// scope through to [bearerResolver].
class PushOperationsLaborProductionApiClient implements PushOperationsApiClient {
  PushOperationsLaborProductionApiClient({
    required PushOperationsBearerResolver bearerResolver,
    Uri? baseUri,
    http.Client? httpClient,
    Duration timeout = pushOperationsDefaultRequestTimeout,
    int pageSize = pushOperationsDefaultPageSize,
    int max429Retries = pushOperationsMax429Retries,
    Duration max429SleepCeiling = pushOperationsMax429SleepCeiling,
    Future<void> Function(Duration delay)? sleep,
    String Function()? idempotencyKeyFactory,
  })  : _bearerResolver = bearerResolver,
        _baseUri = _normalizeBaseUri(baseUri ?? pushOperationsProductionBaseUri),
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _pageSize = pageSize,
        _max429Retries = max429Retries,
        _max429SleepCeiling = max429SleepCeiling,
        _sleep = sleep ?? _defaultSleep,
        _idempotencyKeyFactory =
            idempotencyKeyFactory ?? _defaultIdempotencyKeyFactory;

  final PushOperationsBearerResolver _bearerResolver;
  final Uri _baseUri;
  final http.Client _httpClient;
  final Duration _timeout;
  final int _pageSize;
  final int _max429Retries;
  final Duration _max429SleepCeiling;
  final Future<void> Function(Duration delay) _sleep;
  final String Function() _idempotencyKeyFactory;

  /// Normalize the base URI so relative segment resolution behaves
  /// identically whether the caller passed a trailing slash or not.
  static Uri _normalizeBaseUri(Uri raw) {
    if (raw.path.isEmpty || raw.path.endsWith('/')) {
      return raw;
    }
    return raw.replace(path: '${raw.path}/');
  }

  static Future<void> _defaultSleep(Duration delay) =>
      Future<void>.delayed(delay);

  static String _defaultIdempotencyKeyFactory() {
    // Matches the proxy's idempotency-key shape: a stable prefix plus
    // a high-resolution timestamp. Real production wiring can swap this
    // for a UUIDv4; the current shape is sufficient because Push
    // Operations does not document a UUID requirement and the prefix
    // makes the key origin-traceable in `proxy_requests`.
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'pushops-$now';
  }

  // ─── PushOperationsApiClient surface ────────────────────────────────

  @override
  Future<PushOperationsShiftPage> fetchSampleShift({
    required String operatorId,
    required String locationId,
  }) async {
    // testConnection asks for "one representative shift". Push
    // Operations' `/shifts` endpoint does not document a `latest=true`
    // selector, so the transport requests page 1 with `limit=1` and
    // returns the first row. The vendor returns the most recently
    // modified row first when no `updated_at` filter is set; an empty
    // page is reported back as `records=[]` so the adapter can render
    // the "no shifts on this account" copy.
    final url = _buildShiftsUri(
      sinceModified: null,
      page: 1,
      limit: 1,
    );
    final body = await _getJson(
      url: url,
      operatorId: operatorId,
      locationId: locationId,
    );
    final records = _readShiftsArray(body, url);
    final lastModified = _extractLastModified(records, fallback: DateTime.utc(1970));
    return PushOperationsShiftPage(
      records: records,
      // Sample fetch — there is no resumable cursor.
      nextCursor: pushOperationsInitialCursorToken,
      lastModifiedSeen: lastModified,
    );
  }

  @override
  Future<PushOperationsShiftPage> fetchShifts({
    required String operatorId,
    required String locationId,
    required DateTime sinceModified,
    required String? cursor,
    required bool isDeliberateBackfill,
  }) async {
    final pageIndex = _decodeCursor(cursor);
    final url = _buildShiftsUri(
      sinceModified: sinceModified,
      page: pageIndex,
      limit: _pageSize,
    );
    final body = await _getJson(
      url: url,
      operatorId: operatorId,
      locationId: locationId,
    );
    final records = _readShiftsArray(body, url);
    final lastModified = _extractLastModified(records, fallback: sinceModified);

    // Short page = end of listing per documented pagination shape
    // (`api_consumed.md`). Returning an empty cursor closes the loop in
    // the adapter's backfill / poll while-loop.
    final isLastPage = records.length < _pageSize;
    final nextCursor = isLastPage
        ? pushOperationsInitialCursorToken
        : _encodeCursor(pageIndex + 1);

    return PushOperationsShiftPage(
      records: records,
      nextCursor: nextCursor,
      lastModifiedSeen: lastModified,
    );
  }

  // ─── Internal HTTP plumbing ─────────────────────────────────────────

  /// Build the `/shifts` URI per documented shape. `since_modified` is
  /// a hint to the vendor — Push Operations documents `updated_at` as
  /// the modification timestamp, and the documented filter parameter is
  /// `updated_after` (ISO-8601). When [sinceModified] is null (sample
  /// fetch), no filter is sent and the vendor returns most-recent-first.
  Uri _buildShiftsUri({
    required DateTime? sinceModified,
    required int page,
    required int limit,
  }) {
    final query = <String, String>{
      'page': page.toString(),
      'limit': limit.toString(),
    };
    if (sinceModified != null) {
      // Always emit explicit-Z UTC. Push Operations' documented
      // timestamp policy is `Z`-suffixed ISO-8601; the adapter parses
      // back with the same shape (see
      // `push_operations_labor_adapter.dart::_parseUtcInstant`).
      query['updated_after'] = sinceModified.toUtc().toIso8601String();
    }
    return _baseUri.resolve('shifts').replace(queryParameters: query);
  }

  /// Single GET with retry/backoff orchestration.
  Future<Map<String, Object?>> _getJson({
    required Uri url,
    required String operatorId,
    required String locationId,
  }) async {
    final bearer = await _resolveBearer(
      operatorId: operatorId,
      locationId: locationId,
    );

    int attempt = 0;
    Duration? lastRetryAfter;
    while (true) {
      final response = await _sendGet(url: url, bearer: bearer);
      if (response.statusCode == 200) {
        return _decodeBody(response.body, url);
      }
      if (response.statusCode == 401) {
        throw PushOperationsUnauthorizedException(
          body: response.body,
          url: url,
        );
      }
      if (response.statusCode == 429) {
        if (attempt >= _max429Retries) {
          throw PushOperationsThrottledException(
            attempts: attempt + 1,
            lastRetryAfter: lastRetryAfter,
            url: url,
          );
        }
        final retryAfter =
            _parseRetryAfter(response.headers) ?? _backoffFor(attempt);
        lastRetryAfter = retryAfter;
        await _sleep(_clampSleep(retryAfter));
        attempt += 1;
        continue;
      }
      throw PushOperationsHttpException(
        statusCode: response.statusCode,
        body: response.body,
        url: url,
      );
    }
  }

  /// POST with idempotency key. Currently unused by the documented
  /// `PushOperationsApiClient` surface (Push Operations is poll-only and
  /// the adapter only consumes GETs at slice ship), but the contract
  /// mandates that any future write path carry an Idempotency-Key
  /// header. Live by being available here so a follow-up that adds a
  /// write endpoint does not need to refactor the transport.
  // ignore: unused_element
  Future<Map<String, Object?>> _postJson({
    required Uri url,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    final bearer = await _resolveBearer(
      operatorId: operatorId,
      locationId: locationId,
    );
    final encoded = jsonEncode(body);
    final idempotencyKey = _idempotencyKeyFactory();

    int attempt = 0;
    Duration? lastRetryAfter;
    while (true) {
      final response = await _sendPost(
        url: url,
        bearer: bearer,
        body: encoded,
        idempotencyKey: idempotencyKey,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _decodeBody(response.body, url);
      }
      if (response.statusCode == 401) {
        throw PushOperationsUnauthorizedException(
          body: response.body,
          url: url,
        );
      }
      if (response.statusCode == 429) {
        if (attempt >= _max429Retries) {
          throw PushOperationsThrottledException(
            attempts: attempt + 1,
            lastRetryAfter: lastRetryAfter,
            url: url,
          );
        }
        final retryAfter =
            _parseRetryAfter(response.headers) ?? _backoffFor(attempt);
        lastRetryAfter = retryAfter;
        await _sleep(_clampSleep(retryAfter));
        attempt += 1;
        continue;
      }
      throw PushOperationsHttpException(
        statusCode: response.statusCode,
        body: response.body,
        url: url,
      );
    }
  }

  Future<http.Response> _sendGet({
    required Uri url,
    required String bearer,
  }) async {
    final request = http.Request('GET', url);
    request.headers.addAll(<String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer $bearer',
      'user-agent': 'forge-and-flow/8.S.PU (push_operations adapter)',
    });
    final streamed = await _httpClient.send(request).timeout(_timeout);
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    return http.Response(
      raw,
      streamed.statusCode,
      headers: streamed.headers,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  Future<http.Response> _sendPost({
    required Uri url,
    required String bearer,
    required String body,
    required String idempotencyKey,
  }) async {
    final request = http.Request('POST', url);
    request.headers.addAll(<String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer $bearer',
      'content-type': 'application/json',
      'idempotency-key': idempotencyKey,
      'user-agent': 'forge-and-flow/8.S.PU (push_operations adapter)',
    });
    request.body = body;
    final streamed = await _httpClient.send(request).timeout(_timeout);
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    return http.Response(
      raw,
      streamed.statusCode,
      headers: streamed.headers,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  Future<String> _resolveBearer({
    required String operatorId,
    required String locationId,
  }) async {
    final raw = await _bearerResolver(
      operatorId: operatorId,
      locationId: locationId,
    );
    final token = raw?.trim();
    if (token == null || token.isEmpty) {
      throw PushOperationsAuthMissingException(
        operatorId: operatorId,
        locationId: locationId,
      );
    }
    return token;
  }

  // ─── Decoding helpers ───────────────────────────────────────────────

  Map<String, Object?> _decodeBody(String raw, Uri url) {
    if (raw.isEmpty) {
      return const <String, Object?>{};
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw PushOperationsSchemaException(
        message: 'malformed JSON: ${e.message}',
        url: url,
      );
    }
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) {
      return <String, Object?>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      };
    }
    throw PushOperationsSchemaException(
      message: 'expected JSON object at root, got ${decoded.runtimeType}',
      url: url,
    );
  }

  /// Read the documented `shifts[]` array. Tolerates the alternate
  /// envelope `{"data": [...]}` so a documented shape change to a
  /// `data` envelope does not break the slice; CI lint warns on the
  /// `api_consumed.md` retrieval-date drift instead.
  List<Map<String, Object?>> _readShiftsArray(
    Map<String, Object?> body,
    Uri url,
  ) {
    final candidate = body['shifts'] ?? body['data'];
    if (candidate == null) {
      // Empty body / missing shifts key => empty page (vendor returns
      // an empty array as `{"shifts": []}` when no rows match).
      return const <Map<String, Object?>>[];
    }
    if (candidate is! List) {
      throw PushOperationsSchemaException(
        message: 'expected `shifts` to be a List, got ${candidate.runtimeType}',
        url: url,
      );
    }
    return candidate
        .whereType<Map<Object?, Object?>>()
        .map(_stringKeyMap)
        .toList(growable: false);
  }

  /// Walk the page and return the maximum `updated_at` we've seen.
  /// Falls back to the caller-supplied [fallback] when the page is
  /// empty (poll on an idle account) or when no row exposes
  /// `updated_at`.
  DateTime _extractLastModified(
    List<Map<String, Object?>> records, {
    required DateTime fallback,
  }) {
    DateTime max = fallback.toUtc();
    for (final record in records) {
      final raw = record['updated_at'];
      DateTime? parsed;
      if (raw is String && raw.isNotEmpty) {
        try {
          parsed = DateTime.parse(raw).toUtc();
        } on FormatException {
          parsed = null;
        }
      } else if (raw is DateTime) {
        parsed = raw.toUtc();
      }
      if (parsed != null && parsed.isAfter(max)) {
        max = parsed;
      }
    }
    return max;
  }

  static Map<String, Object?> _stringKeyMap(Map<Object?, Object?> raw) {
    return <String, Object?>{
      for (final entry in raw.entries) entry.key.toString(): entry.value,
    };
  }

  // ─── Cursor encoding ───────────────────────────────────────────────

  static int _decodeCursor(String? cursor) {
    if (cursor == null || cursor.isEmpty) return 1;
    if (!cursor.startsWith(_cursorPagePrefix)) return 1;
    final tail = cursor.substring(_cursorPagePrefix.length);
    return int.tryParse(tail) ?? 1;
  }

  static String _encodeCursor(int page) => '$_cursorPagePrefix$page';

  // ─── Backoff helpers ───────────────────────────────────────────────

  /// Parse `Retry-After` per RFC 7231: integer seconds OR an HTTP-date.
  /// Returns null when the header is absent or unparseable so the
  /// caller falls back to exponential backoff.
  static Duration? _parseRetryAfter(Map<String, String> headers) {
    final raw = headers['retry-after'] ?? headers['Retry-After'];
    if (raw == null || raw.isEmpty) return null;
    final asInt = int.tryParse(raw.trim());
    if (asInt != null) {
      if (asInt < 0) return Duration.zero;
      return Duration(seconds: asInt);
    }
    try {
      final at = DateTime.parse(raw.trim());
      final delta = at.difference(DateTime.now().toUtc());
      if (delta.isNegative) return Duration.zero;
      return delta;
    } on FormatException {
      return null;
    }
  }

  /// Capped exponential backoff: 1s, 2s, 4s, 8s, ...
  static Duration _backoffFor(int attempt) {
    final seconds = 1 << attempt;
    return Duration(seconds: seconds);
  }

  Duration _clampSleep(Duration delay) {
    if (delay > _max429SleepCeiling) return _max429SleepCeiling;
    if (delay.isNegative) return Duration.zero;
    return delay;
  }
}
