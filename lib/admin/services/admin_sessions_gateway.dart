// Fix-first #2 (audit findings G1 + G2) — admin console auth-session
// ledger + Active Sessions parity gateway.
//
// The operator-web and mobile apps both record every sign-in/out into
// the Postgres `auth_sessions` ledger and expose a self-service Active
// Sessions surface (list / revoke / sign out everywhere). The F&F Ops
// admin console did neither: `FirebaseAdminAuthSource` admitted a
// session with no ledger row, and the My Account screen stated sessions
// were "not available here yet". This gateway closes both gaps.
//
// Wire shape mirrors the existing `HttpAdminAccountGateway`
// (`admin_account_gateway.dart`): the bearer source is injected so the
// admin Firebase ID-token stream binds at startup and tests pin a
// synthetic value; every state-changing POST carries a required
// caller-stable `Idempotency-Key`. The routes are the SAME Phase 9 /
// 11A.1 self-service proxy routes the operator-web + mobile clients use
// — no new admin-only route, no parallel permission catalog entry
// (CLAUDE.md HP #11 + R-2):
//
//   * POST /v1/auth/session/login        — record a session ledger row
//                                          (body `{token_hash}`; the
//                                          proxy resolves user/operator/
//                                          location from the verified
//                                          bearer). Verified contract:
//                                          tool/advisor_proxy/
//                                          advisor_proxy.dart:13502 +
//                                          :13792-13805 (200 →
//                                          `{session_id,user_id,
//                                          operator_id,location_id}`;
//                                          503 `auth_session_ledger_
//                                          unavailable` on writer
//                                          failure — fail-closed).
//   * POST /v1/auth/session/revoke       — close a single session
//                                          (body `{session_id,reason?}`;
//                                          200 `{ok:true}`). Verified:
//                                          advisor_proxy.dart:13876 +
//                                          :13945.
//   * POST /v1/auth/session/revoke-all   — close every session for the
//                                          verified caller (body
//                                          `{reason?}`; 200 `{ok:true,
//                                          revoked_count}`). Verified:
//                                          advisor_proxy.dart:13949 +
//                                          :14006.
//   * POST /v1/auth/refresh-tokens/revoke-all
//                                        — server-side Firebase
//                                          refresh-token revoke (body
//                                          `{}`; 200 `{ok:true}`).
//                                          Verified: advisor_proxy.dart
//                                          :12942 + :12989.
//   * GET  /v1/auth/sessions             — list the verified caller's
//                                          own active sessions (200 →
//                                          `{sessions:[...]}`). Verified:
//                                          advisor_proxy.dart:12993 +
//                                          :13025; row shape from
//                                          `_authSessionSummaryToJson`
//                                          advisor_proxy.dart:19349.
//
// Privacy posture (parity with `web_team_sessions_gateway.dart`): the
// raw `ip` field is dropped on the way through so the screen layer
// cannot render it. City-level geo (`geo_country`) only.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'admin_http_timeout.dart';

/// Bearer source the gateway attaches to every proxy call. Production
/// binds this to the admin Firebase ID-token stream (the same
/// `_firebaseIdTokenProvider` the sibling admin gateways use); tests
/// pin a synthetic value.
typedef AdminSessionsBearerTokenProvider = Future<String> Function();

/// Narrow error the gateway throws so the screen layer can render a
/// calm friendly message. Mirrors `AdminAccountGatewayError`.
class AdminSessionsGatewayError implements Exception {
  const AdminSessionsGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'AdminSessionsGatewayError($statusCode/$errorCode): $message';
}

/// One row in the admin's own Active Sessions list. Drops the raw IP
/// per the parity privacy rule.
@immutable
class AdminSessionEntry {
  const AdminSessionEntry({
    required this.sessionId,
    required this.createdAt,
    required this.lastSeenAt,
    this.deviceLabel,
    this.userAgent,
    this.geoCountry,
    this.revokedAt,
  });

  final String sessionId;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final String? deviceLabel;
  final String? userAgent;
  final String? geoCountry;

  /// Non-null once the session has been revoked. The screen filters
  /// these out of the "active" list but the proxy may still echo a
  /// recently-revoked row.
  final DateTime? revokedAt;

  bool get isActive => revokedAt == null;
}

/// Result of recording a sign-in into the ledger. The admin auth
/// source keeps [sessionId] so sign-out can close exactly that row.
@immutable
class AdminSessionLedgerRecord {
  const AdminSessionLedgerRecord({
    required this.sessionId,
    required this.userId,
  });

  final String sessionId;
  final String userId;
}

