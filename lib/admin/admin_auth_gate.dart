// Phase 11A.0 - Admin auth gate.
//
// The admin console is F&F-internal back-office. Only Firebase users
// whose ID token carries a `super_admin` or `ff_support` role claim
// are admitted; everyone else is fail-closed to a "Forbidden" surface
// that exposes a sign-out affordance.
//
// Two auth sources ship with this slice:
//
//   * [FirebaseAdminAuthSource] - production. Wraps the shared
//     `FirebaseAuthClient` adapter and reads custom claims from the
//     returned credential. Phase 11A.x slices wire the Firebase web
//     init step against the production admin project; the source is a
//     thin adapter so that wiring is additive rather than
//     restructuring this gate.
//   * [DemoAdminAuthSource] - tests + the kDemoMode walkthrough. Lets
//     a widget exercise both the admit path (super_admin / ff_support)
//     and the fail-closed path (any other role list, or signed-out)
//     without touching live Firebase Authentication.
//
// The gate widget itself is auth-source agnostic - it watches a
// [Stream] of [AdminAuthState] and renders one of the auth surfaces
// (loading / unauthenticated / MFA challenge / forbidden / admin shell). The same
// shape works for both production and demo.
//
// Operator-app auth (`lib/state/auth_session_notifier.dart`,
// `lib/screens/auth/login_screen.dart`) is intentionally NOT reused.
// Phase 11A is admin-only, on a separate Cloud Run service, with a
// different Firebase project / role catalog. Sharing the operator
// notifier would couple two products that the Hard Promises keep
// separate.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../auth/mfa_freshness_redirect_listener.dart';
import '../auth/permission_keys.dart';
import '../screens/auth/totp_challenge_view.dart';
import '../services/auth/firebase_auth_client.dart';
import '../services/auth/firebase_auth_client_sdk.dart';
import '../theme/app_theme.dart';
import 'admin_button_styles.dart';
import 'services/admin_sessions_gateway.dart';

/// Roles that are admitted to the admin console. Mirrors the
/// `_adminTierRoles` set in `lib/auth/mfa_policy.dart` for
/// `super_admin` + `ff_support`. Operator roles
/// (`operator_owner` / `operator_manager`) are explicitly NOT
/// admitted here - the admin console is F&F-internal, not operator
/// self-service.
const Set<String> kAdminConsoleRoles = <String>{
  PermissionKeys.roleSuperAdmin,
  PermissionKeys.roleFfSupport,
};

/// Identity payload an admit decision was made against. Carries only
/// what the gate / shell need to render the admin surface; it does
/// not promise to be a full Firebase user object.
@immutable
class AdminAuthSession {
  const AdminAuthSession({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.roles,
    this.lastFreshAuthAt,
  });

  /// Firebase user UID (or a synthetic id under demo mode).
  final String uid;

  /// Email if the IdP returned one. May be empty for demo fixtures.
  final String email;

  /// Display name. Falls back to email-localpart if Firebase did not
  /// supply one.
  final String displayName;

  /// Role claims. Membership in [kAdminConsoleRoles] is what the
  /// admit decision keys off.
  final List<String> roles;

  /// JWT `auth_time` (last time the user actually authenticated,
  /// including MFA completion). Drives the
  /// [FreshMfaResolver]-backed gate on the four MFA-pinned admin
  /// actions (canEditSeededRoles, canResetMfaFactors,
  /// canIssuePairedErasure, canExportAuditLog). Null for demo
  /// fixtures and the legacy bare-claims path; the resolver treats
  /// null/epoch-zero as "never fresh" so the affordance fails closed.
  final DateTime? lastFreshAuthAt;

  /// True if any admitted role is present.
  bool get isAdmin => roles.any(kAdminConsoleRoles.contains);
}

/// Sealed state machine the gate switches on. `forbidden` is the
/// fail-closed branch: signed-in but the ID token did not carry an
/// admin role claim.
sealed class AdminAuthState {
  const AdminAuthState();
}

class AdminAuthLoading extends AdminAuthState {
  const AdminAuthLoading();
}

class AdminAuthUnauthenticated extends AdminAuthState {
  const AdminAuthUnauthenticated({
    this.lastErrorMessage,
    this.lastInfoMessage,
    this.redirectUri,
  });

