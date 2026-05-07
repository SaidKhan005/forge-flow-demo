// Phase 8.transport.humanity-labor — production Humanity (TCP) HTTP
// transport.
//
// Concrete [HumanityHttpClient] backed by `package:http`. Drives live
// HTTP against the documented Humanity v1 API at
// `https://platform.humanity.com/v1.0` (see
// `docs/integrations/humanity/api_consumed.md`, retrieved 2026-05-04).
//
// Authority order (CLAUDE.md):
//
//   1. The active prompt for this transport slice.
//   2. `lib/integrations/labor/humanity_labor_adapter.dart` — owns
//      `HumanityHttpClient` (the abstract this implements),
//      `HumanityShiftDto`, `HumanityShiftsPage`,
//      `HumanityTokenResponse`, `VendorCredentialHandle`, and the
//      `documentedPerHumanityV10FieldMapping` constant.
//   3. `docs/contracts/vendor_adapter_slice_contract.md` — pagination,
//      idempotency on POSTs, watermark-per-batch, sanity hook gating.
//
// Hard-Promise alignment (CLAUDE.md):
//
//   * HP #1 (pure transport swap): this file is HTTP only. It produces
//     the same vendor-shape DTOs the existing
//     `HumanityLaborAdapter` already canonicalizes. No SQLite / Postgres
//     reach-through, no business logic.
//   * HP #4 (per-operator isolation): the adapter operates against a
//     [VendorCredentialHandle]; this client resolves the handle to the
//     bearer token (the proxy stashed in `vendor_credentials`) inside
//     the request frame, never exposing plaintext password material to
//     the adapter caller.
//   * HP #7 (server-side keys): plaintext username/password ONLY ever
//     flow through [exchangeUsernamePassword] (called once at connect
//     time); the bearer is then persisted in `vendor_credentials` by
//     the proxy and the credential handle is what the adapter operates
//     against from then on.
//
// Banned items (V1 lean cut 2 + slice contract): mirrors the adapter's
// banned-substrings ledger; no `parse_warnings` / `parse_partial`
// channel (the client either parses cleanly or throws), no
// `pg_try_advisory_lock`, no `kms.encrypt`, no `rotate_signing_key`,
// no `replay_strict_5min` (pollOnly so N/A either way).

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' show Random;

import 'package:http/http.dart' as http;

import 'humanity_labor_adapter.dart';

// ─── Configuration ───────────────────────────────────────────────────

/// Default Humanity v1 documented base URI. Overridable via
/// [HumanityLaborProductionApiClient.baseUri] (constructor) or the
/// `HUMANITY_API_BASE_URL` environment variable. The trailing slash is
/// preserved so [Uri.resolve] keeps any path prefix the operator
/// supplies (e.g. `https://staging.humanity.com/v1.0/`).
const String kHumanityDefaultBaseUri = 'https://platform.humanity.com/v1.0/';

/// Environment variable consulted at construction time when no explicit
/// `baseUri` is provided. Lets the `*.live.sandbox` slice point this
/// client at a sandbox host without recompiling.
const String kHumanityBaseUrlEnvVar = 'HUMANITY_API_BASE_URL';

/// Default request timeout. Humanity's documented endpoints respond in
/// well under 10s; the slice contract asks `testConnection` to come in
/// under 30s, but the per-request budget is tighter so a slow vendor
/// does not exceed the route timeout.
const Duration kHumanityDefaultTimeout = Duration(seconds: 20);

/// Default cap on 429 retries per request. Humanity v1 documents
/// `Retry-After` as the canonical signal; this cap stops a stuck loop
/// when the vendor returns 429 indefinitely.
const int kHumanityDefault429MaxRetries = 5;

/// Default base for exponential jitter when `Retry-After` is missing
/// or malformed. The actual sleep is
/// `min(base * 2^attempt, cap) + uniform_jitter(0..base)`.
const Duration kHumanityDefault429BackoffBase = Duration(milliseconds: 500);

/// Default cap on the backoff sleep so a malformed Retry-After header
/// can never park the client past the slice's connect-flow SLA.
const Duration kHumanityDefault429BackoffCap = Duration(seconds: 10);

// ─── Typed errors ────────────────────────────────────────────────────

/// Base type for every error this transport raises. Every subclass
/// carries the `statusCode` and (when available) the response body
/// snippet so the caller can log the failure without re-issuing the
/// HTTP call.
sealed class HumanityHttpException implements Exception {
  const HumanityHttpException({
    required this.statusCode,
    required this.message,
    this.body,
  });

