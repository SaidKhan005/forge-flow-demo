// Phase 9 live-closeout B6 — HTTP client for the proxy auth-session
// ledger endpoints.
//
// The Flutter app holds no Postgres credentials. Every `auth_sessions`
// mutation flows through the four `/v1/auth/session/*` proxy routes
// added in this slice; the proxy verifies the Firebase ID token
// server-side, derives operator/location/user from the verified
// claims, and writes through `RepositoryAuthSessionLedgerWriter` over
// `AuthSessionsRepository`.
//
// This file:
//   * Defines [ProxyHttpJsonClient] — a small JSON-POST seam so the
//     writer's request shape + response mapping are unit-testable
//     without spinning a real HTTP server.
//   * Provides [DartIoProxyHttpJsonClient] — production binding using
//     `dart:io HttpClient`, with a pessimistic timeout so a slow
//     proxy never hangs the sign-in flow.
//   * Provides [ScaffoldFailingProxyHttpJsonClient] — fail-closed
//     default so a misconfigured deploy surfaces a clear "no proxy
//     transport wired" error.
//   * Defines [ProxyAuthSessionLedgerWriter] — the
//     [AuthSessionLedgerWriter] implementation that drives the four
//     proxy endpoints from the Flutter app.
//   * Defines [ProxyAuthSessionLedgerError] — narrow error type the
//     writer throws so the notifier's existing fail-closed posture
//     (`AuthLoginFailure(code: 'ledger_unavailable', ...)`) takes
//     over without leaking proxy internals.
//
// UX lock: this writer NEVER echoes the bearer token, the
// `token_hash`, or the response body's session_id into log paths.
// `toString()` is diagnostic-safe.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'auth_session_ledger_writer.dart';

// ─── HTTP transport seam ─────────────────────────────────────────────

/// Result of a proxy JSON POST. [body] is the parsed JSON object
/// (empty map when the response carried no JSON body).
class ProxyHttpJsonResponse {
  const ProxyHttpJsonResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, Object?> body;
}

/// JSON-POST seam used by [ProxyAuthSessionLedgerWriter]. Production
/// binding is [DartIoProxyHttpJsonClient]; tests inject deterministic
/// fakes that capture the request shape + return canned responses so
/// the writer can be unit-tested without a real HTTP server.
abstract class ProxyHttpJsonClient {
  /// POSTs [body] (encoded as JSON) to [url] with [headers] and a
  /// JSON content-type. Implementations MUST set
  /// `Content-Type: application/json` and apply their configured
  /// timeout. Network-layer failures (timeouts, DNS, socket close)
  /// SHOULD throw so the writer can map them to a calm
  /// [ProxyAuthSessionLedgerError].
  Future<ProxyHttpJsonResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  });
}

/// Production [ProxyHttpJsonClient] backed by `dart:io HttpClient`.
/// Times out the connect AND the response read so the sign-in flow
/// stays responsive when the proxy is slow.
class DartIoProxyHttpJsonClient implements ProxyHttpJsonClient {
  DartIoProxyHttpJsonClient({
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 10),
  }) : _httpClient = httpClient ?? HttpClient(),
       _timeout = timeout;

  final HttpClient _httpClient;
  final Duration _timeout;

  @override
  Future<ProxyHttpJsonResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    final request = await _httpClient.postUrl(url).timeout(_timeout);
    request.headers.contentType = ContentType.json;
    headers.forEach(request.headers.set);
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close().timeout(_timeout);
    final raw = await utf8
        .decodeStream(response.cast<List<int>>())
        .timeout(_timeout);
    if (raw.isEmpty) {
      return ProxyHttpJsonResponse(
        statusCode: response.statusCode,
        body: const <String, Object?>{},
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Non-JSON body (e.g. HTML error page from a load balancer) —
      // surface the status code so the writer can decide; body stays
      // empty so callers do not parse garbage.
      return ProxyHttpJsonResponse(
        statusCode: response.statusCode,
        body: const <String, Object?>{},
      );
    }
    if (decoded is! Map) {
      return ProxyHttpJsonResponse(
        statusCode: response.statusCode,
        body: const <String, Object?>{},
      );
    }
    return ProxyHttpJsonResponse(
      statusCode: response.statusCode,
      body: Map<String, Object?>.from(decoded),
    );
  }
}

