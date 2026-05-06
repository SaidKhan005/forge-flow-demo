// Phase 11W.6 - Operator Web security gateway (live).
//
// `package:http` re-implementation of the Security surface so the
// operator-web build can call the existing Phase 9 + 11A.x proxy
// routes without dragging in `dart:io`.
//
// Routes (already shipped by Phase 9, no new backend surface added by
// 11W.6):
//
//   * POST /v1/auth/mfa/factors/list            - list own factors +
//                                                pending removal
//                                                requests.
//   * POST /v1/auth/mfa/totp/begin              - begin TOTP enroll
//                                                (requires user_email
//                                                in the body).
//   * POST /v1/auth/mfa/totp/confirm            - confirm TOTP enroll.
//   * POST /v1/auth/mfa/factors/revoke          - schedule a 24-hour
//                                                delayed removal.
//   * POST /v1/auth/mfa/factors/removal/cancel  - cancel a pending
//                                                removal.
//   * POST /v1/auth/mfa/recovery/request        - queue an MFA
//                                                recovery request
//                                                (used when the
//                                                operator has lost
//                                                access to every
//                                                enrolled factor).
//   * POST /v1/auth/password/change             - change password
//                                                with current-password
//                                                reverification.
//   * GET  /v1/auth/audit-log                   - source for the
//                                                login-history slice.
//
// Idempotency posture: each write accepts a caller-minted
// `Idempotency-Key`; the gateway threads it through unchanged so the
// proxy `proxy_requests` UNIQUE-key replay surfaces the original
// outcome on retry. Login-history reads are GETs and carry no key.
//
// Login-history scope: the gateway projects the `/v1/auth/audit-log`
// rows down to the Security-relevant set (`auth.session.*` /
// `auth.password.*` / `auth.mfa.*`) and caps the window at 90 days,
// per the parity contract § Security rule.
//
// Web-safe: pure-Dart, no `dart:io`, no `sqflite`.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One MFA factor row. Mirrors the mobile [`MfaFactorSummary`] shape
/// but keeps the gateway free of any dependency on the mobile-only
/// `lib/services/mfa/*` types so the operator-web build stays free of
/// `dart:io`.
class WebSecurityMfaFactor {
  const WebSecurityMfaFactor({
    required this.factorId,
    required this.factorType,
    required this.enrolledAt,
    required this.issuerLabel,
    this.lastUsedAt,
    this.canRevoke = true,
  });

  final String factorId;

  /// `'totp'`, `'sms'`, or `'authenticator_app'`. The screen renders
  /// any unknown value verbatim so a future server-side type still
  /// surfaces.
  final String factorType;
  final DateTime enrolledAt;
  final DateTime? lastUsedAt;
  final String issuerLabel;
  final bool canRevoke;
}

/// Status of an in-flight MFA factor removal. The contract caps
/// status to `'pending'` / `'completed'` / `'cancelled'`.
class WebSecurityMfaRemoval {
  const WebSecurityMfaRemoval({
    required this.requestId,
    required this.factorId,
    required this.status,
    required this.executeAfter,
    this.completedAt,
  });

  final String requestId;
  final String factorId;
  final String status;
  final DateTime executeAfter;
  final DateTime? completedAt;
}

class WebSecurityFactorsListed {
  const WebSecurityFactorsListed({
    required this.factors,
    this.removalRequests = const <WebSecurityMfaRemoval>[],
  });

  final List<WebSecurityMfaFactor> factors;
  final List<WebSecurityMfaRemoval> removalRequests;
}

/// Artifact returned by [`WebSecurityGateway.beginTotpEnrollment`].
/// The screen renders the otpauth URL + shared secret so the operator
/// can scan or paste either into their authenticator app.
class WebSecurityTotpEnrollment {
  const WebSecurityTotpEnrollment({
    required this.factorId,
    required this.otpAuthUrl,
    required this.secretBase32,
  });

  final String factorId;
  final String otpAuthUrl;
  final String secretBase32;
}

class WebSecurityRevokeFactorResult {
  const WebSecurityRevokeFactorResult({
    required this.revoked,
    this.requestId,
    this.executeAfter,
  });

  /// True iff the factor was removed immediately. Per the parity
  /// contract § Security, operator self-service always returns
  /// `false` here and surfaces a `requestId` + `executeAfter` pinned
  /// 24 hours into the future.
  final bool revoked;
  final String? requestId;
  final DateTime? executeAfter;
}