/// Admin-console auth-session ledger + Active Sessions surface.
abstract class AdminSessionsGateway {
  /// G1 — records a sign-in into the `auth_sessions` ledger. The proxy
  /// resolves user/operator/location from the verified bearer token, so
  /// the body only carries the SHA-256 [tokenHash] of the ID token
  /// (parity with the operator-web + mobile login route body).
  ///
  /// Throws [AdminSessionsGatewayError] on any failure so the caller
  /// can fail the sign-in closed (no unrecorded admin session in live
  /// mode).
  Future<AdminSessionLedgerRecord> recordSessionLogin({
    required String tokenHash,
    required String idempotencyKey,
  });

  /// G1 — closes the session row created at sign-in. Best-effort: the
  /// caller treats a failure as non-fatal (the local sign-out still
  /// proceeds) so a transient blip never traps the admin in a session
  /// they asked to end.
  Future<void> revokeSession({
    required String sessionId,
    required String reason,
    required String idempotencyKey,
  });

  /// G2 — lists the signed-in admin's own active sessions.
  Future<List<AdminSessionEntry>> listOwnSessions();

  /// G2 — signs the admin out everywhere: revokes every `auth_sessions`
  /// row for the verified caller AND revokes their Firebase refresh
  /// tokens server-side (so other devices cannot silently refresh).
  /// Mirrors the mobile `ProxyAuthSessionLedgerWriter
  /// .revokeAllSessionsForUser` + `ProxyRefreshTokenRevoker` pair.
  Future<int> signOutEverywhere({
    required String reason,
    required String idempotencyKey,
  });
}