  final String? lastErrorMessage;

  /// CODE_OPS_DEBT carry-over #1 — non-error explanation rendered on
  /// the sign-in surface when the user landed here because the proxy
  /// returned the `mfa_freshness_required` 403. Falls back to a
  /// generic "please sign in again" copy if the proxy did not supply
  /// a message.
  final String? lastInfoMessage;

  /// CODE_OPS_DEBT carry-over #1 — populated when the user was sent
  /// here by the freshness redirect. The shell uses this hint to
  /// navigate back to the originating surface after a successful
  /// re-auth + MFA completion.
  final String? redirectUri;
}

class AdminAuthForbidden extends AdminAuthState {
  const AdminAuthForbidden(this.session);

  final AdminAuthSession session;
}

class AdminAuthMfaChallenge extends AdminAuthState {
  const AdminAuthMfaChallenge({
    required this.email,
    required this.mfaSessionToken,
    required this.factorIds,
    this.lastErrorMessage,
  });

  final String email;
  final String mfaSessionToken;
  final List<String> factorIds;
  final String? lastErrorMessage;

  AdminAuthMfaChallenge copyWith({String? lastErrorMessage}) {
    return AdminAuthMfaChallenge(
      email: email,
      mfaSessionToken: mfaSessionToken,
      factorIds: factorIds,
      lastErrorMessage: lastErrorMessage,
    );
  }
}

class AdminAuthAuthenticated extends AdminAuthState {
  const AdminAuthAuthenticated(this.session);

  final AdminAuthSession session;
}

/// Source of admin auth state. Both live Firebase wiring and demo
/// fixtures implement this so the gate stays implementation-blind.
///
/// Implementations also act as the [MfaFreshnessRedirectListener] for
/// the admin shell's gateways — when any admin gateway intercepts a
/// `mfa_freshness_required` 403 it dispatches to
/// [onMfaFreshnessRedirect] (CODE_OPS_DEBT carry-over #1), which signs
/// out the current admin session and emits an
/// [AdminAuthUnauthenticated] state carrying the proxy-supplied
/// `redirect_uri` hint.
abstract class AdminAuthSource implements MfaFreshnessRedirectListener {
  Stream<AdminAuthState> get stream;
  AdminAuthState get current;

  /// Sign-in entrypoint. Production source surfaces this through the
  /// branded sign-in card; demo source flips a fixture.
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  });

  Future<void> completeTotpChallenge({
    required String factorId,
    required String oneTimeCode,
  });

  Future<void> signOut();

  void dispose();
}

/// Demo auth source. The admin walkthrough and widget tests run
/// against this so the click path can be exercised without touching
/// live Firebase Authentication.
class DemoAdminAuthSource implements AdminAuthSource {
  DemoAdminAuthSource({AdminAuthState? initial})
    : _state = initial ?? const AdminAuthLoading() {
    _controller.add(_state);
  }

  /// Convenience factory: starts signed-out so the walkthrough drives
  /// the sign-in card explicitly.
  factory DemoAdminAuthSource.signedOut() =>
      DemoAdminAuthSource(initial: const AdminAuthUnauthenticated());

  /// Convenience factory: starts already signed in as a super-admin.
  /// Useful for widget tests that just need the shell rendered.
  factory DemoAdminAuthSource.signedInAsSuperAdmin() => DemoAdminAuthSource(
    initial: const AdminAuthAuthenticated(
      AdminAuthSession(
        uid: 'demo-super-admin',
        email: 'demo.super.admin@forgeflow.test',
        displayName: 'Demo Super Admin',
        roles: <String>[PermissionKeys.roleSuperAdmin],
      ),
    ),
  );

  /// Convenience factory: starts already signed in as F&F support.
  /// Share-preview builds use this so the public link opens directly
  /// into read-only seeded data with no login screen.
  factory DemoAdminAuthSource.signedInAsSupport() => DemoAdminAuthSource(
    initial: const AdminAuthAuthenticated(
      AdminAuthSession(
        uid: 'demo-ff-support',
        email: 'support@forgeflow.test',
        displayName: 'Demo F&F Support',
        roles: <String>[PermissionKeys.roleFfSupport],
      ),
    ),
  );

