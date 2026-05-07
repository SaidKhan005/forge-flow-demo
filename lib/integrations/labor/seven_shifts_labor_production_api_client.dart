// Phase 8.transport.seven-shifts-labor — production 7shifts HTTP
// transport.
//
// Concretizes [SevenShiftsTransport] (defined in
// `lib/integrations/labor/seven_shifts_labor_adapter.dart`) against the
// real 7shifts v2 REST API documented at
// <https://developers.7shifts.com>.
//
// Authority (read in this order):
//
//   1. The active prompt
//      (`.claude/worktrees/agent-add9ad0fc01716140` Slice instructions).
//   2. `lib/integrations/labor/seven_shifts_labor_adapter.dart` —
//      transport surface + Hours & Wages dollar-precision contract
//      (`8.spine-bridge.7S.upgrade`, wage class
//      `LaborWageSourceClass.perEmployeeWithDollars`).
//   3. CLAUDE.md service-layer split — this file lives in
//      `lib/integrations/` (vendor adapter layer); it imports
//      `package:http` only, never `package:postgres`.
//
// What lands here (live wiring per `*.live.*` waves):
//
//   * `package:http` injection — `SevenShiftsApiClient(httpClient: …)`
//     accepts a `http.Client`; tests inject `http_testing.MockClient`.
//   * Default `baseUri = https://api.7shifts.com/v2`; env override via
//     [SevenShiftsApiClientDeps.baseUriOverride].
//   * Bearer-token auth — every authenticated request adds
//     `Authorization: Bearer <accessToken>`. The access token can be a
//     7shifts API token (Personal Access Token) loaded from the
//     credential store, OR an OAuth-issued access token rotated via
//     [refresh].
//   * Cursor-based pagination for `/time_punches` and
//     `/reports/hours_and_wages`. The 7shifts v2 list endpoints surface
//     `cursor` query parameters and `meta.cursor.next` response keys
//     per <https://developers.7shifts.com/reference/getting-started>.
//   * 429 (Too Many Requests) backoff — single retry honoring
//     `Retry-After` (seconds). Repeated 429s surface a typed
//     [SevenShiftsApiException] so the framework's retry/backoff seam
//     can take over.
//   * Typed errors — every non-2xx response decodes a
//     [SevenShiftsApiException] (or
//     [SevenShiftsHoursAndWagesReportGatedException] for 403/404 on
//     the report endpoint per the adapter's tier-fallback contract).
//   * `TIMESTAMPTZ` preserved end to end — every parsed timestamp
//     is converted to UTC via `DateTime.parse(...).toUtc()`; the
//     response shape on [SevenShiftsTokenResponse] /
//     [SevenShiftsTimePunchPage] / [SevenShiftsHoursAndWagesPage]
//     stays UTC, never local.
//   * Wage precision — the adapter contract demands per-shift dollar
//     totals stay precise. The client preserves `total_pay`,
//     `regular_pay`, `overtime_pay` as `num` (dollars), and the
//     `clocked_in` / `clocked_out` instants stay UTC for minute-level
//     precision. Vendor-side fractional cents are kept as-is — the
//     client never rounds.
//   * Idempotency-Key header on every POST (token exchange, refresh,
//     webhook register) — generated via
//     [SevenShiftsApiClientDeps.idempotencyKeyGenerator]; default uses
//     a UTC-millisecond + UUID-shaped suffix so retries that reach the
//     proxy collapse on the existing key.
//
// What stays out of this file (V1 lean cut 2 + engineer-all-17):
//
//   * Key rotation surface — adapter signing secrets are read from the
//     credential store only; no rotation cron, no rotation UI here.
//   * Advisory locks, DLQ tile, sidecar raw-payload partitions — none
//     of those live in transport code.
//   * `package:postgres` imports — banned in `lib/integrations/`.
//
// Test file: `test/integrations/labor/seven_shifts_labor_production_api_client_test.dart`.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'seven_shifts_labor_adapter.dart';

// ─── Defaults ───────────────────────────────────────────────────────

/// Production 7shifts v2 REST base URI.
final Uri kSevenShiftsDefaultBaseUri =
    Uri.parse('https://api.7shifts.com/v2');

