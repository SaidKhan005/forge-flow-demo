// Phase 9 live-closeout B4 - Production AuthLoginService.
//
// Translates the [FirebaseAuthClient] adapter outcomes (sign-in
// succeeded / requires MFA / failed) into the higher-level
// [AuthLoginResult] shape the rest of the app consumes. Builds the
// [AuthSession] from JWT custom claims per the Phase 9 decision lock:
//
//   * `postgres_user_id` / `user_id` — optional Postgres UUID user id. When
//     present, it wins over the Firebase UID so repository writes address
//     `public.users.user_id`.
//   * `operator_id` — required custom claim.
//   * `is_super_admin` — projected to a `super_admin` role string.
//   * `is_ff_support` — projected to an `ff_support` role string.
//   * `roles_version` — projected to `roles_version:<n>` so the proxy
//     can detect cache-stale role data.
//
// The service does NOT write `auth_sessions` ledger rows — that lives
// in [AuthSessionLedgerWriter] (B6) and is wired through the notifier
// so the auth concern (Firebase) and the persistence concern (Postgres)
// stay separate. Tokens never appear in error messages or `toString()`.

import '../../auth/auth_session.dart';
import '../auth_login_service.dart';
import 'firebase_auth_client.dart';

/// Resolves a [locationId] for the user post-sign-in. Single-location
/// operators use their primary location; multi-location operators
/// route through the operator-app location picker. The resolver
/// fetches whichever value applies.
abstract class AuthLocationResolver {
  /// Returns the location_id the user should land in immediately
  /// after sign-in. Implementations MUST return a strict 8-4-4-4-12
  /// lowercase UUID; the [TenantContext] constructor enforces the
  /// shape downstream and any malformed value would short-circuit
  /// the next operator-scoped query.
  Future<String> resolveDefaultLocationId({
    required String userId,
    required String operatorId,
  });
}

/// Resolver that returns a fixed location_id supplied at construction.
/// Used by tests + by single-location pilot deployments where the
/// proxy injects the operator's primary_location_id directly.
class FixedAuthLocationResolver implements AuthLocationResolver {
  const FixedAuthLocationResolver(this.locationId);

  final String locationId;

  @override
  Future<String> resolveDefaultLocationId({
    required String userId,
    required String operatorId,
  }) async {
    return locationId;
  }
}

/// Fail-closed location resolver for runtime wiring that expects the
/// Firebase custom claims to carry `location_id`. If the claim is absent and
/// no repository-backed resolver is wired yet, sign-in returns
/// `invalid_claims` rather than creating a session in an unknown location.
class ScaffoldFailingAuthLocationResolver implements AuthLocationResolver {
  const ScaffoldFailingAuthLocationResolver();

  @override
  Future<String> resolveDefaultLocationId({
    required String userId,
    required String operatorId,
  }) async {
    throw const FirebaseAuthLoginProjectionError(
      'JWT custom claim `location_id` is missing and no location resolver is wired',
    );
  }
}

/// Production [AuthLoginService] backed by a [FirebaseAuthClient]
/// adapter. The adapter is the only seam that ever imports the real
/// `firebase_auth` SDK; tests inject fakes.
class FirebaseAuthLoginService implements AuthLoginService {
  FirebaseAuthLoginService({
    required FirebaseAuthClient client,
    required AuthLocationResolver locationResolver,
  }) : _client = client,
       _locationResolver = locationResolver;

  final FirebaseAuthClient _client;
  final AuthLocationResolver _locationResolver;

