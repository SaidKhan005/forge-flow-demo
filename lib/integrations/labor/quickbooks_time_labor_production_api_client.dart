// Phase 8 / `8.transport.quickbooks-time-labor` — production HTTP
// transport for the QuickBooks Time (TSheets) labor adapter.
//
// Authority (read in this order):
//   1. The active prompt (`8.transport.quickbooks-time-labor`).
//   2. `lib/integrations/labor/quickbooks_time_labor_adapter.dart`
//      — abstract [QuickBooksTimeTransport] surface this client
//      implements (DO NOT modify the abstract).
//   3. `docs/integrations/quickbooks_time/api_consumed.md` and
//      `oauth_shape.md` — documented field shape this transport
//      mirrors.
//
// What this file is:
//
//   * The concrete `QuickBooksTimeTransport` implementation that talks
//     to the real QuickBooks Time / TSheets developer API. The
//     `*.live.sandbox` / `*.live.prod` rolling slices instantiate this
//     against issued credentials; tests inject a fake `http.Client`.
//
// What this file is NOT:
//
//   * Not a credential store — bearer access tokens are loaded from
//     [QuickBooksTimeCredentialStore] (a tiny dependency injected at
//     construction). The store contract intentionally does NOT touch
//     the database; production wires it to the operator-scoped
//     credential gateway.
//   * Not a side-effect channel — every method is request/response.
//     Idempotency keys are generated per write and propagated to the
//     proxy (per CLAUDE.md "Every proxy write is idempotent.").
//
// Conventions:
//
//   * Default [baseUri] is `https://rest.tsheets.com/api/v1` per the
//     QuickBooks Time developer portal. Operators can override at
//     construction (sandbox endpoint, regional Intuit data residency,
//     etc.).
//   * Default [oauthBaseUri] is `https://oauth.platform.intuit.com`
//     because the OAuth 2.0 token + revoke endpoints live on Intuit's
//     OAuth host (NOT `rest.tsheets.com`). The two hosts are deliberate
//     — see `oauth_shape.md`.
//   * 429 handling: respect `Retry-After` when present; otherwise
//     exponential backoff (200ms, 400ms, 800ms) with a hard cap of
//     three retries. After the cap the client throws a typed
//     [QuickBooksTimeRateLimitException] so the caller can decide
//     whether to surface to the operator or retry on the next polling
//     tick.
//   * 401 handling: raise [QuickBooksTimeAuthException] without
//     retrying. The framework's refresh-token path is the policy
//     owner; this transport never refreshes silently.
//   * Other 4xx/5xx: raise [QuickBooksTimeApiException] with the
//     status code + truncated body for upstream surfacing.
//   * TIMESTAMPTZ preserved: every documented timestamp field
//     (`start`, `end`, `last_modified`) is read as a string and parsed
//     as UTC by the adapter mapper, never reformatted here. The
//     transport simply hands raw vendor JSON back to the adapter.
//
// No new pub deps. Only `package:http` (already in `pubspec.yaml`).

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'quickbooks_time_labor_adapter.dart';

/// Default base URI for the QuickBooks Time / TSheets developer API.
/// The TSheets brand still serves the v1 REST API at `rest.tsheets.com`
/// even after the Intuit rebrand to "QuickBooks Time"; the developer
/// portal at https://tsheetsteam.github.io/api_docs/ confirms the host.
const String kQuickBooksTimeDefaultBaseUri =
    'https://rest.tsheets.com/api/v1';

/// Default base URI for the Intuit OAuth 2.0 token + revoke endpoints.
/// The endpoints documented at https://developer.intuit.com/app/developer/
/// (Account > OAuth 2.0) live on the Intuit OAuth host, NOT on
/// `rest.tsheets.com`.
const String kQuickBooksTimeDefaultOauthBaseUri =
    'https://oauth.platform.intuit.com';

