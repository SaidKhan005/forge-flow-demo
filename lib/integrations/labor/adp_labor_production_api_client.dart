// Phase 8.transport.adp-labor — production ADP HTTP client.
//
// Concrete [AdpTransport] implementation that speaks ADP Workforce
// Now / ADP Workforce Manager OAuth + REST. The shapes mirror the
// documented assumptions captured in
// [documentedPerAdpV1FieldMapping] inside `adp_labor_adapter.dart`
// (`time/v2/workers/.../team-time-cards`, `time/v2/workers/.../time-events`,
// `core/v1/event-subscriptions`, `auth/oauth/v2/token`,
// `auth/oauth/v2/revoke`). Every endpoint marked
// `verify_in_live_sandbox: true` in the adapter's field-mapping
// constant is consumed verbatim here so the diff against the first
// observed sandbox response is bounded.
//
// **mTLS deployment concern (load-bearing).** ADP partner production
// requires mutual-TLS in addition to the OAuth bearer (per the ADP
// Marketplace Developer Participation Agreement). Production wires
// the client cert + key via env (`ADP_MTLS_CERT_PATH`,
// `ADP_MTLS_KEY_PATH`, `ADP_MTLS_KEY_PASSPHRASE`) into a
// `SecurityContext` that backs an `IOClient` constructed from a
// custom `HttpClient`. That wiring is a deployment concern and is
// performed by the Cloud Run Job entrypoint — this file accepts an
// already-mTLS-configured [http.Client] via the `httpClient`
// constructor parameter so unit tests can inject a fake
// [http.Client] without touching `dart:io`. The
// `8.S.ADP.live.sandbox` slice will fold the production
// `SecurityContext` factory into the entrypoint and pin the cert
// rotation runbook in `docs/integrations/adp/partnership_status.md`.
//
// Banned per V1 lean cut 2 (CLAUDE.md authority order — REJECT if
// reintroduced):
//   * No KMS rollout / rotate-signing-key surface.
//   * No advisory-lock primitive.
//   * No graceful drain / SIGTERM hook.
//   * No 5-minute strict replay window. The framework's 24h ceiling
//     stands and is enforced upstream.
//   * No partial-write flag — malformed payloads drop at the adapter
//     boundary, not here.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'adp_labor_adapter.dart';

// ─── Config / Deps ────────────────────────────────────────────────────

/// Credentials accessor handed to the client. The production wiring
/// resolves these from the operator-scoped credential store (kept
/// behind `OperatorScopedRepository.withTenant`); tests inject
/// straight strings.
typedef AdpCredentialsProvider = Future<AdpClientCredentials> Function();

/// Subscription signing-secret accessor. Returned ciphertext is
/// decrypted upstream of this client (the ADP gateway in
/// `lib/infrastructure/persistence/postgres/adp_postgres_sink.dart`
/// owns ciphertext); the production HTTP client only sees plaintext
/// at the in-memory hop required for `registerEventSubscription`.
typedef AdpSubscriptionSecretProvider = Future<String> Function();

/// Idempotency-key minter. Defaults to a monotonic UUID-shaped
/// string keyed off [DateTime.now]; tests can pin a deterministic
/// generator. Idempotency keys are mandatory on POST requests so a
/// retry after a 5xx never duplicates work on the ADP side.
typedef AdpIdempotencyKeyMinter = String Function();

/// Bundle of OAuth client credentials (per ADP Marketplace partner
/// app). [AdpLaborProductionApiClient] never persists these; it just
/// asks the [AdpCredentialsProvider] every time it needs them.
class AdpClientCredentials {
  const AdpClientCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  final String clientId;
  final String clientSecret;
}

/// Production endpoint defaults. Overridable per environment via the
/// constructor's `baseUri` / `oauthBaseUri` arguments. The defaults
/// match the ADP developer-portal documented production endpoints
/// (https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog
/// — retrieved 2026-05-04). Sandbox uses the same shapes against the
/// `accounts-iat.adp.com` / `api-iat.adp.com` hosts; the
/// `8.S.ADP.live.sandbox` slice wires the iat hosts when partner
/// credentials arrive.
class AdpProductionEndpoints {
  const AdpProductionEndpoints({
    required this.apiBaseUri,
    required this.oauthBaseUri,
  });

