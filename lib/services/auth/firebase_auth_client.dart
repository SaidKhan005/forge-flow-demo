// Phase 9 live-closeout B4 - FirebaseAuthClient adapter seam.
//
// `FirebaseAuthLoginService` (the production implementation of
// `AuthLoginService`) talks to Firebase Identity Platform through this
// adapter rather than importing `firebase_auth` directly. That keeps
// the production wiring fully unit-testable and lets us defer pulling
// `firebase_auth` into pubspec until the iOS Xcode + Android Gradle
// runtime wiring (B7) lands.
//
// Hard rules:
//
//   * No file outside `lib/services/auth/firebase_auth_client_*.dart`
//     may import the real `package:firebase_auth/firebase_auth.dart`.
//     Everything else routes through this seam.
//   * The default binding is [ScaffoldFailingFirebaseAuthClient] so a
//     misconfigured deploy that wires `FirebaseAuthLoginService` but
//     forgets the real adapter surfaces a "no Firebase backend wired"
//     error rather than silently allowing.
//   * Tokens never appear in `toString()`, debug prints, or error
//     messages emitted from this layer.

/// Outcome of a Firebase email/password sign-in attempt at the
/// adapter layer. The production `AuthLoginService` translates these
/// into the higher-level `AuthLoginResult` shape the UI consumes.
sealed class FirebaseAuthSignInOutcome {
  const FirebaseAuthSignInOutcome();
}

/// Sign-in succeeded outright (no MFA challenge).
class FirebaseAuthSignInSucceeded extends FirebaseAuthSignInOutcome {
  const FirebaseAuthSignInSucceeded(this.credential);

  final FirebaseAuthCredential credential;
}

/// Firebase requires the user to complete an MFA factor challenge
/// before issuing the ID token. The resolver token + factor list is
/// what the UI passes back to [FirebaseAuthClient.completeTotpChallenge].
class FirebaseAuthSignInRequiresMfa extends FirebaseAuthSignInOutcome {
  const FirebaseAuthSignInRequiresMfa({
    required this.mfaSessionToken,
    required this.factorIds,
  });

  final String mfaSessionToken;
  final List<String> factorIds;
}

/// Sign-in failed at the Firebase layer (bad credentials, suspended
/// account, network error). [code] is the stable machine-readable
/// code the UI maps to localized copy; [message] is human-readable
/// detail. Neither echoes the password or any token contents.
class FirebaseAuthSignInFailed extends FirebaseAuthSignInOutcome {
  const FirebaseAuthSignInFailed({required this.code, required this.message});

  final String code;
  final String message;
}

/// Verified credential returned by Firebase after a successful sign-in
/// (or successful MFA completion). The production `AuthLoginService`
/// projects these fields into an `AuthSession`.
class FirebaseAuthCredential {
  const FirebaseAuthCredential({
    required this.userId,
    required this.idToken,
    required this.idTokenIssuedAt,
    required this.idTokenExpiresAt,
    required this.lastFreshAuthAt,
    this.email,
    this.displayName,
    this.customClaims = const <String, Object?>{},
  });

  /// `users.user_id` (mapped from Firebase `uid` via the per-tenant
  /// JWT custom claim or the `users.firebase_uid` lookup).
  final String userId;

  /// Verified Firebase ID token. Carried in the AuthSession so the
  /// proxy can re-verify on each request without forcing another
  /// Firebase round-trip. NEVER printed by this layer.
  final String idToken;

  /// JWT `iat`. Drives diagnostic/issued-at metadata; not used for
  /// security decisions on its own.
  final DateTime idTokenIssuedAt;

  /// JWT `exp`. Used by the AuthSession to check liveness locally.
  final DateTime idTokenExpiresAt;

  /// JWT `auth_time`. Drives the 5-minute step-up freshness gate
  /// for sensitive operations (locked decision: 5 minutes).
  final DateTime lastFreshAuthAt;

