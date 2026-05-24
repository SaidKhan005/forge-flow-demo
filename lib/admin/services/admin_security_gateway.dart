// Audit fix-first #7 (cross-surface parity finding G4) — admin
// console self-service Security gateway (MFA enroll/confirm/recover +
// password change).
//
// The F&F Ops admin console pins 4 MFA-fresh-gated actions
// (`admin_routes.dart` `_isAdminMfaFresh` ~:94-114; gates :816-819)
// yet, before this slice, gave an admin NO way to enroll/recover their
// own MFA or change their password — the My Account Security card was
// read-only. An admin who never enrolled MFA out-of-band was
// permanently locked out of those 4 actions.
//
// Step-1 verdict: A — admin MFA/password is meant to be self-served
// in-app against the EXISTING shared self-service proxy routes, NOT
// provisioned out-of-band. Evidence:
//   * `docs/contracts/team_roles_hierarchy_console_parity_contract.md`
//     :38 — the "Security (MFA + password + login history)" row maps
//     the F&F admin's OWN-user self-service to `/v1/auth/mfa/*` +
//     `/v1/auth/password/*` (the SAME routes operator-web + mobile
//     use). The `/v1/admin/auth/users/:id/*` paths are for an admin
//     acting on SOMEONE ELSE — not their own factors.
//   * Same contract :208 — Security row, F&F admin self-service is
//     "(own user)"; current-password reverification per write.
//   * Same contract :221 — "No new backend routes" — every read/write
//     hits a route already shipped by Phase 9 + 11A.1.
//   * The proxy resolves the acting user from the verified bearer
//     token (`_resolveOperatorContextOrWrite`), so an admin Firebase
//     ID token targets the admin automatically:
//       - password change handler: advisor_proxy.dart:10406-10473
//         (scope from `_resolveOperatorContextOrWrite` :10416-10421;
//         200 `{ok:true,hibp_unavailable}`; PasswordChangeRejected →
//         `{error,message,rejections}`; 503 fail-closed).
//       - MFA begin/confirm/list handler: advisor_proxy.dart
//         :10927-11123 (scope :10937-10942; bearer required
//         :10943-10952; begin 200 `{factor_id,secret_base32,
//         otp_auth_url}` :10995-10999; confirm 200 `{factor_id}`
//         :11065-11067; list 200 `{factors:[...],removal_requests:
//         [...]}` :11087-11121).
//       - recovery request handler: advisor_proxy.dart:10858-10925
//         (UNauthenticated by design — recovery is for an actor who
//         has lost access to every factor; body `{email,reason?}`;
//         202 `{ok:true,queued,request_id?}`).
//
// Wire shape mirrors the sibling admin gateways exactly
// (`HttpAdminSessionsGateway` / `HttpAdminAccountGateway`): the bearer
// source is injected so the admin Firebase ID-token stream binds at
// startup and tests pin a synthetic value; every state-changing POST
// carries a required CALLER-stable `Idempotency-Key` threaded through
// unchanged (no fresh-key-per-call G60 bug — the screen layer mints
// one key per user action). No new admin-only route, no parallel
// permission catalog entry (CLAUDE.md HP #11 + R-2). Proxy code is
// NOT touched by this slice.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'admin_http_timeout.dart';

/// Bearer source the gateway attaches to authenticated proxy calls.
/// Production binds this to the admin Firebase ID-token stream (the
/// same `_firebaseIdTokenProvider` the sibling admin gateways use);
/// tests pin a synthetic value.
typedef AdminSecurityBearerTokenProvider = Future<String> Function();

/// Narrow error the gateway throws so the screen layer can render a
/// calm friendly message. Mirrors `AdminSessionsGatewayError`. The
/// optional [rejections] carries the server's password-policy
/// rejection codes (parity with `WebSecurityError.rejections`).
class AdminSecurityGatewayError implements Exception {
  const AdminSecurityGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
    this.rejections = const <String>[],
  });

  final int statusCode;
  final String errorCode;
  final String message;
  final List<String> rejections;

  /// True iff this is the proxy's "you must sign in again before
  /// changing two-factor sign-in" signal. Mirrors the operator-web
  /// classifier, which folds BOTH the `mfa_freshness_required` 403 and
  /// the RFC 9470 step-up `insufficient_user_authentication` sentinel
  /// into the same "sign in again" remedy. Kept inside `lib/admin/` so
  /// the admin build never imports `lib/operator_web/`.
  bool get requiresFreshSignIn =>
      errorCode == 'mfa_freshness_required' ||
      errorCode == 'insufficient_user_authentication';

  @override
  String toString() =>
      'AdminSecurityGatewayError($statusCode/$errorCode): $message';
}