/// Source of bearer access tokens for the live transport. Kept as a
/// tiny interface so the concrete client never touches the operator
/// credential store directly — production wires this to the
/// operator-scoped credential gateway; tests inject a fixed string.
abstract class QuickBooksTimeCredentialStore {
  /// Returns the active QBT OAuth bearer access token. Throws
  /// [QuickBooksTimeAuthException] if no token is available.
  Future<String> readAccessToken();
}

/// Trivial in-memory implementation used by tests and the local demo
/// runtime. Never use in production — use the operator credential
/// gateway instead.
class StaticQuickBooksTimeCredentialStore
    implements QuickBooksTimeCredentialStore {
  StaticQuickBooksTimeCredentialStore(this._token);

  final String _token;

  @override
  Future<String> readAccessToken() async => _token;
}

/// Source of OAuth client credentials for the token + revoke endpoints.
/// Tests inject literals; production reads from server-side env / KMS.
abstract class QuickBooksTimeOauthClientCredentials {
  String get clientId;
  String get clientSecret;
}

/// Trivial literal credentials used by tests + local dev. Production
/// reads from server-side env / KMS.
class StaticQuickBooksTimeOauthClientCredentials
    implements QuickBooksTimeOauthClientCredentials {
  const StaticQuickBooksTimeOauthClientCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  @override
  final String clientId;
  @override
  final String clientSecret;
}

/// Idempotency-key generator. Pulled out so tests can inject a
/// deterministic key. Production binds to a UUIDv4 generator.
typedef QuickBooksTimeIdempotencyKeyFactory = String Function();

String _defaultIdempotencyKeyFactory() {
  final now = DateTime.now().toUtc();
  final rand = math.Random.secure();
  final entropy = List<int>.generate(8, (_) => rand.nextInt(256));
  final hex =
      entropy.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'qbt-${now.microsecondsSinceEpoch}-$hex';
}

/// Dependency record handed to [QuickBooksTimeLaborProductionApiClient]
/// at construction. Mirrors the "Deps record" shape used elsewhere in
/// the integrations layer so wiring sites can compose dependencies in
/// one place without long argument lists.
class QuickBooksTimeProductionApiClientDeps {
  QuickBooksTimeProductionApiClientDeps({
    required this.credentials,
    required this.oauthCredentials,
    Uri? baseUri,
    Uri? oauthBaseUri,
    http.Client? httpClient,
    Duration? timeout,
    QuickBooksTimeIdempotencyKeyFactory? idempotencyKeyFactory,
    Duration Function(int)? backoffStrategy,
    int? maxRetries,
  })  : baseUri = baseUri ?? Uri.parse(kQuickBooksTimeDefaultBaseUri),
        oauthBaseUri = oauthBaseUri ??
            Uri.parse(kQuickBooksTimeDefaultOauthBaseUri),
        httpClient = httpClient ?? http.Client(),
        timeout = timeout ?? const Duration(seconds: 30),
        idempotencyKeyFactory =
            idempotencyKeyFactory ?? _defaultIdempotencyKeyFactory,
        backoffStrategy = backoffStrategy ?? _defaultBackoff,
        maxRetries = maxRetries ?? 3;

  /// Source of the per-call bearer access token.
  final QuickBooksTimeCredentialStore credentials;

  /// Source of OAuth client credentials (client_id + client_secret) for
  /// token exchange and revoke calls.
  final QuickBooksTimeOauthClientCredentials oauthCredentials;

  /// Base URI for the TSheets v1 REST API (e.g.
  /// `https://rest.tsheets.com/api/v1`).
  final Uri baseUri;

  /// Base URI for the Intuit OAuth host (e.g.
  /// `https://oauth.platform.intuit.com`).
  final Uri oauthBaseUri;

  /// Injected HTTP client. Production passes a long-lived
  /// `http.Client()`; tests pass `MockClient`.
  final http.Client httpClient;

  /// Per-request timeout (applies to each individual HTTP attempt;
  /// retries get fresh timeouts).
  final Duration timeout;

