// Phase 11W.4 - Operator Web sessions gateway (live).
//
// `package:http` re-implementation of the Active Sessions surface so
// the operator-web build can call the existing Phase 9 + 11A.1 proxy
// routes without dragging in `dart:io`.
//
// Routes (already shipped by Phase 9, no new backend surface added by
// 11W.4):
//
//   * GET  /v1/auth/sessions             - own sessions
//   * GET  /v1/auth/team/sessions        - team-wide sessions, gated
//                                          server-side on
//                                          team.session.force_logout
//   * POST /v1/auth/session/revoke       - revoke a single session,
//                                          carries Idempotency-Key
//
// Idempotency posture: the screen mints one key per user action and
// threads it through to revokeSession. The gateway does NOT mint keys
// internally per the parity contract.
//
// Privacy posture: the gateway exposes the geo hint as city + country
// only. Raw IP never leaves this gateway - the `ip` field on the
// proxy payload is dropped on the way through so the screen cannot
// accidentally render it. This matches the parity contract § Sessions
// "city-level only, never raw IP" rule.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One row in the sessions list. Captures the fields the parity
/// contract § Sessions row shape requires - device fingerprint
/// (browser + OS), city-level geo hint, last_active_at - and
/// deliberately drops the raw IP so the screen layer cannot render
/// it.
class WebTeamSessionEntry {
  const WebTeamSessionEntry({
    required this.sessionId,
    required this.lastActiveAt,
    required this.createdAt,
    this.deviceLabel,
    this.userAgent,
    this.deviceFingerprint,
    this.geoCity,
    this.geoCountry,
    this.targetUserId,
    this.targetUserDisplayName,
    this.targetUserEmail,
  });

  final String sessionId;
  final DateTime lastActiveAt;
  final DateTime createdAt;

  /// Friendly browser + OS label projected by the proxy. Falls back
  /// to [userAgent] when null.
  final String? deviceLabel;
  final String? userAgent;
  final String? deviceFingerprint;

  /// City-level geo hint. Optional; some sessions only carry a country.
  final String? geoCity;

  /// ISO-3166 alpha-2 country code captured at login time.
  final String? geoCountry;

  /// Target user identity. Null on rows returned from
  /// `/v1/auth/sessions` (the actor's own ledger). Populated on rows
  /// returned from `/v1/auth/team/sessions` so the screen can render
  /// the team member each row belongs to.
  final String? targetUserId;
  final String? targetUserDisplayName;
  final String? targetUserEmail;
}

class WebTeamSessionsListed {
  const WebTeamSessionsListed({required this.sessions});

  final List<WebTeamSessionEntry> sessions;
}

class WebTeamSessionRevokeCommand {
  const WebTeamSessionRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.sessionId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String sessionId;
  final String? reason;
}

class WebTeamSessionRevoked {
  const WebTeamSessionRevoked({required this.revoked});

  final bool revoked;
}

/// Narrow gateway interface the Sessions screen reads + writes
/// against. Mirrors the Phase 9 self-service Active Sessions API
/// shape. Future 11W slices keep their own gateway under this
/// naming pattern.
abstract class WebTeamSessionsGateway {
  /// Lists the actor's own active sessions via `/v1/auth/sessions`.
  Future<WebTeamSessionsListed> listOwnSessions();

  /// Lists every team-member session within scope via
  /// `/v1/auth/team/sessions`. Server-side gated on
  /// `team.session.force_logout`; the proxy returns 403 for actors
  /// without the key.
  Future<WebTeamSessionsListed> listTeamSessions();

  /// Revokes a single session via `/v1/auth/session/revoke`. The
  /// Idempotency-Key header carries the screen-minted key so a
  /// re-submission of the same revoke replays the original 2xx.
  Future<WebTeamSessionRevoked> revokeSession(
    WebTeamSessionRevokeCommand command, {
    required String idempotencyKey,
  });
}

/// HTTP wire response. Mirrors the envelope the live impl decodes so
/// the unit test can assert on status + body without re-implementing
/// the parser.
class WebTeamSessionsResponse {
  const WebTeamSessionsResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

/// Thrown when the proxy returns a non-2xx for an active sessions
/// call, or when the response body cannot be parsed.
class WebTeamSessionsError implements Exception {
  const WebTeamSessionsError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  /// True iff the proxy returned the locked
  /// `validation_failed/cannot_revoke_self` shape. The F&F admin path
  /// returns this when an admin tries to revoke their own admin
  /// session; operator self-service does not return it (revoking the
  /// current session triggers the local `signOut()` path instead).
  /// Surfaced here so the gateway tests can pin the mapping.
  bool get isCannotRevokeSelf => code == 'cannot_revoke_self';

  @override
  String toString() =>
      'WebTeamSessionsError(code: $code, status: $statusCode, message: $message)';
}

/// Path constants used by both the gateway and its tests.
class WebTeamSessionsPaths {
  const WebTeamSessionsPaths._();