/// One enrolled MFA factor row. Mirrors the operator-web
/// `WebSecurityMfaFactor` shape.
@immutable
class AdminSecurityMfaFactor {
  const AdminSecurityMfaFactor({
    required this.factorId,
    required this.factorType,
    required this.enrolledAt,
    required this.issuerLabel,
    this.lastUsedAt,
  });

  final String factorId;
  final String factorType;
  final DateTime enrolledAt;
  final DateTime? lastUsedAt;
  final String issuerLabel;
}

/// One in-flight MFA factor removal request. Mirrors the operator-web
/// `WebSecurityMfaRemoval` shape. Self-service removal is always a
/// 24-hour delayed request (never an immediate delete), so the screen
/// surfaces the [executeAfter] date + a "Cancel removal" affordance
/// while [status] is `'pending'`.
@immutable
class AdminSecurityMfaRemoval {
  const AdminSecurityMfaRemoval({
    required this.requestId,
    required this.factorId,
    required this.status,
    required this.executeAfter,
    this.completedAt,
  });

  final String requestId;
  final String factorId;

  /// `'pending'` / `'completed'` / `'cancelled'` per the contract.
  final String status;
  final DateTime executeAfter;
  final DateTime? completedAt;

  bool get isPending => status == 'pending';
}

/// Snapshot of the admin's enrolled MFA factors plus any in-flight
/// removal requests. Before this slice the gateway IGNORED the
/// `removal_requests` array the proxy returns (see the file header
/// note); the card could not show a pending removal. Parsing it lets
/// the Two-factor card render the same pending/scheduled state
/// operator-web shows.
@immutable
class AdminSecurityFactorsListed {
  const AdminSecurityFactorsListed({
    required this.factors,
    this.removalRequests = const <AdminSecurityMfaRemoval>[],
  });

  final List<AdminSecurityMfaFactor> factors;
  final List<AdminSecurityMfaRemoval> removalRequests;

  bool get hasEnrolledFactor => factors.isNotEmpty;

  /// The first still-pending removal request, or null if none. The
  /// self-service flow only ever has one factor + one removal in play
  /// for the admin, so the card reads off the first pending row.
  AdminSecurityMfaRemoval? get pendingRemoval {
    for (final removal in removalRequests) {
      if (removal.isPending) return removal;
    }
    return null;
  }
}

/// Artifact returned by [AdminSecurityGateway.beginTotpEnrollment].
/// The screen renders the otpauth URL + shared secret so the admin
/// can scan or paste either into their authenticator app.
@immutable
class AdminSecurityTotpEnrollment {
  const AdminSecurityTotpEnrollment({
    required this.factorId,
    required this.otpAuthUrl,
    required this.secretBase32,
  });

  final String factorId;
  final String otpAuthUrl;
  final String secretBase32;
}

/// Result of confirming a TOTP enrollment.
@immutable
class AdminSecurityTotpConfirmed {
  const AdminSecurityTotpConfirmed({required this.factorId});

  final String factorId;
}

/// Result of [AdminSecurityGateway.changePassword].
@immutable
class AdminSecurityPasswordChanged {
  const AdminSecurityPasswordChanged({this.hibpUnavailable = false});

  final bool hibpUnavailable;
}

/// Result of [AdminSecurityGateway.requestMfaRecovery]. The proxy
/// returns 202 + a queue receipt; the recovery email lands
/// out-of-band so the screen only needs the queued + requestId hint.
@immutable
class AdminSecurityRecoveryRequested {
  const AdminSecurityRecoveryRequested({
    required this.queued,
    this.requestId,
  });

  final bool queued;
  final String? requestId;
}

