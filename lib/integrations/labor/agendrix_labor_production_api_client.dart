// Phase 8 / `8.transport.agendrix-labor` — production HTTP transport
// for [AgendrixApiClient].
//
// Authority (read in this order):
//
//   1. The active prompt (slice `8.transport.agendrix-labor`).
//   2. `lib/integrations/labor/agendrix_labor_adapter.dart` — the
//      abstract API client interface this file implements; the adapter
//      depends on the interface only.
//   3. `docs/integrations/agendrix/api_consumed.md` — documented
//      endpoint shape, base URL, pagination cursor, rate-limit policy.
//
// Scope: this file is a pure transport. It does NOT touch
// canonical fact tables, watermarks, or `connector_sync_log` — those
// live behind the framework's [AgendrixCanonicalSink] and the
// `AgendrixPostgresSink` writer. The production API client only:
//
//   1. Resolves an API key + Agendrix `company_id` for
//      `(operatorId, locationId)` via the injected
//      [AgendrixCredentialStore].
//   2. Issues the documented `GET /v2/companies/{company_id}/time_entries`
//      requests against [defaultAgendrixBaseUri] (overridable via env
//      / constructor for sandbox + tests).
//   3. Pages with the documented opaque cursor token; empty cursor
//      means "no more pages".
//   4. Honors HTTP 429 with bounded exponential backoff + `Retry-After`
//      respect, and throws typed [AgendrixApiException] on non-retryable
//      failures.
//   5. Stamps `Idempotency-Key` on POSTs (defense-in-depth — the V1
//      consumed surface is GET-only, so today this only kicks in if
//      future surfaces add POSTs through this same client).
//   6. Preserves vendor TIMESTAMPTZ shape: ISO-8601 strings with
//      explicit `Z` are parsed to UTC `DateTime` and round-tripped
//      back into [AgendrixTimeEntryPage.records] / `lastModifiedSeen`
//      without silent fallback. Ambiguous timestamps without `Z` are
//      a Scenario E boundary captured by `agendrix.asUtc` policy and
//      surface here as a `FormatException` rather than silent UTC.
//
// No new pub deps: only `package:http` (already direct) +
// `dart:convert` + `dart:async` + `dart:math` for jitter.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'agendrix_labor_adapter.dart';

/// Default production base URI for the Agendrix Public REST API.
/// Overridable via constructor for sandbox / testing. Trailing `/v2/`
/// matches the path prefix in `api_consumed.md`.
final Uri defaultAgendrixBaseUri = Uri.parse('https://api.agendrix.com/v2/');

/// Header name carrying the Agendrix API key. Per the slice prompt
/// (`8.transport.agendrix-labor`) the production transport authenticates
/// every request with a partner-issued static API key delivered through
/// an `X-Api-Key` header. The plaintext key never crosses the Flutter
/// boundary — [AgendrixCredentialStore] is wired server-side and the
/// adapter only carries a `(operatorId, locationId)` pair.
const String agendrixApiKeyHeader = 'X-Api-Key';

/// Optional header carrying the operator-bound Agendrix `company_id`.
/// Documented endpoints take it as a path parameter; the header is a
/// belt-and-braces correlation aid for vendor-side logs.
const String agendrixCompanyHeader = 'X-Agendrix-Company-Id';

/// Header used to stamp client-issued idempotency keys onto POST
/// requests. Agendrix does not currently document required POST
/// surfaces, but the framework contract requires every proxy write to
/// be idempotent (CLAUDE.md: "every proxy write is idempotent"). A
/// future POST surface (e.g. webhook subscription, partner export)
/// inherits this header automatically.
const String agendrixIdempotencyHeader = 'Idempotency-Key';

/// Default per-request timeout. Bounded above by Cloud Run task budget
/// and well below the 60-day backfill window requirement — single
/// requests should complete in seconds.
const Duration defaultAgendrixRequestTimeout = Duration(seconds: 30);