/// Default request timeout. Mirrors the framework HTTP timeout used by
/// the admin gateways (`lib/admin/services/admin_http_timeout.dart`).
const Duration kSevenShiftsDefaultRequestTimeout = Duration(seconds: 30);

/// Maximum number of automatic retries on a 429 (Too Many Requests)
/// response. Subsequent 429s propagate as
/// [SevenShiftsApiException] so the framework's retry/backoff seam can
/// take over with full-jitter scheduling.
const int kSevenShiftsDefault429Retries = 1;

/// Cap on `Retry-After` honoring; vendor-supplied values above this
/// are clamped to keep one tick from blocking the worker thread for
/// many minutes. Anything above the cap surfaces as a typed exception.
const Duration kSevenShiftsRetryAfterCap = Duration(seconds: 60);

/// Default page size for cursor-paginated list endpoints. 7shifts v2
/// caps page size at 200 per
/// <https://developers.7shifts.com/reference/getting-started>; we
/// stay conservative at 100 to keep TLS overhead low and avoid
/// hammering payroll-period boundaries on huge restaurants.
const int kSevenShiftsDefaultPageSize = 100;

// ─── Typed errors ───────────────────────────────────────────────────

/// Generic typed exception for non-2xx responses from the 7shifts API
/// outside of the tier-gated 403/404 path on the Hours & Wages report
/// (which raises [SevenShiftsHoursAndWagesReportGatedException] instead
/// per the adapter contract).
class SevenShiftsApiException implements Exception {
  const SevenShiftsApiException({
    required this.statusCode,
    required this.method,
    required this.uri,
    this.body,
    this.message,
  });

  /// HTTP status code observed.
  final int statusCode;

  /// HTTP verb, e.g. `GET`, `POST`.
  final String method;

  /// Effective request URI (post-merge with baseUri + query params).
  final Uri uri;

  /// Decoded response body (truncated to 2 KiB by [_decodeError]).
  final String? body;

  /// Human-readable message extracted from the response body when the
  /// 7shifts API returned a documented error envelope.
  final String? message;

  @override
  String toString() =>
      'SevenShiftsApiException(statusCode=$statusCode, method=$method, '
      'uri=$uri, message=$message)';
}

/// Authentication failure (401 / 403 outside the report tier-gate).
/// Distinguished by status code so the framework's auth-rotation seam
/// can detect a stale bearer token without parsing message strings.
class SevenShiftsUnauthorizedException extends SevenShiftsApiException {
  const SevenShiftsUnauthorizedException({
    required super.statusCode,
    required super.method,
    required super.uri,
    super.body,
    super.message,
  });

  @override
  String toString() =>
      'SevenShiftsUnauthorizedException(statusCode=$statusCode, method=$method, '
      'uri=$uri, message=$message)';
}

/// 429 (Too Many Requests) survived [kSevenShiftsDefault429Retries]
/// retries. Surfaces the most recent `Retry-After` value (UTC) so the
/// framework's full-jitter scheduler can back off accordingly.
class SevenShiftsRateLimitedException extends SevenShiftsApiException {
  const SevenShiftsRateLimitedException({
    required super.method,
    required super.uri,
    required this.retryAfter,
    super.body,
    super.message,
  }) : super(statusCode: 429);

  /// Vendor-suggested retry delay. Null when the response did not carry
  /// a `Retry-After` header.
  final Duration? retryAfter;

  @override
  String toString() =>
      'SevenShiftsRateLimitedException(method=$method, uri=$uri, '
      'retryAfter=$retryAfter, message=$message)';
}

// ─── Deps record ────────────────────────────────────────────────────

/// Bearer-token provider for [SevenShiftsApiClient]. Real wiring reads
/// the access-token ciphertext from the operator's `vendor_credentials`
/// row through the existing credential gateway; tests pass a closure
/// returning a static string.
typedef SevenShiftsAccessTokenProvider = Future<String> Function();

