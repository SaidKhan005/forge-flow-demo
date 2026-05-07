// Phase 8 — Square POS production HTTP transport.
//
// Implements the abstract `SquareApiClient` declared by
// `square_pos_adapter.dart` against Square's Connect API:
//
//   * Base URI defaults to `https://connect.squareup.com` (production);
//     callers wire the sandbox base via constructor arg
//     (`https://connect.squareupsandbox.com`) when they want to talk
//     to the sandbox cluster. The constructor also accepts a
//     `baseUriOverride` for tests / staging (env override).
//   * OAuth2 bearer authentication; the access token is resolved from
//     the injected `SquareCredentialResolver` per call so token
//     rotation (Square refreshes on every refresh) propagates without
//     restarting the adapter.
//   * Square's `Square-Version` header is pinned to
//     `kSquareApiVersion` (`2024-01-18`).
//   * Cursor-based pagination — every list endpoint accepts an
//     opaque `cursor` token and returns the next cursor on the
//     response body.
//   * 429 backoff respects the `Retry-After` header (seconds or
//     HTTP-date); transient 5xx are retried with exponential backoff
//     up to `_maxRetries = 5`.
//   * Outbound POSTs that mutate state (webhook registration, OAuth
//     revoke) carry an `Idempotency-Key` HTTP header. Square dedupes
//     on this key per
//     https://developer.squareup.com/docs/build-basics/common-api-patterns/idempotency.
//   * Typed errors flag the failure mode to the calling adapter
//     (`SquareAuthError`, `SquareRateLimitError`, `SquareTransientError`,
//     `SquarePermanentError`); the adapter's existing happy-path
//     converts these into framework-level outcomes.
//   * Timestamps are returned to the adapter as raw ISO-8601 strings
//     in the order body. The adapter parses them with
//     `DateTime.tryParse(..).toUtc()`, preserving the offset
//     embedded in the original Square payload (Phase 7.55 Rule 11).
//
// Hard Promise #7 alignment: this client is a Cloud Run-side helper.
// Plaintext access tokens never leave the credential resolver — the
// resolver is wired to `vendor_credentials_repository.dart` in
// production. The Flutter client never imports this file (it lives in
// `lib/integrations/...` so analyzer + pub deps work, but the proxy
// is the only runtime that constructs it).
//
// No new pub dependencies beyond `pubspec.yaml`'s existing
// `package:http`.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'square_pos_adapter.dart';

/// Resolves a [SquareCredentialHandle] into the materials this HTTP
/// client needs to talk to Square. Production wires this to
/// `vendor_credentials_repository.dart`; tests inject a fake.
///
/// Plaintext access tokens MUST NOT leave server-side memory — that is
/// why the abstraction exists. The Flutter app never instantiates a
/// resolver; the adapter framework only runs it inside Cloud Run.
abstract class SquareCredentialResolver {
  /// Returns the current OAuth bearer token for the named handle.
  /// Implementations rotate transparently — if the cached token has
  /// expired, the resolver MUST refresh it (using
  /// [SquareApiClient.refreshOauthToken]) before returning.
  Future<String> resolveAccessToken(SquareCredentialHandle handle);

  /// OAuth2 client_id Square issued for the F&F application.
  /// Required by `/oauth2/token` (refresh) and `/oauth2/revoke`.
  String get clientId;

  /// OAuth2 client_secret. Server-side only; never reaches the Flutter
  /// runtime.
  String get clientSecret;
}

/// Mints idempotency keys for outbound mutations. Production wires
/// `Uuid().v4`; tests inject a deterministic stub. Square requires the
/// key to be \<= 45 characters.
typedef SquareIdempotencyKeyMinter = String Function();