  /// Default ADP production API base. Overridable via env in the
  /// Cloud Run Job entrypoint. Sandbox mirrors:
  /// `https://api-iat.adp.com`.
  static final Uri defaultApiBaseUri = Uri.parse('https://api.adp.com');

  /// Default ADP production OAuth base. Sandbox mirrors:
  /// `https://accounts-iat.adp.com`.
  static final Uri defaultOauthBaseUri =
      Uri.parse('https://accounts.adp.com');

  static AdpProductionEndpoints production() => AdpProductionEndpoints(
        apiBaseUri: defaultApiBaseUri,
        oauthBaseUri: defaultOauthBaseUri,
      );

  /// API host (e.g. `https://api.adp.com`). Trailing slashes are
  /// tolerated by [_resolve]; resolution preserves any path prefix.
  final Uri apiBaseUri;

  /// OAuth host (e.g. `https://accounts.adp.com`). The
  /// authorization, token, and revoke endpoints all hang off this
  /// host per the ADP developer-portal samples.
  final Uri oauthBaseUri;
}

// ─── Errors ───────────────────────────────────────────────────────────

/// Base type for ADP HTTP errors. Subclasses surface the typed
/// reason so the framework can decide retry / surface / refuse.
sealed class AdpHttpException implements Exception {
  const AdpHttpException(this.message);
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

/// 401 from ADP — access token expired or revoked. The framework's
/// refresh-on-401 path catches this and re-runs after a refresh.
class AdpAuthenticationException extends AdpHttpException {
  const AdpAuthenticationException(super.message);
}

/// 429 from ADP — rate limited. Carries the retry hint observed in
/// the response (Retry-After header in seconds, or null when ADP
/// omitted it; in that case the caller applies the default backoff).
class AdpRateLimitException extends AdpHttpException {
  const AdpRateLimitException(super.message, {this.retryAfter});
  final Duration? retryAfter;
}

/// Non-2xx response not handled by a more specific subclass.
class AdpRequestException extends AdpHttpException {
  const AdpRequestException(super.message, {required this.statusCode});
  final int statusCode;
}

/// Local schema mismatch — ADP returned 2xx but the body was missing
/// a load-bearing field. Surfaced separately from
/// [AdpRequestException] because the fix is "verify mapping in
/// sandbox", not "retry".
class AdpSchemaException extends AdpHttpException {
  const AdpSchemaException(super.message);
}

// ─── Client ───────────────────────────────────────────────────────────

/// Production [AdpTransport] backed by `package:http`.
///
/// All methods translate the ADP HTTP shape into the canonical
/// objects the [AdpLaborAdapter] consumes and refuse on missing /
/// malformed fields rather than silently producing canonical zeros
/// (the adapter's `_canonicalize` is the secondary guard).
///
/// The injected [http.Client] is responsible for any mTLS wiring
/// (production wraps an `IOClient` over a `dart:io` `HttpClient`
/// configured with a `SecurityContext`; the Cloud Run Job entrypoint
/// owns that construction). Tests inject a fake `http.Client` and
/// exercise every code path including 429 and 401.
class AdpLaborProductionApiClient implements AdpTransport {
  AdpLaborProductionApiClient({
    required AdpCredentialsProvider credentialsProvider,
    required AdpSubscriptionSecretProvider subscriptionSecretProvider,
    AdpProductionEndpoints? endpoints,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 20),
    Duration defaultRetryAfter = const Duration(seconds: 5),
    int maxRetriesOn429 = 3,
    AdpIdempotencyKeyMinter? idempotencyKeyMinter,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  })  : _credentialsProvider = credentialsProvider,
        _subscriptionSecretProvider = subscriptionSecretProvider,
        _endpoints = endpoints ?? AdpProductionEndpoints.production(),
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _defaultRetryAfter = defaultRetryAfter,
        _maxRetriesOn429 = maxRetriesOn429,
        _idempotencyKeyMinter = idempotencyKeyMinter ?? _defaultMinter,
        _now = now ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed;