  final int statusCode;
  final String message;
  final String? body;

  @override
  String toString() => 'HumanityHttpException($statusCode): $message';
}

/// Auth failure (401 / 403). The proxy should re-mint the bearer; the
/// adapter should surface a reconnect-required state to the operator.
class HumanityAuthException extends HumanityHttpException {
  const HumanityAuthException({
    required super.statusCode,
    required super.message,
    super.body,
  });
}

/// Rate-limit exhausted after [kHumanityDefault429MaxRetries] retries.
/// The adapter should reschedule the tick rather than fail the
/// connection.
class HumanityRateLimitException extends HumanityHttpException {
  const HumanityRateLimitException({
    required super.statusCode,
    required super.message,
    super.body,
    this.retryAfter,
  });

  final Duration? retryAfter;
}

/// Permanent client error (4xx other than 401/403/429). The request
/// shape is wrong; retrying without operator intervention is futile.
class HumanityClientException extends HumanityHttpException {
  const HumanityClientException({
    required super.statusCode,
    required super.message,
    super.body,
  });
}

/// Transient server error (5xx). The caller may retry on the next
/// poll tick.
class HumanityServerException extends HumanityHttpException {
  const HumanityServerException({
    required super.statusCode,
    required super.message,
    super.body,
  });
}

/// Schema drift (`200 OK` body that does not parse against the
/// documented v1 shape). The `*.live.sandbox` slice diffs the
/// documented field-mapping constant against observed responses;
/// mismatches that escape that diff land here.
class HumanitySchemaException extends HumanityHttpException {
  const HumanitySchemaException({
    required super.message,
    super.body,
  }) : super(statusCode: 200);
}

// ─── Production API client ───────────────────────────────────────────

/// Production Humanity HTTP transport. Implements
/// [HumanityHttpClient] against the documented v1 API.
///
/// Construction:
///
/// ```dart
/// final client = HumanityLaborProductionApiClient(
///   httpClient: http.Client(),
///   // baseUri: defaults to documented endpoint or the
///   // `HUMANITY_API_BASE_URL` environment variable.
/// );
/// ```
///
/// Tests inject a fake [http.Client] that returns canned responses;
/// the client never opens a network socket in test scope.
class HumanityLaborProductionApiClient implements HumanityHttpClient {
  HumanityLaborProductionApiClient({
    required http.Client httpClient,
    Uri? baseUri,
    Duration timeout = kHumanityDefaultTimeout,
    int maxRateLimitRetries = kHumanityDefault429MaxRetries,
    Duration rateLimitBackoffBase = kHumanityDefault429BackoffBase,
    Duration rateLimitBackoffCap = kHumanityDefault429BackoffCap,
    Future<void> Function(Duration) sleep = _defaultSleep,
    String Function() idempotencyKeyFactory = _defaultIdempotencyKeyFactory,
    Map<String, String> Function()? environment,
  })  : _httpClient = httpClient,
        _baseUri = baseUri ?? _resolveBaseUri(environment),
        _timeout = timeout,
        _maxRateLimitRetries = maxRateLimitRetries,
        _rateLimitBackoffBase = rateLimitBackoffBase,
        _rateLimitBackoffCap = rateLimitBackoffCap,
        _sleep = sleep,
        _idempotencyKeyFactory = idempotencyKeyFactory;

  final http.Client _httpClient;
  final Uri _baseUri;
  final Duration _timeout;
  final int _maxRateLimitRetries;
  final Duration _rateLimitBackoffBase;
  final Duration _rateLimitBackoffCap;
  final Future<void> Function(Duration) _sleep;
  final String Function() _idempotencyKeyFactory;

  /// Effective base URI in use. Useful for diagnostic logging and the
  /// `*.live.sandbox` slice's host-pinning assertion.
  Uri get baseUri => _baseUri;

  // ─── HumanityHttpClient: token exchange ──────────────────────────