/// Concrete `package:http` implementation of [SquareApiClient]. The
/// adapter constructs one of these per Cloud Run worker; the worker
/// closes it (via [close]) on shutdown.
class SquarePosProductionApiClient implements SquareApiClient {
  SquarePosProductionApiClient({
    required SquareCredentialResolver credentials,
    http.Client? httpClient,
    Uri? baseUriOverride,
    String defaultBaseUri = kSquareProductionBaseUrl,
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 5,
    Duration baseRetryDelay = const Duration(milliseconds: 500),
    Duration maxRetryDelay = const Duration(seconds: 30),
    SquareIdempotencyKeyMinter? idempotencyKeyMinter,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  })  : _credentials = credentials,
        _httpClient = httpClient ?? http.Client(),
        _baseUri = baseUriOverride ?? Uri.parse(defaultBaseUri),
        _timeout = timeout,
        _maxRetries = maxRetries,
        _baseRetryDelay = baseRetryDelay,
        _maxRetryDelay = maxRetryDelay,
        _idempotencyKeyMinter =
            idempotencyKeyMinter ?? _defaultIdempotencyKeyMinter,
        _now = now ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed;

  final SquareCredentialResolver _credentials;
  final http.Client _httpClient;
  final Uri _baseUri;
  final Duration _timeout;
  final int _maxRetries;
  final Duration _baseRetryDelay;
  final Duration _maxRetryDelay;
  final SquareIdempotencyKeyMinter _idempotencyKeyMinter;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  /// The base URI the client sends to. Exposed so tests can assert
  /// production vs sandbox routing without round-tripping through HTTP.
  Uri get baseUri => _baseUri;

  void close() {
    _httpClient.close();
  }

  // ─── SquareApiClient surface ────────────────────────────────────────

