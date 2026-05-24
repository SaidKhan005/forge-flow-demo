// Phase 11W.live - web-safe account action seam.
//
// The Account screen is shared between demo and live mode. Demo mode keeps
// the local fixture behavior; live mode injects this seam so MFA enrollment
// and password rotation call the existing Phase 9 proxy routes without the UI
// importing a Firebase or HTTP implementation directly.

import '../../auth/mfa_freshness_redirect_listener.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_error_envelope.dart';
import '../services/operator_web_team_gateway_providers.dart';
import '../services/web_account_gateway.dart';
import '../services/web_security_gateway.dart';

/// Optional live-auth hook used by the My Account MFA card before sensitive
/// removal/cancel actions. Implementations that cannot inspect a current
/// Firebase ID token may omit it; the server-side MFA route still enforces
/// freshness and the extension below dispatches the existing listener when
/// that route returns `mfa_freshness_required`.
abstract class OperatorWebAccountMfaFreshnessGate {
  Future<void> requireFreshMfaForAccountSecurity({required String actionLabel});
}

abstract class OperatorWebAccountActions {
  /// Begins TOTP enrollment. [idempotencyKey], when supplied, is the
  /// caller-stable key for the WHOLE enroll attempt (begin + confirm).
  /// The My Account screen mints ONE key per enroll button press and
  /// passes the SAME key to both [beginAccountMfaEnrollment] and the
  /// matching [confirmAccountMfaEnrollment] so a retried confirm replays
  /// (proxy `proxy_requests` UNIQUE guard). Null preserves the legacy
  /// fresh-random-key-per-call behavior unchanged.
  Future<MfaEnrollmentArtifact> beginAccountMfaEnrollment({
    required String email,
    String? idempotencyKey,
  });

  /// Confirms TOTP enrollment. Pass the SAME [idempotencyKey] the paired
  /// [beginAccountMfaEnrollment] used so a retry of this confirm replays
  /// rather than mints a new key. Null = legacy per-call key.
  Future<void> confirmAccountMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
    String? idempotencyKey,
  });

  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  });

  String? get currentAccountSessionId {
    if (this is OperatorWebTeamSessionsGatewayProvider) {
      return (this as OperatorWebTeamSessionsGatewayProvider).currentSessionId;
    }
    return null;
  }

  Future<AccountActiveSessionsListed> listAccountActiveSessions() async {
    final gateway = _accountSessionGateway;
    if (gateway == null) {
      return const AccountActiveSessionsListed(
        sessions: <AccountActiveSessionEntry>[],
      );
    }
    return gateway.listActiveSessions();
  }

  Future<AccountSessionSignOutOthersResult> signOutOtherAccountSessions({
    required Iterable<String> sessionIds,
  }) async {
    final gateway = _accountSessionGateway;
    if (gateway == null) {
      return const AccountSessionSignOutOthersResult(revokedCount: 0);
    }
    try {
      return await gateway.signOutOtherSessions(sessionIds: sessionIds);
    } on AccountSessionFreshMfaRequiredException catch (error) {
      _dispatchFreshMfaRedirect(error);
      rethrow;
    }
  }

  /// Wave 2 W-3 — self-service profile edit. Routes through the
  /// account gateway (which owns the freshness gate for email change)
  /// and surfaces the result so the screen can decide whether to force
  /// a sign-out.
  Future<SelfProfilePatchResult?> patchSelfProfile({
    String? displayName,
    String? email,
  }) async {
    if (this is! OperatorWebAccountGatewayProvider) return null;
    final gateway = (this as OperatorWebAccountGatewayProvider).accountGateway;
    try {
      return await gateway.patchSelfProfile(
        SelfProfilePatchPayload(displayName: displayName, email: email),
      );
    } on AccountSessionFreshMfaRequiredException catch (error) {
      _dispatchFreshMfaRedirect(error);
      rethrow;
    }
  }

  WebAccountSessionGateway? get _accountSessionGateway {
    if (this is OperatorWebAccountGatewayProvider) {
      final gateway =
          (this as OperatorWebAccountGatewayProvider).accountGateway;
      if (gateway is WebAccountSessionGateway) {
        return gateway as WebAccountSessionGateway;
      }
    }
    return null;
  }

  void _dispatchFreshMfaRedirect(
    AccountSessionFreshMfaRequiredException error,
  ) {
    if (this is MfaFreshnessRedirectListener) {
      (this as MfaFreshnessRedirectListener).onMfaFreshnessRedirect(
        MfaFreshnessRedirectPayload(
          redirectUri: error.redirectUri!,
          message: error.message,
        ),
      );
    }
  }
}