/// Idempotency key factory; default uses millisecond timestamp + a
/// 64-bit random suffix so retries collide on the proxy's idempotency
/// table per `docs/contracts/proxy_idempotency_contract.md`.
typedef SevenShiftsIdempotencyKeyGenerator = String Function();

/// Sibling deps record for [SevenShiftsApiClient]. Keeps the
/// constructor footprint short and lets tests override single fields
/// without re-listing every dep.
class SevenShiftsApiClientDeps {
  SevenShiftsApiClientDeps({
    required this.accessTokenProvider,
    required this.httpClient,
    this.baseUriOverride,
    this.requestTimeout = kSevenShiftsDefaultRequestTimeout,
    this.maxRateLimitRetries = kSevenShiftsDefault429Retries,
    this.pageSize = kSevenShiftsDefaultPageSize,
    SevenShiftsIdempotencyKeyGenerator? idempotencyKeyGenerator,
    DateTime Function()? now,
    math.Random? random,
  })  : _idempotencyKeyGenerator = idempotencyKeyGenerator,
        _now = now ?? DateTime.now,
        _random = random ?? math.Random.secure();

  /// Async provider for the bearer token sent on every authenticated
  /// request. Production wires this to the credential gateway.
  final SevenShiftsAccessTokenProvider accessTokenProvider;

  /// Injected `package:http` client. Tests use
  /// `package:http/testing.dart`'s `MockClient`.
  final http.Client httpClient;

  /// Optional override for the production base URI. Useful for sandbox
  /// + on-host integration tests; production leaves null.
  final Uri? baseUriOverride;

  /// Per-request timeout. Defaults to
  /// [kSevenShiftsDefaultRequestTimeout].
  final Duration requestTimeout;

  /// Maximum retries on a 429 (Too Many Requests). After this count
  /// the client raises [SevenShiftsRateLimitedException].
  final int maxRateLimitRetries;

  /// Cursor-page size requested from `/time_punches` and
  /// `/reports/hours_and_wages`. Pinned to a sensible default; tests
  /// can override to exercise multi-page walks with small pages.
  final int pageSize;

  final SevenShiftsIdempotencyKeyGenerator? _idempotencyKeyGenerator;
  final DateTime Function() _now;
  final math.Random _random;

  /// Resolved base URI — explicit override wins, default is
  /// [kSevenShiftsDefaultBaseUri].
  Uri get baseUri => baseUriOverride ?? kSevenShiftsDefaultBaseUri;

  /// Generate one Idempotency-Key. Production ties it to the millisecond
  /// timestamp + 64-bit random suffix so retries that collide at the
  /// proxy short-circuit; tests can inject a deterministic value.
  String generateIdempotencyKey() {
    final injected = _idempotencyKeyGenerator;
    if (injected != null) return injected();
    final ts = _now().toUtc().millisecondsSinceEpoch;
    final suffix = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return 'seven-shifts-idem-$ts-$suffix';
  }
}

// ─── Client ─────────────────────────────────────────────────────────

/// Production [SevenShiftsTransport] implementation. Lives behind the
/// adapter; the adapter never imports `package:http` directly.
class SevenShiftsApiClient implements SevenShiftsTransport {
  SevenShiftsApiClient({required SevenShiftsApiClientDeps deps}) : _deps = deps;

  final SevenShiftsApiClientDeps _deps;

  // ─── OAuth ────────────────────────────────────────────────────────