  /// Convenience factory: starts signed in as a non-admin so the
  /// fail-closed path renders.
  factory DemoAdminAuthSource.signedInAsNonAdmin() => DemoAdminAuthSource(
    initial: const AdminAuthForbidden(
      AdminAuthSession(
        uid: 'demo-non-admin',
        email: 'demo.operator@forgeflow.test',
        displayName: 'Demo Operator',
        roles: <String>['operator_owner'],
      ),
    ),
  );

  final StreamController<AdminAuthState> _controller =
      StreamController<AdminAuthState>.broadcast();
  AdminAuthState _state;

  /// Demo registry - matches against the email submitted on the
  /// sign-in card. Keeps the walkthrough deterministic without
  /// shipping live credentials.
  static const Map<String, AdminAuthSession> _demoUsers =
      <String, AdminAuthSession>{
        'super.admin@forgeflow.test': AdminAuthSession(
          uid: 'demo-super-admin',
          email: 'super.admin@forgeflow.test',
          displayName: 'Demo Super Admin',
          roles: <String>[PermissionKeys.roleSuperAdmin],
        ),
        'support@forgeflow.test': AdminAuthSession(
          uid: 'demo-ff-support',
          email: 'support@forgeflow.test',
          displayName: 'Demo F&F Support',
          roles: <String>[PermissionKeys.roleFfSupport],
        ),
        'operator@forgeflow.test': AdminAuthSession(
          uid: 'demo-operator',
          email: 'operator@forgeflow.test',
          displayName: 'Demo Operator',
          roles: <String>['operator_owner'],
        ),
      };

  @override
  Stream<AdminAuthState> get stream => _controller.stream;

  @override
  AdminAuthState get current => _state;

  @override
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final normalized = email.trim().toLowerCase();
    final fixture = _demoUsers[normalized];
    if (fixture == null) {
      _emit(
        const AdminAuthUnauthenticated(
          lastErrorMessage:
              'Demo mode: unknown email. Try super.admin@forgeflow.test, '
              'support@forgeflow.test, or operator@forgeflow.test.',
        ),
      );
      return;
    }
    _emit(
      fixture.isAdmin
          ? AdminAuthAuthenticated(fixture)
          : AdminAuthForbidden(fixture),
    );
  }

  @override
  Future<void> completeTotpChallenge({
    required String factorId,
    required String oneTimeCode,
  }) async {
    final current = _state;
    if (current is! AdminAuthMfaChallenge) {
      throw StateError('completeTotpChallenge requires admin MFA state');
    }
    if (oneTimeCode == '123456') {
      _emit(
        const AdminAuthAuthenticated(
          AdminAuthSession(
            uid: 'demo-super-admin',
            email: 'super.admin@forgeflow.test',
            displayName: 'Demo Super Admin',
            roles: <String>[PermissionKeys.roleSuperAdmin],
          ),
        ),
      );
      return;
    }
    _emit(
      current.copyWith(
        lastErrorMessage: 'Verification failed. Check the code and try again.',
      ),
    );
  }

  @override
  Future<void> signOut() async {
    _emit(const AdminAuthUnauthenticated());
  }

  /// CODE_OPS_DEBT carry-over #1 — proxy 403 redirect listener. The
  /// demo source has no real Firebase session; we emit an
  /// unauthenticated state carrying the redirect hint so widget tests
  /// can assert the contract.
  @override
  void onMfaFreshnessRedirect(MfaFreshnessRedirectPayload payload) {
    _emit(
      AdminAuthUnauthenticated(
        lastInfoMessage:
            payload.message ??
            'Please sign in again to continue. This protects your '
                'account.',
        redirectUri: payload.redirectUri,
      ),
    );
  }

  /// Test helper: swap the state directly without going through
  /// sign-in. Lets widget tests pin a fixture without async timing.
  @visibleForTesting
  void emitForTesting(AdminAuthState state) => _emit(state);

  void _emit(AdminAuthState next) {
    _state = next;
    _controller.add(next);
  }

  @override
  void dispose() {
    _controller.close();
  }
}

/// Live Firebase Authentication source. Reads custom claims from the
/// shared Firebase auth adapter and emits the matching admin gate state.
class FirebaseAdminAuthSource implements AdminAuthSource {
  FirebaseAdminAuthSource({
    FirebaseAuthClient? client,
    AdminSessionsGateway? sessionLedger,
  }) : _client = client ?? FirebaseAuthSdkClient(),
       _sessionLedger = sessionLedger,
       _state = const AdminAuthLoading() {
    _controller.add(_state);
    unawaited(_bootstrapCurrentUser());
  }

