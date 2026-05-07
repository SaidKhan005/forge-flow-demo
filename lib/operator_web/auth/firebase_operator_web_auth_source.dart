// Phase 11W.live - Firebase + proxy operator-web auth source.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../services/auth/account_info_gateway.dart';
import '../../services/auth/firebase_auth_client.dart';
import '../account/operator_web_account_actions.dart';
import '../services/operator_web_notification_preferences_gateway_provider.dart';
import '../services/operator_web_proxy_client.dart';
import '../services/operator_web_team_gateway_providers.dart';
import '../services/operator_web_vendor_connections_gateway.dart';
import '../services/web_account_gateway.dart';
import '../services/web_business_timing_gateway.dart';
import '../services/web_security_gateway.dart';
import '../services/web_team_audit_log_gateway.dart';
import '../services/web_team_hierarchy_gateway.dart';
import '../services/web_team_roles_gateway.dart';
import '../services/web_team_sessions_gateway.dart';
import '../services/web_team_users_gateway.dart';
import 'operator_web_auth_source.dart';

class FirebaseOperatorWebAuthSource
    implements
        OperatorWebAuthSource,
        OperatorWebAccountActions,
        OperatorWebVendorConnectionsGatewayProvider,
        OperatorWebAccountGatewayProvider,
        OperatorWebBusinessTimingWriteGatewayProvider,
        OperatorWebDataAccuracyGatewayProvider,
        OperatorWebTeamUsersGatewayProvider,
        OperatorWebTeamRolesGatewayProvider,
        OperatorWebTeamHierarchyGatewayProvider,
        OperatorWebTeamSessionsGatewayProvider,
        OperatorWebTeamAuditLogGatewayProvider,
        OperatorWebSecurityGatewayProvider,
        OperatorWebNotificationPreferencesGatewayProvider,
        OperatorWebWageAuthorityGatewayProvider {
  FirebaseOperatorWebAuthSource({
    required FirebaseAuthClient authClient,
    required OperatorWebProxyClient proxyClient,
  }) : _authClient = authClient,
       _proxyClient = proxyClient,
       vendorConnectionsGateway = OperatorWebHttpVendorConnectionsGateway(
         proxyClient: proxyClient,
         idTokenProvider: authClient.currentIdToken,
       ),
       accountGateway = HttpWebAccountGateway(
         client: proxyClient,
         idTokenProvider: authClient.currentIdToken,
       ),
       businessTimingWriteGateway = HttpWebBusinessTimingGateway(
         client: proxyClient,
         idTokenProvider: authClient.currentIdToken,
       ),
       dataAccuracyGateway = OperatorWebHttpDataAccuracyGateway(
         client: proxyClient,
         idTokenProvider: authClient.currentIdToken,
       ),
       teamUsersGateway = WebTeamUsersGatewayLive(
         proxyBaseUri: proxyClient.baseUri,
         idTokenProvider: authClient.currentIdToken,
       ),
       teamRolesGateway = WebTeamRolesGatewayLive(
         proxyBaseUri: proxyClient.baseUri,
         idTokenProvider: authClient.currentIdToken,
       ),
       teamHierarchyGateway = WebTeamHierarchyGatewayLive(
         proxyBaseUri: proxyClient.baseUri,
         idTokenProvider: authClient.currentIdToken,
       ),
       teamSessionsGateway = _OperatorWebLiveSessionsGateway(
         delegate: WebTeamSessionsGatewayLive(
           proxyBaseUri: proxyClient.baseUri,
           idTokenProvider: authClient.currentIdToken,
         ),
       ),
       teamAuditLogGateway = WebTeamAuditLogGatewayLive(
         proxyBaseUri: proxyClient.baseUri,
         idTokenProvider: authClient.currentIdToken,
       ),
       securityGateway = WebSecurityGatewayLive(
         proxyBaseUri: proxyClient.baseUri,
         idTokenProvider: authClient.currentIdToken,
       ),
       notificationPreferencesGateway = HttpWebNotificationPreferencesGateway(
         proxyBaseUri: proxyClient.baseUri,
         idTokenProvider: authClient.currentIdToken,
       ),
       wageAuthorityGateway = OperatorWebHttpWageAuthorityGateway(
         proxyBaseUri: proxyClient.baseUri,
         idTokenProvider: authClient.currentIdToken,
       ) {
    _controller.add(_state);
    unawaited(_bootstrap());
  }

  final FirebaseAuthClient _authClient;
  final OperatorWebProxyClient _proxyClient;
  final StreamController<OperatorWebAuthState> _controller =
      StreamController<OperatorWebAuthState>.broadcast();
  OperatorWebAuthState _state = const OperatorWebLoading();
  bool _closed = false;

  @override
  final OperatorWebHttpVendorConnectionsGateway vendorConnectionsGateway;

  @override
  final WebAccountGateway accountGateway;

  @override
  final WebBusinessTimingGateway businessTimingWriteGateway;

  @override
  final OperatorWebDataAccuracyGateway dataAccuracyGateway;

  @override
  final WebTeamUsersGateway teamUsersGateway;

  @override
  final WebTeamRolesGateway teamRolesGateway;

  @override
  final WebTeamHierarchyGateway teamHierarchyGateway;

  @override
  final WebTeamSessionsGateway teamSessionsGateway;

  @override
  final WebTeamAuditLogGateway teamAuditLogGateway;

  @override
  final WebSecurityGateway securityGateway;

  @override
  final WebNotificationPreferencesGateway notificationPreferencesGateway;

  @override
  final OperatorWebWageAuthorityGateway wageAuthorityGateway;

  String? _currentSessionId;

  @override
  String? get currentSessionId => _currentSessionId;

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  Future<void> _bootstrap() async {
    try {
      final credential = await _authClient.refreshIdToken();
      if (credential == null) {
        _emit(const OperatorWebNeedsSignIn());
        return;
      }
      await _completeCredential(credential);
    } catch (_) {
      _emit(
        const OperatorWebNeedsSignIn(
          lastErrorMessage:
              'Sign-in is unavailable right now. Refresh the page and try again.',
        ),
      );
    }
  }

  @override
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = email.trim();
    if (normalizedEmail.isEmpty || password.isEmpty) {
      _emit(
        const OperatorWebNeedsSignIn(
          lastErrorMessage: 'Enter your email and password to continue.',
        ),
      );
      return;
    }
    final outcome = await _authClient.signInWithEmailPassword(
      email: normalizedEmail,
      password: password,
    );
    await _handleSignInOutcome(outcome, email: normalizedEmail);
  }

  @override
  Future<void> completeSignInMfaChallenge({
    required String oneTimeCode,
    String? factorId,
  }) async {
    final current = _state;
    if (current is! OperatorWebSignInMfaChallenge) {
      _emit(
        const OperatorWebNeedsSignIn(
          lastErrorMessage: 'The verification session expired. Sign in again.',
        ),
      );
      return;
    }
    final selectedFactor =
        factorId ??
        (current.factorIds.isEmpty ? null : current.factorIds.first);
    if (selectedFactor == null || oneTimeCode.trim().isEmpty) {
      _emit(
        OperatorWebSignInMfaChallenge(
          email: current.email,
          mfaSessionToken: current.mfaSessionToken,
          factorIds: current.factorIds,
          lastErrorMessage: 'Enter the 6-digit code from your authenticator.',
        ),
      );
      return;
    }
    final outcome = await _authClient.completeTotpChallenge(
      mfaSessionToken: current.mfaSessionToken,
      factorId: selectedFactor,
      oneTimeCode: oneTimeCode.trim(),
    );
    await _handleSignInOutcome(outcome, email: current.email);
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {
    final normalizedEmail = email.trim();
    if (normalizedEmail.isEmpty) {
      _emit(
        const OperatorWebNeedsSignIn(
          lastErrorMessage:
              'Enter your email first, then request a reset link.',
        ),
      );
      return;
    }
    try {
      await _authClient.requestPasswordReset(email: normalizedEmail);
      _emit(
        OperatorWebNeedsSignIn(
          lastInfoMessage:
              'If $normalizedEmail is registered, a password reset email is on the way.',
        ),
      );
    } catch (_) {
      _emit(
        const OperatorWebNeedsSignIn(
          lastErrorMessage:
              'Password reset is unavailable right now. Try again in a moment.',
        ),
      );
    }
  }

  Future<void> _handleSignInOutcome(
    FirebaseAuthSignInOutcome outcome, {
    required String email,
  }) async {
    switch (outcome) {
      case FirebaseAuthSignInSucceeded(:final credential):
        await _completeCredential(credential);
      case FirebaseAuthSignInRequiresMfa(
        :final mfaSessionToken,
        :final factorIds,
      ):
        _emit(
          OperatorWebSignInMfaChallenge(
            email: email,
            mfaSessionToken: mfaSessionToken,
            factorIds: List<String>.unmodifiable(factorIds),
          ),
        );
      case FirebaseAuthSignInFailed(:final message):
        _emit(OperatorWebNeedsSignIn(lastErrorMessage: message));
    }
  }

  Future<void> _completeCredential(FirebaseAuthCredential credential) async {
    try {
      final tokenHash = sha256
          .convert(utf8.encode(credential.idToken))
          .toString();
      final ledger = await _proxyClient.recordSessionLogin(
        idToken: credential.idToken,
        tokenHash: tokenHash,
        email: credential.email,
      );
      _currentSessionId = ledger.sessionId;
      final profileResults = await Future.wait<Object>([
        _proxyClient.loadAccountInfo(idToken: credential.idToken),
        _proxyClient.loadPermissionSnapshot(idToken: credential.idToken),
      ]);
      final account = profileResults[0] as AccountInfo;
      final snapshot = profileResults[1] as OperatorWebPermissionSnapshot;
      if (snapshot.userId != ledger.userId ||
          snapshot.operatorId != ledger.operatorId ||
          snapshot.locationId != ledger.locationId) {
        throw const OperatorWebProxyException(
          code: 'permission_scope_mismatch',
          message:
              'The proxy returned a permission snapshot for a different account.',
        );
      }
      final roles = _inferRoles(account, snapshot);
      final displayName = _firstNonBlank(
        account.displayName,
        credential.displayName,
        credential.email,
        ledger.userId,
      );
      final session = OperatorWebSession(
        uid: ledger.userId,
        email: _firstNonBlank(account.email, credential.email, ''),
        displayName: displayName,
        operatorId: ledger.operatorId,
        businessName: _businessName(credential.customClaims, account),
        primaryLocationId: ledger.locationId,
        primaryLocationName: account.locationLabel,
        roles: List<String>.unmodifiable(roles),
        permissions: snapshot.allowedPermissions,
        mfaEnrolled:
            account.mfaEnabled ||
            credential.customClaims['mfa_enrolled'] == true,
      );
      if (_hasConsoleAccess(session)) {
        _emit(OperatorWebCompleted(session: session));
      } else {
        _emit(OperatorWebForbidden(session: session));
      }
    } on OperatorWebProxyException catch (error) {
      await _authClient.signOut();
      _emit(
        OperatorWebNeedsSignIn(
          lastErrorMessage:
              '${error.message} Sign in again after support checks the proxy.',
        ),
      );
    } catch (_) {
      await _authClient.signOut();
      _emit(
        const OperatorWebNeedsSignIn(
          lastErrorMessage:
              'Your sign-in worked, but the operator web profile could not be loaded. Try again in a moment.',
        ),
      );
    }
  }

  @override
  Future<MfaEnrollmentArtifact> beginAccountMfaEnrollment({
    required String email,
  }) async {
    final token = await _requireCurrentToken();
    final setup = await _proxyClient.beginTotpEnrollment(
      idToken: token,
      email: email,
    );
    return MfaEnrollmentArtifact(
      enrollmentId: setup.factorId,
      factorType: MfaFactorType.totp,
      totpSharedSecret: setup.secretBase32,
      totpQrUri: setup.otpAuthUrl,
    );
  }

  @override
  Future<void> confirmAccountMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
  }) async {
    final token = await _requireCurrentToken();
    await _proxyClient.confirmTotpEnrollment(
      idToken: token,
      factorId: enrollmentId,
      oneTimeCode: oneTimeCode,
    );
    final current = _state;
    if (current is OperatorWebCompleted) {
      _emit(
        OperatorWebCompleted(
          session: _copySession(current.session, mfaEnrolled: true),
        ),
      );
    }
  }

  @override
  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final token = await _requireCurrentToken();
    await _proxyClient.changePassword(
      idToken: token,
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  Future<String> _requireCurrentToken() async {
    final token = await _authClient.currentIdToken();
    if (token == null || token.trim().isEmpty) {
      await signOut();
      throw const OperatorWebProxyException(
        code: 'missing_id_token',
        message: 'Your sign-in expired.',
        statusCode: 401,
      );
    }
    return token.trim();
  }

  @override
  Future<void> verifyMagicLinkToken(String token) async {
    _emit(
      const OperatorWebNeedsSignIn(
        lastInfoMessage:
            'Operator web now uses your Firebase email and password. Use the password you set from your invite email.',
      ),
    );
  }

  @override
  Future<void> submitPassword({
    required String password,
    required String confirmation,
  }) {
    throw UnsupportedError(
      'live password setup is handled by Firebase action links',
    );
  }

  @override
  Future<MfaEnrollmentArtifact> beginMfaEnrollment({
    required MfaFactorType factorType,
    String? phoneNumber,
  }) {
    throw UnsupportedError('live onboarding MFA is handled after sign-in');
  }

  @override
  Future<void> confirmMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
  }) {
    throw UnsupportedError('live onboarding MFA is handled after sign-in');
  }

  @override
  Future<void> acceptTos({required String versionId, required String scope}) {
    throw UnsupportedError(
      'live TOS acceptance is not exposed by the proxy yet',
    );
  }

  @override
  Future<void> signOut() async {
    _currentSessionId = null;
    await _authClient.signOut();
    _emit(const OperatorWebNeedsSignIn());
  }

  @override
  void dispose() {
    _closed = true;
    _controller.close();
  }

  void _emit(OperatorWebAuthState next) {
    if (_closed) return;
    // Lifecycle invariant: every path back to the sign-in surface clears
    // the cached session id so a re-sign-in by a different user (same
    // browser) cannot mark the wrong row as `(this session)` on the
    // sessions screen. Centralizing the reset here keeps the invariant
    // in one place — every emit path (token refresh failure, scope
    // mismatch, completeCredential exception, signOut, etc.) flows
    // through `_emit` and inherits the cleanup automatically.
    if (next is OperatorWebNeedsSignIn) {
      _currentSessionId = null;
    }
    _state = next;
    _controller.add(next);
  }

  static List<String> _inferRoles(
    AccountInfo account,
    OperatorWebPermissionSnapshot snapshot,
  ) {
    final roles = <String>{};
    for (final label in account.roleLabels) {
      final normalized = label.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]+'),
        '_',
      );
      if (normalized.contains('operator_owner') ||
          normalized == 'owner' ||
          normalized.endsWith('_owner')) {
        roles.add('operator_owner');
      }
      if (normalized.contains('operator_admin') ||
          normalized == 'admin' ||
          normalized.endsWith('_admin')) {
        roles.add('operator_admin');
      }
      if (normalized.contains('operator_manager') ||
          normalized == 'manager' ||
          normalized.endsWith('_manager')) {
        roles.add('operator_manager');
      }
      if (normalized.contains('location_manager')) {
        roles.add('location_manager');
      }
    }
    if (snapshot.allows('integrations.configure')) {
      roles.add('operator_owner');
    }
    if (roles.isEmpty &&
        snapshot.allowedPermissions.any(
          const <String>{
            'team.users.view',
            'admin.users.view',
            'forgeflow.settings.view',
            'integrations.configure',
          }.contains,
        )) {
      roles.add('operator_manager');
    }
    return roles.toList(growable: false);
  }

  static bool _hasConsoleAccess(OperatorWebSession session) {
    if (session.roles.any(kOperatorWebAdmittedRoles.contains)) return true;
    return session.permissions.any(
      const <String>{
        'team.users.view',
        'admin.users.view',
        'forgeflow.settings.view',
        'integrations.configure',
      }.contains,
    );
  }

  static String _businessName(
    Map<String, Object?> claims,
    AccountInfo account,
  ) {
    return _firstNonBlank(
      _readString(claims['business_name']),
      _readString(claims['operator_name']),
      account.locationLabel,
      'Forge & Flow operator',
    );
  }

  static OperatorWebSession _copySession(
    OperatorWebSession session, {
    bool? mfaEnrolled,
  }) {
    return OperatorWebSession(
      uid: session.uid,
      email: session.email,
      displayName: session.displayName,
      operatorId: session.operatorId,
      businessName: session.businessName,
      primaryLocationId: session.primaryLocationId,
      primaryLocationName: session.primaryLocationName,
      roles: session.roles,
      permissions: session.permissions,
      phone: session.phone,
      mfaEnrolled: mfaEnrolled ?? session.mfaEnrolled,
    );
  }

  static String _firstNonBlank(
    Object? first, [
    Object? second,
    Object? third,
    Object? fourth,
  ]) {
    for (final value in <Object?>[first, second, third, fourth]) {
      final string = _readString(value);
      if (string != null) return string;
    }
    return '';
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _OperatorWebLiveSessionsGateway implements WebTeamSessionsGateway {
  const _OperatorWebLiveSessionsGateway({
    required WebTeamSessionsGatewayLive delegate,
  }) : _delegate = delegate;

  final WebTeamSessionsGatewayLive _delegate;

  @override
  Future<WebTeamSessionsListed> listOwnSessions() {
    return _delegate.listOwnSessions();
  }

  @override
  Future<WebTeamSessionsListed> listTeamSessions() {
    throw const WebTeamSessionsError(
      code: 'team_sessions_not_routed',
      message: 'Team-wide session listing is not routed by the proxy yet.',
      statusCode: 501,
    );
  }

  @override
  Future<WebTeamSessionRevoked> revokeSession(
    WebTeamSessionRevokeCommand command, {
    required String idempotencyKey,
  }) {
    return _delegate.revokeSession(command, idempotencyKey: idempotencyKey);
  }
}