class WebSecurityCancelRemovalResult {
  const WebSecurityCancelRemovalResult({required this.cancelled});

  final bool cancelled;
}

class WebSecurityPasswordChangeResult {
  const WebSecurityPasswordChangeResult({this.hibpUnavailable = false});

  final bool hibpUnavailable;
}

/// One login-history row. Subset of `/v1/auth/audit-log` filtered to
/// `auth.session.*` + `auth.password.*` + `auth.mfa.*` events; the
/// 90-day window is enforced gateway-side.
class WebSecurityLoginHistoryEntry {
  const WebSecurityLoginHistoryEntry({
    required this.eventId,
    required this.eventType,
    required this.friendlyLabel,
    required this.occurredAt,
    this.deviceLabel,
    this.userAgent,
    this.geoCity,
    this.geoCountry,
  });

  final String eventId;
  final String eventType;

  /// Stable human-readable label projected gateway-side from
  /// [eventType]. The screen renders this verbatim so a future
  /// server-side event type that lacks a friendly mapping still
  /// reads naturally.
  final String friendlyLabel;
  final DateTime occurredAt;
  final String? deviceLabel;
  final String? userAgent;
  final String? geoCity;
  final String? geoCountry;
}

class WebSecurityLoginHistoryListed {
  const WebSecurityLoginHistoryListed({required this.entries});

  final List<WebSecurityLoginHistoryEntry> entries;
}

/// Result returned by [WebSecurityGateway.requestMfaRecovery]. The
/// proxy returns 202 Accepted plus a queue receipt; the actual
/// recovery email lands out-of-band so the screen only needs the
/// queued + requestId hint.
class WebSecurityRecoveryRequestResult {
  const WebSecurityRecoveryRequestResult({
    required this.queued,
    this.requestId,
  });

  final bool queued;
  final String? requestId;
}

/// Narrow gateway interface the Security screen reads + writes
/// against. Mirrors the locked Phase 9 self-service Security routes
/// shape.
abstract class WebSecurityGateway {
  /// Lists the actor's MFA factors + any in-flight removal requests
  /// via `POST /v1/auth/mfa/factors/list`.
  Future<WebSecurityFactorsListed> listFactors();

  /// Begins a TOTP enrollment via `POST /v1/auth/mfa/totp/begin`.
  /// The proxy requires [userEmail] in the body so the issued
  /// otpauth URL carries an account label the operator's
  /// authenticator app recognises.
  Future<WebSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  });

  /// Confirms a TOTP enrollment via `POST /v1/auth/mfa/totp/confirm`.
  Future<WebSecurityMfaFactor> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  });

  /// Schedules a 24-hour delayed removal via
  /// `POST /v1/auth/mfa/factors/revoke`.
  Future<WebSecurityRevokeFactorResult> revokeFactor({
    required String factorId,
    required String idempotencyKey,
  });

  /// Cancels a pending removal via
  /// `POST /v1/auth/mfa/factors/removal/cancel`.
  Future<WebSecurityCancelRemovalResult> cancelFactorRemoval({
    required String requestId,
    required String idempotencyKey,
  });

  /// Queues an MFA recovery request via
  /// `POST /v1/auth/mfa/recovery/request`. The proxy accepts the
  /// request without an authenticated bearer token (recovery is for
  /// operators who have lost access to every enrolled factor) and
  /// emails the operator with a recovery link out-of-band.
  Future<WebSecurityRecoveryRequestResult> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  });

  /// Changes the actor's password via `POST /v1/auth/password/change`.
  /// The proxy reverifies [currentPassword] before applying the
  /// change, per the parity contract § Security write rule.
  Future<WebSecurityPasswordChangeResult> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  });

  /// Reads the actor's login history via `GET /v1/auth/audit-log` and
  /// projects it down to the Security-relevant subset
  /// (`auth.session.*` / `auth.password.*` / `auth.mfa.*`) within the
  /// last 90 days.
  Future<WebSecurityLoginHistoryListed> listLoginHistory();
}

/// HTTP wire response. Mirrors the envelope the live impl decodes so
/// the unit test can assert on status + body without re-implementing
/// the parser.
class WebSecurityResponse {
  const WebSecurityResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

/// Thrown when the proxy returns a non-2xx for a Security call, or
/// when the response body cannot be parsed.
class WebSecurityError implements Exception {
  const WebSecurityError({
    required this.code,
    required this.message,
    this.statusCode,
    this.rejections = const <String>[],
  });

