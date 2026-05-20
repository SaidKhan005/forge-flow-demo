// Phase 11W.live - Firebase + proxy operator-web auth source.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../auth/mfa_freshness_redirect_listener.dart';
import '../../auth/permission_keys.dart';
import '../../services/auth/account_info_gateway.dart';
import '../../services/auth/firebase_auth_client.dart';
import '../account/operator_web_account_actions.dart';
import '../services/operator_web_notification_preferences_gateway_provider.dart';
import '../services/business_timing_gateway.dart';
import '../services/business_logo_upload_gateway.dart';
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
        OperatorWebBusinessLogoUploadGatewayProvider,
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
        OperatorWebAuditLogHierarchyGatewayProvider,
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
       businessLogoUploadGateway = HttpBusinessLogoUploadGateway(
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
       auditLogHierarchyGateway = HttpWebAuditLogHierarchyGateway(
         proxyBaseUri: proxyClient.baseUri,
         tokenProvider: () async {
           final token = await authClient.currentIdToken();
           if (token == null || token.trim().isEmpty) {
             throw const WebAuditLogHierarchyGatewayError(
               'Sign in again to filter the audit log.',
               statusCode: 401,
             );
           }
           return token;
         },
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

  @override
  final BusinessLogoUploadGateway businessLogoUploadGateway;

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
  final WebAuditLogHierarchyGateway auditLogHierarchyGateway;

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
    // G7d (spec §2.B/§3, 2026-05-16): re-based on the v2 default role
    // catalog (`202605150000_phase_r2l_default_role_catalog_v2.sql`).
    //
    // Operator decision: live `roleLabels` provenance is
    // `roles.display_name` (`users_repository.dart:366,458`), so post-v2
    // labels are the v2 *display names*. There is NO raw v1 role-key
    // label and NO v1→v2 label-translation table — we normalize the v2
    // display names directly to their `PermissionKeys.role*` constants.
    //
    // Removed vs the v1 shape:
    //   * the phantom `'operator_admin'` synthesis branch (never seeded
    //     in v1 or v2; folded into `operator_owner` per the resolved
    //     `operator_admin` verdict);
    //   * the `integrations.configure → operator_owner` inflation
    //     (behavior-neutral on the live path — real users carry the
    //     hydrated permission snapshot so the per-screen
    //     `PermissionKeys.*` gates + `_hasConsoleAccess` permission
    //     fallback decide; the empty-snapshot demo/boot path now
    //     fails closed for the removed `operator_admin` collision,
    //     which is the operator-accepted, safer behavior).
    //
    // `location_manager` is a REAL v2 role and is KEPT (mapped to
    // `PermissionKeys.roleLocationManager`).
    final roles = <String>{};
    for (final label in account.roleLabels) {
      final normalized = label.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]+'),
        '_',
      );
      // v2 display name: 'F&F Support' → 'f_f_support'.
      if (normalized.contains('f_f_support') ||
          normalized.contains('ff_support')) {
        roles.add(PermissionKeys.roleFfSupport);
      }
      // v2 display name: 'Owner'.
      if (normalized == 'owner' ||
          normalized.endsWith('_owner') ||
          normalized.contains('operator_owner')) {
        roles.add(PermissionKeys.roleOperatorOwner);
      }
      // v2 display name: 'General Manager' (v1 soft-deleted
      // `operator_manager` → `operator_general_manager` per spec §3).
      if (normalized.contains('general_manager') ||
          normalized.contains('operator_general_manager') ||
          normalized.contains('operator_manager') ||
          normalized == 'manager') {
        roles.add(PermissionKeys.roleOperatorGeneralManager);
      }
      // v2 display name: 'Location Manager' (REAL v2 role — keep).
      if (normalized.contains('location_manager')) {
        roles.add(PermissionKeys.roleLocationManager);
      }
      // v2 display name: 'Supervisor' (v1 soft-deleted
      // `operator_supervisor`/`operator_staff` → `supervisor`).
      if (normalized == 'supervisor' ||
          normalized.endsWith('_supervisor') ||
          normalized.contains('operator_supervisor') ||
          normalized.contains('operator_staff')) {
        roles.add(PermissionKeys.roleSupervisor);
      }
      // v2 display name: 'Finance Analyst'.
      if (normalized.contains('finance_analyst')) {
        roles.add(PermissionKeys.roleFinanceAnalyst);
      }
      // v2 display name: 'Auditor / Compliance' → 'auditor_compliance'.
      if (normalized.contains('auditor') || normalized.contains('compliance')) {
        roles.add(PermissionKeys.roleAuditorCompliance);
      }
      // v2 display name: 'Training Lead'.
      if (normalized.contains('training_lead')) {
        roles.add(PermissionKeys.roleTrainingLead);
      }
      // v2 display name: 'Team Admin' (distinct from the removed
      // phantom `operator_admin` — this is the seeded v2 `team_admin`).
      if (normalized.contains('team_admin')) {
        roles.add(PermissionKeys.roleTeamAdmin);
      }
    }
    if (roles.isEmpty &&
        snapshot.allowedPermissions.any(
          const <String>{
            PermissionKeys.teamUsersView,
            PermissionKeys.adminUsersView,
            PermissionKeys.forgeflowSettingsView,
            PermissionKeys.integrationsConfigure,
          }.contains,
        )) {
      // Empty-label fallback: emit the v2 General Manager constant
      // (v1 `operator_manager` → `operator_general_manager`, spec §3).
      roles.add(PermissionKeys.roleOperatorGeneralManager);
    }
    return roles.toList(growable: false);
  }

  static bool _hasConsoleAccess(OperatorWebSession session) {
    if (session.roles.any(kOperatorWebAdmittedRoles.contains)) return true;
    return session.permissions.any(
      const <String>{
        PermissionKeys.teamUsersView,
        PermissionKeys.adminUsersView,
        PermissionKeys.forgeflowSettingsView,
        PermissionKeys.integrationsConfigure,
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