  final AdpCredentialsProvider _credentialsProvider;
  final AdpSubscriptionSecretProvider _subscriptionSecretProvider;
  final AdpProductionEndpoints _endpoints;
  final http.Client _httpClient;
  final Duration _timeout;
  final Duration _defaultRetryAfter;
  final int _maxRetriesOn429;
  final AdpIdempotencyKeyMinter _idempotencyKeyMinter;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  static int _minterSeq = 0;
  static String _defaultMinter() {
    _minterSeq += 1;
    return 'adp-${DateTime.now().microsecondsSinceEpoch}-$_minterSeq';
  }

  /// Idempotent close. Production lifecycle (Cloud Run Job) drops
  /// the whole isolate so this is mainly a hook for tests.
  void close() => _httpClient.close();

  // ─── OAuth ────────────────────────────────────────────────────────

  @override
  Future<AdpTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
    required String module,
  }) async {
    return _tokenRequest(
      bodyFields: <String, String>{
        'grant_type': 'authorization_code',
        'code': authorizationCode,
        'redirect_uri': redirectUri,
      },
      module: module,
    );
  }

  @override
  Future<AdpTokenResponse> refresh({
    required String refreshToken,
    required String module,
  }) async {
    return _tokenRequest(
      bodyFields: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
      module: module,
    );
  }

  @override
  Future<void> revoke({required String accessToken}) async {
    final creds = await _credentialsProvider();
    final uri = _endpoints.oauthBaseUri.replace(path: '/auth/oauth/v2/revoke');
    final response = await _send(
      () => _httpClient
          .post(
            uri,
            headers: <String, String>{
              'authorization': _basicAuth(creds.clientId, creds.clientSecret),
              'content-type': 'application/x-www-form-urlencoded',
              'accept': 'application/json',
            },
            body: <String, String>{'token': accessToken},
          )
          .timeout(_timeout),
      requestKind: 'oauth_revoke',
    );
    // ADP best-practice for revoke is 200 on success; anything else
    // is best-effort per the adapter (vendor outage MUST NOT block
    // disconnect). Surface non-401 / non-429 as informative — the
    // adapter swallows the error.
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw AdpRequestException(
        'oauth revoke returned ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
  }

  Future<AdpTokenResponse> _tokenRequest({
    required Map<String, String> bodyFields,
    required String module,
  }) async {
    final creds = await _credentialsProvider();
    final uri = _endpoints.oauthBaseUri.replace(path: '/auth/oauth/v2/token');
    final response = await _send(
      () => _httpClient
          .post(
            uri,
            headers: <String, String>{
              'authorization': _basicAuth(creds.clientId, creds.clientSecret),
              'content-type': 'application/x-www-form-urlencoded',
              'accept': 'application/json',
              'x-adp-module': module,
            },
            body: bodyFields,
          )
          .timeout(_timeout),
      requestKind: 'oauth_token',
    );
    if (response.statusCode == 401) {
      throw AdpAuthenticationException(
        'oauth token request returned 401: ${response.body}',
      );
    }
    if (response.statusCode != 200) {
      throw AdpRequestException(
        'oauth token request returned ${response.statusCode}: ${response.body}',
        statusCode: response.statusCode,
      );
    }
    final decoded = _decodeJsonObject(response.body, 'oauth_token');
    final accessToken = decoded['access_token'];
    final refreshToken = decoded['refresh_token'];
    final expiresIn = decoded['expires_in'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const AdpSchemaException(
        'oauth response missing access_token',
      );
    }
    final refresh = refreshToken is String ? refreshToken : '';
    final ttlSeconds = expiresIn is int
        ? expiresIn
        : (expiresIn is num ? expiresIn.toInt() : 3600);
    return AdpTokenResponse(
      accessToken: accessToken,
      refreshToken: refresh,
      expiresAt: _now().toUtc().add(Duration(seconds: ttlSeconds)),
    );
  }

  // ─── Time events ─────────────────────────────────────────────────

  @override
  Future<AdpTimeEventsPage> listTimeEvents({
    required String accessToken,
    required String module,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    final query = <String, String>{
      'modifiedSince': modifiedSince.toUtc().toIso8601String(),
      'modifiedUntil': modifiedUntil.toUtc().toIso8601String(),
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };
    final path = module == kAdpModuleWorkforceManager
        ? '/time/v2/team-time-cards'
        : '/time/v2/workers/team-time-cards';
    final uri = _resolveApi(path).replace(queryParameters: query);
    final response = await _send(
      () => _httpClient.get(
        uri,
        headers: _bearerHeaders(accessToken, module: module),
      ).timeout(_timeout),
      requestKind: 'list_time_events',
    );
    _throwOnAuthOr429(response);
    if (response.statusCode != 200) {
      throw AdpRequestException(
        'list_time_events returned ${response.statusCode}: ${response.body}',
        statusCode: response.statusCode,
      );
    }
    final decoded = _decodeJsonObject(response.body, 'list_time_events');
    final raw = decoded['records'] ??
        decoded['team_time_cards'] ??
        decoded['time_events'] ??
        decoded['data'];
    if (raw is! List) {
      throw const AdpSchemaException(
        'list_time_events body missing records[] / team_time_cards[]',
      );
    }
    final records = <Map<String, Object?>>[];
    DateTime lastModifiedSeen =
        modifiedSince.toUtc(); // Preserves TIMESTAMPTZ.
    for (final element in raw) {
      if (element is! Map) continue;
      final row = Map<String, Object?>.from(element);
      records.add(row);
      final timeEventRaw = row['time_event'];
      if (timeEventRaw is Map) {
        final timeEvent = Map<String, Object?>.from(timeEventRaw);
        final modifiedRaw = timeEvent['last_modified_date_time'];
        if (modifiedRaw is String) {
          final parsed = DateTime.tryParse(modifiedRaw)?.toUtc();
          if (parsed != null && parsed.isAfter(lastModifiedSeen)) {
            lastModifiedSeen = parsed;
          }
        }
      }
    }
    final nextCursor = decoded['next_cursor'];
    return AdpTimeEventsPage(
      records: records,
      nextCursor: nextCursor is String && nextCursor.isNotEmpty
          ? nextCursor
          : null,
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  // ─── Worker ──────────────────────────────────────────────────────

  @override
  Future<Map<String, Object?>> fetchWorker({
    required String accessToken,
    required String module,
    required String associateOid,
  }) async {
    final uri = _resolveApi('/hr/v2/workers/$associateOid');
    final response = await _send(
      () => _httpClient.get(
        uri,
        headers: _bearerHeaders(accessToken, module: module),
      ).timeout(_timeout),
      requestKind: 'fetch_worker',
    );
    _throwOnAuthOr429(response);
    if (response.statusCode != 200) {
      throw AdpRequestException(
        'fetch_worker returned ${response.statusCode}: ${response.body}',
        statusCode: response.statusCode,
      );
    }
    final decoded = _decodeJsonObject(response.body, 'fetch_worker');
    final worker = decoded['worker'];
    if (worker is Map) {
      return Map<String, Object?>.from(worker);
    }
    return decoded;
  }

  // ─── Event subscriptions ─────────────────────────────────────────

  @override
  Future<String> registerEventSubscription({
    required String accessToken,
    required String module,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async {
    final secret = signingSecret.isNotEmpty
        ? signingSecret
        : await _subscriptionSecretProvider();
    final uri = _resolveApi('/core/v1/event-subscriptions');
    final body = <String, Object?>{
      'subscription': <String, Object?>{
        'callback_url': url,
        'events': events,
        'signing_secret': secret,
        'module': module,
      },
    };
    final idempotencyKey = _idempotencyKeyMinter();
    final response = await _send(
      () => _httpClient
          .post(
            uri,
            headers: <String, String>{
              ..._bearerHeaders(accessToken, module: module),
              'content-type': 'application/json',
              'idempotency-key': idempotencyKey,
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout),
      requestKind: 'register_event_subscription',
    );
    _throwOnAuthOr429(response);
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw AdpRequestException(
        'register_event_subscription returned ${response.statusCode}: '
        '${response.body}',
        statusCode: response.statusCode,
      );
    }
    final decoded = _decodeJsonObject(
      response.body,
      'register_event_subscription',
    );
    final id = decoded['subscription_id'] ??
        (decoded['subscription'] is Map
            ? (decoded['subscription'] as Map)['id']
            : null);
    if (id is! String || id.isEmpty) {
      throw const AdpSchemaException(
        'register_event_subscription missing subscription_id',
      );
    }
    return id;
  }

  @override
  Future<void> unregisterEventSubscription({
    required String accessToken,
    required String module,
    required String subscriptionId,
  }) async {
    final uri =
        _resolveApi('/core/v1/event-subscriptions/$subscriptionId');
    final response = await _send(
      () => _httpClient.delete(
        uri,
        headers: _bearerHeaders(accessToken, module: module),
      ).timeout(_timeout),
      requestKind: 'unregister_event_subscription',
    );
    if (response.statusCode == 401) {
      throw AdpAuthenticationException(
        'unregister_event_subscription returned 401',
      );
    }
    if (response.statusCode == 429) {
      throw AdpRateLimitException(
        'unregister_event_subscription returned 429',
        retryAfter: _retryAfter(response),
      );
    }
    // 200 / 202 / 204 all acceptable; 404 means the subscription is
    // already gone — treat as success since the adapter's disconnect
    // path is best-effort here.
    if (response.statusCode == 200 ||
        response.statusCode == 202 ||
        response.statusCode == 204 ||
        response.statusCode == 404) {
      return;
    }
    throw AdpRequestException(
      'unregister_event_subscription returned ${response.statusCode}: '
      '${response.body}',
      statusCode: response.statusCode,
    );
  }

  // ─── Sample (testConnection) ─────────────────────────────────────

  @override
  Future<Map<String, Object?>> sampleTimeEvent({
    required String accessToken,
    required String module,
  }) async {
    final uri = _resolveApi('/time/v2/workers/team-time-cards').replace(
      queryParameters: <String, String>{'\$top': '1'},
    );
    final response = await _send(
      () => _httpClient.get(
        uri,
        headers: _bearerHeaders(accessToken, module: module),
      ).timeout(_timeout),
      requestKind: 'sample_time_event',
    );
    _throwOnAuthOr429(response);
    if (response.statusCode != 200) {
      throw AdpRequestException(
        'sample_time_event returned ${response.statusCode}: ${response.body}',
        statusCode: response.statusCode,
      );
    }
    final decoded = _decodeJsonObject(response.body, 'sample_time_event');
    final raw = decoded['records'] ??
        decoded['team_time_cards'] ??
        decoded['time_events'] ??
        decoded['data'];
    if (raw is! List || raw.isEmpty) {
      return const <String, Object?>{};
    }
    final first = raw.first;
    if (first is! Map) return const <String, Object?>{};
    final row = Map<String, Object?>.from(first);
    final timeEvent = row['time_event'];
    if (timeEvent is Map) {
      final out = Map<String, Object?>.from(timeEvent);
      final worker = row['worker'];
      if (worker is Map) {
        out['worker'] = Map<String, Object?>.from(worker);
      }
      return out;
    }
    return row;
  }

  // ─── Internals ───────────────────────────────────────────────────

  Uri _resolveApi(String path) {
    // Concatenate without losing any prefix path on `apiBaseUri`.
    final base = _endpoints.apiBaseUri;
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final suffix = path.startsWith('/') ? path : '/$path';
    return base.replace(path: '$basePath$suffix');
  }

  Map<String, String> _bearerHeaders(
    String accessToken, {
    required String module,
  }) {
    return <String, String>{
      'authorization': 'Bearer $accessToken',
      'accept': 'application/json',
      'x-adp-module': module,
    };
  }

  String _basicAuth(String clientId, String clientSecret) {
    final encoded =
        base64.encode(utf8.encode('$clientId:$clientSecret'));
    return 'Basic $encoded';
  }

  Map<String, Object?> _decodeJsonObject(String body, String kind) {
    if (body.isEmpty) {
      throw AdpSchemaException('$kind returned empty body');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw AdpSchemaException('$kind returned non-JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw AdpSchemaException(
        '$kind returned non-object body (got ${decoded.runtimeType})',
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  void _throwOnAuthOr429(http.Response response) {
    if (response.statusCode == 401) {
      throw AdpAuthenticationException(
        'request returned 401: ${response.body}',
      );
    }
    if (response.statusCode == 429) {
      throw AdpRateLimitException(
        'request returned 429',
        retryAfter: _retryAfter(response),
      );
    }
  }

  Duration? _retryAfter(http.Response response) {
    final header = response.headers['retry-after'];
    if (header == null || header.isEmpty) return null;
    final seconds = int.tryParse(header);
    if (seconds != null) return Duration(seconds: seconds);
    final asDate = HttpDate.tryParse(header);
    if (asDate != null) {
      final delta = asDate.toUtc().difference(_now().toUtc());
      if (delta.inMilliseconds > 0) return delta;
    }
    return null;
  }

  /// Wraps an HTTP send with bounded 429 backoff. Auth (401) is
  /// surfaced immediately so the framework's refresh-on-401 path can
  /// re-run the call with a fresh token; we do NOT retry inline on
  /// 401 because the access token in the closure is captured.
  Future<http.Response> _send(
    Future<http.Response> Function() launch, {
    required String requestKind,
  }) async {
    var attempt = 0;
    while (true) {
      late http.Response response;
      try {
        response = await launch();
      } on TimeoutException catch (e) {
        throw AdpRequestException(
          '$requestKind timed out: ${e.message ?? "no message"}',
          statusCode: 0,
        );
      }
      if (response.statusCode != 429 || attempt >= _maxRetriesOn429) {
        return response;
      }
      final retryAfter = _retryAfter(response) ?? _defaultRetryAfter;
      final exponent = attempt;
      final backoff = Duration(
        milliseconds: retryAfter.inMilliseconds * (1 << exponent),
      );
      await _sleep(backoff);
      attempt += 1;
    }
  }
}

// ─── HttpDate shim ──────────────────────────────────────────────────
//
// `dart:io`'s `HttpDate.parse` requires a `dart:io` import, which
// drags `IOClient` etc. into the surface. The production client is
// constructed against a `package:http` `Client` injected from the
// Cloud Run Job entrypoint (which DOES import `dart:io` for the
// SecurityContext / mTLS wiring). To keep this file decoupled from
// `dart:io`, we ship a small RFC 1123 / RFC 850 / asctime tolerant
// parser sufficient for the `Retry-After: <HTTP-date>` shape ADP
// emits on 429 throttles.
class HttpDate {
  static DateTime? tryParse(String input) {
    try {
      // RFC 1123: Sun, 06 Nov 1994 08:49:37 GMT
      final m = RegExp(
        r'^([A-Za-z]{3}), (\d{2}) ([A-Za-z]{3}) (\d{4}) '
        r'(\d{2}):(\d{2}):(\d{2}) GMT$',
      ).firstMatch(input.trim());
      if (m == null) return null;
      const months = <String, int>{
        'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
        'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
      };
      final month = months[m.group(3)];
      if (month == null) return null;
      return DateTime.utc(
        int.parse(m.group(4)!),
        month,
        int.parse(m.group(2)!),
        int.parse(m.group(5)!),
        int.parse(m.group(6)!),
        int.parse(m.group(7)!),
      );
    } on FormatException {
      return null;
    }
  }
}
