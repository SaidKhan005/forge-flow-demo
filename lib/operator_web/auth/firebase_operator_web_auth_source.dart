// Phase 11W.live - Firebase + proxy operator-web auth source.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../auth/mfa_freshness_redirect_listener.dart';
import '../../services/auth/account_info_gateway.dart';
import '../../services/auth/firebase_auth_client.dart';
import '../account/operator_web_account_actions.dart';
import '../services/operator_web_notification_preferences_gateway_provider.dart';
import '../services/business_timing_gateway.dart';
import '../services/http_business_timing_read_gateway.dart';
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
import 'operator_web_handoff_redeem_gateway.dart';
import 'operator_web_auth_source.dart';

class FirebaseOperatorWebAuthSource extends OperatorWebAccountActions
    implements
        OperatorWebAuthSource,
        OperatorWebAccountMfaFreshnessGate,
        OperatorWebVendorConnectionsGatewayProvider,
        OperatorWebVendorLifecycleRecentlyAvailableGatewayProvider,
        OperatorWebAccountGatewayProvider,
        OperatorWebBusinessTimingGatewayProvider,
        OperatorWebBusinessTimingWriteGatewayProvider,
        OperatorWebDataAccuracyGatewayProvider,
        OperatorWebVendorApplicabilityGatewayProvider,
        // Per-Daypart Targets V1 / Slice 2 (Gap 35): no
        // OperatorWebBenchmarksGatewayProvider — override surface cut.
        OperatorWebTeamUsersGatewayProvider,
        OperatorWebTeamRolesGatewayProvider,
        OperatorWebTeamHierarchyGatewayProvider,
        OperatorWebTeamSessionsGatewayProvider,
        OperatorWebTeamAuditLogGatewayProvider,
        OperatorWebSecurityGatewayProvider,
        OperatorWebNotificationPreferencesGatewayProvider,
        OperatorWebWageAuthorityGatewayProvider,
        OperatorWebScheduleGatewayProvider,
        OperatorWebHandoffRedeemGatewayProvider,
        MfaFreshnessRedirectListener {
  factory FirebaseOperatorWebAuthSource({
    required FirebaseAuthClient authClient,
    required OperatorWebProxyClient proxyClient,
  }) {
    final businessTimingWriteGateway = HttpWebBusinessTimingGateway(
      client: proxyClient,
      idTokenProvider: authClient.currentIdToken,
    );
    final businessTimingReadGateway = HttpBusinessTimingReadGateway(
      gateway: businessTimingWriteGateway,
    );
    return FirebaseOperatorWebAuthSource._(
      authClient: authClient,
      proxyClient: proxyClient,
      businessTimingReadGateway: businessTimingReadGateway,
      businessTimingWriteGateway: businessTimingWriteGateway,
    );
  }

  FirebaseOperatorWebAuthSource._({
    required FirebaseAuthClient authClient,
    required OperatorWebProxyClient proxyClient,
    required HttpBusinessTimingReadGateway businessTimingReadGateway,
    required this.businessTimingWriteGateway,
  }) : _authClient = authClient,
       _proxyClient = proxyClient,
       _businessTimingReadGateway = businessTimingReadGateway,
       vendorConnectionsGateway = OperatorWebHttpVendorConnectionsGateway(
         proxyClient: proxyClient,
         idTokenProvider: authClient.currentIdToken,
       ),
       accountGateway = HttpWebAccountGateway(
         client: proxyClient,
         idTokenProvider: authClient.currentIdToken,
       ),
       dataAccuracyGateway = OperatorWebHttpDataAccuracyGateway(
         client: proxyClient,
         idTokenProvider: authClient.currentIdToken,
       ),
       vendorApplicabilityGateway = HttpWebVendorApplicabilityGateway(
         proxyBaseUri: proxyClient.baseUri,
         idTokenProvider: authClient.currentIdToken,
       ),
       // Per-Daypart Targets V1 / Slice 2 (Gap 35): benchmarksGateway
       // init removed — operator-web Benchmarks override surface cut.
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
       ),
       scheduleGateway = OperatorWebHttpScheduleGateway(
         proxyBaseUri: proxyClient.baseUri,
         idTokenProvider: authClient.currentIdToken,
       ),
       handoffRedeemGateway = ProxyOperatorWebHandoffRedeemGateway(
         client: proxyClient,
         idTokenProvider: authClient.currentIdToken,
       ),
       vendorLifecycleRecentlyAvailableGateway =
           OperatorWebVendorLifecycleRecentlyAvailableGatewayLive(
             proxyBaseUri: proxyClient.baseUri,
             idTokenProvider: authClient.currentIdToken,
           ) {
    // CODE_OPS_DEBT carry-over #1 — register this auth source as the
    // proxy client's listener for the `mfa_freshness_required` 403
    // redirect. The proxy client surfaces the `redirect_uri` payload
    // by calling `onMfaFreshnessRedirect` (below) just before it
    // throws the `OperatorWebProxyException`. Doing the listener
    // wire-up here (rather than at the proxy-client construction
    // site) keeps the `OperatorWebProxyClient` constructor optional-
    // listener-friendly and lets the auth source take ownership of
    // the sign-out + state-emit handshake.
    proxyClient.mfaFreshnessRedirectListener = this;
    _controller.add(_state);
    unawaited(_bootstrap());
  }

  final FirebaseAuthClient _authClient;
  final OperatorWebProxyClient _proxyClient;
  final HttpBusinessTimingReadGateway _businessTimingReadGateway;
  final StreamController<OperatorWebAuthState> _controller =
      StreamController<OperatorWebAuthState>.broadcast();
  OperatorWebAuthState _state = const OperatorWebLoading();
  bool _closed = false;

  @override
  final OperatorWebHttpVendorConnectionsGateway vendorConnectionsGateway;

  @override
  final WebAccountGateway accountGateway;

  /// Live read gateway for the Business setup screen. Wraps
  /// [businessTimingWriteGateway] so the read view and the editor see
  /// the same proxy responses without a duplicate round trip.
  @override
  BusinessTimingGateway get businessTimingGateway => _businessTimingReadGateway;

  /// Most recently observed timing profiles, exposed so the router can
  /// hand the resolved profile to [BusinessTimingEditorScreen] in edit
  /// mode rather than defaulting to "new profile".
  HttpBusinessTimingReadGateway get businessTimingReadAdapter =>
      _businessTimingReadGateway;

  @override
  final WebBusinessTimingGateway businessTimingWriteGateway;

  @override
  final OperatorWebDataAccuracyGateway dataAccuracyGateway;

  @override
  final WebVendorApplicabilityGateway vendorApplicabilityGateway;

  // Per-Daypart Targets V1 / Slice 2 (Gap 35): benchmarksGateway field
  // removed — operator-web Benchmarks override surface cut.

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

  @override
  final OperatorWebScheduleGateway scheduleGateway;

  @override
  final OperatorWebHandoffRedeemGateway handoffRedeemGateway;

  @override
  final OperatorWebVendorLifecycleRecentlyAvailableGateway
  vendorLifecycleRecentlyAvailableGateway;

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

  /// [onboarding] — when true (magic-link redeem / onboarding MFA
  /// confirm), a session that has not yet enrolled MFA is routed to
  /// the [OperatorWebEnrollingMfa] stage instead of straight to
  /// Completed, so a brand-new invitee completes the onboarding click
  /// path. The production email/password path leaves this false so its
  /// behavior is byte-unchanged (a returning operator with no MFA still
  /// lands on Completed exactly as before).
  ///
  /// [mfaJustEnrolled] — set right after a successful onboarding TOTP
  /// confirm so the resulting session reflects `mfaEnrolled: true` even
  /// if the freshly-refreshed token/account snapshot still lags.
  Future<void> _completeCredential(
    FirebaseAuthCredential credential, {
    bool onboarding = false,
    bool mfaJustEnrolled = false,
  }) async {
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
            mfaJustEnrolled ||
            account.mfaEnabled ||
            credential.customClaims['mfa_enrolled'] == true,
      );
      if (!_hasConsoleAccess(session)) {
        _emit(OperatorWebForbidden(session: session));
        return;
      }
      // Onboarding click path: a brand-new invitee who has not yet
      // enrolled MFA must complete the enroll step before landing on
      // the console. The production email/password path keeps
      // [onboarding] false so its behavior is byte-unchanged.
      if (onboarding && !session.mfaEnrolled) {
        _emit(OperatorWebEnrollingMfa(session: session));
        return;
      }
      _emit(OperatorWebCompleted(session: session));
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

  @override
  Future<void> requireFreshMfaForAccountSecurity({
    required String actionLabel,
  }) async {
    final token = await _requireCurrentToken();
    final authTime = _readAuthTime(token);
    final now = DateTime.now().toUtc();
    if (_isFreshForAccountMfa(authTime: authTime, now: now)) {
      return;
    }
    const redirectUri = '/auth/login?reason=fresh_mfa_required';
    final message =
        'Please sign in again before $actionLabel. This protects '
        'your account settings.';
    onMfaFreshnessRedirect(
      MfaFreshnessRedirectPayload(redirectUri: redirectUri, message: message),
    );
    throw OperatorWebProxyException(
      code: MfaFreshnessRedirectPayload.errorCode,
      message: message,
      statusCode: 403,
      redirectUri: redirectUri,
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
    // A7 — POST the token in the request body, never as a URL query
    // param. G60 — the idempotency_key is derived from the invite
    // token so a network retry (or a double-tap) for the SAME logical
    // redemption replays the proxy's cached result instead of being
    // treated as a fresh redeem. A freshly-minted random key per call
    // would defeat the proxy's `proxy_requests` dedupe (G60 bug).
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      _emit(
        const OperatorWebNeedsToken(
          lastErrorMessage:
              'Paste the code from your invite email and try again.',
        ),
      );
      return;
    }
    final idempotencyKey = _stableIdempotencyKey('magic-link-redeem', trimmed);
    try {
      final response = await _proxyClient.postJsonUnauthenticated(
        OperatorWebProxyClient.authMagicLinkRedeemPath,
        body: <String, Object?>{
          'token': trimmed,
          'idempotency_key': idempotencyKey,
        },
      );
      if (response.statusCode >= 400 && response.statusCode < 500) {
        // Calm operator-facing message regardless of specific 4xx code.
        _emit(
          const OperatorWebNeedsToken(
            lastErrorMessage:
                'This link has expired or been used. Ask your '
                'invite-sender for a new one.',
          ),
        );
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _emit(
          const OperatorWebNeedsToken(
            lastErrorMessage:
                'Something went wrong. Try again or ask Forge & '
                'Flow support to resend your invite.',
          ),
        );
        return;
      }
      // Redemption succeeded. The proxy returns a Firebase custom
      // token; consume it here so a brand-new invitee — who has no
      // email/password yet — lands in an authenticated session and
      // continues onboarding. (G24/G3 fix: previously this emitted a
      // dead-end NeedsSignIn telling the invitee to "sign in with
      // email/password", credentials they do not have.)
      final customToken = _readNonBlank(response.body['firebase_custom_token']);
      if (customToken == null) {
        // Fail-closed: a 2xx with no token means the server contract
        // is not satisfied. Do not fall through to a signed-in state.
        _emit(
          const OperatorWebNeedsToken(
            lastErrorMessage:
                'Something went wrong. Try again or ask Forge & '
                'Flow support to resend your invite.',
          ),
        );
        return;
      }
      final outcome = await _authClient.signInWithCustomToken(
        customToken: customToken,
      );
      switch (outcome) {
        case FirebaseAuthSignInSucceeded(:final credential):
          await _completeCredential(credential, onboarding: true);
        case FirebaseAuthSignInRequiresMfa():
          // Custom-token sign-in never returns an MFA challenge (the
          // token is minted for a specific UID). Treat as fail-closed.
          await _authClient.signOut();
          _emit(
            const OperatorWebNeedsToken(
              lastErrorMessage:
                  'Something went wrong. Try again or ask Forge & '
                  'Flow support to resend your invite.',
            ),
          );
        case FirebaseAuthSignInFailed():
          _emit(
            const OperatorWebNeedsToken(
              lastErrorMessage:
                  'This link has expired or been used. Ask your '
                  'invite-sender for a new one.',
            ),
          );
      }
    } on OperatorWebProxyException catch (error) {
      if ((error.statusCode ?? 0) >= 400 && (error.statusCode ?? 0) < 500) {
        _emit(
          const OperatorWebNeedsToken(
            lastErrorMessage:
                'This link has expired or been used. Ask your '
                'invite-sender for a new one.',
          ),
        );
      } else {
        _emit(
          const OperatorWebNeedsToken(
            lastErrorMessage:
                'Something went wrong. Try again or ask Forge & '
                'Flow support to resend your invite.',
          ),
        );
      }
    } catch (_) {
      _emit(
        const OperatorWebNeedsToken(
          lastErrorMessage:
              'Something went wrong. Try again or ask Forge & '
              'Flow support to resend your invite.',
        ),
      );
    }
  }

  @override
  Future<void> submitPassword({
    required String password,
    required String confirmation,
  }) async {
    // G24/G3 — onboarding password-set.
    //
    // Production invite design (see
    // `lib/infrastructure/persistence/postgres/repositories/
    // invited_user_activation_repository.dart` header) delivers the
    // invite as a Firebase password-reset/action email: the operator
    // sets their password on the Firebase-hosted action page (HIBP
    // screened by Phase 9), then signs in with email/password. By the
    // time the magic-link `firebase_custom_token` is redeemed the
    // account already HAS a password — there is no in-app
    // password-SET step in the live contract.
    //
    // The only proxy password route is `/v1/auth/password/change`
    // (`authPasswordChangePath`), which the server REQUIRES a valid
    // `current_password` for: it calls `firebaseAdmin.verifyPassword`
    // and rejects with `current_password_invalid` / HTTP 403 when the
    // verification fails (see
    // `lib/services/auth/repository_password_change_gateway.dart`
    // lines ~62-73, and the proxy handler at
    // `tool/advisor_proxy/advisor_proxy.dart` ~line 10406). A
    // first-time invitee has no current password to supply, so wiring
    // `submitPassword` to that route would always 403. There is NO
    // dedicated onboarding password-SET route on the proxy.
    //
    // Fail-closed: rather than guessing at a non-existent route, route
    // the operator to the working email/password path (the live
    // contract) with a calm message. We never advance to a signed-in
    // or completed state from here.
    final current = _state;
    final session = current.session;
    if (session != null && current is OperatorWebSettingPassword) {
      _emit(
        OperatorWebSettingPassword(
          session: session,
          lastErrorMessage:
              'Set your password from the link in your invite email, '
              'then sign in below with that email and password.',
        ),
      );
      return;
    }
    _emit(
      const OperatorWebNeedsSignIn(
        lastInfoMessage:
            'Set your password from the link in your invite email, '
            'then sign in with that email and password.',
      ),
    );
  }

  @override
  Future<MfaEnrollmentArtifact> beginMfaEnrollment({
    required MfaFactorType factorType,
    String? phoneNumber,
  }) async {
    // G24/G3 — onboarding TOTP enrollment against the real proxy
    // route. SMS enrollment is demo-only (no proxy SMS route exists);
    // keep it unsupported here.
    if (factorType != MfaFactorType.totp) {
      throw UnsupportedError(
        'SMS MFA is demo-only; use an authenticator app (TOTP).',
      );
    }
    final current = _state;
    final session = current.session;
    if (session == null) {
      throw StateError(
        'beginMfaEnrollment requires an authenticated onboarding session',
      );
    }
    final token = await _requireCurrentToken();
    final setup = await _proxyClient.beginTotpEnrollment(
      idToken: token,
      email: session.email,
    );
    return MfaEnrollmentArtifact(
      enrollmentId: setup.factorId,
      factorType: MfaFactorType.totp,
      totpSharedSecret: setup.secretBase32,
      totpQrUri: setup.otpAuthUrl,
    );
  }

  @override
  Future<void> confirmMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
  }) async {
    // G24/G3 — confirm onboarding TOTP enrollment against the real
    // proxy route, then advance the onboarding state machine.
    final current = _state;
    final session = current.session;
    if (session == null) {
      throw StateError(
        'confirmMfaEnrollment requires an authenticated onboarding session',
      );
    }
    final token = await _requireCurrentToken();
    try {
      await _proxyClient.confirmTotpEnrollment(
        idToken: token,
        factorId: enrollmentId,
        oneTimeCode: oneTimeCode,
      );
    } on OperatorWebProxyException catch (error) {
      // Fail-closed: stay on the enroll step with a calm message; do
      // NOT advance. 4xx => bad/expired code; otherwise generic.
      final status = error.statusCode ?? 0;
      _emit(
        OperatorWebEnrollingMfa(
          session: session,
          lastErrorMessage: status >= 400 && status < 500
              ? 'That code did not match. Codes refresh every 30 '
                    'seconds — type the current one and try again.'
              : 'Two-factor setup is unavailable right now. Try '
                    'again in a moment.',
        ),
      );
      return;
    }
    // MFA enrolled. Re-load the profile so the session reflects
    // `mfaEnrolled: true`. With MFA now enrolled the onboarding-aware
    // path lands on Completed (the ToS step has no proxy route — see
    // the BLOCKER note on [acceptTos]).
    await _completeCredential(
      await _refreshedCredentialOrThrow(),
      onboarding: true,
      mfaJustEnrolled: true,
    );
  }

  @override
  Future<void> acceptTos({
    required String versionId,
    required String scope,
  }) async {
    // G24/G3 — BLOCKER: there is NO `/v1/auth/tos/*` route on the
    // proxy (verified: no `tos` route anywhere in
    // `tool/advisor_proxy/`, and `MagicLinkRedeemGateway` has no
    // production binding either). The `operator_self_served_tos_contract`
    // says the clickwrap infra (tables, screen, state) exists but the
    // server route was never built. Wiring this to a guessed route
    // would violate the slice's "verify the contract or STOP" rule.
    //
    // Fail-closed: surface a calm state instead of throwing an
    // UnsupportedError that would crash the onboarding screen. We do
    // NOT advance to Completed — the operator stays gated until the
    // server route lands (tracked as a BLOCKER in the PR body).
    final current = _state;
    if (current is OperatorWebAcceptingTos) {
      _emit(
        OperatorWebAcceptingTos(
          session: current.session,
          tosVersion: current.tosVersion,
          tosBodyMarkdown: current.tosBodyMarkdown,
          lastErrorMessage:
              'We could not record your acceptance right now. Please '
              'try again shortly, or contact Forge & Flow support.',
        ),
      );
      return;
    }
    _emit(
      const OperatorWebNeedsSignIn(
        lastErrorMessage:
            'We could not record your acceptance right now. Please '
            'try again shortly, or contact Forge & Flow support.',
      ),
    );
  }

  /// Derives a caller-stable idempotency key for an onboarding write so
  /// a network retry (or double-tap) for the SAME logical action
  /// replays the proxy's cached result instead of being treated as a
  /// fresh write (G60). Mirrors the stable-key pattern in
  /// `web_team_roles_gateway.dart` — hash a stable action label plus a
  /// stable per-action seed (here, the invite token / user id) rather
  /// than minting a fresh random key per attempt.
  static String _stableIdempotencyKey(String action, String seed) {
    final digest = sha256.convert(utf8.encode('$action:$seed'));
    return digest.toString();
  }

  Future<FirebaseAuthCredential> _refreshedCredentialOrThrow() async {
    final credential = await _authClient.refreshIdToken();
    if (credential == null) {
      await signOut();
      throw const OperatorWebProxyException(
        code: 'missing_id_token',
        message: 'Your sign-in expired.',
        statusCode: 401,
      );
    }
    return credential;
  }

  static String? _readNonBlank(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<void> signOut() async {
    _currentSessionId = null;
    await _authClient.signOut();
    _emit(const OperatorWebNeedsSignIn());
  }

  /// CODE_OPS_DEBT carry-over #1 — the proxy client invokes this when
  /// any HTTP call returns the `mfa_freshness_required` 403 payload.
  /// Contract: sign out the current Firebase session (no special
  /// flow — the existing [signOut] path) and emit a
  /// [OperatorWebNeedsSignIn] that carries the proxy-supplied
  /// `redirect_uri` so the router can navigate back to the original
  /// surface after re-auth completes.
  ///
  /// This method must NOT throw — it runs inside an HTTP error path
  /// where any throw would mask the original 403.
  @override
  void onMfaFreshnessRedirect(MfaFreshnessRedirectPayload payload) {
    // Capture the redirect intent and clear the cached session id
    // before we drive the async sign-out so a re-render between the
    // two does not see a stale session id paired with the
    // needs-sign-in state.
    _currentSessionId = null;
    final intent = payload.redirectUri;
    // Drive sign-out asynchronously — listener contract is sync.
    // Failures fall through to the unauthenticated state with a
    // safe info message; we deliberately never re-throw.
    unawaited(() async {
      try {
        await _authClient.signOut();
      } catch (_) {
        // Best-effort — fall through to emit so the user lands on
        // the sign-in surface even if the sign-out RPC failed.
      }
      _emit(
        OperatorWebNeedsSignIn(
          lastInfoMessage:
              payload.message ??
              'Please sign in again to continue. This protects your account.',
          redirectUri: intent,
        ),
      );
    }());
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

  static const Duration _accountMfaFreshnessWindow = Duration(minutes: 5);
  static const Duration _accountMfaFreshnessSkew = Duration(seconds: 60);

  static DateTime? _readAuthTime(String idToken) {
    final parts = idToken.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?>) return null;
      final seconds = _readAuthTimeSeconds(decoded['auth_time']);
      if (seconds == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    } on Object {
      return null;
    }
  }

  static int? _readAuthTimeSeconds(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static bool _isFreshForAccountMfa({
    required DateTime? authTime,
    required DateTime now,
  }) {
    if (authTime == null) return false;
    final utcNow = now.toUtc();
    final earliest = utcNow.subtract(_accountMfaFreshnessWindow);
    final latest = utcNow.add(_accountMfaFreshnessSkew);
    return !authTime.toUtc().isBefore(earliest) &&
        !authTime.toUtc().isAfter(latest);
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
    // 11W.4 ops-debt fix — `/v1/auth/team/sessions` now exists on the
    // proxy (see `tool/advisor_proxy/advisor_proxy.dart`); route the
    // call through the live delegate so the operator-web Sessions
    // screen no longer silently degrades to "own sessions only" in
    // production.
    return _delegate.listTeamSessions();
  }

  @override
  Future<WebTeamSessionRevoked> revokeSession(
    WebTeamSessionRevokeCommand command, {
    required String idempotencyKey,
  }) {
    return _delegate.revokeSession(command, idempotencyKey: idempotencyKey);
  }
}