/// Result of [AdminSecurityGateway.requestFactorRemoval]. Mirrors the
/// operator-web `WebSecurityRevokeFactorResult`. Self-service removal
/// is always a 24-hour delayed request, so [revoked] is `false` and
/// the proxy returns a [requestId] + an [executeAfter] pinned 24 hours
/// into the future. The card uses [executeAfter] to render the
/// scheduled date and [requestId] to wire the Cancel-removal action.
@immutable
class AdminSecurityFactorRemovalRequested {
  const AdminSecurityFactorRemovalRequested({
    required this.revoked,
    this.requestId,
    this.executeAfter,
  });

  final bool revoked;
  final String? requestId;
  final DateTime? executeAfter;
}

/// Result of [AdminSecurityGateway.cancelFactorRemoval]. Mirrors the
/// operator-web `WebSecurityCancelRemovalResult`.
@immutable
class AdminSecurityFactorRemovalCancelled {
  const AdminSecurityFactorRemovalCancelled({required this.cancelled});

  final bool cancelled;
}

/// One account audit / sign-in history row projected from
/// `GET /v1/auth/audit-log`. Mirrors the operator-web
/// `WebSecurityLoginHistoryEntry` shape so the admin My Account
/// surface reads identically.
@immutable
class AdminSecurityAuditEntry {
  const AdminSecurityAuditEntry({
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

  /// Human-readable label projected from [eventType] so an unmapped
  /// future event type still reads naturally.
  final String friendlyLabel;
  final DateTime occurredAt;
  final String? deviceLabel;
  final String? userAgent;
  final String? geoCity;
  final String? geoCountry;
}

/// Snapshot of the admin's projected audit rows, newest first.
@immutable
class AdminSecurityAuditListed {
  const AdminSecurityAuditListed({required this.entries});

  final List<AdminSecurityAuditEntry> entries;
}

/// 90-day cap for the admin "Recent sign-in activity" projection.
/// Mirrors the operator-web `kWebSecurityLoginHistoryWindow`.
const Duration kAdminSignInHistoryWindow = Duration(days: 90);

/// Security-relevant event prefixes for the sign-in history filter.
/// Duplicated from the operator-web Security gateway (kept inside
/// `lib/admin/` so the admin build never imports `lib/operator_web/`).
/// When the proxy adds a security event type, both sides update.
const Set<String> kAdminSignInHistoryEventPrefixes = <String>{
  'auth.session.',
  'auth.password.',
  'auth.mfa.',
  'auth.session_',
  'auth.password_',
  'auth.mfa_',
  'auth.all_sessions_',
  'auth.signed_in',
  'auth.signed_out',
  'auth.login_',
  'auth.user.password_',
  'auth.user.mfa_',
  'mfa_factor_revocation_',
};

/// True iff [eventType] belongs to the admin sign-in history
/// projection (the security-relevant subset).
bool adminIsSignInHistoryEvent(String eventType) {
  for (final prefix in kAdminSignInHistoryEventPrefixes) {
    if (eventType == prefix || eventType.startsWith(prefix)) return true;
  }
  return false;
}

/// Friendly label projection. Mirrors the operator-web
/// `webSecurityFriendlyLabelFor` mapping so the two surfaces read the
/// same. The screen renders the result verbatim.
String adminAuditFriendlyLabelFor(String eventType) {
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

/// Self-service Security surface for the F&F admin console. Every
/// method targets the SIGNED-IN admin (the proxy resolves the actor
/// from the verified bearer token); [requestMfaRecovery] is the one
/// exception — it runs unauthenticated because it exists precisely
/// for the locked-out admin who cannot present a fresh factor.
abstract class AdminSecurityGateway {
  /// Lists the signed-in admin's enrolled MFA factors via
  /// `POST /v1/auth/mfa/factors/list`.
  Future<AdminSecurityFactorsListed> listFactors();

  /// Begins a TOTP enrollment via `POST /v1/auth/mfa/totp/begin`. The
  /// proxy requires [userEmail] so the issued otpauth URL carries an
  /// account label the admin's authenticator app recognises.
  Future<AdminSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  });

  /// Confirms a TOTP enrollment via `POST /v1/auth/mfa/totp/confirm`.
  Future<AdminSecurityTotpConfirmed> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  });

  /// Schedules a 24-hour delayed removal of [factorId] via
  /// `POST /v1/auth/mfa/factors/revoke` (the SAME self-scoped route
  /// operator-web + mobile use; the proxy resolves the acting admin
  /// from the verified bearer token). Returns `revoked:false` plus a
  /// request id + an execute-after timestamp pinned 24 hours out.
  ///
  /// [freshAuthProof] mirrors operator-web's freshness gate: the proxy
  /// reverifies a recent step-up before scheduling removal. When the
  /// caller cannot present one (or the proxy rejects it), the gateway
  /// throws an [AdminSecurityGatewayError] whose [requiresFreshSignIn]
  /// is true so the screen can surface a "sign in again" remedy.
  Future<AdminSecurityFactorRemovalRequested> requestFactorRemoval({
    required String factorId,
    required String idempotencyKey,
    String? freshAuthProof,
  });

  /// Cancels a pending removal via
  /// `POST /v1/auth/mfa/factors/removal/cancel` (self-scoped; actor
  /// resolved from the bearer token).
  Future<AdminSecurityFactorRemovalCancelled> cancelFactorRemoval({
    required String requestId,
    required String idempotencyKey,
  });

  /// Changes the admin's password via `POST /v1/auth/password/change`.
  /// The proxy reverifies [currentPassword] before applying.
  Future<AdminSecurityPasswordChanged> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  });

  /// Queues an MFA recovery request via
  /// `POST /v1/auth/mfa/recovery/request`. The proxy accepts this
  /// WITHOUT an authenticated bearer token (recovery is for an admin
  /// who has lost access to every enrolled factor) and emails a
  /// recovery link out-of-band.
  Future<AdminSecurityRecoveryRequested> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  });

  /// Lists the signed-in admin's recent SECURITY events (sign-ins,
  /// password changes, authenticator events) via
  /// `GET /v1/auth/audit-log`, capped at the last 90 days. Mirrors the
  /// operator-web Security "Recent sign-in activity" projection.
  Future<AdminSecurityAuditListed> listSignInHistory();
}

