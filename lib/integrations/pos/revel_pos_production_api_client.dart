// Phase 8 — `8.transport.revel-pos`. Production HTTP transport for the
// Revel Systems POS adapter.
//
// Implements [RevelTransport] (declared in
// `lib/integrations/pos/revel_pos_adapter.dart`) against the Revel
// REST surface documented at
// `https://developer.revelsystems.com/revelsystems/docs` (retrieval
// date 2026-05-06). The fixture-driven `_FakeRevelTransport` in
// `test/integrations/pos/revel_pos_adapter_test.dart` proves the
// adapter contract; this file proves the wire shape — auth headers,
// pagination, 429 backoff, typed errors, idempotency keys, TIMESTAMPTZ
// preservation.
//
// Auth modes (`RevelAuthMode`):
//   * `RevelAuthMode.oauth` — OAuth tier. Calls
//     `POST {oauthTokenUri}` with `grant_type=client_credentials` and
//     uses the resulting bearer JWT on every subsequent request as
//     `Authorization: Bearer <jwt>`. The 24h JWT TTL is honored via
//     [RevelTokenResponse.expiresAt]; refresh is the framework's job
//     (see `RevelOAuthRefresher` in the adapter).
//   * `RevelAuthMode.apiKeyHeader` — legacy tier. The transport never
//     hits the OAuth endpoint; `exchangeClientCredentials` synthesizes
//     a synthetic envelope (`<client_id>:<client_secret>`) which the
//     adapter persists as the access-token ciphertext. Subsequent
//     requests carry the `API-AUTHENTICATION: <client_id>:<client_secret>`
//     header per Revel's legacy API contract.
//
// Pagination:
//   Revel's REST list endpoints expose `offset` + `limit` query params
//   plus a `meta.next_offset` / `meta.total_count` envelope. The
//   transport encodes the next offset as the cursor token returned to
//   the adapter so the framework's cursor-based watermark advance
//   works unchanged.
//
// 429 backoff:
//   On HTTP 429 the client honors the `Retry-After` header (seconds or
//   HTTP-date) when present. Otherwise it backs off using exponential
//   delays starting at the configured `initialBackoff` (default 500ms)
//   capped at `maxBackoff` (default 32s). The retry budget is
//   `maxRetries` attempts (default 3) — exhaustion surfaces a typed
//   [RevelTransportException] with `kind = rateLimited`.
//
// 5xx retry:
//   HTTP 500-599 retries with the same exponential backoff schedule
//   under the same `maxRetries` budget. A 5xx exhaustion surfaces a
//   typed exception with `kind = serverError`.
//
// 4xx errors (non-429):
//   No retry. 401 → `kind = unauthorized` (caller should refresh
//   token); 403 → `kind = forbidden`; 404 → `kind = notFound`; other
//   client errors → `kind = badRequest`.
//
// Idempotency:
//   Every POST / DELETE carries an `Idempotency-Key` header. The
//   key is either a deterministic string the caller passes through
//   the deps record, or a random UUID v4 minted from the injected
//   `Random` (default `Random.secure`) so each retry attempt within a
//   request reuses the same key.
//
// TIMESTAMPTZ posture:
//   Vendor-shape `created_date` / `updated_date` are emitted by Revel
//   as ISO 8601 UTC strings. The transport surfaces them unchanged in
//   `RevelOrdersPage.records[*]['created_date' / 'updated_date']` so
//   the adapter's `_canonicalize` parses them via `DateTime.parse(...).toUtc()`
//   without a second timezone conversion. The transport DOES parse
//   `meta.last_modified_seen` (when the server emits one) for the
//   page's `lastModifiedSeen` field — falling back to the latest
//   record's `updated_date` when absent.
//
// V1 lean cut 2 alignment: this file does not introduce new pub deps,
// does not open new persistence surfaces, and stays inside the
// allowlist scope. No 5-second SLA, no advisory locks, no graceful
// drain hook.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'revel_pos_adapter.dart';

/// Auth mode selection — see file header.
enum RevelAuthMode { oauth, apiKeyHeader }