/// Hard-fail-closed default so a misconfigured deploy that wires the
/// proxy ledger writer but forgets the transport surfaces a clear
/// error rather than silently dropping ledger rows.
class ScaffoldFailingProxyHttpJsonClient implements ProxyHttpJsonClient {
  const ScaffoldFailingProxyHttpJsonClient();

  @override
  Future<ProxyHttpJsonResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    throw StateError(
      'B6 scaffold: real ProxyHttpJsonClient is not wired — bind '
      '`DartIoProxyHttpJsonClient` (or another transport) before '
      'serving authenticated traffic.',
    );
  }
}

// ─── Errors ──────────────────────────────────────────────────────────

/// Narrow error the writer throws when a proxy call fails. The
/// notifier's existing fail-closed posture catches any throw on
/// `recordLogin` and surfaces
/// `AuthLoginFailure(code: 'ledger_unavailable', ...)`; refresh /
/// revoke errors are intentionally log-and-continue per the
/// audit-fix decision (so a transient blip doesn't punish the user).
class ProxyAuthSessionLedgerError implements Exception {
  ProxyAuthSessionLedgerError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  /// Stable error code for the notifier / UI to switch on. Mirrors
  /// the proxy's JSON `error` field when one was returned.
  final String code;

  /// Human-readable diagnostic. Never carries the bearer token, the
  /// `token_hash`, or any provider stack-trace fragment.
  final String message;

  /// HTTP status code observed (when the failure was an HTTP-level
  /// rejection). Null for transport-level failures.
  final int? statusCode;

  @override
  String toString() =>
      'ProxyAuthSessionLedgerError(code: $code, status: $statusCode)';
}

// ─── Writer ──────────────────────────────────────────────────────────