/// Production HTTP implementation. Constructor shape + bearer source +
/// timeout mirror `HttpAdminSessionsGateway`.
class HttpAdminSecurityGateway implements AdminSecurityGateway {
  HttpAdminSecurityGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
    DateTime Function()? now,
  })  : _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _now = now ?? DateTime.now;

  final Uri baseUri;
  final AdminSecurityBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;
  final DateTime Function() _now;

  // Path constants intentionally duplicate the proxy's
  // `authMfaTotpBeginPath` etc. The proxy file lives under tool/ and
  // lib/ cannot import it without dragging the whole proxy into the
  // Flutter binary. The strings are part of the wire contract; the
  // proxy endpoint tests pin both sides.
  static const String mfaFactorsListPath = '/v1/auth/mfa/factors/list';
  static const String mfaTotpBeginPath = '/v1/auth/mfa/totp/begin';
  static const String mfaTotpConfirmPath = '/v1/auth/mfa/totp/confirm';
  static const String mfaRevokePath = '/v1/auth/mfa/factors/revoke';
  static const String mfaRemovalCancelPath =
      '/v1/auth/mfa/factors/removal/cancel';
  static const String mfaRecoveryRequestPath = '/v1/auth/mfa/recovery/request';
  static const String passwordChangePath = '/v1/auth/password/change';
  static const String auditLogPath = '/v1/auth/audit-log';

  @override
  Future<AdminSecurityFactorsListed> listFactors() async {
    final body = await _send(
      method: 'POST',
      path: mfaFactorsListPath,
      jsonBody: const <String, Object?>{},
    );
    final raw = body['factors'];
    if (raw is! List) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin MFA factors proxy returned an incomplete response',
      );
    }
    final rawRemovals = body['removal_requests'];
    return AdminSecurityFactorsListed(
      factors: List<AdminSecurityMfaFactor>.unmodifiable(
        raw.map(_factorFromJson),
      ),
      removalRequests: List<AdminSecurityMfaRemoval>.unmodifiable(
        rawRemovals is List
            ? rawRemovals.map(_removalFromJson)
            : const <AdminSecurityMfaRemoval>[],
      ),
    );
  }

  @override
  Future<AdminSecurityFactorRemovalRequested> requestFactorRemoval({
    required String factorId,
    required String idempotencyKey,
    String? freshAuthProof,
  }) async {
    final body = await _send(
      method: 'POST',
      path: mfaRevokePath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'factor_id': factorId,
        if (freshAuthProof != null && freshAuthProof.trim().isNotEmpty)
          'fresh_auth_proof': freshAuthProof.trim(),
      },
    );
    final revoked = body['revoked'];
    final executeAfterRaw = _readNonBlank(body['execute_after']);
    return AdminSecurityFactorRemovalRequested(
      revoked: revoked is bool ? revoked : false,
      requestId: _readNonBlank(body['request_id']),
      executeAfter:
          executeAfterRaw == null ? null : DateTime.parse(executeAfterRaw).toUtc(),
    );
  }

  @override
  Future<AdminSecurityFactorRemovalCancelled> cancelFactorRemoval({
    required String requestId,
    required String idempotencyKey,
  }) async {
    final body = await _send(
      method: 'POST',
      path: mfaRemovalCancelPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{'request_id': requestId},
    );
    final cancelled = body['cancelled'];
    return AdminSecurityFactorRemovalCancelled(
      cancelled: cancelled is bool ? cancelled : false,
    );
  }

  @override
  Future<AdminSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  }) async {
    final trimmedEmail = userEmail.trim();
    if (trimmedEmail.isEmpty) {
      throw const AdminSecurityGatewayError(
        statusCode: 400,
        errorCode: 'missing_user_email',
        message: 'an account email is required to begin enrollment',
      );
    }
    final body = await _send(
      method: 'POST',
      path: mfaTotpBeginPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{'user_email': trimmedEmail},
    );
    final factorId = _readNonBlank(body['factor_id']);
    final otpAuthUrl = _readNonBlank(body['otp_auth_url']) ??
        _readNonBlank(body['otpauth_url']);
    final secret = _readNonBlank(body['secret_base32']) ??
        _readNonBlank(body['shared_secret']);
    if (factorId == null || otpAuthUrl == null || secret == null) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin TOTP begin proxy returned an incomplete response',
      );
    }
    return AdminSecurityTotpEnrollment(
      factorId: factorId,
      otpAuthUrl: otpAuthUrl,
      secretBase32: secret,
    );
  }

  @override
  Future<AdminSecurityTotpConfirmed> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  }) async {
    final body = await _send(
      method: 'POST',
      path: mfaTotpConfirmPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'factor_id': factorId,
        'one_time_code': oneTimeCode,
      },
    );
    final confirmedFactorId = _readNonBlank(body['factor_id']);
    if (confirmedFactorId == null) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin TOTP confirm proxy returned an incomplete response',
      );
    }
    return AdminSecurityTotpConfirmed(factorId: confirmedFactorId);
  }

  @override
  Future<AdminSecurityPasswordChanged> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  }) async {
    final body = await _send(
      method: 'POST',
      path: passwordChangePath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    );
    return AdminSecurityPasswordChanged(
      hibpUnavailable: body['hibp_unavailable'] == true,
    );
  }

  @override
  Future<AdminSecurityRecoveryRequested> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  }) async {
    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty) {
      throw const AdminSecurityGatewayError(
        statusCode: 400,
        errorCode: 'missing_email',
        message: 'an account email is required to request recovery',
      );
    }
    // Recovery runs UNauthenticated (the admin has lost access to
    // every factor); still thread an Idempotency-Key so a retried
    // submit does not multiply the recovery queue.
    final uri = baseUri.resolve(mfaRecoveryRequestPath);
    final request = http.Request('POST', uri)
      ..headers['accept'] = 'application/json'
      ..headers['content-type'] = 'application/json'
      ..headers['Idempotency-Key'] = idempotencyKey
      ..bodyBytes = utf8.encode(jsonEncode(<String, Object?>{
        'email': trimmedEmail,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      }));
    final parsed = await _dispatch(request, expectStatuses: const <int>[
      200,
      202,
    ]);
    final queued = parsed['queued'];
    return AdminSecurityRecoveryRequested(
      queued: queued is bool ? queued : true,
      requestId: _readNonBlank(parsed['request_id']),
    );
  }

  /// Lists the admin's own recent sign-in history via
  /// `GET /v1/auth/audit-log`. The proxy resolves the actor from the
  /// verified bearer token, so the admin's own events come back
  /// automatically; the result is projected to the Security-relevant
  /// sign-in subset and capped at the 90-day window.
  @override
  Future<AdminSecurityAuditListed> listSignInHistory() async {
    final since = _now().toUtc().subtract(kAdminSignInHistoryWindow);
    final uri = baseUri.resolve(auditLogPath).replace(
      queryParameters: <String, String>{
        'from': since.toIso8601String(),
        'limit': '200',
      },
    );
    final token = await bearerTokenProvider();
    final request = http.Request('GET', uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    final body = await _dispatch(request, expectStatuses: const <int>[200]);
    final raw = body['entries'] ?? body['events'];
    if (raw is! List) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin audit-log proxy returned an incomplete response',
      );
    }
    final out = <AdminSecurityAuditEntry>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final json = Map<String, Object?>.from(entry);
      final eventType = _readNonBlank(json['event_type']);
      if (eventType == null) continue;
      if (!adminIsSignInHistoryEvent(eventType)) continue;
      final occurredAtRaw = _readNonBlank(json['occurred_at']) ??
          _readNonBlank(json['created_at']);
      if (occurredAtRaw == null) continue;
      final occurredAt = DateTime.parse(occurredAtRaw).toUtc();
      if (occurredAt.isBefore(since)) continue;
      out.add(
        AdminSecurityAuditEntry(
          eventId: _readNonBlank(json['event_id']) ?? occurredAtRaw,
          eventType: eventType,
          friendlyLabel: adminAuditFriendlyLabelFor(eventType),
          occurredAt: occurredAt,
          deviceLabel: _readNonBlank(json['device_label']),
          userAgent: _readNonBlank(json['user_agent']),
          geoCity: _readNonBlank(json['geo_city']),
          geoCountry: _readNonBlank(json['geo_country']),
        ),
      );
    }
    out.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return AdminSecurityAuditListed(
      entries: List<AdminSecurityAuditEntry>.unmodifiable(out),
    );
  }

  AdminSecurityMfaFactor _factorFromJson(Object? raw) {
    if (raw is! Map) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin MFA factor row was malformed',
      );
    }
    final json = Map<String, Object?>.from(raw);
    final factorId = _readNonBlank(json['factor_id']);
    final factorType = _readNonBlank(json['factor_type']);
    final enrolledAtRaw = _readNonBlank(json['enrolled_at']);
    if (factorId == null || factorType == null || enrolledAtRaw == null) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin MFA factor row was incomplete',
      );
    }
    final lastUsedAtRaw = _readNonBlank(json['last_used_at']);
    return AdminSecurityMfaFactor(
      factorId: factorId,
      factorType: factorType,
      enrolledAt: DateTime.parse(enrolledAtRaw).toUtc(),
      lastUsedAt:
          lastUsedAtRaw == null ? null : DateTime.parse(lastUsedAtRaw).toUtc(),
      issuerLabel: _readNonBlank(json['issuer_label']) ?? 'Forge & Flow',
    );
  }

  AdminSecurityMfaRemoval _removalFromJson(Object? raw) {
    if (raw is! Map) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin MFA removal row was malformed',
      );
    }
    final json = Map<String, Object?>.from(raw);
    final requestId = _readNonBlank(json['request_id']);
    final factorId = _readNonBlank(json['factor_id']);
    final status = _readNonBlank(json['status']);
    final executeAfterRaw = _readNonBlank(json['execute_after']);
    if (requestId == null ||
        factorId == null ||
        status == null ||
        executeAfterRaw == null) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin MFA removal row was incomplete',
      );
    }
    final completedAtRaw = _readNonBlank(json['completed_at']);
    return AdminSecurityMfaRemoval(
      requestId: requestId,
      factorId: factorId,
      status: status,
      executeAfter: DateTime.parse(executeAfterRaw).toUtc(),
      completedAt:
          completedAtRaw == null ? null : DateTime.parse(completedAtRaw).toUtc(),
    );
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    String? idempotencyKey,
    Map<String, Object?>? jsonBody,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    return _dispatch(request, expectStatuses: const <int>[200]);
  }

  Future<Map<String, Object?>> _dispatch(
    http.Request request, {
    required List<int> expectStatuses,
  }) async {
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw AdminSecurityGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin security proxy timed out after ${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) parsed = decoded.cast<String, Object?>();
      } on FormatException {
        // Non-JSON body (e.g. an LB error page) — leave parsed empty
        // so the status branch surfaces a calm error rather than
        // parsing garbage.
      }
    }
    if (expectStatuses.contains(response.statusCode)) {
      return parsed;
    }
    throw AdminSecurityGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: (parsed['message'] as String?) ??
          'admin security proxy returned an error',
      rejections: _rejections(parsed['rejections']),
    );
  }

  static List<String> _rejections(Object? raw) {
    if (raw is! List) return const <String>[];
    return List<String>.unmodifiable(raw.whereType<String>());
  }

  static String? _readNonBlank(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  // Exposed so a future caller can pin "now" without reflection; kept
  // private-by-convention via the leading underscore on the field.
  // ignore: unused_element
  DateTime _clock() => _now().toUtc();
}