/// Typed error kinds for [RevelTransportException]. Tests pin each
/// kind via the kind enum so message-string changes do not break the
/// suite.
enum RevelTransportErrorKind {
  /// HTTP 401 — bearer token rejected. The adapter reissues via
  /// `OAuthRefreshCronRunner` on the next tick.
  unauthorized,

  /// HTTP 403 — credentials are valid but lack the required scope.
  forbidden,

  /// HTTP 404 — resource not found (e.g. `fetchOrder` with an unknown
  /// id). Caller decides whether to drop or escalate.
  notFound,

  /// HTTP 4xx other than 401/403/404/429. No retry.
  badRequest,

  /// HTTP 429 retry budget exhausted.
  rateLimited,

  /// HTTP 5xx retry budget exhausted.
  serverError,

  /// Network / TLS / DNS / read-timeout failure. Retries within the
  /// same budget; final surface is this kind.
  network,

  /// JSON decode failure or schema mismatch on a 2xx response.
  malformedResponse,
}

/// Typed exception every public method of [RevelProductionApiClient]
/// throws on failure. `kind` is stable across message wording changes.
class RevelTransportException implements Exception {
  const RevelTransportException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.responseBodyPreview,
  });

  final RevelTransportErrorKind kind;
  final String message;
  final int? statusCode;

  /// First 256 chars of the response body when the server sent one.
  /// Useful for triage; never logged at info level by callers
  /// (the adapter scrubs PII before logging via `connector_sync_log`).
  final String? responseBodyPreview;

  @override
  String toString() =>
      'RevelTransportException(kind=$kind, status=$statusCode): $message';
}

/// Sidecar deps record. Keeping the record separate from the client
/// constructor lets unit tests build a deps record once and re-use it
/// across multiple production-client instances (e.g. parameterized
/// over auth mode). All fields default to safe production values when
/// unspecified.
class RevelProductionApiClientDeps {
  RevelProductionApiClientDeps({
    http.Client? httpClient,
    Uri? baseUri,
    Uri? oauthTokenUri,
    this.authMode = RevelAuthMode.oauth,
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 3,
    this.initialBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 32),
    this.pageLimit = 100,
    Future<void> Function(Duration delay)? sleep,
    Random? random,
    this.idempotencyKeyGenerator,
    DateTime Function()? clock,
  })  : httpClient = httpClient ?? http.Client(),
        baseUri = baseUri ?? _defaultBaseUri,
        oauthTokenUri = oauthTokenUri ?? _defaultOauthTokenUri,
        sleep = sleep ?? Future.delayed,
        random = random ?? Random.secure(),
        clock = clock ?? DateTime.now;

  final http.Client httpClient;
  final Uri baseUri;
  final Uri oauthTokenUri;
  final RevelAuthMode authMode;
  final Duration timeout;
  final int maxRetries;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final int pageLimit;
  final Future<void> Function(Duration delay) sleep;
  final Random random;
  final String Function()? idempotencyKeyGenerator;
  final DateTime Function() clock;

  static final Uri _defaultBaseUri = Uri.parse(
    documentedPerRevelV1['api_base_url']! as String,
  );
  static final Uri _defaultOauthTokenUri = Uri.parse(
    documentedPerRevelV1['oauth_token_url']! as String,
  );
}

/// Production HTTP implementation of [RevelTransport].
///
/// Default-constructed against Revel's documented production REST
/// endpoint (`https://api.revelsystems.com`). The OAuth token endpoint
/// (`https://authentication.revelup.com/oauth/token`) is used when
/// [RevelAuthMode.oauth] is selected. Both URIs are overridable via
/// [RevelProductionApiClientDeps] so an `*.live.sandbox` slice can
/// point at the Revel sandbox host without code change.
class RevelProductionApiClient implements RevelTransport {
  RevelProductionApiClient({RevelProductionApiClientDeps? deps})
      : _deps = deps ?? RevelProductionApiClientDeps();

  final RevelProductionApiClientDeps _deps;

  // ─── OAuth token exchange ────────────────────────────────────────