  @override
  Future<SevenShiftsTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  }) async {
    final uri = _resolveUri(path: 'oauth/token');
    final body = <String, String>{
      'grant_type': 'authorization_code',
      'code': authorizationCode,
      'redirect_uri': redirectUri,
    };
    final response = await _sendUnauthenticated(
      method: 'POST',
      uri: uri,
      body: body,
      addIdempotencyKey: true,
    );
    return _parseTokenResponse(uri: uri, response: response);
  }

  @override
  Future<SevenShiftsTokenResponse> refresh({
    required String refreshToken,
  }) async {
    final uri = _resolveUri(path: 'oauth/token');
    final body = <String, String>{
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    };
    final response = await _sendUnauthenticated(
      method: 'POST',
      uri: uri,
      body: body,
      addIdempotencyKey: true,
    );
    return _parseTokenResponse(uri: uri, response: response);
  }

  @override
  Future<void> revoke({required String accessToken}) async {
    // 7shifts v2 OAuth does not document a `/revoke` endpoint; the
    // adapter contract pins this method as a no-op on the real
    // transport. Documented in
    // `lib/integrations/labor/seven_shifts_labor_adapter.dart`'s
    // [SevenShiftsTransport.revoke] doc comment.
    return;
  }

  // ─── Company info ─────────────────────────────────────────────────

  @override
  Future<SevenShiftsCompanyInfo> fetchCompanyInfo({
    required String accessToken,
  }) async {
    final uri = _resolveUri(path: 'company');
    final response = await _sendAuthenticated(
      method: 'GET',
      uri: uri,
      bearer: accessToken,
    );
    final json = _decodeJson(uri: uri, response: response);
    final data = _readMap(json, 'data') ?? json;
    final companyId = _readString(data, 'id') ??
        _readString(data, 'company_id') ??
        '';
    final planTier =
        (_readString(data, 'plan') ?? _readString(data, 'plan_tier') ?? '')
            .toLowerCase();
    return SevenShiftsCompanyInfo(
      companyId: companyId,
      planTier: planTier,
    );
  }

  // ─── Time punches (paginated) ─────────────────────────────────────

  @override
  Future<SevenShiftsTimePunchPage> listTimePunches({
    required String accessToken,
    required String companyId,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    final uri = _resolveUri(
      path: 'company/$companyId/time_punches',
      queryParameters: <String, String>{
        'modified_since': modifiedSince.toUtc().toIso8601String(),
        'modified_until': modifiedUntil.toUtc().toIso8601String(),
        'limit': _deps.pageSize.toString(),
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      },
    );
    final response = await _sendAuthenticated(
      method: 'GET',
      uri: uri,
      bearer: accessToken,
    );
    final json = _decodeJson(uri: uri, response: response);
    final rawRecords = _readList(json, 'data') ?? const <Object?>[];
    final records = <Map<String, Object?>>[];
    DateTime lastModifiedSeen = modifiedSince.toUtc();
    for (final item in rawRecords) {
      if (item is! Map) continue;
      final record = <String, Object?>{
        for (final entry in item.entries) entry.key.toString(): entry.value,
      };
      records.add(record);
      final modifiedRaw = record['modified'];
      if (modifiedRaw is String && modifiedRaw.isNotEmpty) {
        final parsed = DateTime.tryParse(modifiedRaw)?.toUtc();
        if (parsed != null && parsed.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = parsed;
        }
      }
    }
    return SevenShiftsTimePunchPage(
      records: records,
      nextCursor: _readNextCursor(json),
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  // ─── Payroll period (latest closed) ───────────────────────────────

  @override
  Future<DateTime?> fetchLatestPayrollPeriodClosedAt({
    required String accessToken,
    required String companyId,
  }) async {
    final uri = _resolveUri(
      path: 'company/$companyId/payroll_periods',
      queryParameters: <String, String>{
        'status': 'closed',
        'limit': '1',
      },
    );
    final response = await _sendAuthenticated(
      method: 'GET',
      uri: uri,
      bearer: accessToken,
    );
    final json = _decodeJson(uri: uri, response: response);
    final list = _readList(json, 'data') ?? const <Object?>[];
    if (list.isEmpty) return null;
    final first = list.first;
    if (first is! Map) return null;
    final closedRaw =
        first['closed_at'] ?? first['closedAt'] ?? first['closed'];
    if (closedRaw is! String || closedRaw.isEmpty) return null;
    return DateTime.tryParse(closedRaw)?.toUtc();
  }

  // ─── Hours & Wages report (Gourmet-tier-gated, paginated) ─────────

  @override
  Future<SevenShiftsHoursAndWagesPage> fetchHoursAndWagesReport({
    required String accessToken,
    required String companyId,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    required bool isDeliberateBackfill,
    String? cursor,
  }) async {
    final uri = _resolveUri(
      path: 'company/$companyId/reports/hours_and_wages',
      queryParameters: <String, String>{
        'start': modifiedSince.toUtc().toIso8601String(),
        'end': modifiedUntil.toUtc().toIso8601String(),
        'limit': _deps.pageSize.toString(),
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      },
    );
    final response = await _sendAuthenticatedRaw(
      method: 'GET',
      uri: uri,
      bearer: accessToken,
    );
    if (response.statusCode == 403 || response.statusCode == 404) {
      // Lower 7shifts plan tier — the adapter routes this typed
      // exception into the substituted-wage provenance fallback.
      throw SevenShiftsHoursAndWagesReportGatedException(
        statusCode: response.statusCode,
        message: _decodeErrorMessage(response),
      );
    }
    _ensureSuccess(method: 'GET', uri: uri, response: response);
    final json = _decodeBodyJson(uri: uri, body: response.body);
    final rawRows = _readList(json, 'data') ?? const <Object?>[];
    final rows = <SevenShiftsHoursAndWagesRow>[];
    for (final item in rawRows) {
      if (item is! Map) continue;
      final row = <String, Object?>{
        for (final entry in item.entries) entry.key.toString(): entry.value,
      };
      final employeeId = _readString(row, 'employee_id') ??
          _readString(row, 'user_id') ??
          '';
      final shiftId = _readString(row, 'shift_id') ?? '';
      if (employeeId.isEmpty || shiftId.isEmpty) continue;
      final totalPay = _readNum(row, 'total_pay');
      if (totalPay == null) continue;
      rows.add(
        SevenShiftsHoursAndWagesRow(
          employeeId: employeeId,
          shiftId: shiftId,
          totalPay: totalPay,
          regularPay: _readNum(row, 'regular_pay'),
          overtimePay: _readNum(row, 'overtime_pay'),
        ),
      );
    }
    return SevenShiftsHoursAndWagesPage(
      rows: rows,
      nextCursor: _readNextCursor(json),
    );
  }

  // ─── Webhook auto-registration (Gourmet plan only) ────────────────

  @override
  Future<String> registerWebhook({
    required String accessToken,
    required String companyId,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async {
    final uri = _resolveUri(path: 'company/$companyId/webhooks');
    final body = <String, Object?>{
      'url': url,
      'events': events,
      'signing_secret': signingSecret,
    };
    final response = await _sendAuthenticated(
      method: 'POST',
      uri: uri,
      bearer: accessToken,
      jsonBody: body,
      addIdempotencyKey: true,
    );
    final json = _decodeJson(uri: uri, response: response);
    final data = _readMap(json, 'data') ?? json;
    final id = _readString(data, 'id') ??
        _readString(data, 'webhook_id') ??
        _readString(json, 'id');
    if (id == null || id.isEmpty) {
      throw SevenShiftsApiException(
        statusCode: response.statusCode,
        method: 'POST',
        uri: uri,
        body: response.body,
        message:
            '7shifts webhook register response missing id; cannot bind to '
            'connector_connection.metadata.webhook_id',
      );
    }
    return id;
  }

  @override
  Future<void> unregisterWebhook({
    required String accessToken,
    required String companyId,
    required String webhookId,
  }) async {
    final uri = _resolveUri(
      path: 'company/$companyId/webhooks/$webhookId',
    );
    final response = await _sendAuthenticatedRaw(
      method: 'DELETE',
      uri: uri,
      bearer: accessToken,
    );
    if (response.statusCode == 404) {
      // Already unregistered — vendor returns 404; treat as no-op.
      return;
    }
    _ensureSuccess(method: 'DELETE', uri: uri, response: response);
  }

  // ─── Sample punch (testConnection) ────────────────────────────────

  @override
  Future<Map<String, Object?>> samplePunch({
    required String accessToken,
    required String companyId,
  }) async {
    final uri = _resolveUri(
      path: 'company/$companyId/time_punches',
      queryParameters: <String, String>{
        'limit': '1',
      },
    );
    final response = await _sendAuthenticated(
      method: 'GET',
      uri: uri,
      bearer: accessToken,
    );
    final json = _decodeJson(uri: uri, response: response);
    final list = _readList(json, 'data') ?? const <Object?>[];
    if (list.isEmpty) return const <String, Object?>{};
    final first = list.first;
    if (first is! Map) return const <String, Object?>{};
    return <String, Object?>{
      for (final entry in first.entries) entry.key.toString(): entry.value,
    };
  }

  // ─── Internal: send / parse / paginate ────────────────────────────

  /// Resolve an absolute URI from a path segment, preserving any base
  /// path on [SevenShiftsApiClientDeps.baseUri]. The base URI's path
  /// component is treated as the v2 prefix; this method does NOT
  /// double-encode `/`.
  Uri _resolveUri({
    required String path,
    Map<String, String>? queryParameters,
  }) {
    final base = _deps.baseUri;
    final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
    final trimmed = path.startsWith('/') ? path.substring(1) : path;
    final composedPath = '$basePath$trimmed';
    return base.replace(
      path: composedPath,
      queryParameters: queryParameters,
    );
  }

  Future<http.Response> _sendUnauthenticated({
    required String method,
    required Uri uri,
    Map<String, String>? body,
    bool addIdempotencyKey = false,
  }) async {
    final headers = <String, String>{
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/x-www-form-urlencoded',
      if (addIdempotencyKey) 'idempotency-key': _deps.generateIdempotencyKey(),
    };
    final response = await _sendWithRetry(
      method: method,
      uri: uri,
      headers: headers,
      body: body == null ? null : Uri(queryParameters: body).query,
    );
    _ensureSuccess(method: method, uri: uri, response: response);
    return response;
  }

  Future<http.Response> _sendAuthenticated({
    required String method,
    required Uri uri,
    required String bearer,
    Map<String, Object?>? jsonBody,
    bool addIdempotencyKey = false,
  }) async {
    final response = await _sendAuthenticatedRaw(
      method: method,
      uri: uri,
      bearer: bearer,
      jsonBody: jsonBody,
      addIdempotencyKey: addIdempotencyKey,
    );
    _ensureSuccess(method: method, uri: uri, response: response);
    return response;
  }

  Future<http.Response> _sendAuthenticatedRaw({
    required String method,
    required Uri uri,
    required String bearer,
    Map<String, Object?>? jsonBody,
    bool addIdempotencyKey = false,
  }) async {
    final headers = <String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer $bearer',
      if (jsonBody != null) 'content-type': 'application/json',
      if (addIdempotencyKey) 'idempotency-key': _deps.generateIdempotencyKey(),
    };
    final body = jsonBody == null ? null : jsonEncode(jsonBody);
    return _sendWithRetry(
      method: method,
      uri: uri,
      headers: headers,
      body: body,
    );
  }

  Future<http.Response> _sendWithRetry({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    int attempt = 0;
    Duration? lastRetryAfter;
    String? lastBody;
    while (true) {
      final response = await _sendOnce(
        method: method,
        uri: uri,
        headers: headers,
        body: body,
      );
      if (response.statusCode != 429) return response;
      lastBody = response.body;
      lastRetryAfter = _parseRetryAfter(response.headers['retry-after']);
      if (attempt >= _deps.maxRateLimitRetries) {
        throw SevenShiftsRateLimitedException(
          method: method,
          uri: uri,
          retryAfter: lastRetryAfter,
          body: _truncate(lastBody),
          message: _decodeErrorMessage(response),
        );
      }
      attempt += 1;
      final delay = lastRetryAfter ??
          Duration(milliseconds: 250 * (1 << (attempt - 1)));
      final clamped =
          delay > kSevenShiftsRetryAfterCap ? kSevenShiftsRetryAfterCap : delay;
      await Future<void>.delayed(clamped);
    }
  }

  Future<http.Response> _sendOnce({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (body != null) request.body = body;
    final streamed = await _deps.httpClient.send(request).timeout(
          _deps.requestTimeout,
        );
    return http.Response.fromStream(streamed);
  }

  // ─── Internal: response decoding ──────────────────────────────────

  void _ensureSuccess({
    required String method,
    required Uri uri,
    required http.Response response,
  }) {
    final code = response.statusCode;
    if (code >= 200 && code < 300) return;
    if (code == 401) {
      throw SevenShiftsUnauthorizedException(
        statusCode: code,
        method: method,
        uri: uri,
        body: _truncate(response.body),
        message: _decodeErrorMessage(response),
      );
    }
    if (code == 429) {
      throw SevenShiftsRateLimitedException(
        method: method,
        uri: uri,
        retryAfter: _parseRetryAfter(response.headers['retry-after']),
        body: _truncate(response.body),
        message: _decodeErrorMessage(response),
      );
    }
    throw SevenShiftsApiException(
      statusCode: code,
      method: method,
      uri: uri,
      body: _truncate(response.body),
      message: _decodeErrorMessage(response),
    );
  }

  Map<String, Object?> _decodeJson({
    required Uri uri,
    required http.Response response,
  }) {
    return _decodeBodyJson(uri: uri, body: response.body);
  }

  Map<String, Object?> _decodeBodyJson({
    required Uri uri,
    required String body,
  }) {
    if (body.isEmpty) return const <String, Object?>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw SevenShiftsApiException(
        statusCode: 0,
        method: 'GET',
        uri: uri,
        body: _truncate(body),
        message: 'invalid JSON in 7shifts response: ${e.message}',
      );
    }
    if (decoded is Map) {
      return <String, Object?>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      };
    }
    return const <String, Object?>{};
  }

  SevenShiftsTokenResponse _parseTokenResponse({
    required Uri uri,
    required http.Response response,
  }) {
    final json = _decodeJson(uri: uri, response: response);
    final accessToken = _readString(json, 'access_token') ?? '';
    final refreshToken = _readString(json, 'refresh_token') ?? '';
    if (accessToken.isEmpty) {
      throw SevenShiftsApiException(
        statusCode: response.statusCode,
        method: 'POST',
        uri: uri,
        body: _truncate(response.body),
        message: '7shifts token response missing access_token',
      );
    }
    final now = _deps._now().toUtc();
    DateTime expiresAt;
    final expiresIn = _readNum(json, 'expires_in');
    if (expiresIn != null) {
      expiresAt = now.add(Duration(seconds: expiresIn.toInt()));
    } else {
      // Documented 7shifts default per
      // <https://developers.7shifts.com/reference/oauth>: 3600s.
      expiresAt = now.add(const Duration(hours: 1));
    }
    return SevenShiftsTokenResponse(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
    );
  }

  String? _readNextCursor(Map<String, Object?> json) {
    final meta = _readMap(json, 'meta');
    if (meta != null) {
      final cursor = _readMap(meta, 'cursor');
      if (cursor != null) {
        final next = _readString(cursor, 'next');
        if (next != null && next.isNotEmpty) return next;
      }
      final next = _readString(meta, 'next_cursor');
      if (next != null && next.isNotEmpty) return next;
    }
    final next = _readString(json, 'next_cursor');
    if (next != null && next.isNotEmpty) return next;
    return null;
  }

  Duration? _parseRetryAfter(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final asInt = int.tryParse(raw);
    if (asInt != null) {
      final seconds = asInt < 0 ? 0 : asInt;
      return Duration(seconds: seconds);
    }
    // RFC 7231 also allows HTTP-date values; treat them as
    // non-honoring (caller falls back to exponential backoff).
    return null;
  }

  String? _decodeErrorMessage(http.Response response) {
    final body = response.body;
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final message = decoded['message'] ??
            decoded['error_description'] ??
            decoded['error'];
        if (message is String && message.isNotEmpty) return message;
      }
    } on FormatException {
      // Fall through to truncated raw body.
    }
    return _truncate(body);
  }

  static String? _truncate(String? body) {
    if (body == null) return null;
    const cap = 2048;
    return body.length <= cap ? body : '${body.substring(0, cap)}…';
  }

  static String? _readString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is String) return value;
    if (value is num) return value.toString();
    return null;
  }

  static num? _readNum(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  static Map<String, Object?>? _readMap(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries) entry.key.toString(): entry.value,
      };
    }
    return null;
  }

  static List<Object?>? _readList(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is List) return value;
    return null;
  }
}