/// In-memory demo gateway. Mirrors a seeded "no factor enrolled" admin
/// so the kDemoMode / share-preview walkthrough renders the enroll +
/// password-change + recovery surface without a backend. Parity with
/// `InMemoryAdminSessionsGateway` / `InMemoryAdminAccountGateway`.
class InMemoryAdminSecurityGateway implements AdminSecurityGateway {
  InMemoryAdminSecurityGateway({
    bool seedEnrolledFactor = false,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (seedEnrolledFactor) {
      _factors.add(
        AdminSecurityMfaFactor(
          factorId: 'demo-admin-factor-1',
          factorType: 'totp',
          enrolledAt: _now().toUtc().subtract(const Duration(days: 30)),
          issuerLabel: 'Forge & Flow',
        ),
      );
    }
  }

  final DateTime Function() _now;
  final List<AdminSecurityMfaFactor> _factors = <AdminSecurityMfaFactor>[];
  final List<String> idempotencyKeys = <String>[];
  String? _pendingFactorId;

  // In-flight removal request (the self-service flow only ever has one
  // factor + one pending removal at a time for the admin). Revoke
  // schedules it 24h out; cancel clears it; listFactors reflects it.
  AdminSecurityMfaRemoval? _pendingRemoval;
  int _removalSeq = 0;

  /// 24-hour grace window the InMemory gateway schedules removals out
  /// by, mirroring the live proxy. Exposed so the screen test can pin
  /// "now" relative to the scheduled date.
  static const Duration removalGrace = Duration(hours: 24);

  @override
  Future<AdminSecurityFactorsListed> listFactors() async =>
      AdminSecurityFactorsListed(
        factors: List<AdminSecurityMfaFactor>.unmodifiable(_factors),
        removalRequests: _pendingRemoval == null
            ? const <AdminSecurityMfaRemoval>[]
            : <AdminSecurityMfaRemoval>[_pendingRemoval!],
      );

  @override
  Future<AdminSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    _pendingFactorId = 'demo-admin-pending-factor';
    return AdminSecurityTotpEnrollment(
      factorId: _pendingFactorId!,
      otpAuthUrl:
          'otpauth://totp/Forge%20%26%20Flow:$userEmail?secret=DEMOSECRET234567'
          '&issuer=Forge%20%26%20Flow',
      secretBase32: 'DEMOSECRET234567',
    );
  }