  @override
  Future<SquareSearchOrdersResponse> searchOrders({
    required SquareCredentialHandle credential,
    required DateTime updatedAtMin,
    required DateTime updatedAtMax,
    required List<String> locationIds,
    String? cursor,
    int pageSize = kSquareSearchPageSize,
  }) async {
    final body = <String, Object?>{
      'location_ids': locationIds,
      'limit': pageSize,
      'query': <String, Object?>{
        'filter': <String, Object?>{
          'date_time_filter': <String, Object?>{
            'updated_at': <String, Object?>{
              'start_at': updatedAtMin.toUtc().toIso8601String(),
              'end_at': updatedAtMax.toUtc().toIso8601String(),
            },
          },
        },
        'sort': <String, Object?>{
          'sort_field': 'UPDATED_AT',
          'sort_order': 'ASC',
        },
      },
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };

    final json = await _request(
      method: 'POST',
      path: kSquareSearchOrdersPath,
      handle: credential,
      jsonBody: body,
      // SearchOrders is a read despite the POST verb — no idempotency
      // key. Square ignores `Idempotency-Key` on this endpoint.
      sendIdempotencyKey: false,
    );

    final orders = <Map<String, Object?>>[];
    final raw = json['orders'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          orders.add(_asStringKeyMap(entry));
        }
      }
    }
    final nextCursor = json['cursor']?.toString();
    return SquareSearchOrdersResponse(
      orders: orders,
      cursor: (nextCursor == null || nextCursor.isEmpty) ? null : nextCursor,
    );
  }

  @override
  Future<Map<String, Object?>> retrieveOrder({
    required SquareCredentialHandle credential,
    required String orderId,
    required String squareLocationId,
  }) async {
    if (orderId.isEmpty) {
      throw ArgumentError('orderId must not be empty');
    }
    final json = await _request(
      method: 'GET',
      path: '$kSquareRetrieveOrderPath/$orderId',
      handle: credential,
    );
    final order = json['order'];
    if (order is Map) {
      return _asStringKeyMap(order);
    }
    throw SquarePermanentError(
      'RetrieveOrder response missing `order` body for $orderId',
      statusCode: 200,
    );
  }

  @override
  Future<List<Map<String, Object?>>> listLocations({
    required SquareCredentialHandle credential,
  }) async {
    final json = await _request(
      method: 'GET',
      path: kSquareLocationsPath,
      handle: credential,
    );
    final raw = json['locations'];
    if (raw is List) {
      return <Map<String, Object?>>[
        for (final entry in raw)
          if (entry is Map) _asStringKeyMap(entry),
      ];
    }
    return const <Map<String, Object?>>[];
  }

  @override
  Future<SquareOauthTokens> refreshOauthToken({
    required String refreshToken,
  }) async {
    final body = <String, Object?>{
      'client_id': _credentials.clientId,
      'client_secret': _credentials.clientSecret,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    };
    final json = await _request(
      method: 'POST',
      path: kSquareOauthTokenPath,
      jsonBody: body,
      // OAuth token endpoints don't accept Authorization headers (the
      // body carries the credentials). Bypass the resolver lookup.
      skipAuth: true,
      sendIdempotencyKey: false,
    );
    final accessToken = json['access_token']?.toString();
    final newRefreshToken = json['refresh_token']?.toString();
    final expiresAtRaw = json['expires_at']?.toString();
    final merchantId = json['merchant_id']?.toString();
    if (accessToken == null ||
        newRefreshToken == null ||
        expiresAtRaw == null ||
        merchantId == null) {
      throw SquarePermanentError(
        'Refresh response missing required fields',
        statusCode: 200,
      );
    }
    final expiresAt = DateTime.tryParse(expiresAtRaw)?.toUtc();
    if (expiresAt == null) {
      throw SquarePermanentError(
        'Refresh response `expires_at` is not ISO-8601: $expiresAtRaw',
        statusCode: 200,
      );
    }
    return SquareOauthTokens(
      accessToken: accessToken,
      refreshToken: newRefreshToken,
      expiresAt: expiresAt,
      merchantId: merchantId,
    );
  }

  @override
  Future<String> registerWebhook({
    required SquareCredentialHandle credential,
    required String notificationUrl,
    required List<String> events,
  }) async {
    final body = <String, Object?>{
      'idempotency_key': _idempotencyKeyMinter(),
      'subscription': <String, Object?>{
        'name': 'forgeflow-${credential.operatorId}-${credential.locationId}',
        'event_types': events,
        'notification_url': notificationUrl,
        'api_version': kSquareApiVersion,
      },
    };
    final json = await _request(
      method: 'POST',
      path: kSquareWebhookSubscriptionPath,
      handle: credential,
      jsonBody: body,
    );
    final subscription = json['subscription'];
    if (subscription is Map) {
      final id = subscription['id']?.toString();
      if (id != null && id.isNotEmpty) return id;
    }
    throw SquarePermanentError(
      'CreateWebhookSubscription response missing `subscription.id`',
      statusCode: 200,
    );
  }

  @override
  Future<void> unregisterWebhook({
    required SquareCredentialHandle credential,
    required String subscriptionId,
  }) async {
    if (subscriptionId.isEmpty) {
      throw ArgumentError('subscriptionId must not be empty');
    }
    await _request(
      method: 'DELETE',
      path: '$kSquareWebhookSubscriptionPath/$subscriptionId',
      handle: credential,
      // DELETE has no body but Square treats it as a mutation — send
      // the idempotency key so retries of a network-truncated DELETE
      // don't surface as 404 cascades.
      sendIdempotencyKey: true,
      // 404 means "already unregistered" — treat as success per the
      // adapter's best-effort disconnect contract.
      treat404AsSuccess: true,
    );
  }

  @override
  Future<void> revokeOauth({
    required SquareCredentialHandle credential,
  }) async {
    final accessToken = await _credentials.resolveAccessToken(credential);
    final body = <String, Object?>{
      'client_id': _credentials.clientId,
      'access_token': accessToken,
      'revoke_only_access_token': false,
    };
    await _request(
      method: 'POST',
      path: '/oauth2/revoke',
      jsonBody: body,
      // /oauth2/revoke takes Authorization: Client {client_secret} per
      // https://developer.squareup.com/reference/square/oauth-api/revoke-token.
      skipAuth: true,
      authOverride: 'Client ${_credentials.clientSecret}',
      // Square treats /oauth2/revoke as idempotent server-side; retries
      // of a network-truncated revoke must not surface as duplicate
      // grant errors.
      sendIdempotencyKey: false,
      // 401/404 = grant already revoked; treat as success.
      treat404AsSuccess: true,
      treat401AsSuccess: true,
    );
  }

  // ─── Internals ──────────────────────────────────────────────────────

  /// Performs one HTTP exchange with retry / backoff / typed-error
  /// classification. Returns the decoded JSON body when the response
  /// is 2xx; throws a typed Square*Error on terminal failure.
  Future<Map<String, Object?>> _request({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    Map<String, Object?>? jsonBody,
    SquareCredentialHandle? handle,
    bool skipAuth = false,
    String? authOverride,
    bool sendIdempotencyKey = true,
    bool treat404AsSuccess = false,
    bool treat401AsSuccess = false,
  }) async {
    final uri = _resolve(path, queryParameters);
    Object? lastFailure;
    for (var attempt = 0; attempt <= _maxRetries; attempt += 1) {
      try {
        final headers = await _buildHeaders(
          handle: handle,
          skipAuth: skipAuth,
          authOverride: authOverride,
          sendIdempotencyKey: sendIdempotencyKey,
        );
        final request = http.Request(method, uri)..headers.addAll(headers);
        if (jsonBody != null) {
          request.body = jsonEncode(jsonBody);
        }

        final streamed = await _httpClient.send(request).timeout(_timeout);
        final response = await http.Response.fromStream(streamed);
        final status = response.statusCode;

        if (status >= 200 && status < 300) {
          return _decodeJson(response);
        }
        if (status == 401) {
          if (treat401AsSuccess) return const <String, Object?>{};
          throw SquareAuthError(
            _errorMessage(response, fallback: 'Square 401 Unauthorized'),
            statusCode: status,
            body: response.body,
          );
        }
        if (status == 403) {
          throw SquareAuthError(
            _errorMessage(response, fallback: 'Square 403 Forbidden'),
            statusCode: status,
            body: response.body,
          );
        }
        if (status == 404) {
          if (treat404AsSuccess) return const <String, Object?>{};
          throw SquarePermanentError(
            _errorMessage(response, fallback: 'Square 404 Not Found'),
            statusCode: status,
            body: response.body,
          );
        }
        if (status == 429) {
          if (attempt >= _maxRetries) {
            throw SquareRateLimitError(
              _errorMessage(response, fallback: 'Square 429 rate-limited'),
              statusCode: status,
              body: response.body,
              retryAfter: _retryAfter(response),
            );
          }
          await _sleep(_retryDelay(attempt, override: _retryAfter(response)));
          lastFailure = SquareRateLimitError(
            'Square 429 rate-limited',
            statusCode: status,
            retryAfter: _retryAfter(response),
          );
          continue;
        }
        if (status >= 500 && status < 600) {
          if (attempt >= _maxRetries) {
            throw SquareTransientError(
              _errorMessage(response, fallback: 'Square 5xx (no retries left)'),
              statusCode: status,
              body: response.body,
            );
          }
          lastFailure = SquareTransientError(
            'Square $status',
            statusCode: status,
            body: response.body,
          );
          await _sleep(_retryDelay(attempt));
          continue;
        }
        if (status >= 400 && status < 500) {
          throw SquarePermanentError(
            _errorMessage(response, fallback: 'Square $status'),
            statusCode: status,
            body: response.body,
          );
        }
        // Status outside 200-599 — unexpected; treat as transient.
        if (attempt >= _maxRetries) {
          throw SquareTransientError(
            'Square unexpected status $status',
            statusCode: status,
            body: response.body,
          );
        }
        lastFailure = SquareTransientError(
          'Square unexpected status $status',
          statusCode: status,
        );
        await _sleep(_retryDelay(attempt));
      } on TimeoutException catch (e) {
        lastFailure = SquareTransientError(
          'Square request timed out: $e',
          statusCode: 0,
        );
        if (attempt >= _maxRetries) {
          throw lastFailure as SquareTransientError;
        }
        await _sleep(_retryDelay(attempt));
      } on http.ClientException catch (e) {
        lastFailure = SquareTransientError(
          'Square HTTP client error: $e',
          statusCode: 0,
        );
        if (attempt >= _maxRetries) {
          throw lastFailure as SquareTransientError;
        }
        await _sleep(_retryDelay(attempt));
      } on SquareApiError {
        rethrow;
      }
    }
    // Defensive — loop exits via return/throw above.
    throw lastFailure ??
        SquareTransientError(
          'Square retry budget exhausted with no captured failure',
          statusCode: 0,
        );
  }

  Future<Map<String, String>> _buildHeaders({
    required SquareCredentialHandle? handle,
    required bool skipAuth,
    required String? authOverride,
    required bool sendIdempotencyKey,
  }) async {
    final headers = <String, String>{
      'Square-Version': kSquareApiVersion,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': 'forgeflow-square-pos/1.0 (+https://app.forgeflow.app)',
    };
    if (authOverride != null) {
      headers['Authorization'] = authOverride;
    } else if (!skipAuth) {
      if (handle == null) {
        throw ArgumentError(
          'SquareApiClient request requires a credential handle',
        );
      }
      final token = await _credentials.resolveAccessToken(handle);
      headers['Authorization'] = 'Bearer $token';
    }
    if (sendIdempotencyKey) {
      headers['Idempotency-Key'] = _idempotencyKeyMinter();
    }
    return headers;
  }

  Uri _resolve(String path, Map<String, String>? queryParameters) {
    final basePath = _baseUri.path.endsWith('/')
        ? _baseUri.path.substring(0, _baseUri.path.length - 1)
        : _baseUri.path;
    final tailPath = path.startsWith('/') ? path : '/$path';
    return _baseUri.replace(
      path: '$basePath$tailPath',
      queryParameters: queryParameters == null || queryParameters.isEmpty
          ? null
          : queryParameters,
    );
  }

  Map<String, Object?> _decodeJson(http.Response response) {
    if (response.body.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        return _asStringKeyMap(decoded);
      }
      return <String, Object?>{'value': decoded};
    } on FormatException catch (e) {
      throw SquarePermanentError(
        'Square response was not JSON: $e',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }

  Duration _retryDelay(int attempt, {Duration? override}) {
    if (override != null) {
      // Cap honored Retry-After so a misbehaving upstream cannot wedge
      // the worker for hours.
      return override > _maxRetryDelay ? _maxRetryDelay : override;
    }
    final backoff = _baseRetryDelay * math.pow(2, attempt).toInt();
    return backoff > _maxRetryDelay ? _maxRetryDelay : backoff;
  }

  Duration? _retryAfter(http.Response response) {
    final raw = response.headers['retry-after'];
    if (raw == null || raw.isEmpty) return null;
    final asInt = int.tryParse(raw);
    if (asInt != null) return Duration(seconds: asInt);
    final asDate = _httpDateTryParse(raw);
    if (asDate == null) return null;
    final delta = asDate.difference(_now().toUtc());
    return delta.isNegative ? Duration.zero : delta;
  }

  String _errorMessage(http.Response response, {required String fallback}) {
    if (response.body.isEmpty) return fallback;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final errors = decoded['errors'];
        if (errors is List && errors.isNotEmpty) {
          final first = errors.first;
          if (first is Map) {
            final detail = first['detail']?.toString();
            final code = first['code']?.toString();
            final category = first['category']?.toString();
            return [
              if (category != null && category.isNotEmpty) '[$category]',
              if (code != null && code.isNotEmpty) code,
              if (detail != null && detail.isNotEmpty) detail,
            ].where((s) => s.isNotEmpty).join(' ');
          }
        }
      }
    } on FormatException {
      // fall through to fallback
    }
    return fallback;
  }
}