  /// Generator for the `Idempotency-Key` header on POSTs.
  final QuickBooksTimeIdempotencyKeyFactory idempotencyKeyFactory;

  /// Backoff schedule for 429s. Receives the zero-based retry attempt
  /// number, returns the wait duration before the next retry.
  final Duration Function(int attempt) backoffStrategy;

  /// Maximum 429 retries before throwing
  /// [QuickBooksTimeRateLimitException].
  final int maxRetries;
}

Duration _defaultBackoff(int attempt) {
  // 200ms, 400ms, 800ms, 1600ms ... bounded by [maxRetries].
  final ms = 200 * (1 << attempt);
  return Duration(milliseconds: ms);
}

/// Concrete `QuickBooksTimeTransport` over `package:http`.
class QuickBooksTimeLaborProductionApiClient
    implements QuickBooksTimeTransport {
  QuickBooksTimeLaborProductionApiClient(this._deps);

  final QuickBooksTimeProductionApiClientDeps _deps;

  // ─── OAuth ─────────────────────────────────────────────────────────

  @override
  Future<QuickBooksTimeTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  }) async {
    final body = <String, String>{
      'grant_type': 'authorization_code',
      'code': authorizationCode,
      'redirect_uri': redirectUri,
    };
    final json = await _postOauthForm(
      path: const <String>['oauth2', 'v1', 'tokens', 'bearer'],
      formBody: body,
    );
    return _decodeTokenResponse(json);
  }

  @override
  Future<QuickBooksTimeTokenResponse> refresh({
    required String refreshToken,
  }) async {
    final body = <String, String>{
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    };
    final json = await _postOauthForm(
      path: const <String>['oauth2', 'v1', 'tokens', 'bearer'],
      formBody: body,
    );
    return _decodeTokenResponse(json);
  }

  @override
  Future<void> revoke({required String refreshToken}) async {
    final body = <String, String>{'token': refreshToken};
    // Intuit's revoke endpoint lives at
    // /v2/oauth2/tokens/revoke per developer.intuit.com.
    await _postOauthForm(
      path: const <String>['v2', 'oauth2', 'tokens', 'revoke'],
      formBody: body,
      expectJson: false,
    );
  }

  // ─── Timesheets / jobcodes / users ────────────────────────────────

  @override
  Future<QuickBooksTimeTimesheetsPage> listTimesheets({
    required String accessToken,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    int? page,
  }) async {
    final query = <String, String>{
      'modified_since': modifiedSince.toUtc().toIso8601String(),
      'modified_before': modifiedUntil.toUtc().toIso8601String(),
      'supplemental_data': 'no',
      if (page != null && page > 0) 'page': page.toString(),
    };
    final json = await _getJson(
      path: const <String>['timesheets'],
      query: query,
      accessToken: accessToken,
    );
    return _decodeTimesheetsPage(json, page);
  }

  @override
  Future<Map<String, Object?>> fetchTimesheet({
    required String accessToken,
    required String timesheetId,
  }) async {
    final json = await _getJson(
      path: <String>['timesheets', timesheetId],
      query: const <String, String>{},
      accessToken: accessToken,
    );
    final results = _readMap(json, 'results');
    final timesheets = results == null
        ? null
        : results['timesheets'];
    if (timesheets is Map<String, Object?> && timesheets.isNotEmpty) {
      // Vendor returns `results.timesheets` as a map keyed by id; we
      // hand back the first (and only) value.
      final entry = timesheets.values.first;
      if (entry is Map<String, Object?>) return entry;
      if (entry is Map) {
        return entry.map(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        );
      }
    }
    if (timesheets is List && timesheets.isNotEmpty) {
      final first = timesheets.first;
      if (first is Map<String, Object?>) return first;
      if (first is Map) {
        return first.map(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        );
      }
    }
    return const <String, Object?>{};
  }

  @override
  Future<Map<String, Map<String, Object?>>> fetchJobcodes({
    required String accessToken,
  }) async {
    final json = await _getJson(
      path: const <String>['jobcodes'],
      query: const <String, String>{},
      accessToken: accessToken,
    );
    return _decodeKeyedRecords(json, 'jobcodes');
  }

  @override
  Future<Map<String, Map<String, Object?>>> fetchUsers({
    required String accessToken,
  }) async {
    final json = await _getJson(
      path: const <String>['users'],
      query: const <String, String>{},
      accessToken: accessToken,
    );
    return _decodeKeyedRecords(json, 'users');
  }

  @override
  Future<Map<String, Object?>> sampleTimesheet({
    required String accessToken,
  }) async {
    // testConnection seam: pull the most recent timesheet (page 1, no
    // window). Vendor returns newest-first.
    final query = <String, String>{
      'page': '1',
      'supplemental_data': 'no',
    };
    final json = await _getJson(
      path: const <String>['timesheets'],
      query: query,
      accessToken: accessToken,
    );
    final results = _readMap(json, 'results');
    final timesheets = results == null
        ? null
        : results['timesheets'];
    if (timesheets is Map<String, Object?> && timesheets.isNotEmpty) {
      final entry = timesheets.values.first;
      if (entry is Map<String, Object?>) return entry;
      if (entry is Map) {
        return entry.map(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        );
      }
    }
    if (timesheets is List && timesheets.isNotEmpty) {
      final first = timesheets.first;
      if (first is Map<String, Object?>) return first;
      if (first is Map) {
        return first.map(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        );
      }
    }
    return const <String, Object?>{};
  }

  // ─── HTTP plumbing ────────────────────────────────────────────────

  Future<Map<String, Object?>> _getJson({
    required List<String> path,
    required Map<String, String> query,
    required String accessToken,
  }) async {
    final uri = _resolve(_deps.baseUri, path, query);
    final headers = <String, String>{
      'Authorization': 'Bearer $accessToken',
      'Accept': 'application/json',
    };
    final body = await _executeWithRetry(() async {
      return _deps.httpClient.get(uri, headers: headers).timeout(_deps.timeout);
    });
    return _decodeJsonObject(body);
  }

  Future<Map<String, Object?>> _postOauthForm({
    required List<String> path,
    required Map<String, String> formBody,
    bool expectJson = true,
  }) async {
    final uri = _resolve(_deps.oauthBaseUri, path, const <String, String>{});
    final basic = base64Encode(
      utf8.encode(
        '${_deps.oauthCredentials.clientId}:${_deps.oauthCredentials.clientSecret}',
      ),
    );
    final headers = <String, String>{
      'Authorization': 'Basic $basic',
      'Accept': 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
      'Idempotency-Key': _deps.idempotencyKeyFactory(),
    };
    final encodedBody = _encodeForm(formBody);
    final body = await _executeWithRetry(() async {
      return _deps.httpClient
          .post(uri, headers: headers, body: encodedBody)
          .timeout(_deps.timeout);
    });
    if (!expectJson) return const <String, Object?>{};
    return _decodeJsonObject(body);
  }

  Future<String> _executeWithRetry(
    Future<http.Response> Function() send,
  ) async {
    var attempt = 0;
    while (true) {
      late http.Response response;
      try {
        response = await send();
      } on TimeoutException catch (e) {
        throw QuickBooksTimeApiException(
          statusCode: 0,
          code: 'timeout',
          message: 'QuickBooks Time request timed out: $e',
        );
      } on http.ClientException catch (e) {
        throw QuickBooksTimeApiException(
          statusCode: 0,
          code: 'transport',
          message: 'QuickBooks Time transport error: $e',
        );
      }
      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        return response.body;
      }
      if (status == 401) {
        throw QuickBooksTimeAuthException(
          message: _truncatedBody(response.body),
        );
      }
      if (status == 429) {
        if (attempt >= _deps.maxRetries) {
          throw QuickBooksTimeRateLimitException(
            attempts: attempt,
            retryAfter: _parseRetryAfter(response.headers['retry-after']),
            message: _truncatedBody(response.body),
          );
        }
        final wait = _parseRetryAfter(response.headers['retry-after']) ??
            _deps.backoffStrategy(attempt);
        attempt += 1;
        await Future<void>.delayed(wait);
        continue;
      }
      // 4xx (other) and 5xx surface as a typed error. The caller
      // decides whether to retry on the next polling tick.
      throw QuickBooksTimeApiException(
        statusCode: status,
        code: status >= 500 ? 'server_error' : 'client_error',
        message: _truncatedBody(response.body),
      );
    }
  }

  // ─── Decoders ─────────────────────────────────────────────────────

  Map<String, Object?> _decodeJsonObject(String body) {
    if (body.isEmpty) return const <String, Object?>{};
    final dynamic parsed;
    try {
      parsed = jsonDecode(body);
    } on FormatException catch (e) {
      throw QuickBooksTimeApiException(
        statusCode: 200,
        code: 'invalid_json',
        message: 'QuickBooks Time response is not JSON: $e',
      );
    }
    if (parsed is Map<String, Object?>) return parsed;
    if (parsed is Map) {
      return parsed.map(
        (k, v) => MapEntry<String, Object?>(k.toString(), v),
      );
    }
    throw const QuickBooksTimeApiException(
      statusCode: 200,
      code: 'invalid_json_shape',
      message: 'QuickBooks Time response is not a JSON object',
    );
  }

  QuickBooksTimeTokenResponse _decodeTokenResponse(
    Map<String, Object?> json,
  ) {
    final accessToken = json['access_token'];
    final refreshToken = json['refresh_token'];
    final expiresIn = json['expires_in'];
    final scope = json['scope'];
    final realmId = json['realmId'] ?? json['x_refresh_token_expires_in'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const QuickBooksTimeApiException(
        statusCode: 200,
        code: 'missing_access_token',
        message: 'OAuth response missing access_token',
      );
    }
    final refresh = refreshToken is String ? refreshToken : '';
    final ttl = expiresIn is num ? expiresIn.toInt() : 3600;
    final expiresAt = DateTime.now().toUtc().add(Duration(seconds: ttl));
    final scopeStr = scope is String ? scope : '';
    final realmStr = json['realmId'] is String
        ? json['realmId'] as String
        : (realmId is String ? realmId : null);
    return QuickBooksTimeTokenResponse(
      accessToken: accessToken,
      refreshToken: refresh,
      expiresAt: expiresAt,
      scope: scopeStr,
      realmId: realmStr,
    );
  }

  QuickBooksTimeTimesheetsPage _decodeTimesheetsPage(
    Map<String, Object?> json,
    int? requestedPage,
  ) {
    final results = _readMap(json, 'results');
    final timesheetsRaw = results == null ? null : results['timesheets'];
    final records = <Map<String, Object?>>[];
    if (timesheetsRaw is Map<String, Object?>) {
      for (final value in timesheetsRaw.values) {
        if (value is Map<String, Object?>) {
          records.add(value);
        } else if (value is Map) {
          records.add(value.map(
            (k, v) => MapEntry<String, Object?>(k.toString(), v),
          ));
        }
      }
    } else if (timesheetsRaw is Map) {
      for (final value in timesheetsRaw.values) {
        if (value is Map<String, Object?>) {
          records.add(value);
        } else if (value is Map) {
          records.add(value.map(
            (k, v) => MapEntry<String, Object?>(k.toString(), v),
          ));
        }
      }
    } else if (timesheetsRaw is List) {
      for (final entry in timesheetsRaw) {
        if (entry is Map<String, Object?>) {
          records.add(entry);
        } else if (entry is Map) {
          records.add(entry.map(
            (k, v) => MapEntry<String, Object?>(k.toString(), v),
          ));
        }
      }
    }
    final more = json['more'];
    final hasMore = more is bool ? more : false;
    final currentPage = requestedPage ?? 1;
    final nextPage = hasMore ? currentPage + 1 : null;

    DateTime lastModifiedSeen = DateTime.utc(1970);
    for (final r in records) {
      final raw = r['last_modified'];
      if (raw is String && raw.isNotEmpty) {
        final parsed = DateTime.tryParse(raw)?.toUtc();
        if (parsed != null && parsed.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = parsed;
        }
      }
    }

    return QuickBooksTimeTimesheetsPage(
      records: records,
      nextPage: nextPage,
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  Map<String, Map<String, Object?>> _decodeKeyedRecords(
    Map<String, Object?> json,
    String resultsKey,
  ) {
    final results = _readMap(json, 'results');
    final raw = results == null ? null : results[resultsKey];
    final out = <String, Map<String, Object?>>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is Map<String, Object?>) {
          out[key] = value;
        } else if (value is Map) {
          out[key] = value.map(
            (k, v) => MapEntry<String, Object?>(k.toString(), v),
          );
        }
      }
    } else if (raw is List) {
      for (final entry in raw) {
        if (entry is Map<String, Object?>) {
          final id = entry['id'];
          out[id == null ? out.length.toString() : id.toString()] = entry;
        } else if (entry is Map) {
          final coerced = entry.map(
            (k, v) => MapEntry<String, Object?>(k.toString(), v),
          );
          final id = coerced['id'];
          out[id == null ? out.length.toString() : id.toString()] = coerced;
        }
      }
    }
    return out;
  }

  // ─── Utilities ────────────────────────────────────────────────────

  Map<String, Object?>? _readMap(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return value.map(
        (k, v) => MapEntry<String, Object?>(k.toString(), v),
      );
    }
    return null;
  }

  Uri _resolve(Uri base, List<String> segments, Map<String, String> query) {
    final basePath = base.path;
    final baseSegments = basePath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList(growable: true);
    baseSegments.addAll(segments.where((s) => s.isNotEmpty));
    return base.replace(
      pathSegments: baseSegments,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  String _encodeForm(Map<String, String> form) {
    return form.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  Duration? _parseRetryAfter(String? header) {
    if (header == null || header.isEmpty) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds);
    }
    final asDate = DateTime.tryParse(header.trim());
    if (asDate != null) {
      final delta = asDate.toUtc().difference(DateTime.now().toUtc());
      return delta.isNegative ? Duration.zero : delta;
    }
    return null;
  }

  String _truncatedBody(String body) {
    const max = 512;
    if (body.length <= max) return body;
    return '${body.substring(0, max)}...';
  }
}