  @override
  Future<RevelTokenResponse> exchangeClientCredentials({
    required String clientId,
    required String clientSecret,
    required String audience,
  }) async {
    if (_deps.authMode == RevelAuthMode.apiKeyHeader) {
      // Legacy tier — synthesize an "access token" envelope the
      // adapter persists. Subsequent calls re-derive the API key +
      // secret from this envelope and emit them as the
      // API-AUTHENTICATION header. Expiration is set far in the
      // future so the OAuth refresh cron does not churn on it.
      final synthetic = '$clientId:$clientSecret';
      final farFuture = _deps.clock().toUtc().add(const Duration(days: 365));
      return RevelTokenResponse(
        accessToken: synthetic,
        expiresAt: farFuture,
      );
    }

    final body = <String, String>{
      'grant_type': documentedPerRevelV1['oauth_grant_type']! as String,
      'client_id': clientId,
      'client_secret': clientSecret,
      'audience': audience,
    };
    final response = await _runWithRetries(
      attempt: () => _deps.httpClient
          .post(
            _deps.oauthTokenUri,
            headers: <String, String>{
              'content-type': 'application/x-www-form-urlencoded',
              'accept': 'application/json',
            },
            body: body,
          )
          .timeout(_deps.timeout),
      operation: 'exchangeClientCredentials',
    );

    final json = _decodeJson(response.body, 'exchangeClientCredentials');
    final accessToken = json['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw RevelTransportException(
        kind: RevelTransportErrorKind.malformedResponse,
        message: 'OAuth response missing access_token',
        statusCode: response.statusCode,
        responseBodyPreview: _bodyPreview(response.body),
      );
    }

    final expiresIn = json['expires_in'];
    final ttlSeconds = (expiresIn is num)
        ? expiresIn.toInt()
        : (documentedPerRevelV1['oauth_access_ttl_seconds']! as int);
    final expiresAt = _deps.clock().toUtc().add(Duration(seconds: ttlSeconds));