/// Maximum 429 retry attempts before surfacing the failure to the
/// adapter. The adapter surfaces this through `connector_sync_log`
/// `event_kind = 'rate_limited'` (framework call #4).
const int defaultAgendrix429MaxRetries = 5;

/// Bounded exponential backoff base. Attempt N waits
/// `base * 2^(N-1)` plus jitter, clamped at [defaultAgendrix429MaxBackoff].
const Duration defaultAgendrix429BackoffBase = Duration(milliseconds: 500);

/// Hard ceiling on a single 429 backoff sleep. Prevents a misbehaving
/// `Retry-After` ("delay this 30 minutes") from stalling the worker.
const Duration defaultAgendrix429MaxBackoff = Duration(seconds: 30);

/// Documented page size cap on Agendrix list endpoints. The transport
/// requests this cap on every call; the adapter loops on the returned
/// cursor until empty.
const int defaultAgendrixPageSize = 100;

/// Field name for the Agendrix `time_entries[]` array in a list
/// response. Pinned per `documented_per_agendrix_v2`.
const String agendrixTimeEntriesField = 'time_entries';

/// Field name carrying the next-page cursor. Empty / missing means
/// "no more pages" per the documented pagination shape.
const String agendrixNextCursorField = 'next_cursor';

// ─── Credential store dep ───────────────────────────────────────────

/// Resolves the API key + Agendrix `company_id` for the active
/// `(operatorId, locationId)` pair. Production wires this to the
/// server-side `vendor_credentials_repository` so plaintext keys never
/// cross the Flutter boundary; tests pass an in-memory stub.
abstract class AgendrixCredentialStore {
  /// Returns the resolved credential bundle, or throws
  /// [AgendrixApiException] with `kind = unauthorized` when no active
  /// credential row exists for the tenant.
  Future<AgendrixCredential> readCredential({
    required String operatorId,
    required String locationId,
  });
}

/// Resolved credential bundle. The plaintext API key only exists on
/// the server-side path between [AgendrixCredentialStore.readCredential]
/// and the outbound HTTP request — never persisted on the adapter.
class AgendrixCredential {
  const AgendrixCredential({
    required this.apiKey,
    required this.companyId,
  });

  /// Partner-issued static API key.
  final String apiKey;

  /// Agendrix organization (`company`) id this credential is bound to.
  /// Used as the path parameter on every list / lookup endpoint.
  final String companyId;
}

// ─── Typed errors ───────────────────────────────────────────────────

/// Categorisation of HTTP failures the transport surfaces. Adapter /
/// framework caller decides how to map each kind to
/// `connector_sync_log.event_kind`.
enum AgendrixApiErrorKind {
  /// HTTP 401 / 403 — credential is invalid / revoked. Adapter must
  /// flip the connection to `disconnected` + surface a reconnect
  /// prompt.
  unauthorized,

  /// HTTP 404 — the company id or time entry id is unknown. Adapter
  /// treats this as a hard config error.
  notFound,

  /// HTTP 429 retries exhausted. Adapter logs and waits for the next
  /// poll tick; framework call #4.
  rateLimitExhausted,

  /// HTTP 5xx — vendor-side outage. Adapter logs and continues.
  vendorOutage,

  /// Body shape did not match documented assumptions
  /// (`time_entries[]` missing, cursor wrong type, etc.). Surfaces as
  /// a `parse_failure` event.
  malformedResponse,

  /// Network / timeout error. Adapter logs and continues.
  network,
}

/// Exception type raised by [AgendrixProductionApiClient] for any
/// non-success HTTP outcome or malformed body. Carries the categorised
/// [kind] plus enough context for the adapter to log a useful
/// `connector_sync_log` row without re-issuing the request.
class AgendrixApiException implements Exception {
  AgendrixApiException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.responseBodyPreview,
  });

  final AgendrixApiErrorKind kind;
  final String message;

  /// HTTP status code when the failure was an HTTP response.
  /// `null` for transport / parse failures.
  final int? statusCode;

  /// First N chars of the response body, for log context. `null`
  /// when no body was received (network failure / timeout).
  final String? responseBodyPreview;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' status=$statusCode';
    return 'AgendrixApiException(${kind.name}$status): $message';
  }
}