  @override
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final FirebaseAuthSignInOutcome outcome;
    try {
      outcome = await _client.signInWithEmailPassword(
        email: email,
        password: password,
      );
    } on StateError {
      // Scaffold path is wired but the adapter has not been bound —
      // fail closed so a misconfigured deploy can't fall through.
      rethrow;
    }
    return _projectOutcome(outcome);
  }

  @override
  Future<AuthLoginResult> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    final outcome = await _client.completeTotpChallenge(
      mfaSessionToken: mfaSessionToken,
      factorId: factorId,
      oneTimeCode: oneTimeCode,
    );
    return _projectOutcome(outcome);
  }

  @override
  Future<void> requestPasswordReset({required String email}) {
    return _client.requestPasswordReset(email: email);
  }

  @override
  Future<AuthSession?> refreshSession(AuthSession current) async {
    final refreshed = await _client.refreshIdToken();
    if (refreshed == null) return null;
    return await _projectCredentialToSession(
      refreshed,
      // Refresh keeps the same operator/location context as the live
      // session — the resolver is not consulted again.
      locationOverride: current.locationId,
    );
  }

  @override
  Future<void> signOutThisSession() {
    return _client.signOut();
  }

  @override
  Future<void> signOutAllSessions() async {
    await _client.revokeAllRefreshTokens();
    await _client.signOut();
  }

  Future<AuthLoginResult> _projectOutcome(
    FirebaseAuthSignInOutcome outcome,
  ) async {
    switch (outcome) {
      case FirebaseAuthSignInSucceeded(:final credential):
        try {
          final session = await _projectCredentialToSession(credential);
          return AuthLoginSuccess(session);
        } on FirebaseAuthLoginProjectionError catch (error) {
          return AuthLoginFailure(
            code: 'invalid_claims',
            message: error.message,
          );
        }
      case FirebaseAuthSignInRequiresMfa(
        :final mfaSessionToken,
        :final factorIds,
      ):
        return AuthLoginMfaRequired(
          mfaSessionToken: mfaSessionToken,
          factorIds: factorIds,
        );
      case FirebaseAuthSignInFailed(:final code, :final message):
        return AuthLoginFailure(code: code, message: message);
    }
  }

  Future<AuthSession> _projectCredentialToSession(
    FirebaseAuthCredential credential, {
    String? locationOverride,
  }) async {
    final operatorIdClaim = credential.customClaims['operator_id'];
    if (operatorIdClaim is! String || operatorIdClaim.isEmpty) {
      throw const FirebaseAuthLoginProjectionError(
        'JWT custom claim `operator_id` is missing or not a string',
      );
    }
    final postgresUserIdClaim = credential.customClaims['postgres_user_id'];
    final userIdClaim = credential.customClaims['user_id'];
    final userId = userIdClaim is String && userIdClaim.isNotEmpty
        ? userIdClaim
        : postgresUserIdClaim is String && postgresUserIdClaim.isNotEmpty
        ? postgresUserIdClaim
        : credential.userId;
    final locationClaim = credential.customClaims['location_id'];
    final locationId =
        locationOverride ??
        (locationClaim is String && locationClaim.isNotEmpty
            ? locationClaim
            : await _locationResolver.resolveDefaultLocationId(
                userId: credential.userId,
                operatorId: operatorIdClaim,
              ));
    final roles = _extractRoles(credential.customClaims);
    final mfaEnrolled = _extractMfaEnrolled(credential.customClaims);
    return AuthSession(
      userId: userId,
      operatorId: operatorIdClaim,
      locationId: locationId,
      firebaseIdToken: credential.idToken,
      issuedAt: credential.idTokenIssuedAt,
      expiresAt: credential.idTokenExpiresAt,
      lastFreshAuthAt: credential.lastFreshAuthAt,
      roles: roles,
      mfaEnrolled: mfaEnrolled,
    );
  }

  static List<String> _extractRoles(Map<String, Object?> claims) {
    final roles = <String>[];
    if (claims['is_super_admin'] == true) roles.add('super_admin');
    if (claims['is_ff_support'] == true) roles.add('ff_support');
    final rolesVersion = claims['roles_version'];
    if (rolesVersion is int) {
      roles.add('roles_version:$rolesVersion');
    } else if (rolesVersion is String && rolesVersion.isNotEmpty) {
      roles.add('roles_version:$rolesVersion');
    }
    return List<String>.unmodifiable(roles);
  }

  static bool _extractMfaEnrolled(Map<String, Object?> claims) {
    // Firebase ID tokens carry MFA enrollment via the `firebase`
    // claim's `sign_in_second_factor` field; the adapter normalizes
    // it into a top-level `mfa_enrolled` boolean for us.
    final value = claims['mfa_enrolled'];
    return value == true;
  }
}

/// Thrown when a Firebase credential cannot be projected into an
/// [AuthSession] because the JWT custom claims are malformed. Carried
/// inside the service so the caller surfaces it as an
/// [AuthLoginFailure] (`code: 'invalid_claims'`) without leaking
/// claim values to the UI.
class FirebaseAuthLoginProjectionError implements Exception {
  const FirebaseAuthLoginProjectionError(this.message);

  final String message;

  @override
  String toString() => 'FirebaseAuthLoginProjectionError: $message';
}