  final FirebaseAuthClient _client;

  /// G1 (audit fix-first #2) — admin-side `auth_sessions` ledger
  /// writer. Wired live in `lib/main_admin.dart`; null in demo /
  /// share-preview (no-op, the walkthrough has no proxy). When live,
  /// an admitted sign-in MUST record a ledger row before the admin
  /// shell renders: a failed ledger write fails the sign-in CLOSED
  /// (mirrors the mobile `ledger_unavailable` posture in
  /// `lib/services/auth/auth_session_notifier.dart`). An unrecorded
  /// admin session is never admitted in live mode.
  final AdminSessionsGateway? _sessionLedger;

  /// Session id returned by the ledger at sign-in. Kept so `signOut`
  /// can close exactly that row (parity with operator-web's
  /// `_currentSessionId`). Null in demo / share-preview or before the
  /// first admitted sign-in.
  String? _ledgerSessionId;

  int _ledgerIdempotencyCounter = 0;

  final StreamController<AdminAuthState> _controller =
      StreamController<AdminAuthState>.broadcast();
  AdminAuthState _state;
  bool _disposed = false;

  @override
  Stream<AdminAuthState> get stream => _controller.stream;

  @override
  AdminAuthState get current => _state;

  @override
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final outcome = await _client.signInWithEmailPassword(
      email: email.trim(),
      password: password,
    );
    await _applyOutcome(outcome, emailForMfa: email.trim());
  }

  @override
  Future<void> completeTotpChallenge({
    required String factorId,
    required String oneTimeCode,
  }) async {
    final current = _state;
    if (current is! AdminAuthMfaChallenge) {
      throw StateError('completeTotpChallenge requires admin MFA state');
    }
    final outcome = await _client.completeTotpChallenge(
      mfaSessionToken: current.mfaSessionToken,
      factorId: factorId,
      oneTimeCode: oneTimeCode,
    );
    await _applyOutcome(
      outcome,
      emailForMfa: current.email,
      previousChallenge: current,
    );
  }

  @override
  Future<void> signOut() async {
    // G1 — close the ledger row this session opened at sign-in.
    // Best-effort: a transient proxy blip must NOT trap the admin in a
    // session they asked to end, so a failure here is logged-and-
    // continued (mirrors the mobile revoke posture). The local Firebase
    // sign-out + state emit always proceed.
    final ledger = _sessionLedger;
    final sessionId = _ledgerSessionId;
    if (ledger != null && sessionId != null) {
      try {
        await ledger.revokeSession(
          sessionId: sessionId,
          reason: 'admin_signed_out_this_session',
          idempotencyKey: _mintLedgerIdempotencyKey('revoke', sessionId),
        );
      } catch (_) {
        // Swallow — see comment above. The row is reconciled by the
        // proxy's session-expiry sweep if the revoke never lands.
      }
    }
    _ledgerSessionId = null;
    await _client.signOut();
    _emit(const AdminAuthUnauthenticated());
  }

  /// CODE_OPS_DEBT carry-over #1 — proxy 403 redirect listener. Drive
  /// the existing Firebase Auth sign-out flow then emit an
  /// unauthenticated state carrying the proxy-supplied
  /// `redirect_uri`. This method is called from inside an HTTP
  /// error path (gateway about to throw) so it MUST NOT throw —
  /// failures fall through to a generic info message and the user
  /// still lands on the sign-in card.
  @override
  void onMfaFreshnessRedirect(MfaFreshnessRedirectPayload payload) {
    final intent = payload.redirectUri;
    final infoMessage =
        payload.message ??
        'Please sign in again to continue. This protects your account.';
    unawaited(() async {
      try {
        await _client.signOut();
      } catch (_) {
        // Best-effort — fall through to emit so the user still lands
        // on the sign-in card even if the sign-out RPC failed.
      }
      _emit(
        AdminAuthUnauthenticated(
          lastInfoMessage: infoMessage,
          redirectUri: intent,
        ),
      );
    }());
  }

  Future<void> _bootstrapCurrentUser() async {
    try {
      final credential = await _client.refreshIdToken();
      if (credential == null) {
        _emit(const AdminAuthUnauthenticated());
        return;
      }
      await _emitForCredential(credential);
    } catch (error) {
      _emit(
        AdminAuthUnauthenticated(
          lastErrorMessage: 'Could not initialize admin auth: $error',
        ),
      );
    }
  }

  Future<void> _applyOutcome(
    FirebaseAuthSignInOutcome outcome, {
    required String emailForMfa,
    AdminAuthMfaChallenge? previousChallenge,
  }) async {
    switch (outcome) {
      case FirebaseAuthSignInSucceeded(:final credential):
        await _emitForCredential(credential, emailFallback: emailForMfa);
      case FirebaseAuthSignInRequiresMfa(
        :final mfaSessionToken,
        :final factorIds,
      ):
        _emit(
          AdminAuthMfaChallenge(
            email: emailForMfa,
            mfaSessionToken: mfaSessionToken,
            factorIds: factorIds,
          ),
        );
      case FirebaseAuthSignInFailed(:final message):
        if (previousChallenge != null) {
          _emit(previousChallenge.copyWith(lastErrorMessage: message));
        } else {
          _emit(AdminAuthUnauthenticated(lastErrorMessage: message));
        }
    }
  }

  AdminAuthSession _sessionForCredential(
    FirebaseAuthCredential credential, {
    String? emailFallback,
  }) {
    final roles = _extractRoles(credential.customClaims);
    final email = credential.email ?? emailFallback ?? '';
    return AdminAuthSession(
      uid: credential.userId,
      email: email,
      displayName:
          credential.displayName ??
          _localPartOrUid(email: email, uid: credential.userId),
      roles: roles,
      // Carry the verified `auth_time` claim through to the admin
      // shell so the four MFA-pinned action gates (CODE_OPS_DEBT
      // Theme A, item 1) can resolve via the shared
      // FreshMfaResolver instead of the historic `const ... = false`
      // pins.
      lastFreshAuthAt: credential.lastFreshAuthAt,
    );
  }

  /// G1 (audit fix-first #2) — resolve the admit decision AND, for an
  /// admitted session in live mode, record the `auth_sessions` ledger
  /// row BEFORE emitting [AdminAuthAuthenticated].
  ///
  /// Fail-closed: if the ledger writer is wired (live) and the write
  /// fails, the sign-in does NOT proceed — the source emits
  /// [AdminAuthUnauthenticated] with a calm message, mirroring the
  /// mobile `AuthLoginFailure(code: 'ledger_unavailable')` posture in
  /// `lib/services/auth/auth_session_notifier.dart`. An unrecorded
  /// admin session is never admitted in live mode. Demo / share-
  /// preview wire no ledger (`_sessionLedger == null`) → no-op, the
  /// walkthrough is unaffected. The fail-closed gate does NOT touch
  /// the admit logic itself (`session.isAdmin` /
  /// [kAdminConsoleRoles]) — the forbidden branch is unchanged and
  /// never reaches the ledger.
  Future<void> _emitForCredential(
    FirebaseAuthCredential credential, {
    String? emailFallback,
  }) async {
    final session = _sessionForCredential(
      credential,
      emailFallback: emailFallback,
    );
    if (!session.isAdmin) {
      // Fail-closed branch is byte-unchanged: a non-admin never gets a
      // ledger row and never reaches the shell.
      _emit(AdminAuthForbidden(session));
      return;
    }
    final ledger = _sessionLedger;
    if (ledger == null) {
      // Demo / share-preview: no proxy, no ledger. Same admit decision
      // and same emitted state as before this slice.
      _emit(AdminAuthAuthenticated(session));
      return;
    }
    try {
      final tokenHash = sha256
          .convert(utf8.encode(credential.idToken))
          .toString();
      final record = await ledger.recordSessionLogin(
        tokenHash: tokenHash,
        idempotencyKey: _mintLedgerIdempotencyKey('login', credential.userId),
      );
      _ledgerSessionId = record.sessionId;
      _emit(AdminAuthAuthenticated(session));
    } catch (_) {
      // Fail-closed. Do NOT admit an unrecorded admin session. The
      // calm copy mirrors the mobile ledger-unavailable banner: the
      // admin's credentials were fine; the session ledger could not be
      // written, so they are returned to the sign-in card to retry.
      _ledgerSessionId = null;
      try {
        await _client.signOut();
      } catch (_) {
        // Best-effort local sign-out so a half-open Firebase session
        // does not linger; the emit below still lands the admin on the
        // sign-in card regardless.
      }
      _emit(
        const AdminAuthUnauthenticated(
          lastErrorMessage:
              'Your sign-in worked, but we could not start a secure admin '
              'session. Please sign in again in a moment.',
        ),
      );
    }
  }

  String _mintLedgerIdempotencyKey(String action, String scopeHint) {
    _ledgerIdempotencyCounter += 1;
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'admin-auth-session-$action-$scopeHint-$micros-'
        '$_ledgerIdempotencyCounter';
  }

  /// Projects Phase 9's locked admin claim shape onto the gate's
  /// role list. The auth contract (`docs/phases/phase_9/
  /// phase_9_auth_plan.md`, decision lock 2026-04-26) keeps the JWT
  /// custom-claims payload tiny: `operator_id`, `is_super_admin`,
  /// `is_ff_support`, `roles_version`. Postgres remains source of
  /// truth for full role/permission resolution; the JWT only carries
  /// the two boolean admin flags. Mirrors the canonical projection
  /// in `lib/services/auth/firebase_auth_login_service.dart`
  /// `_extractRoles` so the operator app and the admin console
  /// agree on what "admin" means.
  @visibleForTesting
  static List<String> extractRolesFromClaims(Map<String, Object?> claims) {
    final roles = <String>[];
    if (claims['is_super_admin'] == true) {
      roles.add(PermissionKeys.roleSuperAdmin);
    }
    if (claims['is_ff_support'] == true) {
      roles.add(PermissionKeys.roleFfSupport);
    }
    return List<String>.unmodifiable(roles);
  }

  static List<String> _extractRoles(Map<String, Object?> claims) =>
      extractRolesFromClaims(claims);

  static String _localPartOrUid({required String email, required String uid}) {
    if (!email.contains('@')) return uid;
    return email.split('@').first;
  }

  void _emit(AdminAuthState next) {
    if (_disposed) return;
    _state = next;
    _controller.add(next);
  }

  @override
  void dispose() {
    _disposed = true;
    _controller.close();
  }
}