/// Authentication failure (401). The framework's refresh policy is
/// upstream of this transport; the transport simply surfaces 401 as a
/// typed error so callers stop and trigger a refresh / reconnect flow.
class QuickBooksTimeAuthException implements Exception {
  const QuickBooksTimeAuthException({required this.message});

  final String message;

  @override
  String toString() => 'QuickBooksTimeAuthException: $message';
}

/// Thrown after the configured retry budget is exhausted on 429s. The
/// caller (poller / backfill driver) decides whether to surface to the
/// operator or retry on the next tick.
class QuickBooksTimeRateLimitException implements Exception {
  const QuickBooksTimeRateLimitException({
    required this.attempts,
    required this.message,
    this.retryAfter,
  });

  /// Number of attempts made before giving up (zero-based attempt count
  /// at the moment of the throw — i.e. `maxRetries` retries already
  /// burned).
  final int attempts;
  final Duration? retryAfter;
  final String message;

  @override
  String toString() =>
      'QuickBooksTimeRateLimitException(attempts=$attempts, '
      'retryAfter=$retryAfter): $message';
}

/// Generic API error (4xx other than 401, or 5xx). Carries the status
/// code + truncated body for upstream surfacing.
class QuickBooksTimeApiException implements Exception {
  const QuickBooksTimeApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'QuickBooksTimeApiException(status=$statusCode, code=$code): $message';
}