// ─── Production HTTP client ─────────────────────────────────────────

/// Concrete [AgendrixApiClient] backed by `package:http`. Lives in
/// `lib/integrations/labor/` alongside the abstract adapter so the
/// framework wire-up is one import away. The class does NOT capture
/// any operator-scoped state — every public method takes
/// `(operatorId, locationId)` and resolves the credential through
/// the injected [AgendrixCredentialStore].
class AgendrixProductionApiClient implements AgendrixApiClient {
  AgendrixProductionApiClient({
    required AgendrixCredentialStore credentialStore,
    http.Client? httpClient,
    Uri? baseUri,
    Duration requestTimeout = defaultAgendrixRequestTimeout,
    int maxRetriesOn429 = defaultAgendrix429MaxRetries,
    Duration backoffBase = defaultAgendrix429BackoffBase,
    Duration maxBackoff = defaultAgendrix429MaxBackoff,
    int pageSize = defaultAgendrixPageSize,
    Future<void> Function(Duration delay)? sleep,
    String Function()? idempotencyKeyGenerator,
    Random? random,
  })  : _credentialStore = credentialStore,
        _httpClient = httpClient ?? http.Client(),
        _baseUri = baseUri ?? defaultAgendrixBaseUri,
        _requestTimeout = requestTimeout,
        _maxRetriesOn429 = maxRetriesOn429,
        _backoffBase = backoffBase,
        _maxBackoff = maxBackoff,
        _pageSize = pageSize,
        _sleep = sleep ?? _defaultSleep,
        _idempotencyKeyGenerator =
            idempotencyKeyGenerator ?? _defaultIdempotencyKeyGenerator,
        _random = random ?? Random();

  final AgendrixCredentialStore _credentialStore;
  final http.Client _httpClient;
  final Uri _baseUri;
  final Duration _requestTimeout;
  final int _maxRetriesOn429;
  final Duration _backoffBase;
  final Duration _maxBackoff;
  final int _pageSize;
  final Future<void> Function(Duration) _sleep;
  final String Function() _idempotencyKeyGenerator;
  final Random _random;

  @override
  Future<AgendrixTimeEntryPage> fetchSampleTimeEntry({
    required String operatorId,
    required String locationId,
  }) async {
    final credential = await _credentialStore.readCredential(
      operatorId: operatorId,
      locationId: locationId,
    );
    // `testConnection` only needs one representative row; ask for the
    // smallest possible page from the most recent window.
    final uri = _buildListUri(
      credential.companyId,
      sinceModified: null,
      cursor: null,
      pageSize: 1,
    );
    final body = await _getJson(uri, credential: credential);
    return _parsePage(body);
  }

  @override
  Future<AgendrixTimeEntryPage> fetchTimeEntries({
    required String operatorId,
    required String locationId,
    required DateTime sinceModified,
    required String? cursor,
    required bool isDeliberateBackfill,
  }) async {
    final credential = await _credentialStore.readCredential(
      operatorId: operatorId,
      locationId: locationId,
    );
    final uri = _buildListUri(
      credential.companyId,
      sinceModified: sinceModified,
      cursor: cursor,
      pageSize: _pageSize,
    );
    final body = await _getJson(uri, credential: credential);
    return _parsePage(body);
  }

  /// Close the underlying HTTP client. Cloud Run Job lifetime is
  /// per-tick — the dispatcher constructs the client at task start and
  /// closes it on completion / shutdown.
  void close() {
    _httpClient.close();
  }