  final String code;
  final String message;
  final int? statusCode;

  /// Server-supplied rejections array surfaced by
  /// `/v1/auth/password/change` when the new password fails policy.
  /// Each entry maps to a specific lock-step copy on the screen
  /// (e.g. `'too_short'` -> "Password must be at least 12 characters
  /// with one number and one symbol.").
  final List<String> rejections;

  @override
  String toString() =>
      'WebSecurityError(code: $code, status: $statusCode, message: $message)';
}

/// Path constants used by both the gateway and its tests.
class WebSecurityPaths {
  const WebSecurityPaths._();

  static const String mfaFactorsList = '/v1/auth/mfa/factors/list';
  static const String mfaTotpBegin = '/v1/auth/mfa/totp/begin';
  static const String mfaTotpConfirm = '/v1/auth/mfa/totp/confirm';
  static const String mfaRevoke = '/v1/auth/mfa/factors/revoke';
  static const String mfaCancelRemoval = '/v1/auth/mfa/factors/removal/cancel';
  static const String mfaRecoveryRequest = '/v1/auth/mfa/recovery/request';
  static const String passwordChange = '/v1/auth/password/change';
  static const String auditLog = '/v1/auth/audit-log';
}

/// Login-history filter set. The contract caps the surface to
/// `auth.session.*` / `auth.password.*` / `auth.mfa.*`. The actual
/// `auth_events_audit` row shapes use single-word event types
/// (e.g. `auth.signed_in`, `auth.password_changed`,
/// `auth.mfa_totp_enrolled`); the filter accepts both the
/// dot-separated contract form and the underscore-separated row form
/// so neither dialect drops events on the floor. The MFA factor
/// revocation lifecycle events emitted by the mobile gateway
/// (`mfa_factor_revocation_initiated` / `_completed` / `_cancelled`
/// without an `auth.` prefix) are also considered security-relevant.
const Set<String> kWebSecurityLoginHistoryEventPrefixes = <String>{
  // Dot-separated contract form.
  'auth.session.',
  'auth.password.',
  'auth.mfa.',
  // Underscore-separated row form actually present in auth_events_audit.
  'auth.session_',
  'auth.password_',
  'auth.mfa_',
  'auth.all_sessions_',
  'auth.signed_in',
  'auth.signed_out',
  'auth.login_',
  'auth.user.password_',
  'auth.user.mfa_',
  // MFA factor lifecycle events the mfa_operations_gateway writes
  // without the auth. prefix.
  'mfa_factor_revocation_',
};

/// 90-day window cap. Login-history reads ship with this floor so the
/// proxy can short-circuit even if the client forgets to send it.
const Duration kWebSecurityLoginHistoryWindow = Duration(days: 90);

/// Returns true iff [eventType] belongs to the Security login-history
/// projection. Public so the demo gateway + screen test reuse it.
bool isSecurityLoginHistoryEvent(String eventType) {
  for (final prefix in kWebSecurityLoginHistoryEventPrefixes) {
    if (eventType == prefix || eventType.startsWith(prefix)) return true;
  }
  return false;
}

/// Friendly label projection. Kept inline so the live + demo gateways
/// agree on the mapping without dragging in the mobile auth layer.
String webSecurityFriendlyLabelFor(String eventType) {
  switch (eventType) {
    case 'auth.signed_in':
    case 'auth.session.login':
    case 'auth.user.signed_in':
      return 'Signed in';
    case 'auth.session.refresh':
      return 'Session refreshed';
    case 'auth.session_revoked':
    case 'auth.session.revoked':
      return 'Session signed out';
    case 'auth.all_sessions_revoked':
      return 'Signed out of all devices';
    case 'auth.password_changed':
    case 'auth.password.change':
    case 'auth.user.password_changed':
      return 'Password changed';
    case 'auth.password_reset_requested':
    case 'auth.password.reset_requested':
      return 'Password reset requested';
    case 'auth.password_reset_confirmed':
    case 'auth.password.reset_confirmed':
      return 'Password reset completed';
    case 'auth.mfa_totp_enrolled':
    case 'auth.mfa.totp_enrolled':
      return 'Authenticator added';
    case 'auth.mfa_totp_enroll_failed':
    case 'auth.mfa.totp_enroll_failed':
      return 'Authenticator setup failed';
    case 'auth.mfa_factor_removed':
    case 'auth.mfa.factor_removed':
    case 'auth.user.mfa_factor_removed':
      return 'Authenticator removed';
    case 'auth.mfa_recovery_requested':
    case 'auth.mfa.recovery_requested':
    case 'auth.user.mfa_recovery_requested':
      return 'Authenticator recovery requested';
    case 'auth.login_failed':
      return 'Sign-in attempt failed';
    case 'mfa_factor_revocation_initiated':
      return 'Authenticator removal scheduled';
    case 'mfa_factor_revocation_completed':
      return 'Authenticator removal completed';
    case 'mfa_factor_revocation_cancelled':
      return 'Authenticator removal cancelled';
  }
  final tail = eventType.contains('.')
      ? eventType.substring(eventType.lastIndexOf('.') + 1)
      : eventType;
  if (tail.isEmpty) return eventType;
  final words = tail.split('_');
  final first = words.first;
  final rest = words.skip(1).join(' ');
  final head = first.isEmpty
      ? ''
      : first.substring(0, 1).toUpperCase() + first.substring(1);
  return rest.isEmpty ? head : '$head $rest';
}

/// Live `package:http` implementation. Reads the Firebase ID token
/// from the supplied provider on every call so refreshed tokens land
/// on the next request.
class WebSecurityGatewayLive implements WebSecurityGateway {
  WebSecurityGatewayLive({
    required this.proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
    DateTime Function()? now,
  })  : _idTokenProvider = idTokenProvider,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _now = now ?? DateTime.now;

