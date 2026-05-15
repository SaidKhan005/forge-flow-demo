// Phase 11W.6 - Operator Web security demo gateway.
//
// In-memory implementation of [WebSecurityGateway] that the
// operator-web shell binds when `OPERATOR_WEB_DEMO_AUTH=true`. Reads
// the shared fixture set at [demo_team_fixtures.dart] so the
// `/security` walkthrough sees the same MFA factor inventory + login
// history the rest of the 11W slices project from.
//
// Mutations made during a walkthrough (enroll a factor, schedule a
// removal, cancel a removal, change password) are stored on this
// instance only - page reload resets to the fixture defaults.
// Idempotency replays of the same key surface the original response,
// mirroring the proxy `proxy_requests` UNIQUE-key replay semantics.

import 'dart:async';

import 'demo_team_fixtures.dart';
import 'web_security_gateway.dart';

/// In-memory demo gateway. Constructs from the shared fixture set
/// declared in [demo_team_fixtures.dart].
class DemoWebSecurityGateway implements WebSecurityGateway {
  DemoWebSecurityGateway({DateTime? now})
    : _now = now ?? DateTime.utc(2026, 5, 6, 12) {
    for (final fixture in kDemoTeamMfaFactorsFixture) {
      _factors[fixture.factorId] = WebSecurityMfaFactor(
        factorId: fixture.factorId,
        factorType: fixture.factorType,
        enrolledAt: DateTime.parse(fixture.enrolledAtIso).toUtc(),
        lastUsedAt: fixture.lastUsedAtIso == null
            ? null
            : DateTime.parse(fixture.lastUsedAtIso!).toUtc(),
        issuerLabel: fixture.issuerLabel,
        canRevoke: fixture.canRevoke,
      );
    }
    for (final fixture in kDemoTeamLoginHistoryFixture) {
      _loginHistory.add(
        WebSecurityLoginHistoryEntry(
          eventId: fixture.eventId,
          eventType: fixture.eventType,
          friendlyLabel: webSecurityFriendlyLabelFor(fixture.eventType),
          occurredAt: DateTime.parse(fixture.occurredAtIso).toUtc(),
          deviceLabel: fixture.deviceLabel,
          userAgent: fixture.userAgent,
          geoCity: fixture.geoCity,
          geoCountry: fixture.geoCountry,
        ),
      );
    }
  }

  final DateTime _now;
  final Map<String, WebSecurityMfaFactor> _factors =
      <String, WebSecurityMfaFactor>{};
  final Map<String, WebSecurityMfaRemoval> _removals =
      <String, WebSecurityMfaRemoval>{};
  final List<WebSecurityLoginHistoryEntry> _loginHistory =
      <WebSecurityLoginHistoryEntry>[];

  final Map<String, WebSecurityTotpEnrollment> _pendingTotpEnrollments =
      <String, WebSecurityTotpEnrollment>{};

  /// Demo-scenario seeding helper: drops a pending MFA removal row
  /// into the gateway's in-memory state without driving the public
  /// [revokeFactor] mutation path (which would consume an idempotency
  /// key and append a login-history event). Used by the
  /// `mfa-pending-removal` scenario in `main_operator_web.dart` so the
  /// `MfaCardStage.removalRequested` walkthrough lands on a populated
  /// pending-removal posture on first paint.
  ///
  /// Returns the seeded request id so the scenario wiring can log /
  /// reference it. No-op when [factorId] does not match an existing
  /// factor.
  String? seedPendingFactorRemoval({
    required String factorId,
    Duration delay = const Duration(hours: 18),
  }) {
    if (!_factors.containsKey(factorId)) return null;
    final requestId = 'demo-security-removal-scenario-${_removals.length + 1}';
    final executeAfter = _now.add(delay);
    _removals[requestId] = WebSecurityMfaRemoval(
      requestId: requestId,
      factorId: factorId,
      status: 'pending',
      executeAfter: executeAfter,
    );
    return requestId;
  }

  /// Cached responses keyed by the screen-minted idempotency key, so
  /// a re-submission of the same write returns the original outcome
  /// rather than mutating again.
  final Map<String, Object> _idempotency = <String, Object>{};

  /// Demo password the change-password walkthrough reverifies against.
  /// Mutations during the walkthrough rotate the value so the next
  /// change requires the just-set value as the current password,
  /// matching the live proxy posture.
  String _currentPassword = 'demo-pass-1!';

  /// Last 8 passwords the demo flavor rejects as "recently used", so
  /// the walkthrough's reuse-rejection step has a stable trigger.
  final List<String> _passwordHistory = <String>['demo-pass-1!'];

