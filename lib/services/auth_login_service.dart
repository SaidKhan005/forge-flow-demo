// Phase 9.3 - Auth login service seam.
//
// Abstracts Firebase Identity Platform login so the Flutter shells
// can drive the login flow without depending on `firebase_auth`
// directly. Production binds `firebase_auth` (mobile) or
// `firebase_auth_web` (admin web console) — adding those packages
// is a focused follow-up parallel to the 9.1 RS256 backend gap.
// The scaffold default fails closed on every operation so a
// misconfigured deploy can't silently allow.

import '../auth/auth_session.dart';

/// Outcome of a sign-in attempt.
sealed class AuthLoginResult {
  const AuthLoginResult();
}

class AuthLoginSuccess extends AuthLoginResult {
  const AuthLoginSuccess(this.session);

  final AuthSession session;
}

/// User must complete an MFA challenge before the session is issued.
/// Carries the resolver token the UI passes to [AuthLoginService.completeMfaChallenge].
class AuthLoginMfaRequired extends AuthLoginResult {
  const AuthLoginMfaRequired({
    required this.mfaSessionToken,
    required this.factorIds,
  });

  final String mfaSessionToken;
  final List<String> factorIds;
}

class AuthLoginFailure extends AuthLoginResult {
  const AuthLoginFailure({required this.code, required this.message});

  /// Stable machine-readable code (e.g. `invalid_credentials`,
  /// `account_suspended`, `email_not_verified`, `network_error`).
  /// UI maps this to localized copy.
  final String code;

  /// Human-readable detail. Safe to surface in an error banner;
  /// MUST NOT carry the password attempt or any token contents.
  final String message;
}

abstract class AuthLoginService {
  /// Attempts to sign the user in with email + password.
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  });

  /// Completes a TOTP MFA challenge initiated by an
  /// [AuthLoginMfaRequired] result.
  Future<AuthLoginResult> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  });

  /// Sends the standard branded password-reset action link to [email].
  /// The UI surfaces a generic "if the email is registered, you'll get
  /// a link" message regardless of whether the email exists, to avoid
  /// account-existence enumeration.
  Future<void> requestPasswordReset({required String email});

  /// Refreshes the Firebase ID token and emits an updated
  /// [AuthSession] (same userId/operatorId/locationId, new
  /// `firebaseIdToken` + `expiresAt`). Returns null if the refresh
  /// fails (caller must trigger a sign-out flow).
  Future<AuthSession?> refreshSession(AuthSession current);

  /// Single-session sign-out: revokes this client's refresh token
  /// only. Other devices keep their sessions.
  Future<void> signOutThisSession();

  /// All-sessions sign-out: server-side revoke of every refresh
  /// token for the user. Lands fully in 9.6/9.7 once the proxy
  /// endpoint is wired; the seam is here so the UI can call it.
  Future<void> signOutAllSessions();
}

/// Default fail-closed implementation. Every call throws
/// [StateError] so a production deploy without a wired backend
/// surfaces a clear "no auth backend wired" error instead of
/// silently allowing or rejecting.
class ScaffoldFailingAuthLoginService implements AuthLoginService {
  const ScaffoldFailingAuthLoginService();

  @override
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    throw StateError(_message);
  }

  @override
  Future<AuthLoginResult> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    throw StateError(_message);
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {
    throw StateError(_message);
  }

  @override
  Future<AuthSession?> refreshSession(AuthSession current) async {
    throw StateError(_message);
  }

  @override
  Future<void> signOutThisSession() async {
    throw StateError(_message);
  }

  @override
  Future<void> signOutAllSessions() async {
    throw StateError(_message);
  }

  static const String _message =
      '9.3 scaffold: real AuthLoginService is not wired — bind '
      '`firebase_auth` (mobile) or `firebase_auth_web` (admin) in the '
      'app bootstrap before exposing the login screen.';
}