/// The gate widget. Subscribes to [source] and renders one of:
///
///   * branded sign-in card (unauthenticated)
///   * branded TOTP challenge card (MFA challenge)
///   * branded "forbidden" card with sign-out (forbidden)
///   * [adminShellBuilder] result (authenticated)
///   * default loading splash (loading)
///
/// The shell is provided by the caller so this gate has no
/// dependency on `lib/admin/admin_shell.dart` and can stay testable
/// in isolation.
class AdminAuthGate extends StatefulWidget {
  const AdminAuthGate({
    super.key,
    required this.source,
    required this.adminShellBuilder,
    this.loadingBuilder,
  });

  final AdminAuthSource source;
  final Widget Function(BuildContext context, AdminAuthSession session)
  adminShellBuilder;
  final WidgetBuilder? loadingBuilder;

  @override
  State<AdminAuthGate> createState() => _AdminAuthGateState();
}

class _AdminAuthGateState extends State<AdminAuthGate> {
  late AdminAuthState _state;
  late StreamSubscription<AdminAuthState> _subscription;

  @override
  void initState() {
    super.initState();
    _state = widget.source.current;
    _subscription = widget.source.stream.listen((next) {
      if (!mounted) return;
      setState(() => _state = next);
    });
  }

  @override
  void didUpdateWidget(covariant AdminAuthGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _subscription.cancel();
      _state = widget.source.current;
      _subscription = widget.source.stream.listen((next) {
        if (!mounted) return;
        setState(() => _state = next);
      });
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return switch (state) {
      AdminAuthLoading() =>
        widget.loadingBuilder?.call(context) ?? const _AdminLoading(),
      AdminAuthUnauthenticated() => _AdminSignInScreen(
        source: widget.source,
        errorMessage: state.lastErrorMessage,
        infoMessage: state.lastInfoMessage,
        redirectUri: state.redirectUri,
      ),
      AdminAuthForbidden() => _AdminForbiddenScreen(
        source: widget.source,
        session: state.session,
      ),
      AdminAuthMfaChallenge() => _AdminMfaChallengeScreen(
        source: widget.source,
        challenge: state,
      ),
      AdminAuthAuthenticated() => widget.adminShellBuilder(
        context,
        state.session,
      ),
    };
  }
}