  /// Email returned by Firebase when available. Admin console session
  /// projection uses this for display, while operator sessions continue
  /// to source tenant identity from custom claims.
  final String? email;

  /// Display name returned by Firebase when available.
  final String? displayName;

  /// Decoded JWT custom claims. The production `AuthLoginService`
  /// reads `operator_id`, `is_super_admin`, `is_ff_support`, and
  /// `roles_version` from this map per the Phase 9 decision lock
  /// (claims kept tiny; Postgres is source of truth for the rest).
  final Map<String, Object?> customClaims;
}

/// What the production `AuthLoginService` needs from a Firebase Auth
/// SDK. Production wires a thin adapter around
/// `firebase_auth.FirebaseAuth.instance` (mobile) or
/// `firebase_auth_web` (admin web console). Tests inject fakes that
/// return canned outcomes so the higher-level result mapping can be
/// asserted without a live Firebase project.
abstract class FirebaseAuthClient {
  /// Attempts an email/password sign-in. Returns one of the three
  /// [FirebaseAuthSignInOutcome] subclasses.
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  });

  /// Completes a TOTP MFA challenge initiated by a previous
  /// [FirebaseAuthSignInRequiresMfa] outcome.
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  });

  /// Sends the standard branded password-reset action link to [email].
  /// Implementations MUST swallow account-existence errors so the UI
  /// can surface a generic "if the email is registered..." message
  /// regardless of whether the email exists.
  Future<void> requestPasswordReset({required String email});

  /// Refreshes the current user's ID token. Returns null when the
  /// user is signed out or the refresh fails (caller should trigger
  /// a sign-out flow on null).
  Future<FirebaseAuthCredential?> refreshIdToken();

  /// Returns the live (cached) ID token for the current user, or null
  /// when the user is signed out or no token is available.
  ///
  /// This is the input the proxy session-ledger writer presents in
  /// the `Authorization: Bearer …` header so the proxy can verify
  /// the caller before recording an `auth_sessions` row. The SDK
  /// adapter SHOULD return the cached token (Firebase auto-refreshes
  /// when it nears expiry) so the call is cheap; the dedicated
  /// [refreshIdToken] path forces a refresh when needed.
  ///
  /// MUST NOT echo the token through `toString()` or any debug print
  /// path; only the proxy header consumer sees the value.
  Future<String?> currentIdToken();

  /// Signs out the current device only — revokes this client's
  /// refresh token. Other devices keep their sessions.
  Future<void> signOut();

  /// Server-side revoke of every refresh token for the current user.
  /// Production binds this to `firebase_admin.auth().revokeRefreshTokens(uid)`
  /// via a proxy admin endpoint (B17/B19); the SDK's own client-side
  /// `signOut` is not enough because it only affects this device.
  Future<void> revokeAllRefreshTokens();
}

/// Hard-fail-closed default. Every method throws so a production
/// deploy that wired [FirebaseAuthLoginService] but forgot the real
/// SDK adapter surfaces a clear "no Firebase backend wired" error
/// rather than silently rejecting (or worse, silently allowing).
class ScaffoldFailingFirebaseAuthClient implements FirebaseAuthClient {
  const ScaffoldFailingFirebaseAuthClient();

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    throw StateError(_message);
  }

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
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
  Future<FirebaseAuthCredential?> refreshIdToken() async {
    throw StateError(_message);
  }

  @override
  Future<String?> currentIdToken() async {
    throw StateError(_message);
  }

  @override
  Future<void> signOut() async {
    throw StateError(_message);
  }

  @override
  Future<void> revokeAllRefreshTokens() async {
    throw StateError(_message);
  }

  static const String _message =
      'B4 scaffold: real FirebaseAuthClient is not wired — bind the '
      '`firebase_auth` (mobile) or `firebase_auth_web` (admin) adapter '
      'in the app bootstrap before exposing the login screen.';
}