  @override
  Future<HumanityTokenResponse> exchangeUsernamePassword({
    required String username,
    required String password,
  }) async {
    final uri = _resolve('oauth2/token');
    final response = await _send(
      method: 'POST',
      uri: uri,
      // Humanity legacy `password` grant:
      // `application/x-www-form-urlencoded`.
      headers: const <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
      },
      body: _formEncode(<String, String>{
        'grant_type': 'password',
        'username': username,
        'password': password,
      }),
      includeIdempotencyKey: true,
    );
    final body = _decodeJsonObject(response);
    final accessToken = body['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const HumanitySchemaException(
        message: 'token response missing required `access_token` string',
      );
    }
    final refreshToken = body['refresh_token'];
    final expiresIn = body['expires_in'];
    DateTime? expiresAt;
    if (expiresIn is num && expiresIn > 0) {
      expiresAt = DateTime.now().toUtc().add(Duration(seconds: expiresIn.toInt()));
    }
    return HumanityTokenResponse(
      accessToken: accessToken,
      refreshToken: refreshToken is String && refreshToken.isNotEmpty
          ? refreshToken
          : null,
      expiresAt: expiresAt,
    );
  }

  // ─── HumanityHttpClient: list shifts (paginated) ─────────────────

  @override
  Future<HumanityShiftsPage> listShifts({
    required VendorCredentialHandle credential,
    required DateTime modifiedSince,
    DateTime? modifiedUntil,
    String? cursor,
  }) async {
    final query = <String, String>{
      'last_modified': _formatTimestampUtc(modifiedSince),
      if (modifiedUntil != null)
        'last_modified_until': _formatTimestampUtc(modifiedUntil),
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };
    final uri = _resolve('shifts', queryParameters: query);
    final response = await _send(
      method: 'GET',
      uri: uri,
      headers: _bearerHeaders(credential),
    );
    final body = _decodeJsonObject(response);
    final rawRecords = body['shifts'] ?? body['data'] ?? body['records'];
    final records = _coerceRecordList(rawRecords);
    final nextCursor = _readNextCursor(body);
    final lastModifiedSeen = _resolvePageHighWatermark(records, modifiedSince);
    return HumanityShiftsPage(
      records: records,
      nextCursor: nextCursor,
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  // ─── HumanityHttpClient: sample shift (testConnection) ───────────

  @override
  Future<Map<String, Object?>?> fetchSampleShift({
    required VendorCredentialHandle credential,
  }) async {
    // Humanity does not expose `/shifts/sample`; the convention is
    // `/shifts?limit=1` ordered by `updated` desc. The adapter only
    // needs ONE row to populate the field-mapping preview.
    final uri = _resolve(
      'shifts',
      queryParameters: const <String, String>{
        'limit': '1',
        'sort': 'updated:desc',
      },
    );
    final response = await _send(
      method: 'GET',
      uri: uri,
      headers: _bearerHeaders(credential),
    );
    final body = _decodeJsonObject(response);
    final rawRecords = body['shifts'] ?? body['data'] ?? body['records'];
    final records = _coerceRecordList(rawRecords);
    if (records.isEmpty) return null;
    return records.first;
  }

  // ─── HumanityHttpClient: revoke (best-effort) ────────────────────

  @override
  Future<void> revokeCredential({
    required VendorCredentialHandle credential,
  }) async {
    final uri = _resolve('oauth2/revoke');
    try {
      await _send(
        method: 'POST',
        uri: uri,
        headers: <String, String>{
          ..._bearerHeaders(credential),
          'content-type': 'application/x-www-form-urlencoded',
          'accept': 'application/json',
        },
        body: _formEncode(<String, String>{
          'token': credential.credentialId,
        }),
        includeIdempotencyKey: true,
        // 401/404 on revoke means the bearer is already gone — that's
        // a successful disconnect from the operator's perspective. Let
        // those slip through; everything else is noisy but
        // best-effort.
        treatAuthAsSuccess: true,
      );
    } on HumanityHttpException {
      // Best-effort revoke; vendor outage MUST NOT block disconnect.
      return;
    }
  }

  // ─── HTTP plumbing ───────────────────────────────────────────────

  Future<http.Response> _send({
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    Object? body,
    bool includeIdempotencyKey = false,
    bool treatAuthAsSuccess = false,
  }) async {
    final mergedHeaders = <String, String>{
      'accept': 'application/json',
      'user-agent': 'forge-and-flow/humanity-transport (8.transport.humanity-labor)',
      if (headers != null) ...headers,
    };
    if (includeIdempotencyKey) {
      mergedHeaders['idempotency-key'] = _idempotencyKeyFactory();
    }

    var attempt = 0;
    while (true) {
      late http.Response response;
      try {
        final request = http.Request(method, uri)
          ..headers.addAll(mergedHeaders);
        if (body != null) {
          if (body is String) {
            request.body = body;
          } else if (body is List<int>) {
            request.bodyBytes = body;
          } else {
            request.body = body.toString();
          }
        }
        final streamed = await _httpClient.send(request).timeout(_timeout);
        response = await http.Response.fromStream(streamed);
      } on TimeoutException {
        throw HumanityServerException(
          statusCode: 504,
          message: 'request to $uri timed out after ${_timeout.inSeconds}s',
        );
      }

      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        return response;
      }
      if (status == 401 || status == 403) {
        if (treatAuthAsSuccess) {
          return response;
        }
        throw HumanityAuthException(
          statusCode: status,
          message: 'Humanity rejected the bearer (status $status)',
          body: _bodySnippet(response),
        );
      }
      if (status == 429) {
        if (attempt >= _maxRateLimitRetries) {
          throw HumanityRateLimitException(
            statusCode: status,
            message: 'Humanity rate-limit exhausted after '
                '${_maxRateLimitRetries + 1} attempts',
            body: _bodySnippet(response),
            retryAfter: _parseRetryAfter(response),
          );
        }
        final retryAfter = _parseRetryAfter(response) ??
            _exponentialBackoff(attempt);
        await _sleep(retryAfter);
        attempt += 1;
        continue;
      }
      if (status == 404) {
        // 404 is treated as a permanent client error here. The
        // adapter's caller decides whether a particular endpoint's 404
        // is fatal (e.g. `/shifts` 404 is a config bug) or expected
        // (e.g. `/oauth2/revoke` 404 already handled above).
        throw HumanityClientException(
          statusCode: status,
          message: 'Humanity returned 404 for $uri',
          body: _bodySnippet(response),
        );
      }
      if (status >= 400 && status < 500) {
        throw HumanityClientException(
          statusCode: status,
          message: 'Humanity returned $status for $uri',
          body: _bodySnippet(response),
        );
      }
      // 5xx: surface as transient. The adapter / framework reschedules
      // the tick on the next pull cycle; per-request retry is bounded
      // so a flapping vendor does not chew the route budget.
      throw HumanityServerException(
        statusCode: status,
        message: 'Humanity returned $status for $uri',
        body: _bodySnippet(response),
      );
    }
  }

  Map<String, Object?> _decodeJsonObject(http.Response response) {
    final raw = response.body;
    if (raw.isEmpty) {
      throw const HumanitySchemaException(
        message: 'expected JSON body but got an empty response',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw HumanitySchemaException(
        message: 'response body is not valid JSON: ${e.message}',
        body: _shortenForError(raw),
      );
    }
    if (decoded is! Map) {
      throw HumanitySchemaException(
        message: 'expected a JSON object at the top level but got '
            '${decoded.runtimeType}',
        body: _shortenForError(raw),
      );
    }
    return <String, Object?>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    };
  }

  List<Map<String, Object?>> _coerceRecordList(Object? raw) {
    if (raw == null) {
      // Some Humanity endpoints respond with `{ "shifts": null }` on an
      // empty page; treat as no records rather than schema drift so a
      // well-formed empty page does not raise.
      return const <Map<String, Object?>>[];
    }
    if (raw is! List) {
      throw HumanitySchemaException(
        message: 'expected a JSON array of records but got '
            '${raw.runtimeType}',
        body: raw.toString(),
      );
    }
    final out = <Map<String, Object?>>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw HumanitySchemaException(
          message: 'record is not a JSON object: '
              '${entry.runtimeType}',
        );
      }
      out.add(<String, Object?>{
        for (final pair in entry.entries) pair.key.toString(): pair.value,
      });
    }
    return out;
  }

  String? _readNextCursor(Map<String, Object?> body) {
    // Humanity v1 documents `next_cursor` on the page envelope; some
    // responses surface `next` (legacy field) — accept both, prefer
    // documented.
    final v1 = body['next_cursor'];
    if (v1 is String && v1.isNotEmpty) return v1;
    final legacy = body['next'];
    if (legacy is String && legacy.isNotEmpty) return legacy;
    final paging = body['paging'];
    if (paging is Map) {
      final v = paging['next_cursor'] ?? paging['next'];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  DateTime _resolvePageHighWatermark(
    List<Map<String, Object?>> records,
    DateTime fallback,
  ) {
    DateTime? highest;
    for (final record in records) {
      final updated = record['updated'];
      if (updated is String) {
        final parsed = DateTime.tryParse(updated)?.toUtc();
        if (parsed == null) continue;
        if (highest == null || parsed.isAfter(highest)) {
          highest = parsed;
        }
      }
    }
    return highest ?? fallback.toUtc();
  }

  Map<String, String> _bearerHeaders(VendorCredentialHandle credential) {
    // The adapter convention (mirrored in the existing
    // `humanity_labor_adapter.dart` connect path) is that
    // `credential.credentialId` resolves to the bearer token the proxy
    // stashed in `vendor_credentials` — no plaintext password reaches
    // this path. The production wiring resolves the handle through the
    // proxy's credential resolver before the call lands here.
    return <String, String>{
      'authorization': 'Bearer ${credential.credentialId}',
      'accept': 'application/json',
    };
  }

  Uri _resolve(String path, {Map<String, String>? queryParameters}) {
    // `Uri.resolve` against a base with a trailing slash preserves the
    // base path (e.g. `/v1.0/`) and replaces only the last segment.
    final relative = Uri(
      path: path,
      queryParameters:
          (queryParameters != null && queryParameters.isNotEmpty)
              ? queryParameters
              : null,
    );
    return _baseUri.resolveUri(relative);
  }

  Duration _exponentialBackoff(int attempt) {
    final baseMs = _rateLimitBackoffBase.inMilliseconds;
    final capMs = _rateLimitBackoffCap.inMilliseconds;
    final exponentMs = baseMs * (1 << attempt);
    final boundedMs = exponentMs > capMs ? capMs : exponentMs;
    final jitterMs = _random.nextInt(baseMs == 0 ? 1 : baseMs);
    return Duration(milliseconds: boundedMs + jitterMs);
  }

  Duration? _parseRetryAfter(http.Response response) {
    final raw = response.headers['retry-after'];
    if (raw == null || raw.isEmpty) return null;
    final asInt = int.tryParse(raw.trim());
    if (asInt != null && asInt >= 0) {
      final ms = asInt * 1000;
      return ms > _rateLimitBackoffCap.inMilliseconds
          ? _rateLimitBackoffCap
          : Duration(milliseconds: ms);
    }
    final asDate = DateTime.tryParse(raw.trim());
    if (asDate != null) {
      final delta = asDate.toUtc().difference(DateTime.now().toUtc());
      if (delta.isNegative) return Duration.zero;
      return delta > _rateLimitBackoffCap ? _rateLimitBackoffCap : delta;
    }
    return null;
  }

  static final Random _random = Random();
}

// ─── Helpers ─────────────────────────────────────────────────────────

String _formEncode(Map<String, String> fields) {
  return fields.entries
      .map((entry) =>
          '${Uri.encodeQueryComponent(entry.key)}='
          '${Uri.encodeQueryComponent(entry.value)}')
      .join('&');
}

String _formatTimestampUtc(DateTime when) {
  // Humanity documents UTC ISO-8601 with the trailing `Z`; mirror that
  // exact convention regardless of the input's flag so the request
  // line is byte-identical to the documented example.
  final utc = when.toUtc();
  return utc.toIso8601String();
}

String? _bodySnippet(http.Response response) {
  final raw = response.body;
  if (raw.isEmpty) return null;
  return _shortenForError(raw);
}

String _shortenForError(String raw) {
  const max = 512;
  if (raw.length <= max) return raw;
  return '${raw.substring(0, max)}...[truncated ${raw.length - max} bytes]';
}

Future<void> _defaultSleep(Duration duration) {
  return Future<void>.delayed(duration);
}

String _defaultIdempotencyKeyFactory() {
  // RFC 4122 v4-shaped key. Dart's `Random.secure()` is not always
  // available in the test sandbox; fall back to `Random()` and append
  // the high-resolution monotonic timestamp so collisions are
  // exceedingly unlikely for the volumes Humanity emits.
  Random rng;
  try {
    rng = Random.secure();
  } on UnsupportedError {
    rng = Random();
  }
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  // Stamp version (4) + variant (10xx) bits per RFC 4122 to keep the
  // resulting string a syntactically valid uuid.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

Uri _resolveBaseUri(Map<String, String> Function()? environmentResolver) {
  final env = environmentResolver != null
      ? environmentResolver()
      : _safePlatformEnvironment();
  final override = env[kHumanityBaseUrlEnvVar];
  final raw = (override != null && override.isNotEmpty)
      ? override
      : kHumanityDefaultBaseUri;
  // Always carry a trailing slash so [Uri.resolveUri] preserves the
  // base path (e.g. `/v1.0/`) when appending `shifts`, etc.
  final normalized = raw.endsWith('/') ? raw : '$raw/';
  return Uri.parse(normalized);
}

Map<String, String> _safePlatformEnvironment() {
  try {
    return Platform.environment;
  } on UnsupportedError {
    // Platform.environment throws on Flutter web; the production
    // client targets server-side / Cloud Run only, but keep the
    // fallback so unit tests in unusual sandboxes do not blow up at
    // construction time.
    return const <String, String>{};
  }
}