  @override
  Future<AdminSecurityTotpConfirmed> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    if (oneTimeCode.trim().length != 6) {
      throw const AdminSecurityGatewayError(
        statusCode: 422,
        errorCode: 'mfa_totp_invalid_code',
        message: 'That code did not match. Try the next one.',
      );
    }
    _factors.add(
      AdminSecurityMfaFactor(
        factorId: factorId,
        factorType: 'totp',
        enrolledAt: _now().toUtc(),
        issuerLabel: 'Forge & Flow',
      ),
    );
    _pendingFactorId = null;
    return AdminSecurityTotpConfirmed(factorId: factorId);
  }

  @override
  Future<AdminSecurityFactorRemovalRequested> requestFactorRemoval({
    required String factorId,
    required String idempotencyKey,
    String? freshAuthProof,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    if (_factors.every((f) => f.factorId != factorId)) {
      throw const AdminSecurityGatewayError(
        statusCode: 404,
        errorCode: 'mfa_factor_not_found',
        message: 'That authenticator is no longer enrolled.',
      );
    }
    // Self-service removal is ALWAYS the 24-hour delayed request, never
    // an immediate delete (parity with operator-web + the live proxy).
    _removalSeq += 1;
    final executeAfter = _now().toUtc().add(removalGrace);
    _pendingRemoval = AdminSecurityMfaRemoval(
      requestId: 'demo-admin-removal-$_removalSeq',
      factorId: factorId,
      status: 'pending',
      executeAfter: executeAfter,
    );
    return AdminSecurityFactorRemovalRequested(
      revoked: false,
      requestId: _pendingRemoval!.requestId,
      executeAfter: executeAfter,
    );
  }

  @override
  Future<AdminSecurityFactorRemovalCancelled> cancelFactorRemoval({
    required String requestId,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    final pending = _pendingRemoval;
    if (pending == null || pending.requestId != requestId) {
      // Idempotent: nothing pending (or already cancelled) reports
      // cancelled-true rather than a hard error, mirroring the
      // operator-web replay posture.
      return const AdminSecurityFactorRemovalCancelled(cancelled: true);
    }
    _pendingRemoval = null;
    return const AdminSecurityFactorRemovalCancelled(cancelled: true);
  }

  @override
  Future<AdminSecurityPasswordChanged> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    if (newPassword.trim().length < 12) {
      throw const AdminSecurityGatewayError(
        statusCode: 422,
        errorCode: 'password_policy',
        message: 'That password does not meet the policy.',
        rejections: <String>['too_short'],
      );
    }
    return const AdminSecurityPasswordChanged();
  }

  @override
  Future<AdminSecurityRecoveryRequested> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    return const AdminSecurityRecoveryRequested(
      queued: true,
      requestId: 'demo-recovery-request-1',
    );
  }

  @override
  Future<AdminSecurityAuditListed> listSignInHistory() async =>
      AdminSecurityAuditListed(entries: _seedSignInHistory());

  /// Deterministic in-memory sign-in history rows so the demo /
  /// share-preview walkthrough renders the "Recent sign-in activity"
  /// list without a backend.
  List<AdminSecurityAuditEntry> _seedSignInHistory() {
    final now = _now().toUtc();
    final all = <AdminSecurityAuditEntry>[
      AdminSecurityAuditEntry(
        eventId: 'demo-evt-1',
        eventType: 'auth.signed_in',
        friendlyLabel: adminAuditFriendlyLabelFor('auth.signed_in'),
        occurredAt: now.subtract(const Duration(hours: 2)),
        deviceLabel: 'Chrome on macOS',
        geoCity: 'Toronto',
        geoCountry: 'Canada',
      ),
      AdminSecurityAuditEntry(
        eventId: 'demo-evt-2',
        eventType: 'auth.password_changed',
        friendlyLabel: adminAuditFriendlyLabelFor('auth.password_changed'),
        occurredAt: now.subtract(const Duration(days: 6)),
        deviceLabel: 'Chrome on macOS',
      ),
      AdminSecurityAuditEntry(
        eventId: 'demo-evt-3',
        eventType: 'auth.mfa_totp_enrolled',
        friendlyLabel: adminAuditFriendlyLabelFor('auth.mfa_totp_enrolled'),
        occurredAt: now.subtract(const Duration(days: 40)),
        deviceLabel: 'Chrome on macOS',
      ),
    ];
    final sorted = all.toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return List<AdminSecurityAuditEntry>.unmodifiable(sorted);
  }
}