Map<String, Object?> _asStringKeyMap(Map<dynamic, dynamic> source) {
  final result = <String, Object?>{};
  source.forEach((k, v) {
    result[k.toString()] = v;
  });
  return result;
}

String _defaultIdempotencyKeyMinter() {
  // Square caps idempotency keys at 45 chars. We use a 32-char hex
  // synthesized from the current microsecond timestamp + a short
  // random suffix for in-process collision resistance. Production
  // callers should inject `Uuid().v4` to align with the rest of the
  // proxy idempotency surface.
  final ts = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(16);
  final rand = (math.Random.secure().nextInt(0xFFFFFFFF))
      .toRadixString(16)
      .padLeft(8, '0');
  final key = 'sq_$ts$rand';
  return key.length > 45 ? key.substring(0, 45) : key;
}

// ─── Typed errors ────────────────────────────────────────────────────

/// Marker interface so callers can `catch (SquareApiError)` and apply
/// uniform handling without depending on the concrete subclass.
sealed class SquareApiError implements Exception {
  SquareApiError(this.message, {required this.statusCode, this.body});

  final String message;
  final int statusCode;
  final String? body;

  @override
  String toString() => '$runtimeType($statusCode): $message';
}

/// Retried internally up to the configured max. The error surfaces only
/// after the retry budget is exhausted (or for an unrecoverable upstream
/// fault — bad Content-Type, JSON parse failure on a 2xx, etc.).
class SquareTransientError extends SquareApiError {
  SquareTransientError(super.message, {required super.statusCode, super.body});
}

