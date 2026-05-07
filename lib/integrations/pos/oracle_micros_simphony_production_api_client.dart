// Phase 8 / Wave B — Production HTTP client for Oracle MICROS Simphony.
// Slice: `8.transport.oracle-micros-simphony`.
//
// What this file is:
//   * The concrete, HTTP-backed implementation of the abstract
//     [OracleMicrosSimphonyApiClient] declared by the engineering-slice
//     adapter at `lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart`.
//   * The transport seam the `8.OR.live.sandbox` and `8.OR.live.prod`
//     slices wire into the adapter once partner-issued credentials
//     arrive (see `docs/integrations/oracle_micros_simphony/
//     partnership_status.md` and `live_verification_checklist.md`).
//
// What this file is NOT:
//   * NOT a parallel adapter. The single `OracleMicrosSimphonyPosAdapter`
//     stays the framework's vendor surface; this file is its production
//     HTTP transport. Tests still inject a fake `*ApiClient`.
//   * NOT a credential store. Per Hard Promise #7 (CLAUDE.md) plaintext
//     bearer tokens never live in the Flutter client. The class
//     consumes an opaque [SimphonyTokenStore] dep that resolves a
//     [VendorCredentialHandle] to a bearer access token server-side.
//   * NOT an OAuth refresh cron. `pg_cron` runs that job (see
//     `oauth_shape.md` § Refresh semantics). On 401 this client signals
//     the token store to refresh once and retries; persistent failure
//     surfaces a typed error so the connector loop counts strikes.
//
// References:
//   * `docs/integrations/oracle_micros_simphony/api_consumed.md` —
//     endpoint paths, auth flow, soft rate limit (~60 req/min/org).
//   * `docs/integrations/oracle_micros_simphony/oauth_shape.md` —
//     `client_credentials` grant, ~1h access token TTL, perLocation
//     grant scope, reactive 401 refresh.
//   * `docs/integrations/oracle_micros_simphony/field_mapping.md` —
//     Gen2 envelope, every documented field path.
//   * `docs/contracts/vendor_adapter_slice_contract.md` — adapter
//     framework responsibilities.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show pow;

import 'package:meta/meta.dart';
import 'package:http/http.dart' as http;

import 'oracle_micros_simphony_pos_adapter.dart';

// ─── URI / endpoint defaults ─────────────────────────────────────────

/// Default Simphony Cloud production base URI. Overridable per
/// connection so the `8.OR.live.sandbox` slice can point this client at
/// a partner-issued sandbox host without code changes (the exact
/// sandbox hostname is not knowable until partner activation per
/// `api_consumed.md`).
///
/// The path resolves under the documented Gen2 prefix `/sim/api/v2/`.
final Uri defaultOracleMicrosSimphonyBaseUri = Uri.parse(
  'https://api.simphony.oracleindustry.com/sim/api/v2/',
);

/// Token issuance endpoint relative path. Documented at
/// <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/authenticate.html>.
const String oracleMicrosSimphonyTokenPath = 'oauth/token';

/// Paged guest checks endpoint relative path. Documented at
/// <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/getguestchecks.html>.
const String oracleMicrosSimphonyGuestChecksPath = 'posData/getGuestChecks';

/// Default per-request timeout. Bounds how long a single Simphony call
/// can hang before the adapter loop counts a connector failure. The
/// `testConnection` framework SLA is 30s; this stays well under that
/// to leave room for one 401 refresh + one retry on the same call.
const Duration defaultOracleMicrosSimphonyRequestTimeout = Duration(seconds: 12);

/// Default maximum retries for transient errors (429 / 5xx). Three
/// attempts past the initial call is the documented soft cap balance:
/// enough to ride out a brief vendor blip, low enough that a sustained
/// outage trips the connector strike counter.
const int defaultOracleMicrosSimphonyMaxRetries = 3;

/// Default initial back-off when a 429 / 5xx is received and the vendor
/// did not send `Retry-After`. Each retry doubles via
/// `initial * 2^attempt`. The cap prevents runaway delays on a long
/// sustained outage; the connector loop should fail-and-strike before
/// the cap is hit.
const Duration defaultOracleMicrosSimphonyInitialBackoff = Duration(milliseconds: 500);
const Duration defaultOracleMicrosSimphonyMaxBackoff = Duration(seconds: 8);

// ─── Credential / token store seam ───────────────────────────────────