  @override
  Future<WebSecurityFactorsListed> listFactors() async {
    final factors = _factors.values.toList(growable: false)
      ..sort((a, b) => a.enrolledAt.compareTo(b.enrolledAt));
    final removals = _removals.values.toList(growable: false)
      ..sort((a, b) => a.executeAfter.compareTo(b.executeAfter));
    return WebSecurityFactorsListed(
      factors: List<WebSecurityMfaFactor>.unmodifiable(factors),
      removalRequests: List<WebSecurityMfaRemoval>.unmodifiable(removals),
    );
  }

  @override
  Future<WebSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is WebSecurityTotpEnrollment) return cached;
    final factorId =
        'demo-security-totp-pending-${_pendingTotpEnrollments.length + 1}';
    final encodedEmail = Uri.encodeComponent(
      userEmail.isEmpty ? 'sam.owner@demobistro.test' : userEmail,
    );
    final enrollment = WebSecurityTotpEnrollment(
      factorId: factorId,
      otpAuthUrl:
          'otpauth://totp/Forge%20%26%20Flow:$encodedEmail?'
          'secret=JBSWY3DPEHPK3PXP&issuer=Forge%20%26%20Flow',
      secretBase32: 'JBSWY3DPEHPK3PXP',
    );
    _pendingTotpEnrollments[factorId] = enrollment;
    _idempotency[idempotencyKey] = enrollment;
    return enrollment;
  }

  @override
  Future<WebSecurityRecoveryRequestResult> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is WebSecurityRecoveryRequestResult) return cached;
    if (email.trim().isEmpty) {
      throw const WebSecurityError(
        code: 'missing_email',
        message:
            'Type the email address you sign in with so we can route '
            'the recovery link to you.',
        statusCode: 400,
      );
    }
    final requestId = 'demo-security-recovery-${_recoveryRequestsCount += 1}';
    final result = WebSecurityRecoveryRequestResult(
      queued: true,
      requestId: requestId,
    );
    _appendLoginHistory(
      eventId: requestId,
      eventType: 'auth.mfa_recovery_requested',
      occurredAt: _now,
    );
    _idempotency[idempotencyKey] = result;
    return result;
  }

  int _recoveryRequestsCount = 0;

  @override
  Future<WebSecurityMfaFactor> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is WebSecurityMfaFactor) return cached;
    if (!_pendingTotpEnrollments.containsKey(factorId)) {
      throw const WebSecurityError(
        code: 'mfa_factor_not_found',
        message: 'Authenticator setup not found. Restart the enrollment.',
        statusCode: 404,
      );
    }
    if (oneTimeCode.trim() == '000000') {
      throw const WebSecurityError(
        code: 'mfa_totp_invalid_code',
        message:
            "That code didn't match. Try again with the next code from your "
            'authenticator.',
        statusCode: 422,
      );
    }
    _pendingTotpEnrollments.remove(factorId);
    final factor = WebSecurityMfaFactor(
      factorId: factorId,
      factorType: 'totp',
      enrolledAt: _now,
      issuerLabel: 'Forge & Flow',
    );
    _factors[factor.factorId] = factor;
    _appendLoginHistory(
      eventId: 'demo-history-mfa-enroll-${factor.factorId}',
      eventType: 'auth.mfa_totp_enrolled',
      occurredAt: _now,
    );
    _idempotency[idempotencyKey] = factor;
    return factor;
  }

  @override
  Future<WebSecurityRevokeFactorResult> revokeFactor({
    required String factorId,
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is WebSecurityRevokeFactorResult) return cached;
    if (!_factors.containsKey(factorId)) {
      throw const WebSecurityError(
        code: 'mfa_factor_not_found',
        message: 'Authenticator was already removed or does not exist.',
        statusCode: 404,
      );
    }
    WebSecurityMfaRemoval? pending;
    for (final candidate in _removals.values) {
      if (candidate.factorId == factorId && candidate.status == 'pending') {
        pending = candidate;
        break;
      }
    }
    if (pending != null) {
      throw WebSecurityError(
        code: 'mfa_removal_already_pending',
        message: 'Authenticator removal is already scheduled.',
        statusCode: 409,
        rejections: <String>[
          'execute_after:${pending.executeAfter.toIso8601String()}',
        ],
      );
    }
    final requestId = 'demo-security-removal-${_removals.length + 1}';
    final executeAfter = _now.add(const Duration(hours: 24));
    final removal = WebSecurityMfaRemoval(
      requestId: requestId,
      factorId: factorId,
      status: 'pending',
      executeAfter: executeAfter,
    );
    _removals[requestId] = removal;
    final result = WebSecurityRevokeFactorResult(
      revoked: false,
      requestId: requestId,
      executeAfter: executeAfter,
    );
    _idempotency[idempotencyKey] = result;
    return result;
  }

  @override
  Future<WebSecurityRecoveryCodesViewedResult> markRecoveryCodesViewed({
    required String factorId,
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is WebSecurityRecoveryCodesViewedResult) return cached;
    final factor = _factors[factorId];
    if (factor == null) {
      throw const WebSecurityError(
        code: 'mfa_factor_not_found',
        message: 'Authenticator was already removed or does not exist.',
        statusCode: 404,
      );
    }
    final viewedAt = _now;
    _factors[factorId] = WebSecurityMfaFactor(
      factorId: factor.factorId,
      factorType: factor.factorType,
      enrolledAt: factor.enrolledAt,
      lastUsedAt: factor.lastUsedAt,
      recoveryCodesViewedAt: viewedAt,
      issuerLabel: factor.issuerLabel,
      canRevoke: factor.canRevoke,
    );
    final result = WebSecurityRecoveryCodesViewedResult(viewedAt: viewedAt);
    _idempotency[idempotencyKey] = result;
    return result;
  }

  @override
  Future<WebSecurityCancelRemovalResult> cancelFactorRemoval({
    required String requestId,
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is WebSecurityCancelRemovalResult) return cached;
    final existing = _removals[requestId];
    if (existing == null || existing.status != 'pending') {
      throw const WebSecurityError(
        code: 'mfa_removal_request_not_found',
        message: 'Authenticator removal was already completed or cancelled.',
        statusCode: 404,
      );
    }
    _removals[requestId] = WebSecurityMfaRemoval(
      requestId: existing.requestId,
      factorId: existing.factorId,
      status: 'cancelled',
      executeAfter: existing.executeAfter,
      completedAt: existing.completedAt,
    );
    const result = WebSecurityCancelRemovalResult(cancelled: true);
    _idempotency[idempotencyKey] = result;
    return result;
  }

  @override
  Future<WebSecurityPasswordChangeResult> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is WebSecurityPasswordChangeResult) return cached;
    if (currentPassword != _currentPassword) {
      throw const WebSecurityError(
        code: 'wrong_current_password',
        message: 'Current password is incorrect.',
        statusCode: 422,
        rejections: <String>['wrong_current_password'],
      );
    }
    if (!_passwordPolicyOk(newPassword)) {
      throw const WebSecurityError(
        code: 'password_policy_failed',
        message:
            'Password must be at least 12 characters with one number and '
            'one symbol.',
        statusCode: 422,
        rejections: <String>['too_short_or_weak'],
      );
    }
    if (_passwordHistory.contains(newPassword)) {
      throw const WebSecurityError(
        code: 'password_reuse_rejected',
        message: "You can't reuse a recent password. Choose a new one.",
        statusCode: 422,
        rejections: <String>['reused_password'],
      );
    }
    _currentPassword = newPassword;
    _passwordHistory.insert(0, newPassword);
    if (_passwordHistory.length > 8) _passwordHistory.removeLast();
    _appendLoginHistory(
      eventId: 'demo-history-password-changed-$idempotencyKey',
      eventType: 'auth.password_changed',
      occurredAt: _now,
    );
    const result = WebSecurityPasswordChangeResult();
    _idempotency[idempotencyKey] = result;
    return result;
  }

  @override
  Future<WebSecurityLoginHistoryListed> listLoginHistory() async {
    final since = _now.subtract(kWebSecurityLoginHistoryWindow);
    final entries =
        _loginHistory
            .where(
              (entry) =>
                  isSecurityLoginHistoryEvent(entry.eventType) &&
                  !entry.occurredAt.isBefore(since),
            )
            .toList(growable: false)
          ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return WebSecurityLoginHistoryListed(
      entries: List<WebSecurityLoginHistoryEntry>.unmodifiable(entries),
    );
  }

  void _appendLoginHistory({
    required String eventId,
    required String eventType,
    required DateTime occurredAt,
  }) {
    _loginHistory.insert(
      0,
      WebSecurityLoginHistoryEntry(
        eventId: eventId,
        eventType: eventType,
        friendlyLabel: webSecurityFriendlyLabelFor(eventType),
        occurredAt: occurredAt,
        deviceLabel: 'Chrome on macOS',
        userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) Chrome/124.0',
        geoCity: 'Toronto',
        geoCountry: 'CA',
      ),
    );
  }

  bool _passwordPolicyOk(String value) {
    if (value.length < 12) return false;
    final hasDigit = RegExp(r'\d').hasMatch(value);
    final hasSymbol = RegExp(r'[^A-Za-z0-9]').hasMatch(value);
    return hasDigit && hasSymbol;
  }
}