    return RevelTokenResponse(
      accessToken: accessToken,
      expiresAt: expiresAt,
    );
  }

  // ─── Order list (pagination via offset/limit) ────────────────────

  @override
  Future<RevelOrdersPage> listOrders({
    required String accessToken,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    final offset = _parseOffsetCursor(cursor);
    final endpoint = documentedPerRevelV1['integrations_endpoint']! as String;
    final uri = _deps.baseUri.replace(
      pathSegments: <String>[
        ..._splitPath(_deps.baseUri.path),
        ..._splitPath(endpoint),
      ].where((s) => s.isNotEmpty).toList(growable: false),
      queryParameters: <String, String>{
        'modified_since': modifiedSince.toUtc().toIso8601String(),
        'modified_until': modifiedUntil.toUtc().toIso8601String(),
        'offset': offset.toString(),
        'limit': _deps.pageLimit.toString(),
      },
    );

    final response = await _runWithRetries(
      attempt: () => _deps.httpClient
          .get(uri, headers: _authHeaders(accessToken))
          .timeout(_deps.timeout),
      operation: 'listOrders',
    );

    final json = _decodeJson(response.body, 'listOrders');
    final records = _readRecords(json);
    final meta = json['meta'];
    int? nextOffset;
    DateTime? metaLastSeen;
    if (meta is Map) {
      final nextRaw = meta['next_offset'];
      if (nextRaw is num) {
        nextOffset = nextRaw.toInt();
      } else if (nextRaw is String) {
        nextOffset = int.tryParse(nextRaw);
      }
      // Some Revel deployments emit `total_count` / `count` instead of
      // a `next_offset`. Compute the next offset when the count tells
      // us there is more.
      if (nextOffset == null) {
        final totalCount = _readInt(meta['total_count']);
        if (totalCount != null && offset + records.length < totalCount) {
          nextOffset = offset + records.length;
        }
      }
      final lastRaw = meta['last_modified_seen'];
      if (lastRaw is String && lastRaw.isNotEmpty) {
        metaLastSeen = DateTime.tryParse(lastRaw)?.toUtc();
      }
    }

    final lastModifiedSeen = metaLastSeen ??
        _latestUpdatedDate(records) ??
        modifiedSince.toUtc();
    return RevelOrdersPage(
      records: records,
      nextCursor: nextOffset?.toString(),
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  // ─── Order fetch (single) ────────────────────────────────────────

  @override
  Future<Map<String, Object?>> fetchOrder({
    required String accessToken,
    required String orderId,
  }) async {
    final endpoint = documentedPerRevelV1['integrations_endpoint']! as String;
    final uri = _deps.baseUri.replace(
      pathSegments: <String>[
        ..._splitPath(_deps.baseUri.path),
        ..._splitPath(endpoint),
        orderId,
      ].where((s) => s.isNotEmpty).toList(growable: false),
    );
    final response = await _runWithRetries(
      attempt: () => _deps.httpClient
          .get(uri, headers: _authHeaders(accessToken))
          .timeout(_deps.timeout),
      operation: 'fetchOrder',
    );
    final json = _decodeJson(response.body, 'fetchOrder');
    final order = json['order'] ?? json;
    if (order is! Map) {
      throw RevelTransportException(
        kind: RevelTransportErrorKind.malformedResponse,
        message: 'fetchOrder response missing order envelope',
        statusCode: response.statusCode,
        responseBodyPreview: _bodyPreview(response.body),
      );
    }
    return Map<String, Object?>.from(order);
  }

  // ─── Webhook subscription register / unregister ──────────────────

  @override
  Future<String> registerWebhook({
    required String accessToken,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async {
    final endpoint = '${documentedPerRevelV1['integrations_endpoint']! as String}/webhooks';
    final uri = _deps.baseUri.replace(
      pathSegments: <String>[
        ..._splitPath(_deps.baseUri.path),
        ..._splitPath(endpoint),
      ].where((s) => s.isNotEmpty).toList(growable: false),
    );
    final idempotencyKey = _mintIdempotencyKey();
    final response = await _runWithRetries(
      attempt: () => _deps.httpClient
          .post(
            uri,
            headers: <String, String>{
              ..._authHeaders(accessToken),
              'content-type': 'application/json',
              'idempotency-key': idempotencyKey,
            },
            body: jsonEncode(<String, Object?>{
              'url': url,
              'events': events,
              'signing_secret': signingSecret,
            }),
          )
          .timeout(_deps.timeout),
      operation: 'registerWebhook',
    );
    final json = _decodeJson(response.body, 'registerWebhook');
    final id = json['subscription_id'] ?? json['id'];
    if (id is! String || id.isEmpty) {
      throw RevelTransportException(
        kind: RevelTransportErrorKind.malformedResponse,
        message: 'registerWebhook response missing subscription id',
        statusCode: response.statusCode,
        responseBodyPreview: _bodyPreview(response.body),
      );
    }
    return id;
  }

  @override
  Future<void> unregisterWebhook({
    required String accessToken,
    required String subscriptionId,
  }) async {
    final endpoint = '${documentedPerRevelV1['integrations_endpoint']! as String}/webhooks';
    final uri = _deps.baseUri.replace(
      pathSegments: <String>[
        ..._splitPath(_deps.baseUri.path),
        ..._splitPath(endpoint),
        subscriptionId,
      ].where((s) => s.isNotEmpty).toList(growable: false),
    );
    final idempotencyKey = _mintIdempotencyKey();
    await _runWithRetries(
      attempt: () => _deps.httpClient
          .delete(
            uri,
            headers: <String, String>{
              ..._authHeaders(accessToken),
              'idempotency-key': idempotencyKey,
            },
          )
          .timeout(_deps.timeout),
      operation: 'unregisterWebhook',
      allow404: true,
    );
  }

  // ─── Sample order (test connection) ──────────────────────────────

  @override
  Future<Map<String, Object?>> sampleOrder({
    required String accessToken,
  }) async {
    final endpoint = documentedPerRevelV1['integrations_endpoint']! as String;
    final uri = _deps.baseUri.replace(
      pathSegments: <String>[
        ..._splitPath(_deps.baseUri.path),
        ..._splitPath(endpoint),
      ].where((s) => s.isNotEmpty).toList(growable: false),
      queryParameters: <String, String>{
        'limit': '1',
        'sort': '-updated_date',
      },
    );
    final response = await _runWithRetries(
      attempt: () => _deps.httpClient
          .get(uri, headers: _authHeaders(accessToken))
          .timeout(_deps.timeout),
      operation: 'sampleOrder',
    );
    final json = _decodeJson(response.body, 'sampleOrder');
    final records = _readRecords(json);
    if (records.isEmpty) {
      return const <String, Object?>{};
    }
    return records.first;
  }

  // ─── Auth + pagination helpers ───────────────────────────────────

  Map<String, String> _authHeaders(String accessToken) {
    switch (_deps.authMode) {
      case RevelAuthMode.oauth:
        return <String, String>{
          'authorization': 'Bearer $accessToken',
          'accept': 'application/json',
        };
      case RevelAuthMode.apiKeyHeader:
        // The legacy access token is stored as `<key>:<secret>`.
        return <String, String>{
          'API-AUTHENTICATION': accessToken,
          'accept': 'application/json',
        };
    }
  }

  static int _parseOffsetCursor(String? cursor) {
    if (cursor == null || cursor.isEmpty) return 0;
    return int.tryParse(cursor) ?? 0;
  }

  static List<Map<String, Object?>> _readRecords(Map<String, Object?> json) {
    final candidates = <String>['records', 'orders', 'data', 'items'];
    for (final key in candidates) {
      final value = json[key];
      if (value is List) {
        return value
            .whereType<Map<Object?, Object?>>()
            .map<Map<String, Object?>>(
              (m) => Map<String, Object?>.from(m),
            )
            .toList(growable: false);
      }
    }
    return const <Map<String, Object?>>[];
  }

  static DateTime? _latestUpdatedDate(List<Map<String, Object?>> records) {
    DateTime? latest;
    for (final row in records) {
      final raw = row['updated_date'];
      if (raw is String && raw.isNotEmpty) {
        final parsed = DateTime.tryParse(raw)?.toUtc();
        if (parsed != null && (latest == null || parsed.isAfter(latest))) {
          latest = parsed;
        }
      }
    }
    return latest;
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static List<String> _splitPath(String path) {
    if (path.isEmpty) return const <String>[];
    return path.split('/').where((s) => s.isNotEmpty).toList(growable: false);
  }

  static String _bodyPreview(String body) {
    if (body.isEmpty) return '';
    return body.length <= 256 ? body : body.substring(0, 256);
  }

  Map<String, Object?> _decodeJson(String body, String operation) {
    if (body.isEmpty) {
      return const <String, Object?>{};
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        return Map<String, Object?>.from(decoded);
      }
      // Some Revel endpoints return a bare list. Wrap it so callers
      // see a uniform map shape.
      if (decoded is List) {
        return <String, Object?>{'records': decoded};
      }
      throw RevelTransportException(
        kind: RevelTransportErrorKind.malformedResponse,
        message: '$operation: response body is not a JSON object/array',
        responseBodyPreview: _bodyPreview(body),
      );
    } on FormatException catch (e) {
      throw RevelTransportException(
        kind: RevelTransportErrorKind.malformedResponse,
        message: '$operation: ${e.message}',
        responseBodyPreview: _bodyPreview(body),
      );
    }
  }

  String _mintIdempotencyKey() {
    final generator = _deps.idempotencyKeyGenerator;
    if (generator != null) {
      final key = generator();
      if (key.isNotEmpty) return key;
    }
    return _randomUuidV4(_deps.random);
  }

  // ─── Retry / backoff core ─────────────────────────────────────────

  Future<http.Response> _runWithRetries({
    required Future<http.Response> Function() attempt,
    required String operation,
    bool allow404 = false,
  }) async {
    var attemptNumber = 0;
    var delay = _deps.initialBackoff;
    String? lastBodyPreview;
    int? lastStatus;
    while (true) {
      attemptNumber += 1;
      http.Response? response;
      Object? networkError;
      try {
        response = await attempt();
      } on TimeoutException catch (e) {
        networkError = e;
      } on http.ClientException catch (e) {
        networkError = e;
      } catch (e) {
        networkError = e;
      }

      if (response != null) {
        final status = response.statusCode;
        lastStatus = status;
        lastBodyPreview = _bodyPreview(response.body);
        if (status >= 200 && status < 300) {
          return response;
        }
        if (status == 404 && allow404) {
          return response;
        }
        if (status == 429) {
          if (attemptNumber > _deps.maxRetries) {
            throw RevelTransportException(
              kind: RevelTransportErrorKind.rateLimited,
              message: '$operation: 429 retry budget exhausted',
              statusCode: status,
              responseBodyPreview: lastBodyPreview,
            );
          }
          final wait = _retryAfterFromHeader(response.headers) ??
              _expBackoffWithJitter(delay);
          await _deps.sleep(wait);
          delay = _nextBackoff(delay);
          continue;
        }
        if (status >= 500 && status < 600) {
          if (attemptNumber > _deps.maxRetries) {
            throw RevelTransportException(
              kind: RevelTransportErrorKind.serverError,
              message: '$operation: $status retry budget exhausted',
              statusCode: status,
              responseBodyPreview: lastBodyPreview,
            );
          }
          await _deps.sleep(_expBackoffWithJitter(delay));
          delay = _nextBackoff(delay);
          continue;
        }
        // Non-retryable 4xx — translate kind and throw.
        throw RevelTransportException(
          kind: _kindForClientStatus(status),
          message: '$operation: HTTP $status',
          statusCode: status,
          responseBodyPreview: lastBodyPreview,
        );
      }

      // Network error path.
      if (attemptNumber > _deps.maxRetries) {
        throw RevelTransportException(
          kind: RevelTransportErrorKind.network,
          message: '$operation: network failure: $networkError',
          statusCode: lastStatus,
          responseBodyPreview: lastBodyPreview,
        );
      }
      await _deps.sleep(_expBackoffWithJitter(delay));
      delay = _nextBackoff(delay);
    }
  }

  static RevelTransportErrorKind _kindForClientStatus(int status) {
    switch (status) {
      case 401:
        return RevelTransportErrorKind.unauthorized;
      case 403:
        return RevelTransportErrorKind.forbidden;
      case 404:
        return RevelTransportErrorKind.notFound;
      default:
        return RevelTransportErrorKind.badRequest;
    }
  }

  Duration? _retryAfterFromHeader(Map<String, String> headers) {
    String? value;
    headers.forEach((k, v) {
      if (k.toLowerCase() == 'retry-after') value = v;
    });
    final raw = value;
    if (raw == null || raw.isEmpty) return null;
    final secs = int.tryParse(raw);
    if (secs != null && secs >= 0) {
      return Duration(seconds: min(secs, _deps.maxBackoff.inSeconds));
    }
    final asDate = DateTime.tryParse(raw);
    if (asDate != null) {
      final now = _deps.clock().toUtc();
      final diff = asDate.toUtc().difference(now);
      if (diff.isNegative) return Duration.zero;
      if (diff > _deps.maxBackoff) return _deps.maxBackoff;
      return diff;
    }
    return null;
  }

  Duration _nextBackoff(Duration current) {
    final next = current * 2;
    if (next > _deps.maxBackoff) return _deps.maxBackoff;
    return next;
  }

  Duration _expBackoffWithJitter(Duration base) {
    // Full-jitter — pick a uniform sample in [0, base]. Capped to
    // maxBackoff. Tests inject a deterministic Random so this is
    // reproducible.
    final capped = base > _deps.maxBackoff ? _deps.maxBackoff : base;
    final ms = capped.inMilliseconds;
    if (ms <= 0) return Duration.zero;
    final jittered = _deps.random.nextInt(ms + 1);
    return Duration(milliseconds: jittered);
  }
}

// ─── UUID v4 minting (no external dep) ─────────────────────────────

String _randomUuidV4(Random rng) {
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  // Set version (4) and variant (10xx) bits per RFC 4122.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int byte) => byte.toRadixString(16).padLeft(2, '0');
  final sb = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) sb.write('-');
    sb.write(hex(bytes[i]));
  }
  return sb.toString();
}