  /// Defense-in-depth POST helper. The V1 consumed surface
  /// (`api_consumed.md` 2026-05-04) is GET-only, so this method is
  /// not yet wired into `fetchTimeEntries` / `fetchSampleTimeEntry`.
  /// A future POST surface (webhook subscription, partner export, etc.)
  /// inherits the framework's idempotency contract automatically by
  /// going through this helper instead of issuing `_httpClient.post`
  /// directly.
  ///
  /// `idempotencyKey` may be supplied by the caller (when the framework
  /// is replaying a prior request and needs the same key) or left
  /// `null` to let the transport mint a fresh key per call.
  Future<Map<String, Object?>> postJson({
    required String operatorId,
    required String locationId,
    required String relativePath,
    required Map<String, Object?> body,
    String? idempotencyKey,
  }) async {
    final credential = await _credentialStore.readCredential(
      operatorId: operatorId,
      locationId: locationId,
    );
    final base = _baseUri.toString().endsWith('/')
        ? _baseUri.toString()
        : '${_baseUri.toString()}/';
    final trimmed = relativePath.startsWith('/')
        ? relativePath.substring(1)
        : relativePath;
    final uri = Uri.parse('$base$trimmed');
    final headers = <String, String>{
      agendrixApiKeyHeader: credential.apiKey,
      agendrixCompanyHeader: credential.companyId,
      agendrixIdempotencyHeader: idempotencyKey ?? _idempotencyKeyGenerator(),
      HttpHeaders.acceptHeader: 'application/json',
      HttpHeaders.contentTypeHeader: 'application/json',
      HttpHeaders.userAgentHeader: 'forge-and-flow-agendrix/1.0',
    };
    final encoded = jsonEncode(body);
    return _executeWithRetry(() async {
      try {
        final response = await _httpClient
            .post(uri, headers: headers, body: encoded)
            .timeout(_requestTimeout);
        return _decodeResponse(response);
      } on TimeoutException catch (e) {
        throw AgendrixApiException(
          kind: AgendrixApiErrorKind.network,
          message: 'POST $uri timed out: $e',
        );
      } on SocketException catch (e) {
        throw AgendrixApiException(
          kind: AgendrixApiErrorKind.network,
          message: 'POST $uri socket error: ${e.message}',
        );
      } on http.ClientException catch (e) {
        throw AgendrixApiException(
          kind: AgendrixApiErrorKind.network,
          message: 'POST $uri client error: ${e.message}',
        );
      }
    });
  }

  // ─── HTTP plumbing ──────────────────────────────────────────────

  Uri _buildListUri(
    String companyId, {
    required DateTime? sinceModified,
    required String? cursor,
    required int pageSize,
  }) {
    // Path: `/v2/companies/{company_id}/time_entries` per
    // `api_consumed.md`. The base URI already carries the `/v2/`
    // prefix; resolve a relative path that joins safely whether the
    // base ends in `/` or not.
    final base = _baseUri.toString().endsWith('/')
        ? _baseUri.toString()
        : '${_baseUri.toString()}/';
    final endpoint =
        Uri.parse('${base}companies/${Uri.encodeComponent(companyId)}/time_entries');
    final queryParameters = <String, String>{
      'limit': pageSize.toString(),
    };
    if (sinceModified != null) {
      queryParameters['updated_after'] = _formatInstant(sinceModified);
    }
    if (cursor != null && cursor.isNotEmpty) {
      queryParameters['cursor'] = cursor;
    }
    return endpoint.replace(queryParameters: queryParameters);
  }

  Future<Map<String, Object?>> _getJson(
    Uri uri, {
    required AgendrixCredential credential,
  }) async {
    final headers = <String, String>{
      agendrixApiKeyHeader: credential.apiKey,
      agendrixCompanyHeader: credential.companyId,
      HttpHeaders.acceptHeader: 'application/json',
      HttpHeaders.userAgentHeader: 'forge-and-flow-agendrix/1.0',
    };
    return _executeWithRetry(() async {
      try {
        final response = await _httpClient
            .get(uri, headers: headers)
            .timeout(_requestTimeout);
        return _decodeResponse(response);
      } on TimeoutException catch (e) {
        throw AgendrixApiException(
          kind: AgendrixApiErrorKind.network,
          message: 'GET $uri timed out: $e',
        );
      } on SocketException catch (e) {
        throw AgendrixApiException(
          kind: AgendrixApiErrorKind.network,
          message: 'GET $uri socket error: ${e.message}',
        );
      } on http.ClientException catch (e) {
        throw AgendrixApiException(
          kind: AgendrixApiErrorKind.network,
          message: 'GET $uri client error: ${e.message}',
        );
      }
    });
  }