/// Opaque server-side credential reference. Mirrors the local-to-vendor
/// pattern used by `humanity_labor_adapter.dart` and
/// `libro_reservation_adapter.dart` — declared in this file so the
/// production HTTP client never sees plaintext credentials.
///
/// `credentialId` is the row id in `vendor_credentials` that holds the
/// encrypted client_id + client_secret pair the Simphony Partner
/// Integration Program issued for this `(operator_id, location_id)`.
class SimphonyVendorCredentialHandle {
  const SimphonyVendorCredentialHandle({required this.credentialId});

  final String credentialId;
}

/// A short-lived access token plus its expiry instant. Returned by
/// [SimphonyTokenStore.fetchAccessToken] and by
/// [SimphonyTokenStore.refreshAccessToken]. The store is responsible
/// for caching; this client only ever holds the value briefly inside a
/// single request invocation.
class SimphonyAccessToken {
  const SimphonyAccessToken({
    required this.accessToken,
    required this.expiresAt,
  });

  /// Raw bearer; threaded into the `Authorization: Bearer <...>` header.
  final String accessToken;

  /// UTC instant the access token expires. The pg_cron refresh job
  /// keeps this comfortably in the future; reactive 401 refresh covers
  /// the gap when the vendor invalidates a token early.
  final DateTime expiresAt;
}

/// Token-resolution dep. Production binding lives behind the proxy
/// boundary (per Hard Promise #7); the adapter file consumes only this
/// abstraction so plaintext client_id / client_secret never reach
/// Flutter or this file.
///
/// `fetchAccessToken` returns the currently-cached bearer (issuing a
/// fresh one if no cached token exists or the cached one expired).
/// `refreshAccessToken` is called reactively on a 401 to force a new
/// `client_credentials` round trip even if the cached token has not
/// yet hit its `expiresAt` — vendors sometimes invalidate early.
abstract class SimphonyTokenStore {
  Future<SimphonyAccessToken> fetchAccessToken({
    required String operatorId,
    required String locationId,
    required SimphonyVendorCredentialHandle credential,
  });

  Future<SimphonyAccessToken> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required SimphonyVendorCredentialHandle credential,
  });
}

/// Maps a vendor location reference (`locRef`) onto the F&F
/// `(operator_id, location_id)` slot. The proxy's connect route
/// resolves this from `connector_connection.metadata.simphony_loc_ref`
/// (see adapter `connect` method); the production HTTP client just
/// reads it.
typedef SimphonyLocRefResolver = Future<String> Function({
  required String operatorId,
  required String locationId,
});

/// Idempotency-Key generator. Defaults to a deterministic shape based
/// on operator + location + a monotonic counter so a retry at the
/// transport layer emits the same key (vendor de-duplicates). Tests
/// inject a deterministic stub.
typedef SimphonyIdempotencyKeyFn = String Function({
  required String operatorId,
  required String locationId,
  required String purpose,
});

// ─── Typed errors ────────────────────────────────────────────────────