  final Uri proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;
  final DateTime Function() _now;

  @override
  Future<WebSecurityFactorsListed> listFactors() async {
    final response = await _send(
      method: 'POST',
      path: WebSecurityPaths.mfaFactorsList,
      body: const <String, Object?>{},
    );
    _expectStatus(response, 200);
    return _parseFactors(response);
  }

  @override
  Future<WebSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebSecurityPaths.mfaTotpBegin,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'user_email': userEmail,
      },
    );
    _expectStatus(response, 200);
    final factorId = _readNonBlankString(response.body['factor_id']);
    final otpAuthUrl = _readNonBlankString(response.body['otp_auth_url']) ??
        _readNonBlankString(response.body['otpauth_url']);
    final secret = _readNonBlankString(response.body['secret_base32']) ??
        _readNonBlankString(response.body['shared_secret']);
    if (factorId == null || otpAuthUrl == null || secret == null) {
      throw _malformed(response, 'TOTP enrollment response was incomplete');
    }
    return WebSecurityTotpEnrollment(
      factorId: factorId,
      otpAuthUrl: otpAuthUrl,
      secretBase32: secret,
    );
  }

  @override
  Future<WebSecurityRecoveryRequestResult> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  }) async {
    // Recovery requests run unauthenticated (the operator has lost
    // access to every factor); the gateway still threads an
    // Idempotency-Key so a retried submit does not multiply the
    // queue.
    final url = proxyBaseUri.resolve(WebSecurityPaths.mfaRecoveryRequest);
    final headers = <String, String>{
      'accept': 'application/json',
      'content-type': 'application/json',
      'Idempotency-Key': idempotencyKey,
    };
    final body = <String, Object?>{
      'email': email,
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    };
    final request = http.Request('POST', url);
    request.headers.addAll(headers);
    request.body = jsonEncode(body);
    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const WebSecurityError(
        code: 'transport_timeout',
        message:
            'security gateway request timed out before reaching the proxy.',
      );
    } catch (error) {
      throw WebSecurityError(
        code: 'transport_error',
        message:
            'security gateway request failed before reaching the proxy '
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
    if (streamed.statusCode != 202 && streamed.statusCode != 200) {
      throw WebSecurityError(
        code: _readNonBlankString(responseBody['error']) ??
            'mfa_recovery_request_failed',
        message: _readNonBlankString(responseBody['message']) ??
            'proxy returned status ${streamed.statusCode}',
        statusCode: streamed.statusCode,
      );
    }
    final queued = responseBody['queued'];
    return WebSecurityRecoveryRequestResult(
      queued: queued is bool ? queued : true,
      requestId: _readNonBlankString(responseBody['request_id']),
    );
  }

  @override
  Future<WebSecurityMfaFactor> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebSecurityPaths.mfaTotpConfirm,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'factor_id': factorId,
        'one_time_code': oneTimeCode,
      },
    );
    _expectStatus(response, 200);
    final confirmedFactorId = _readNonBlankString(response.body['factor_id']);
    if (confirmedFactorId == null) {
      throw _malformed(response, 'TOTP confirm response was incomplete');
    }
    final enrolledAtRaw = _readNonBlankString(response.body['enrolled_at']);
    return WebSecurityMfaFactor(
      factorId: confirmedFactorId,
      factorType: _readNonBlankString(response.body['factor_type']) ?? 'totp',
      enrolledAt: enrolledAtRaw == null
          ? _now().toUtc()
          : DateTime.parse(enrolledAtRaw).toUtc(),
      issuerLabel:
          _readNonBlankString(response.body['issuer_label']) ?? 'Forge & Flow',
    );
  }

  @override
  Future<WebSecurityRevokeFactorResult> revokeFactor({
    required String factorId,
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebSecurityPaths.mfaRevoke,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{'factor_id': factorId},
    );
    _expectStatus(response, 200);
    final revoked = response.body['revoked'];
    final executeAfterRaw = _readNonBlankString(response.body['execute_after']);
    return WebSecurityRevokeFactorResult(
      revoked: revoked is bool ? revoked : false,
      requestId: _readNonBlankString(response.body['request_id']),
      executeAfter: executeAfterRaw == null
          ? null
          : DateTime.parse(executeAfterRaw).toUtc(),
    );
  }

  @override
  Future<WebSecurityCancelRemovalResult> cancelFactorRemoval({
    required String requestId,
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebSecurityPaths.mfaCancelRemoval,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{'request_id': requestId},
    );
    _expectStatus(response, 200);
    final cancelled = response.body['cancelled'];
    return WebSecurityCancelRemovalResult(
      cancelled: cancelled is bool ? cancelled : false,
    );
  }

  @override
  Future<WebSecurityPasswordChangeResult> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebSecurityPaths.passwordChange,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    );
    _expectStatus(response, 200);
    return WebSecurityPasswordChangeResult(
      hibpUnavailable: response.body['hibp_unavailable'] == true,
    );
  }

  @override
  Future<WebSecurityLoginHistoryListed> listLoginHistory() async {
    final since = _now().toUtc().subtract(kWebSecurityLoginHistoryWindow);
    final url = proxyBaseUri.resolve(WebSecurityPaths.auditLog).replace(
      queryParameters: <String, String>{
        'from': since.toIso8601String(),
        'limit': '200',
      },
    );
    final response = await _sendUrl(method: 'GET', url: url);
    _expectStatus(response, 200);
    return _parseLoginHistory(response, since: since);
  }

  WebSecurityFactorsListed _parseFactors(WebSecurityResponse response) {
    final rawFactors = response.body['factors'];
    if (rawFactors is! List) {
      throw _malformed(response, 'MFA factors response was incomplete');
    }
    final factors = <WebSecurityMfaFactor>[
      for (final raw in rawFactors) _factorFromJson(response, raw),
    ];
    final rawRemovals = response.body['removal_requests'];
    final removals = <WebSecurityMfaRemoval>[
      if (rawRemovals is List)
        for (final raw in rawRemovals) _removalFromJson(response, raw),
    ];
    return WebSecurityFactorsListed(
      factors: List<WebSecurityMfaFactor>.unmodifiable(factors),
      removalRequests: List<WebSecurityMfaRemoval>.unmodifiable(removals),
    );
  }

  WebSecurityMfaFactor _factorFromJson(
    WebSecurityResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'MFA factor payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final factorId = _readNonBlankString(json['factor_id']);
    final factorType = _readNonBlankString(json['factor_type']);
    final enrolledAtRaw = _readNonBlankString(json['enrolled_at']);
    if (factorId == null || factorType == null || enrolledAtRaw == null) {
      throw _malformed(response, 'MFA factor payload was incomplete');
    }
    final lastUsedAtRaw = _readNonBlankString(json['last_used_at']);
    final canRevoke = json['can_revoke'];
    return WebSecurityMfaFactor(
      factorId: factorId,
      factorType: factorType,
      enrolledAt: DateTime.parse(enrolledAtRaw).toUtc(),
      lastUsedAt: lastUsedAtRaw == null
          ? null
          : DateTime.parse(lastUsedAtRaw).toUtc(),
      issuerLabel: _readNonBlankString(json['issuer_label']) ?? 'Forge & Flow',
      canRevoke: canRevoke is bool ? canRevoke : true,
    );
  }

  WebSecurityMfaRemoval _removalFromJson(
    WebSecurityResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'MFA removal payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final requestId = _readNonBlankString(json['request_id']);
    final factorId = _readNonBlankString(json['factor_id']);
    final status = _readNonBlankString(json['status']);
    final executeAfterRaw = _readNonBlankString(json['execute_after']);
    if (requestId == null ||
        factorId == null ||
        status == null ||
        executeAfterRaw == null) {
      throw _malformed(response, 'MFA removal payload was incomplete');
    }
    final completedAtRaw = _readNonBlankString(json['completed_at']);
    return WebSecurityMfaRemoval(
      requestId: requestId,
      factorId: factorId,
      status: status,
      executeAfter: DateTime.parse(executeAfterRaw).toUtc(),
      completedAt: completedAtRaw == null
          ? null
          : DateTime.parse(completedAtRaw).toUtc(),
    );
  }

  WebSecurityLoginHistoryListed _parseLoginHistory(
    WebSecurityResponse response, {
    required DateTime since,
  }) {
    final raw = response.body['entries'] ?? response.body['events'];
    if (raw is! List) {
      throw _malformed(response, 'audit log response was incomplete');
    }
    final filtered = <WebSecurityLoginHistoryEntry>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final json = Map<String, Object?>.from(entry);
      final eventType = _readNonBlankString(json['event_type']);
      if (eventType == null) continue;
      if (!isSecurityLoginHistoryEvent(eventType)) continue;
      final occurredAtRaw =
          _readNonBlankString(json['occurred_at']) ??
              _readNonBlankString(json['created_at']);
      if (occurredAtRaw == null) continue;
      final occurredAt = DateTime.parse(occurredAtRaw).toUtc();
      if (occurredAt.isBefore(since)) continue;
      filtered.add(
        WebSecurityLoginHistoryEntry(
          eventId: _readNonBlankString(json['event_id']) ?? occurredAtRaw,
          eventType: eventType,
          friendlyLabel: webSecurityFriendlyLabelFor(eventType),
          occurredAt: occurredAt,
          deviceLabel: _readNonBlankString(json['device_label']),
          userAgent: _readNonBlankString(json['user_agent']),
          geoCity: _readNonBlankString(json['geo_city']),
          geoCountry: _readNonBlankString(json['geo_country']),
        ),
      );
    }
    filtered.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return WebSecurityLoginHistoryListed(
      entries: List<WebSecurityLoginHistoryEntry>.unmodifiable(filtered),
    );
  }

  Future<WebSecurityResponse> _send({
    required String method,
    required String path,
    String? idempotencyKey,
    Map<String, Object?>? body,
  }) {
    return _sendUrl(
      method: method,
      url: proxyBaseUri.resolve(path),
      idempotencyKey: idempotencyKey,
      body: body,
    );
  }

  Future<WebSecurityResponse> _sendUrl({
    required String method,
    required Uri url,
    String? idempotencyKey,
    Map<String, Object?>? body,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const WebSecurityError(
        code: 'no_id_token',
        message:
            'security gateway has no live Firebase ID token to attach to '
            'the request.',
      );
    }
    final headers = <String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer ${token.trim()}',
      if (body != null) 'content-type': 'application/json',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
    final request = http.Request(method, url);
    request.headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const WebSecurityError(
        code: 'transport_timeout',
        message:
            'security gateway request timed out before reaching the proxy.',
      );
    } catch (error) {
      throw WebSecurityError(
        code: 'transport_error',
        message:
            'security gateway request failed before reaching the proxy '
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
    return WebSecurityResponse(
      statusCode: streamed.statusCode,
      body: responseBody,
    );
  }

  void _expectStatus(WebSecurityResponse response, int expected) {
    if (response.statusCode == expected) return;
    final code = _readNonBlankString(response.body['error']) ??
        _readNonBlankString(response.body['code']) ??
        'security_failed';
    throw WebSecurityError(
      code: code,
      message: _readNonBlankString(response.body['message']) ??
          'proxy returned status ${response.statusCode}',
      statusCode: response.statusCode,
      rejections: _rejections(response.body['rejections']),
    );
  }

  WebSecurityError _malformed(
    WebSecurityResponse response,
    String message,
  ) {
    return WebSecurityError(
      code: 'malformed_response',
      message: message,
      statusCode: response.statusCode,
    );
  }

  static List<String> _rejections(Object? raw) {
    if (raw is! List) return const <String>[];
    return List<String>.unmodifiable(raw.whereType<String>());
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