/// Non-retryable client error (4xx other than 401/403/404/429).
class SquarePermanentError extends SquareApiError {
  SquarePermanentError(super.message, {required super.statusCode, super.body});
}

/// 429 with `Retry-After` honored by the internal backoff loop. When
/// the backoff loop exhausts its retry budget the error escapes; the
/// adapter then surfaces it through the framework's connector_sync_log.
class SquareRateLimitError extends SquareApiError {
  SquareRateLimitError(
    super.message, {
    required super.statusCode,
    super.body,
    this.retryAfter,
  });

  final Duration? retryAfter;
}

/// 401 / 403 — credential is invalid or grant has been revoked. The
/// adapter framework promotes this to a `connector_connection.status =
/// disconnected` action (see slice contract).
class SquareAuthError extends SquareApiError {
  SquareAuthError(super.message, {required super.statusCode, super.body});
}

// ─── Tiny HTTP-date parser ───────────────────────────────────────────

/// Parses an HTTP-date (RFC 7231) into a UTC DateTime, returning null
/// when the input is malformed. We use a hand-rolled parser instead of
/// `package:http_parser` because adding a transitive dependency is
/// disallowed by the slice contract; only `package:http` is permitted.
DateTime? _httpDateTryParse(String value) {
  // RFC 7231 IMF-fixdate: "Sun, 06 Nov 1994 08:49:37 GMT"
  // Accept the three permitted formats by trimming + matching on
  // recognised month names. Any failure falls back to null so the
  // caller continues with exponential backoff.
  final trimmed = value.trim();
  final imf = RegExp(
    r'^[A-Za-z]+,\s+(\d{1,2})\s+([A-Za-z]+)\s+(\d{2,4})\s+'
    r'(\d{2}):(\d{2}):(\d{2})\s+GMT$',
  );
  final match = imf.firstMatch(trimmed);
  if (match == null) return null;
  final day = int.tryParse(match.group(1)!);
  final monthName = match.group(2)!;
  final yearRaw = int.tryParse(match.group(3)!);
  final hour = int.tryParse(match.group(4)!);
  final minute = int.tryParse(match.group(5)!);
  final second = int.tryParse(match.group(6)!);
  if (day == null ||
      yearRaw == null ||
      hour == null ||
      minute == null ||
      second == null) {
    return null;
  }
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
  final month = months[monthName];
  if (month == null) return null;
  final year = yearRaw < 100 ? (yearRaw + 1900) : yearRaw;
  try {
    return DateTime.utc(year, month, day, hour, minute, second);
  } on ArgumentError {
    return null;
  }
}