class _AdminLoading extends StatelessWidget {
  const _AdminLoading();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: const Center(
        child: SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      ),
    );
  }
}

class _AdminMfaChallengeScreen extends StatefulWidget {
  const _AdminMfaChallengeScreen({
    required this.source,
    required this.challenge,
  });

  final AdminAuthSource source;
  final AdminAuthMfaChallenge challenge;

  @override
  State<_AdminMfaChallengeScreen> createState() =>
      _AdminMfaChallengeScreenState();
}

class _AdminMfaChallengeScreenState extends State<_AdminMfaChallengeScreen> {
  String? _helpMessage;

  Future<void> _submit(String code) async {
    final factorId = widget.challenge.factorIds.isNotEmpty
        ? widget.challenge.factorIds.first
        : 'totp';
    await widget.source.completeTotpChallenge(
      factorId: factorId,
      oneTimeCode: code,
    );
  }

  Future<void> _requestHelp() async {
    setState(() {
      _helpMessage =
          'Contact the F&F ecosystem admin for a factor reset or recovery review.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return TotpChallengeView(
      title: 'Two-factor sign-in',
      email: widget.challenge.email,
      errorMessage: widget.challenge.lastErrorMessage,
      helpMessage: _helpMessage,
      helpButtonLabel: 'Contact F&F support',
      helpButtonLoadingLabel: 'Sending...',
      onSubmit: _submit,
      onRequestHelp: _requestHelp,
      onCancel: widget.source.signOut,
    );
  }
}

class _AdminSignInScreen extends StatefulWidget {
  const _AdminSignInScreen({
    required this.source,
    this.errorMessage,
    this.infoMessage,
    this.redirectUri,
  });