/// Production HTTP implementation. Constructor shape + bearer source +
/// timeout mirror `HttpAdminAccountGateway`.
class HttpAdminSessionsGateway implements AdminSessionsGateway {
  HttpAdminSessionsGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  })  : _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  final Uri baseUri;
  final AdminSessionsBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  // Path constants intentionally duplicate the proxy's
  // `authSessionLoginPath` etc. The proxy file lives under tool/ and
  // lib/ cannot import it without dragging the whole proxy into the
  // Flutter binary. The strings are part of the wire contract; the
  // proxy endpoint tests pin both sides.
  static const String sessionLoginPath = '/v1/auth/session/login';
  static const String sessionRevokePath = '/v1/auth/session/revoke';
  static const String sessionRevokeAllPath = '/v1/auth/session/revoke-all';
  static const String refreshTokensRevokeAllPath =
      '/v1/auth/refresh-tokens/revoke-all';
  static const String sessionsListPath = '/v1/auth/sessions';

  @override
  Future<AdminSessionLedgerRecord> recordSessionLogin({
    required String tokenHash,
    required String idempotencyKey,
  }) async {
    final body = await _send(
      method: 'POST',
      path: sessionLoginPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{'token_hash': tokenHash},
    );
    final sessionId = _optionalStringField(body, 'session_id');
    final userId = _optionalStringField(body, 'user_id');
    if (sessionId == null || userId == null) {
      throw const AdminSessionsGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin session-login proxy returned an incomplete response',
      );
    }
    return AdminSessionLedgerRecord(sessionId: sessionId, userId: userId);
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String reason,
    required String idempotencyKey,
  }) async {
    await _send(
      method: 'POST',
      path: sessionRevokePath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'session_id': sessionId,
        'reason': reason,
      },
    );
  }

  @override
  Future<List<AdminSessionEntry>> listOwnSessions() async {
    final body = await _send(
      method: 'GET',
      path: sessionsListPath,
      // GET is idempotent by definition; the proxy ignores the header
      // on reads but the helper requires one for a uniform shape.
      idempotencyKey: _readOnlyIdempotencyKey(),
    );
    final raw = body['sessions'];
    if (raw is! List) {
      throw const AdminSessionsGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin sessions list proxy returned an incomplete response',
      );
    }
    return List<AdminSessionEntry>.unmodifiable(
      raw.map(_entryFromJson),
    );
  }

  @override
  Future<int> signOutEverywhere({
    required String reason,
    required String idempotencyKey,
  }) async {
    // Order matters: revoke the ledger rows first (so the Active
    // Sessions surface reflects the action even if the Firebase
    // refresh-token revoke is slow), then revoke refresh tokens so no
    // other device can silently refresh. Both carry the SAME caller-
    // stable idempotency key so a retry of the whole logical action
    // replays the original 2xx on each route.
    final revokeAllBody = await _send(
      method: 'POST',
      path: sessionRevokeAllPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{'reason': reason},
    );
    await _send(
      method: 'POST',
      path: refreshTokensRevokeAllPath,
      idempotencyKey: idempotencyKey,
      jsonBody: const <String, Object?>{},
    );
    final count = revokeAllBody['revoked_count'];
    if (count is int) return count;
    if (count is num) return count.toInt();
    return 0;
  }

  AdminSessionEntry _entryFromJson(Object? raw) {
    if (raw is! Map) {
      throw const AdminSessionsGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin sessions list row was malformed',
      );
    }
    final json = Map<String, Object?>.from(raw);
    final sessionId = _readNonBlank(json['session_id']);
    final createdAtRaw = _readNonBlank(json['created_at']);
    final lastSeenAtRaw =
        _readNonBlank(json['last_seen_at']) ?? _readNonBlank(json['last_active_at']);
    if (sessionId == null || createdAtRaw == null || lastSeenAtRaw == null) {
      throw const AdminSessionsGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin sessions list row was incomplete',
      );
    }
    final revokedAtRaw = _readNonBlank(json['revoked_at']);
    return AdminSessionEntry(
      sessionId: sessionId,
      createdAt: DateTime.parse(createdAtRaw).toUtc(),
      lastSeenAt: DateTime.parse(lastSeenAtRaw).toUtc(),
      deviceLabel: _readNonBlank(json['device_label']),
      userAgent: _readNonBlank(json['user_agent']),
      geoCountry: _readNonBlank(json['geo_country']),
      // Raw `ip` is intentionally NOT read — parity privacy rule.
      revokedAt:
          revokedAtRaw == null ? null : DateTime.parse(revokedAtRaw).toUtc(),
    );
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    required String idempotencyKey,
    Map<String, Object?>? jsonBody,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json'
      ..headers['Idempotency-Key'] = idempotencyKey;
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw AdminSessionsGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message: 'admin sessions proxy timed out after ${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) parsed = decoded.cast<String, Object?>();
      } on FormatException {
        // Non-JSON body (e.g. an LB error page) — leave parsed empty so
        // the status branch surfaces a calm error rather than parsing
        // garbage.
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    throw AdminSessionsGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: (parsed['message'] as String?) ??
          'admin sessions proxy returned an error',
    );
  }

  static final math.Random _readOnlyRandom = math.Random.secure();
  static String _readOnlyIdempotencyKey() {
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36);
    final r = _readOnlyRandom.nextInt(0x7fffffff).toRadixString(36);
    return 'admin-sessions-list-$ts-$r';
  }

  static String? _optionalStringField(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  static String? _readNonBlank(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// In-memory demo gateway. Mirrors the seeded admin session so the
/// kDemoMode walkthrough renders the surface without a backend. The
/// admin auth source treats a null gateway as "demo / no-op", so this
/// is only used by the My Account route's demo fallback (parity with
/// `InMemoryAdminAccountGateway`).
class InMemoryAdminSessionsGateway implements AdminSessionsGateway {
  InMemoryAdminSessionsGateway({DateTime Function()? now})
      : _now = now ?? DateTime.now {
    final reference = _now().toUtc();
    _sessions.add(
      AdminSessionEntry(
        sessionId: 'demo-admin-session-1',
        createdAt: reference.subtract(const Duration(hours: 3)),
        lastSeenAt: reference.subtract(const Duration(minutes: 2)),
        deviceLabel: 'Chrome on macOS',
        geoCountry: 'CA',
      ),
    );
    _sessions.add(
      AdminSessionEntry(
        sessionId: 'demo-admin-session-2',
        createdAt: reference.subtract(const Duration(days: 2)),
        lastSeenAt: reference.subtract(const Duration(hours: 20)),
        deviceLabel: 'Safari on iPad',
        geoCountry: 'CA',
      ),
    );
  }

  final DateTime Function() _now;
  final List<AdminSessionEntry> _sessions = <AdminSessionEntry>[];
  final List<String> revokedSessionIds = <String>[];
  int signOutEverywhereCalls = 0;

  @override
  Future<AdminSessionLedgerRecord> recordSessionLogin({
    required String tokenHash,
    required String idempotencyKey,
  }) async {
    return const AdminSessionLedgerRecord(
      sessionId: 'demo-admin-session-1',
      userId: 'demo-admin',
    );
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String reason,
    required String idempotencyKey,
  }) async {
    revokedSessionIds.add(sessionId);
    _sessions.removeWhere((s) => s.sessionId == sessionId);
  }

  @override
  Future<List<AdminSessionEntry>> listOwnSessions() async =>
      List<AdminSessionEntry>.unmodifiable(_sessions);

  @override
  Future<int> signOutEverywhere({
    required String reason,
    required String idempotencyKey,
  }) async {
    signOutEverywhereCalls += 1;
    final count = _sessions.length;
    _sessions.clear();
    return count;
  }
}