  /// Wraps a single-attempt operation with bounded 429 retry. Returns
  /// the operation's value on the first non-429 outcome (success or
  /// any other failure type, which propagates immediately).
  Future<Map<String, Object?>> _executeWithRetry(
    Future<Map<String, Object?>> Function() attempt,
  ) async {
    int retries = 0;
    while (true) {
      try {
        return await attempt();
      } on AgendrixApiException catch (e) {
        if (e.kind != AgendrixApiErrorKind.rateLimitExhausted) {
          rethrow;
        }
        if (retries >= _maxRetriesOn429) {
          rethrow;
        }
        // Backoff sleep — `Retry-After` from the server (when present)
        // wins over the computed exponential backoff, but is clamped
        // at `_maxBackoff` so a vendor-bug 30-minute hint cannot stall
        // the worker.
        final hint = _retryAfterFromMessage(e.message);
        final computed = _computeBackoff(retries);
        final chosen =
            hint != null && hint <= _maxBackoff ? hint : computed;
        await _sleep(chosen);
        retries += 1;
      }
    }
  }

  Duration _computeBackoff(int retryIndex) {
    // base * 2^retryIndex + jitter (0..base/2). Clamp at maxBackoff.
    final millis = _backoffBase.inMilliseconds * pow(2, retryIndex).toInt();
    final jitter = _random.nextInt(_backoffBase.inMilliseconds ~/ 2 + 1);
    final total = Duration(milliseconds: millis + jitter);
    return total > _maxBackoff ? _maxBackoff : total;
  }

  /// `Retry-After` is delivered by the server through the response
  /// header; the wrapper threads it into the exception message so the
  /// retry loop can read it back without exposing the response. Format
  /// is either a delta-seconds integer or an HTTP-date.
  Duration? _retryAfterFromMessage(String message) {
    final match = RegExp(r'retry_after=(\d+)').firstMatch(message);
    if (match == null) return null;
    final seconds = int.tryParse(match.group(1)!);
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }

  Map<String, Object?> _decodeResponse(http.Response response) {
    final code = response.statusCode;
    if (code == 401 || code == 403) {
      throw AgendrixApiException(
        kind: AgendrixApiErrorKind.unauthorized,
        message: 'Agendrix rejected the API key (HTTP $code). '
            'Operator must reconnect.',
        statusCode: code,
        responseBodyPreview: _previewBody(response.body),
      );
    }
    if (code == 404) {
      throw AgendrixApiException(
        kind: AgendrixApiErrorKind.notFound,
        message: 'Agendrix returned 404 — company or resource unknown.',
        statusCode: code,
        responseBodyPreview: _previewBody(response.body),
      );
    }
    if (code == 429) {
      // Encode the server's Retry-After hint into the message so the
      // retry loop can extract it without reading the response.
      final hint = response.headers['retry-after'];
      final parsedHint = hint == null ? null : int.tryParse(hint);
      final hintTag = parsedHint == null ? '' : ' retry_after=$parsedHint';
      throw AgendrixApiException(
        kind: AgendrixApiErrorKind.rateLimitExhausted,
        message: 'Agendrix returned 429 rate-limited.$hintTag',
        statusCode: code,
        responseBodyPreview: _previewBody(response.body),
      );
    }
    if (code >= 500 && code < 600) {
      throw AgendrixApiException(
        kind: AgendrixApiErrorKind.vendorOutage,
        message: 'Agendrix returned $code (vendor-side outage).',
        statusCode: code,
        responseBodyPreview: _previewBody(response.body),
      );
    }
    if (code != 200) {
      throw AgendrixApiException(
        kind: AgendrixApiErrorKind.malformedResponse,
        message: 'Agendrix returned unexpected HTTP $code.',
        statusCode: code,
        responseBodyPreview: _previewBody(response.body),
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw AgendrixApiException(
        kind: AgendrixApiErrorKind.malformedResponse,
        message: 'Agendrix returned non-JSON body: ${e.message}',
        statusCode: code,
        responseBodyPreview: _previewBody(response.body),
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw AgendrixApiException(
        kind: AgendrixApiErrorKind.malformedResponse,
        message: 'Agendrix response body is not a JSON object.',
        statusCode: code,
        responseBodyPreview: _previewBody(response.body),
      );
    }
    return decoded;
  }

  AgendrixTimeEntryPage _parsePage(Map<String, Object?> body) {
    final raw = body[agendrixTimeEntriesField];
    if (raw is! List) {
      throw AgendrixApiException(
        kind: AgendrixApiErrorKind.malformedResponse,
        message: 'Agendrix response missing `$agendrixTimeEntriesField` array.',
      );
    }
    final records = <Map<String, Object?>>[];
    DateTime lastModifiedSeen = DateTime.utc(1970, 1, 1);
    for (final entry in raw) {
      if (entry is! Map) {
        throw AgendrixApiException(
          kind: AgendrixApiErrorKind.malformedResponse,
          message: 'Agendrix response: `time_entries[]` element is not an object.',
        );
      }
      final asMap = <String, Object?>{
        for (final e in entry.entries) e.key.toString(): e.value,
      };
      records.add(asMap);
      final updatedAt = asMap['updated_at'];
      if (updatedAt is String && updatedAt.isNotEmpty) {
        // Per `agendrix.asUtc`: explicit-Z ISO-8601 only. A non-Z
        // shape surfaces as a `FormatException`; the transport rethrows
        // as a `malformedResponse` so the live verification slice
        // catches the boundary instead of silently coercing.
        final DateTime parsed;
        try {
          parsed = DateTime.parse(updatedAt).toUtc();
        } on FormatException catch (e) {
          throw AgendrixApiException(
            kind: AgendrixApiErrorKind.malformedResponse,
            message: 'Agendrix `updated_at` failed ISO-8601 parse: ${e.message}',
          );
        }
        if (parsed.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = parsed;
        }
      }
    }
    final cursorRaw = body[agendrixNextCursorField];
    final cursor = cursorRaw is String ? cursorRaw : '';
    return AgendrixTimeEntryPage(
      records: records,
      nextCursor: cursor,
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  static String _previewBody(String body) {
    const maxLen = 512;
    if (body.length <= maxLen) return body;
    return '${body.substring(0, maxLen)}...[truncated]';
  }

  /// Format a UTC `DateTime` as ISO-8601 with explicit `Z`. The
  /// `agendrix.asUtc` policy mandates explicit-Z on outbound `updated_after`
  /// queries; Dart's `toIso8601String` already adds the `Z` suffix when
  /// the value `isUtc`.
  static String _formatInstant(DateTime instant) {
    final utc = instant.isUtc ? instant : instant.toUtc();
    return utc.toIso8601String();
  }

  static Future<void> _defaultSleep(Duration delay) {
    return Future<void>.delayed(delay);
  }

  static String _defaultIdempotencyKeyGenerator() {
    // Time-based UUIDv4-ish key. Crypto-quality randomness is not
    // required: server-side dedup uses the
    // `(operator_id, idempotency_key)` UNIQUE in `proxy_requests`,
    // which only needs collision avoidance within a 24-hour window.
    final rand = Random();
    final part1 = rand.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final part2 = rand.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '$part1-$part2-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  }
}