  final AdminAuthSource source;
  final String? errorMessage;

  /// CODE_OPS_DEBT carry-over #1 — surfaces the post-freshness-403
  /// info banner ("Please sign in again to continue. This protects
  /// your account.") on the sign-in card. Distinct from
  /// [errorMessage] so we render it in a calm tone, not the red
  /// error band.
  final String? infoMessage;

  /// CODE_OPS_DEBT carry-over #1 — opaque return-to hint emitted by
  /// the proxy. Stored on the screen as a hidden field so
  /// post-sign-in flows can resume the originally-requested admin
  /// action. Not currently rendered, but threaded through so future
  /// slices can wire it without re-touching this gate.
  final String? redirectUri;

  @override
  State<_AdminSignInScreen> createState() => _AdminSignInScreenState();
}

class _AdminSignInScreenState extends State<_AdminSignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _localError;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _localError = 'Email and password are required.';
      });
      return;
    }
    setState(() {
      _submitting = true;
      _localError = null;
    });
    try {
      await widget.source.signInWithEmailPassword(
        email: email,
        password: password,
      );
    } catch (_) {
      // The source is responsible for surfacing its own error via
      // the stream. Local catch keeps the spinner from leaking.
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final externalError = widget.errorMessage;
    final error = _localError ?? externalError;
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.backgroundDeep,
              AppColors.backgroundMid,
              AppColors.shimmer,
            ],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _AdminBrandMark(subtitle: 'Admin Console'),
                    const SizedBox(height: 28),
                    if (widget.infoMessage != null) ...[
                      _AdminInfoBanner(
                        key: const Key('admin_signin_info_banner'),
                        message: widget.infoMessage!,
                      ),
                      const SizedBox(height: 14),
                    ],
                    _AdminSignInCard(
                      key: const Key('admin_signin_card'),
                      emailController: _emailController,
                      passwordController: _passwordController,
                      submitting: _submitting,
                      errorMessage: error,
                      onSubmit: _submit,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'F&F internal access only.',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AdminBrandMark extends StatelessWidget {
  const _AdminBrandMark({required this.subtitle});

  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.sunset.withValues(alpha: 0.18),
                blurRadius: 22,
                spreadRadius: 1,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/images/forge_flow_splash_icon.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Forge & Flow',
          textAlign: TextAlign.center,
          style: AppTextStyles.display28(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: AppTextStyles.mono8(color: AppColors.sunsetDark),
        ),
      ],
    );
  }
}