extension OperatorWebAccountMfaActions on OperatorWebAccountActions {
  bool get supportsAccountMfaServerState => _accountSecurityGateway != null;

  Future<WebSecurityFactorsListed?> listAccountMfaFactors() {
    return _accountSecurityGateway?.listFactors() ??
        Future<WebSecurityFactorsListed?>.value();
  }

  Future<void> requireFreshMfaForAccountSecurity({
    required String actionLabel,
  }) async {
    if (this is OperatorWebAccountMfaFreshnessGate) {
      await (this as OperatorWebAccountMfaFreshnessGate)
          .requireFreshMfaForAccountSecurity(actionLabel: actionLabel);
    }
  }

  Future<WebSecurityRevokeFactorResult> requestAccountMfaRemoval({
    required String factorId,
  }) async {
    final gateway = _requireAccountSecurityGateway();
    await requireFreshMfaForAccountSecurity(
      actionLabel: 'removing two-factor sign-in',
    );
    try {
      return await gateway.revokeFactor(
        factorId: factorId,
        idempotencyKey: _accountMfaIdempotencyKey('request_removal'),
      );
    } on WebSecurityError catch (error) {
      _dispatchMfaSecurityRedirectIfNeeded(error);
      rethrow;
    }
  }

  Future<WebSecurityRecoveryCodesViewedResult>
  markAccountMfaRecoveryCodesViewed({required String factorId}) async {
    final gateway = _requireAccountSecurityGateway();
    try {
      return await gateway.markRecoveryCodesViewed(
        factorId: factorId,
        idempotencyKey: _accountMfaIdempotencyKey('recovery_codes_viewed'),
      );
    } on WebSecurityError catch (error) {
      _dispatchMfaSecurityRedirectIfNeeded(error);
      rethrow;
    }
  }

  Future<WebSecurityCancelRemovalResult> cancelAccountMfaRemoval({
    required String requestId,
  }) async {
    final gateway = _requireAccountSecurityGateway();
    await requireFreshMfaForAccountSecurity(
      actionLabel: 'cancelling two-factor sign-in removal',
    );
    try {
      return await gateway.cancelFactorRemoval(
        requestId: requestId,
        idempotencyKey: _accountMfaIdempotencyKey('cancel_removal'),
      );
    } on WebSecurityError catch (error) {
      _dispatchMfaSecurityRedirectIfNeeded(error);
      rethrow;
    }
  }

  WebSecurityGateway? get _accountSecurityGateway {
    if (this is OperatorWebSecurityGatewayProvider) {
      return (this as OperatorWebSecurityGatewayProvider).securityGateway;
    }
    return null;
  }

  WebSecurityGateway _requireAccountSecurityGateway() {
    final gateway = _accountSecurityGateway;
    if (gateway == null) {
      throw const WebSecurityError(
        code: 'mfa_gateway_not_configured',
        message: 'MFA management is not available from My Account.',
        statusCode: 503,
      );
    }
    return gateway;
  }

  String _accountMfaIdempotencyKey(String action) {
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'op-web-account-mfa-$action-$micros-${identityHashCode(this)}';
  }

  void _dispatchMfaSecurityRedirectIfNeeded(WebSecurityError error) {
    // G63 — recognise the freshness redirect via the shared classifier
    // (folds both `mfa_freshness_required` and the step-up
    // `insufficient_user_authentication` sentinel into one kind) instead
    // of the gateway re-listing those two codes itself.
    if (error.kind != OperatorWebErrorKind.mfaFreshnessRedirect) {
      return;
    }
    if (this is MfaFreshnessRedirectListener) {
      (this as MfaFreshnessRedirectListener).onMfaFreshnessRedirect(
        MfaFreshnessRedirectPayload(
          redirectUri: '/auth/login?reason=fresh_mfa_required',
          message: error.message,
        ),
      );
    }
  }
}
