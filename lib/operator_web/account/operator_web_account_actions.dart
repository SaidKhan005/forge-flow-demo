// Phase 11W.live - web-safe account action seam.
//
// The Account screen is shared between demo and live mode. Demo mode keeps
// the local fixture behavior; live mode injects this seam so MFA enrollment
// and password rotation call the existing Phase 9 proxy routes without the UI
// importing a Firebase or HTTP implementation directly.

import '../../auth/mfa_freshness_redirect_listener.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_team_gateway_providers.dart';
import '../services/web_account_gateway.dart';

abstract class OperatorWebAccountActions {
  Future<MfaEnrollmentArtifact> beginAccountMfaEnrollment({
    required String email,
  });

  Future<void> confirmAccountMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
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