class _AdminSignInCard extends StatelessWidget {
  const _AdminSignInCard({
    super.key,
    required this.emailController,
    required this.passwordController,
    required this.submitting,
    required this.errorMessage,
    required this.onSubmit,
  });

  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool submitting;
  final String? errorMessage;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.backgroundSurface, AppColors.cardGlow],
          ),
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          boxShadow: [
            BoxShadow(
              color: AppColors.textPrimary.withValues(alpha: 0.04),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Admin sign in',
                style: AppTextStyles.mono15(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                height: 2,
                width: 28,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.sunset, AppColors.sunsetDark],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (errorMessage != null) ...[
                _ErrorBanner(message: errorMessage!),
                const SizedBox(height: 14),
              ],
              _BrandedField(
                fieldKey: const Key('admin_email_field'),
                controller: emailController,
                label: 'Email',
                obscureText: false,
                enabled: !submitting,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const <String>[AutofillHints.username],
              ),
              const SizedBox(height: 14),
              _BrandedField(
                fieldKey: const Key('admin_password_field'),
                controller: passwordController,
                label: 'Password',
                obscureText: true,
                enabled: !submitting,
                autofillHints: const <String>[AutofillHints.password],
                onSubmitted: (_) => onSubmit(),
              ),
              const SizedBox(height: 20),
              _SignInButton(
                submitting: submitting,
                onPressed: submitting ? null : onSubmit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandedField extends StatelessWidget {
  const _BrandedField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.obscureText,
    required this.enabled,
    this.keyboardType,
    this.autofillHints,
    this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool obscureText;
  final bool enabled;
  final TextInputType? keyboardType;
  final List<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
    );
    return TextField(
      key: fieldKey,
      controller: controller,
      obscureText: obscureText,
      enabled: enabled,
      keyboardType: keyboardType,
      autofillHints: autofillHints,
      onSubmitted: onSubmitted,
      cursorColor: AppColors.sunset,
      style: AppTextStyles.body15(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
        floatingLabelStyle: AppTextStyles.mono11(color: AppColors.sunsetDark),
        filled: true,
        fillColor: AppColors.backgroundSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.sunset, width: 1.6),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(
            color: AppColors.borderSubtle.withValues(alpha: 0.6),
            width: 1,
          ),
        ),
      ),
    );
  }
}

class _SignInButton extends StatelessWidget {
  const _SignInButton({required this.submitting, required this.onPressed});

  final bool submitting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        key: const Key('admin_signin_submit'),
        onPressed: onPressed,
        style: AdminButtonStyles.primary,
        child: submitting
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.backgroundSurface,
                ),
              )
            : const Text('Sign in'),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_signin_error_banner'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.negative),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ),
        ],
      ),
    );
  }
}

/// CODE_OPS_DEBT carry-over #1 — calm-tone info banner rendered on
/// the admin sign-in card after a `mfa_freshness_required` 403
/// triggered a forced sign-out. Distinct from [_ErrorBanner] so the
/// user does not read this as a failure they caused.
class _AdminInfoBanner extends StatelessWidget {
  const _AdminInfoBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.sunset.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppColors.sunsetDark),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminForbiddenScreen extends StatelessWidget {
  const _AdminForbiddenScreen({required this.source, required this.session});

  final AdminAuthSource source;
  final AdminAuthSession session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  key: const Key('admin_forbidden_card'),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundSurface,
                    border: Border.all(color: AppColors.borderSubtle, width: 1),
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.lock_outline,
                            size: 18,
                            color: AppColors.negative,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Admin access required',
                              style: AppTextStyles.mono15(
                                color: AppColors.textPrimary,
                                weight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Signed in as ${session.email.isEmpty ? session.uid : session.email}, '
                        'but your account does not carry an admin role claim '
                        '(${kAdminConsoleRoles.join(' / ')}). The Forge & Flow '
                        'Admin Console is internal F&F access only.',
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 42,
                        child: OutlinedButton(
                          key: const Key('admin_forbidden_signout'),
                          onPressed: () => source.signOut(),
                          style: AdminButtonStyles.secondary(),
                          child: const Text('Sign out'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