/// [AuthSessionLedgerWriter] backed by the proxy `/v1/auth/session/*`
/// endpoints. The Flutter app uses this writer in production; the
/// in-memory + scaffold-failing variants in [auth_session_ledger_writer.dart]
/// stay for tests and for the misconfigured-deploy fallback.
///
/// Header conventions:
///   * `Authorization: Bearer <ID token>` carries the live Firebase
///     ID token for the proxy verifier. The token is fetched at call
///     time via [idTokenProvider] so refresh / revoke calls (which
///     happen long after sign-in) get the freshest token.
///   * `Idempotency-Key: <random hex>` is set on every write so a
///     future proxy slice that integrates `proxy_requests` can
///     dedupe replays without a client change. The current proxy
///     accepts but does not yet enforce the header.
///
/// The body of `recordLogin` carries only `token_hash`. The proxy
/// echoes the verified user/operator/location scope with the issued
/// `session_id`; this writer refuses to persist the session id unless
/// the echo matches the local AuthSession scope that produced the
/// ledger call.
class ProxyAuthSessionLedgerWriter
    implements AuthSessionLedgerWriter, AuthSessionLedgerScopeResolvingWriter {
  ProxyAuthSessionLedgerWriter({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    required ProxyHttpJsonClient httpClient,
    String Function()? idempotencyKeyFactory,
  }) : _proxyBaseUri = proxyBaseUri,
       _idTokenProvider = idTokenProvider,
       _httpClient = httpClient,
       _idempotencyKeyFactory = idempotencyKeyFactory ?? _defaultIdempotencyKey;

  /// Proxy base URI, e.g. `https://forge-flow-proxy.run.app`. The
  /// writer resolves the per-endpoint path via [Uri.resolve] so the
  /// base may include or omit a trailing slash.
  final Uri _proxyBaseUri;

  /// Fetches the live Firebase ID token. Production wires this to
  /// `firebase_auth.currentUser?.getIdToken()`; tests inject a
  /// constant.
  final Future<String?> Function() _idTokenProvider;

  final ProxyHttpJsonClient _httpClient;
  final String Function() _idempotencyKeyFactory;

  // Path constants intentionally duplicate the proxy's
  // `authSessionLoginPath` etc. The proxy file lives under tool/
  // and the lib/ side cannot import from tool/ without dragging
  // the entire proxy module into the Flutter binary. The route
  // strings are part of the wire contract; if either side ever
  // disagrees the test suite catches it (see
  // `proxy_auth_session_endpoints_test.dart` which exercises both).
  static const String _loginPath = '/v1/auth/session/login';
  static const String _refreshPath = '/v1/auth/session/refresh';
  static const String _revokePath = '/v1/auth/session/revoke';
  static const String _revokeAllPath = '/v1/auth/session/revoke-all';

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    final response = await _postLogin(login);
    final record = _recordFromLoginResponse(response, login: login);
    _validateLoginScopeEcho(response: response, login: login);
    return record.sessionId;
  }

  @override
  Future<AuthSessionLedgerLoginRecord> recordLoginAndResolveScope(
    AuthSessionLedgerLogin login,
  ) async {
    final response = await _postLogin(login);
    return _recordFromLoginResponse(response, login: login);
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    final response = await _post(
      relativePath: _refreshPath,
      body: <String, Object?>{'session_id': sessionId},
    );
    if (response.statusCode != 200) {
      throw _errorFromResponse(response);
    }
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    final response = await _post(
      relativePath: _revokePath,
      body: <String, Object?>{'session_id': sessionId, 'reason': reason},
    );
    if (response.statusCode != 200) {
      throw _errorFromResponse(response);
    }
  }

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    final response = await _post(
      relativePath: _revokeAllPath,
      body: <String, Object?>{'reason': reason},
    );
    if (response.statusCode != 200) {
      throw _errorFromResponse(response);
    }
    final raw = response.body['revoked_count'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return 0;
  }

  Future<ProxyHttpJsonResponse> _post({
    required String relativePath,
    required Map<String, Object?> body,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.isEmpty) {
      throw ProxyAuthSessionLedgerError(
        code: 'no_id_token',
        message:
            'proxy auth session writer has no live Firebase ID token to '
            'present',
      );
    }
    final url = _proxyBaseUri.resolve(relativePath);
    final headers = <String, String>{
      HttpHeaders.authorizationHeader: 'Bearer $token',
      'Idempotency-Key': _idempotencyKeyFactory(),
    };
    try {
      return await _httpClient.postJson(url: url, headers: headers, body: body);
    } on ProxyAuthSessionLedgerError {
      rethrow;
    } catch (error) {
      // Network-layer failure (timeout, DNS, socket close, TLS
      // handshake, etc.). Map to a calm code so the notifier's
      // sign-in fail-closed branch surfaces a "try again" message
      // without leaking the underlying error type.
      throw ProxyAuthSessionLedgerError(
        code: 'transport_error',
        message:
            'proxy auth session call failed before reaching the proxy '
            '(${_describeTransportError(error)})',
      );
    }
  }

  ProxyAuthSessionLedgerError _errorFromResponse(
    ProxyHttpJsonResponse response,
  ) {
    final code =
        _readNonBlankString(response.body['error']) ??
        'auth_session_ledger_failed';
    final message =
        _readNonBlankString(response.body['message']) ??
        'proxy returned status ${response.statusCode}';
    return ProxyAuthSessionLedgerError(
      code: code,
      message: message,
      statusCode: response.statusCode,
    );
  }

  Future<ProxyHttpJsonResponse> _postLogin(AuthSessionLedgerLogin login) async {
    final response = await _post(
      relativePath: _loginPath,
      body: <String, Object?>{'token_hash': login.tokenHash},
    );
    if (response.statusCode != 200) {
      throw _errorFromResponse(response);
    }
    return response;
  }

  AuthSessionLedgerLoginRecord _recordFromLoginResponse(
    ProxyHttpJsonResponse response, {
    required AuthSessionLedgerLogin login,
  }) {
    final sessionId = _readNonBlankString(response.body['session_id']);
    final userId = _readNonBlankString(response.body['user_id']);
    final operatorId = _readNonBlankString(response.body['operator_id']);
    final locationId = _readNonBlankString(response.body['location_id']);
    if (sessionId == null) {
      throw ProxyAuthSessionLedgerError(
        code: 'malformed_response',
        message: 'proxy /v1/auth/session/login returned no session_id',
        statusCode: response.statusCode,
      );
    }
    // B1 follow-up — global-admin (ff_support / super_admin) sign-in
    // contract: the proxy's `requireOperatorContext` accepts scope-less
    // claims for these roles and returns empty-string `operator_id` /
    // `location_id`. The client parser must mirror that contract or
    // every global-admin sign-in trips
    // `AuthLoginFailure(code: 'ledger_unavailable')` — the exact Bug 1
    // symptom A1 was tracking. See
    // `docs/_audits/post_codex_wave/pr_476_b1_b2_audit.md` §1 and
    // `tool/pressure/p4_session_record_predicate.dart` for the
    // symmetric harness predicate.
    final isGlobalAdmin = _isGlobalAdminCaller(login.roles);
    if (userId == null) {
      throw ProxyAuthSessionLedgerError(
        code: 'malformed_response',
        message: 'proxy /v1/auth/session/login returned incomplete scope',
        statusCode: response.statusCode,
      );
    }
    if (!isGlobalAdmin && (operatorId == null || locationId == null)) {
      throw ProxyAuthSessionLedgerError(
        code: 'malformed_response',
        message: 'proxy /v1/auth/session/login returned incomplete scope',
        statusCode: response.statusCode,
      );
    }
    return AuthSessionLedgerLoginRecord(
      sessionId: sessionId,
      userId: userId,
      // Preserve the proxy's empty echo for global admins; downstream
      // routes that need a concrete tenant call the impersonation
      // flow (`/v1/admin/auth/sessions`) to pick one. Match
      // `OperatorContext` shape from `requireOperatorContext`
      // (`tool/advisor_proxy/advisor_proxy.dart:2222-2233`).
      operatorId: operatorId ?? '',
      locationId: locationId ?? '',
    );
  }

  void _validateLoginScopeEcho({
    required ProxyHttpJsonResponse response,
    required AuthSessionLedgerLogin login,
  }) {
    final userId = _readNonBlankString(response.body['user_id']);
    final operatorId = _readNonBlankString(response.body['operator_id']);
    final locationId = _readNonBlankString(response.body['location_id']);
    // B1 follow-up — see `_recordFromLoginResponse` for the contract.
    // Global admins legitimately echo back empty operator/location
    // because their JWT carried no tenant scope to begin with. The
    // local AuthSession's `operatorId` / `locationId` are also empty
    // strings for these users, so the equality check below still
    // catches a real scope mismatch (e.g. a non-admin's operator id
    // changing between client request and proxy echo).
    final isGlobalAdmin = _isGlobalAdminCaller(login.roles);
    if (userId == null) {
      throw ProxyAuthSessionLedgerError(
        code: 'malformed_response',
        message: 'proxy /v1/auth/session/login returned incomplete scope',
        statusCode: response.statusCode,
      );
    }
    if (!isGlobalAdmin && (operatorId == null || locationId == null)) {
      throw ProxyAuthSessionLedgerError(
        code: 'malformed_response',
        message: 'proxy /v1/auth/session/login returned incomplete scope',
        statusCode: response.statusCode,
      );
    }
    // Compare with empty-string fallback so the global-admin case
    // (both sides empty) reads as a match rather than null != ''.
    final echoedOperatorId = operatorId ?? '';
    final echoedLocationId = locationId ?? '';
    if (userId != login.userId ||
        echoedOperatorId != login.operatorId ||
        echoedLocationId != login.locationId) {
      throw ProxyAuthSessionLedgerError(
        code: 'scope_mismatch',
        message: 'proxy /v1/auth/session/login returned a different scope',
        statusCode: response.statusCode,
      );
    }
  }

  /// Roles that signal a global admin identity (platform-wide; no
  /// per-tenant scope). Mirrors the proxy's `_hasGlobalAdminRole`
  /// at `tool/advisor_proxy/advisor_proxy.dart:2260-2265` and the
  /// soak-harness predicate's `globalAdminRoles` constant at
  /// `tool/pressure/p4_session_record_predicate.dart:57-60`. Three
  /// sites must stay in sync; if either side widens the set, update
  /// here too.
  static const Set<String> _globalAdminRoles = <String>{
    'ff_support',
    'super_admin',
  };

  static bool _isGlobalAdminCaller(List<String> roles) {
    for (final role in roles) {
      if (_globalAdminRoles.contains(role)) return true;
    }
    return false;
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Categorises common transport-failure types without echoing their
  /// message (which can carry connection strings, hostnames, or
  /// stack-trace fragments).
  static String _describeTransportError(Object error) {
    if (error is TimeoutException) return 'timeout';
    if (error is SocketException) return 'socket';
    if (error is HttpException) return 'http';
    if (error is HandshakeException) return 'tls';
    if (error is OSError) return 'os';
    return 'transport';
  }

  static final math.Random _idempotencyRandom = math.Random.secure();

  /// Default idempotency key — 16 random bytes hex-encoded. Not a
  /// strict UUID, but treated by the proxy as an opaque token so the
  /// shape doesn't matter beyond uniqueness.
  static String _defaultIdempotencyKey() {
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _idempotencyRandom.nextInt(256);
    }
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