/// Base type the adapter loop pattern-matches on. The connector strike
/// counter, sync log writer, and reactive refresh path all key off
/// these subclasses.
abstract class SimphonyHttpError implements Exception {
  const SimphonyHttpError(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// 401 / 403 surfaced from the vendor. Distinct from the transient 5xx
/// retry path because the recovery is "rotate the access token", not
/// "wait + retry". The client retries once internally on 401 (forced
/// refresh); a second 401 throws this. 403 always throws immediately.
class SimphonyAuthError extends SimphonyHttpError {
  const SimphonyAuthError({
    required this.statusCode,
    required this.body,
  }) : super('auth failure');

  final int statusCode;
  final String body;
}

/// 429 with retries exhausted. Carries the last `Retry-After` value
/// the vendor sent (when one was sent) so the connector loop can pick
/// up the cadence beyond the per-call retry budget.
class SimphonyRateLimitError extends SimphonyHttpError {
  const SimphonyRateLimitError({
    required this.lastRetryAfter,
    required this.body,
  }) : super('rate limited');

  /// Vendor-reported retry hint from the final 429. Null when the
  /// vendor did not send `Retry-After`.
  final Duration? lastRetryAfter;
  final String body;
}

/// 5xx with retries exhausted. Connector strike counter increments on
/// each surface of this exception; three in a row flips the connection
/// to `error` per `oauth_shape.md` § Refresh semantics.
class SimphonyServerError extends SimphonyHttpError {
  const SimphonyServerError({
    required this.statusCode,
    required this.body,
  }) : super('server error');

  final int statusCode;
  final String body;
}

/// Other 4xx responses (400, 404, 422, etc). Not retried — caller
/// surfaces to `connector_sync_log` and stops the current poll tick.
class SimphonyClientError extends SimphonyHttpError {
  const SimphonyClientError({
    required this.statusCode,
    required this.body,
  }) : super('client error');

  final int statusCode;
  final String body;
}

/// Malformed-but-2xx response (missing `items` array, bad cursor type,
/// etc). Vendor uptime issue; treated like a 5xx for retry purposes
/// inside this slice's scope but carries its own type so telemetry can
/// distinguish "vendor returned 500" from "vendor returned 200 + JSON
/// the client could not parse".
class SimphonyMalformedResponseError extends SimphonyHttpError {
  const SimphonyMalformedResponseError({required this.body}) : super('malformed response');
  final String body;
}

// ─── Production HTTP client ──────────────────────────────────────────

/// HTTP-backed [OracleMicrosSimphonyApiClient].
///
/// Test seams:
///   * `httpClient` — `package:http` `Client` (inject `MockClient` in
///     tests). The class never owns a default; the connect-route
///     bootstrap supplies an `http.Client()` in production.
///   * `tokenStore` — resolves a [SimphonyVendorCredentialHandle] to a
///     bearer; tests stub deterministic responses.
///   * `clock` — UTC instant source. Defaults to `DateTime.now().toUtc()`.
///   * `delay` — back-off sleep injection. Defaults to `Future.delayed`.
///
/// The class is instantiated once per `(operator_id, location_id,
/// vendor_credential_handle)` — the connect-route bootstrap binds the
/// handle so the adapter never sees it.
class OracleMicrosSimphonyProductionApiClient
    implements OracleMicrosSimphonyApiClient {
  OracleMicrosSimphonyProductionApiClient({
    required http.Client httpClient,
    required SimphonyTokenStore tokenStore,
    required SimphonyVendorCredentialHandle credential,
    Uri? baseUri,
    Duration timeout = defaultOracleMicrosSimphonyRequestTimeout,
    int maxRetries = defaultOracleMicrosSimphonyMaxRetries,
    Duration initialBackoff = defaultOracleMicrosSimphonyInitialBackoff,
    Duration maxBackoff = defaultOracleMicrosSimphonyMaxBackoff,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    SimphonyIdempotencyKeyFn? idempotencyKeyFn,
  })  : _httpClient = httpClient,
        _tokenStore = tokenStore,
        _credential = credential,
        _baseUri = baseUri ?? defaultOracleMicrosSimphonyBaseUri,
        _timeout = timeout,
        _maxRetries = maxRetries,
        _initialBackoff = initialBackoff,
        _maxBackoff = maxBackoff,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _delay = delay ?? Future<void>.delayed,
        _idempotencyKeyFn = idempotencyKeyFn ?? _defaultIdempotencyKey;

  final http.Client _httpClient;
  final SimphonyTokenStore _tokenStore;
  final SimphonyVendorCredentialHandle _credential;
  final Uri _baseUri;
  final Duration _timeout;
  final int _maxRetries;
  final Duration _initialBackoff;
  final Duration _maxBackoff;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final SimphonyIdempotencyKeyFn _idempotencyKeyFn;

  // ── Public API (matches OracleMicrosSimphonyApiClient) ─────────────

  @override
  Future<SimphonyGuestCheckPage> fetchSampleGuestCheck({
    required String operatorId,
    required String locationId,
  }) async {
    // Heavy-but-bounded probe: pull the smallest documented page the
    // server will deliver since the recent past, return the first row,
    // and synthesize an end-of-listing cursor so the adapter does not
    // page through more than one batch.
    final since = _clock().subtract(const Duration(days: 7));
    final page = await _fetchGuestChecksPage(
      operatorId: operatorId,
      locationId: locationId,
      sinceModified: since,
      cursor: null,
      isDeliberateBackfill: false,
      pageLimit: 1,
    );
    if (page.records.isEmpty) {
      return SimphonyGuestCheckPage(
        records: const <Map<String, Object?>>[],
        nextCursor: '',
        lastModifiedSeen: page.lastModifiedSeen,
      );
    }
    return SimphonyGuestCheckPage(
      records: <Map<String, Object?>>[page.records.first],
      nextCursor: '',
      lastModifiedSeen: page.lastModifiedSeen,
    );
  }

  @override
  Future<SimphonyGuestCheckPage> fetchGuestChecks({
    required String operatorId,
    required String locationId,
    required DateTime sinceModified,
    required String? cursor,
    required bool isDeliberateBackfill,
  }) {
    return _fetchGuestChecksPage(
      operatorId: operatorId,
      locationId: locationId,
      sinceModified: sinceModified,
      cursor: cursor,
      isDeliberateBackfill: isDeliberateBackfill,
      pageLimit: null,
    );
  }

  // ── Internal: paged GET with retry / refresh ───────────────────────

  Future<SimphonyGuestCheckPage> _fetchGuestChecksPage({
    required String operatorId,
    required String locationId,
    required DateTime sinceModified,
    required String? cursor,
    required bool isDeliberateBackfill,
    required int? pageLimit,
  }) async {
    final queryParams = <String, String>{
      'lastModifiedUTC': sinceModified.toUtc().toIso8601String(),
    };
    if (cursor != null && cursor.isNotEmpty) {
      queryParams['cursor'] = cursor;
    }
    if (pageLimit != null) {
      queryParams['limit'] = pageLimit.toString();
    }
    if (isDeliberateBackfill) {
      // Vendor-side hint that this caller is in deliberate-backfill
      // mode (>90-day floor bypassed). Documented as an opaque flag —
      // the vendor reserves the right to ignore. Carrying it lets
      // `8.OR.live.sandbox` confirm the documented behavior; the
      // sanity-hook gate enforces F&F-side semantics regardless.
      queryParams['mode'] = 'backfill';
    }

    final uri = _resolve(oracleMicrosSimphonyGuestChecksPath, queryParams);
    final idempotencyKey = _idempotencyKeyFn(
      operatorId: operatorId,
      locationId: locationId,
      purpose: 'getGuestChecks',
    );

    final response = await _sendWithRetry(
      operatorId: operatorId,
      locationId: locationId,
      builder: (token) => http.Request('POST', uri)
        ..headers.addAll(<String, String>{
          HttpHeaders.authorizationHeader: 'Bearer ${token.accessToken}',
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.contentTypeHeader: 'application/json',
          'Idempotency-Key': idempotencyKey,
          HttpHeaders.userAgentHeader: _buildUserAgent(),
        })
        ..body = jsonEncode(<String, Object?>{
          'lastModifiedUTC': sinceModified.toUtc().toIso8601String(),
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          if (pageLimit != null) 'limit': pageLimit,
          if (isDeliberateBackfill) 'mode': 'backfill',
        }),
    );

    return _parseGuestChecksPage(response.body, sinceModified);
  }

  /// Decode a Gen2 `getGuestChecks` envelope into a
  /// [SimphonyGuestCheckPage]. The adapter's `_mapGuestCheckToCanonical`
  /// reads `record['header'].*` directly, so this method preserves the
  /// raw vendor-shape map and only extracts pagination + watermark
  /// fields itself.
  @visibleForTesting
  SimphonyGuestCheckPage parseGuestChecksPage(
    String body,
    DateTime fallbackLastModified,
  ) =>
      _parseGuestChecksPage(body, fallbackLastModified);

  SimphonyGuestCheckPage _parseGuestChecksPage(
    String body,
    DateTime fallbackLastModified,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (_) {
      throw SimphonyMalformedResponseError(body: body);
    }
    if (decoded is! Map<String, Object?>) {
      throw SimphonyMalformedResponseError(body: body);
    }
    final rawItems = decoded['items'];
    if (rawItems is! List) {
      throw SimphonyMalformedResponseError(body: body);
    }
    final records = <Map<String, Object?>>[];
    for (final raw in rawItems) {
      if (raw is Map<String, Object?>) {
        records.add(raw);
      } else if (raw is Map) {
        records.add(Map<String, Object?>.from(raw));
      } else {
        throw SimphonyMalformedResponseError(body: body);
      }
    }

    final nextCursorRaw = decoded['nextCursor'];
    final String nextCursor;
    if (nextCursorRaw == null) {
      nextCursor = '';
    } else if (nextCursorRaw is String) {
      nextCursor = nextCursorRaw;
    } else {
      throw SimphonyMalformedResponseError(body: body);
    }

    DateTime lastModified = fallbackLastModified.toUtc();
    final lastModifiedRaw = decoded['lastModifiedUTC'];
    if (lastModifiedRaw is String && lastModifiedRaw.isNotEmpty) {
      try {
        lastModified = DateTime.parse(lastModifiedRaw).toUtc();
      } on FormatException catch (_) {
        throw SimphonyMalformedResponseError(body: body);
      }
    } else if (records.isNotEmpty) {
      // Fall back to the latest `lastUpdatedUTC` in the page when the
      // vendor envelope omits the page-level field. The adapter stamps
      // this onto the watermark; an undefined value would rewind the
      // cursor on the next tick.
      DateTime? best;
      for (final record in records) {
        final header = record['header'];
        if (header is Map<String, Object?>) {
          final updRaw = header['lastUpdatedUTC'];
          if (updRaw is String && updRaw.isNotEmpty) {
            try {
              final parsed = DateTime.parse(updRaw).toUtc();
              if (best == null || parsed.isAfter(best)) {
                best = parsed;
              }
            } on FormatException catch (_) {
              // Ignore a single bad row; sanity-hook will reject it
              // when the adapter calls into it.
            }
          }
        }
      }
      if (best != null) {
        lastModified = best;
      }
    }

    return SimphonyGuestCheckPage(
      records: records,
      nextCursor: nextCursor,
      lastModifiedSeen: lastModified,
    );
  }

  // ── Internal: send + retry pipeline ────────────────────────────────

  /// Build, send, and (where appropriate) retry the request. Returns
  /// the final 2xx response. Throws a typed [SimphonyHttpError]
  /// subclass on terminal failure.
  ///
  /// Retry order:
  ///   1. 401 → force token refresh, retry once.
  ///   2. 429 → honor `Retry-After`, retry up to [_maxRetries] total.
  ///   3. 5xx → exponential back-off, retry up to [_maxRetries] total.
  ///   4. Any other 4xx → throw [SimphonyClientError] without retry.
  Future<http.Response> _sendWithRetry({
    required String operatorId,
    required String locationId,
    required http.Request Function(SimphonyAccessToken token) builder,
  }) async {
    var refreshedOnce = false;
    var transientAttempts = 0;
    Duration? lastRetryAfter;

    SimphonyAccessToken token = await _tokenStore.fetchAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      credential: _credential,
    );

    while (true) {
      final request = builder(token);
      final response = await _send(request);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      }

      if (response.statusCode == 401) {
        if (refreshedOnce) {
          throw SimphonyAuthError(
            statusCode: 401,
            body: response.body,
          );
        }
        refreshedOnce = true;
        token = await _tokenStore.refreshAccessToken(
          operatorId: operatorId,
          locationId: locationId,
          credential: _credential,
        );
        continue;
      }

      if (response.statusCode == 403) {
        throw SimphonyAuthError(
          statusCode: 403,
          body: response.body,
        );
      }

      if (response.statusCode == 429) {
        if (transientAttempts >= _maxRetries) {
          throw SimphonyRateLimitError(
            lastRetryAfter: lastRetryAfter,
            body: response.body,
          );
        }
        transientAttempts += 1;
        lastRetryAfter = _parseRetryAfter(response.headers['retry-after']) ??
            _backoffFor(transientAttempts);
        await _delay(lastRetryAfter);
        continue;
      }

      if (response.statusCode >= 500 && response.statusCode < 600) {
        if (transientAttempts >= _maxRetries) {
          throw SimphonyServerError(
            statusCode: response.statusCode,
            body: response.body,
          );
        }
        transientAttempts += 1;
        await _delay(_backoffFor(transientAttempts));
        continue;
      }

      // All other 4xx — do not retry.
      throw SimphonyClientError(
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }

  Future<http.Response> _send(http.Request request) async {
    final streamed = await _httpClient.send(request).timeout(_timeout);
    return http.Response.fromStream(streamed);
  }

  Uri _resolve(String relativePath, Map<String, String> queryParams) {
    final base = _baseUri.toString();
    final joined = base.endsWith('/') ? '$base$relativePath' : '$base/$relativePath';
    final parsed = Uri.parse(joined);
    if (queryParams.isEmpty) return parsed;
    return parsed.replace(queryParameters: <String, String>{
      ...parsed.queryParameters,
      ...queryParams,
    });
  }

  Duration _backoffFor(int attempt) {
    final factor = pow(2, attempt - 1).toInt();
    final scaled = _initialBackoff * factor;
    return scaled > _maxBackoff ? _maxBackoff : scaled;
  }

  /// Parse an HTTP `Retry-After` header. Supports the integer-seconds
  /// shape (the only one Simphony documents); returns null on absence
  /// or a value the spec permits but the vendor does not send (HTTP
  /// date format is intentionally not implemented — we'd fall through
  /// to the exponential back-off path instead, which is safer than
  /// trusting a stale clock).
  static Duration? _parseRetryAfter(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final asInt = int.tryParse(raw.trim());
    if (asInt == null) return null;
    if (asInt < 0) return Duration.zero;
    return Duration(seconds: asInt);
  }

  static String _defaultIdempotencyKey({
    required String operatorId,
    required String locationId,
    required String purpose,
  }) {
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'simphony:$purpose:$operatorId:$locationId:$stamp';
  }

  static String _buildUserAgent() {
    return 'forge-and-flow-pos-simphony/1.0';
  }
}