  static const String ownSessions = '/v1/auth/sessions';
  static const String teamSessions = '/v1/auth/team/sessions';
  static const String revokeSession = '/v1/auth/session/revoke';
}

/// Live `package:http` implementation. Reads the Firebase ID token
/// from the supplied provider on every call so refreshed tokens land
/// on the next request.
class WebTeamSessionsGatewayLive implements WebTeamSessionsGateway {
  WebTeamSessionsGatewayLive({
    required this.proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
  })  : _idTokenProvider = idTokenProvider,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  final Uri proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  @override
  Future<WebTeamSessionsListed> listOwnSessions() async {
    final response = await _send(
      method: 'GET',
      path: WebTeamSessionsPaths.ownSessions,
    );
    _expectStatus(response, 200);
    return _parseSessions(response, includeTargetUser: false);
  }

  @override
  Future<WebTeamSessionsListed> listTeamSessions() async {
    final response = await _send(
      method: 'GET',
      path: WebTeamSessionsPaths.teamSessions,
    );
    _expectStatus(response, 200);
    return _parseSessions(response, includeTargetUser: true);
  }

  @override
  Future<WebTeamSessionRevoked> revokeSession(
    WebTeamSessionRevokeCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebTeamSessionsPaths.revokeSession,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'session_id': command.sessionId,
        if (_readNonBlankString(command.reason) != null)
          'reason': command.reason!.trim(),
      },
    );
    _expectStatus(response, 200);
    final raw = response.body['revoked'];
    final ok = response.body['ok'];
    final revoked = raw is bool
        ? raw
        : ok is bool
            ? ok
            : false;
    return WebTeamSessionRevoked(revoked: revoked);
  }

  WebTeamSessionsListed _parseSessions(
    WebTeamSessionsResponse response, {
    required bool includeTargetUser,
  }) {
    final raw = response.body['sessions'];
    if (raw is! List) {
      throw _malformed(response, 'sessions response was incomplete');
    }
    return WebTeamSessionsListed(
      sessions: List<WebTeamSessionEntry>.unmodifiable(
        raw.map(
          (entry) => _entryFromJson(
            response,
            entry,
            includeTargetUser: includeTargetUser,
          ),
        ),
      ),
    );
  }

  WebTeamSessionEntry _entryFromJson(
    WebTeamSessionsResponse response,
    Object? raw, {
    required bool includeTargetUser,
  }) {
    if (raw is! Map) {
      throw _malformed(response, 'session payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final sessionId = _readNonBlankString(json['session_id']);
    final lastActiveAtRaw = _readNonBlankString(json['last_seen_at']) ??
        _readNonBlankString(json['last_active_at']);
    final createdAtRaw = _readNonBlankString(json['created_at']);
    if (sessionId == null || lastActiveAtRaw == null || createdAtRaw == null) {
      throw _malformed(response, 'session payload was incomplete');
    }
    return WebTeamSessionEntry(
      sessionId: sessionId,
      lastActiveAt: DateTime.parse(lastActiveAtRaw).toUtc(),
      createdAt: DateTime.parse(createdAtRaw).toUtc(),
      deviceLabel: _readNonBlankString(json['device_label']),
      userAgent: _readNonBlankString(json['user_agent']),
      deviceFingerprint: _readNonBlankString(json['device_fingerprint']),
      geoCity: _readNonBlankString(json['geo_city']),
      geoCountry: _readNonBlankString(json['geo_country']),
      targetUserId: includeTargetUser
          ? _readNonBlankString(json['user_id'])
          : null,
      targetUserDisplayName: includeTargetUser
          ? _readNonBlankString(json['display_name'])
          : null,
      targetUserEmail:
          includeTargetUser ? _readNonBlankString(json['email']) : null,
    );
  }

  Future<WebTeamSessionsResponse> _send({
    required String method,
    required String path,
    String? idempotencyKey,
    Map<String, Object?>? body,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const WebTeamSessionsError(
        code: 'no_id_token',
        message:
            'sessions gateway has no live Firebase ID token to attach to '
            'the request.',
      );
    }
    final headers = <String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer ${token.trim()}',
      if (body != null) 'content-type': 'application/json',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
    final url = proxyBaseUri.resolve(path);
    final request = http.Request(method, url);
    request.headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const WebTeamSessionsError(
        code: 'transport_timeout',
        message:
            'sessions gateway request timed out before reaching the proxy.',
      );
    } catch (error) {
      throw WebTeamSessionsError(
        code: 'transport_error',
        message:
            'sessions gateway request failed before reaching the proxy '
            '($error).',
      );
    }
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    Object? decoded;
    if (raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        decoded = const <String, Object?>{};
      }
    }
    final responseBody = decoded is Map<Object?, Object?>
        ? Map<String, Object?>.from(decoded)
        : const <String, Object?>{};
    return WebTeamSessionsResponse(
      statusCode: streamed.statusCode,
      body: responseBody,
    );
  }

  void _expectStatus(WebTeamSessionsResponse response, int expected) {
    if (response.statusCode == expected) return;
    final code = _readNonBlankString(response.body['error']) ??
        'sessions_failed';
    throw WebTeamSessionsError(
      code: code,
      message: _readNonBlankString(response.body['message']) ??
          'proxy returned status ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }

  WebTeamSessionsError _malformed(
    WebTeamSessionsResponse response,
    String message,
  ) {
    return WebTeamSessionsError(
      code: 'malformed_response',
      message: message,
      statusCode: response.statusCode,
    );
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
