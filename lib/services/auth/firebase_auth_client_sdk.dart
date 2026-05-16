// Phase 9 live-closeout - Firebase Auth SDK adapter.
//
// This is the only runtime file allowed to import the real Firebase Auth SDK.
// The rest of the app talks to [FirebaseAuthClient].

import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;

import 'firebase_auth_client.dart';

typedef RevokeAllRefreshTokens = Future<void> Function();

/// Thin production adapter over `package:firebase_auth`.
///
/// MFA resolver objects are SDK objects, not serializable tokens, so the
/// adapter stores them in memory under short opaque handles. The handle is what
/// the existing [FirebaseAuthSignInRequiresMfa.mfaSessionToken] field carries
/// back to the UI for the next step in the same app process.
class FirebaseAuthSdkClient implements FirebaseAuthClient {
  FirebaseAuthSdkClient({
    firebase_auth.FirebaseAuth? auth,
    RevokeAllRefreshTokens? revokeAllRefreshTokens,
    String Function()? resolverHandleFactory,
  }) : _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _revokeAllRefreshTokens = revokeAllRefreshTokens,
       _resolverHandleFactory = resolverHandleFactory ?? _defaultHandle;

  final firebase_auth.FirebaseAuth _auth;
  final RevokeAllRefreshTokens? _revokeAllRefreshTokens;
  final String Function() _resolverHandleFactory;
  final Map<String, firebase_auth.MultiFactorResolver> _mfaResolvers =
      <String, firebase_auth.MultiFactorResolver>{};

  static int _handleCounter = 0;

  static String _defaultHandle() {
    _handleCounter += 1;
    return 'mfa_${DateTime.now().microsecondsSinceEpoch}_$_handleCounter';
  }

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      return FirebaseAuthSignInSucceeded(
        await _credentialFromUserCredential(credential),
      );
    } on firebase_auth.FirebaseAuthMultiFactorException catch (error) {
      return _mfaRequired(error.resolver);
    } on firebase_auth.FirebaseAuthException catch (error) {
      return FirebaseAuthSignInFailed(
        code: error.code,
        message: _messageForCode(error.code),
      );
    } catch (_) {
      return const FirebaseAuthSignInFailed(
        code: 'firebase_unavailable',
        message: 'Sign-in is unavailable. Please try again in a moment.',
      );
    }
  }

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    final resolver = _mfaResolvers[mfaSessionToken];
    if (resolver == null) {
      return const FirebaseAuthSignInFailed(
        code: 'mfa_session_expired',
        message: 'The verification session expired. Please sign in again.',
      );
    }
    try {
      final assertion =
          await firebase_auth.TotpMultiFactorGenerator.getAssertionForSignIn(
            factorId,
            oneTimeCode,
          );
      final credential = await resolver.resolveSignIn(assertion);
      _mfaResolvers.remove(mfaSessionToken);
      return FirebaseAuthSignInSucceeded(
        await _credentialFromUserCredential(credential),
      );
    } on firebase_auth.FirebaseAuthException catch (error) {
      return FirebaseAuthSignInFailed(
        code: error.code,
        message: _messageForCode(error.code),
      );
    } catch (_) {
      return const FirebaseAuthSignInFailed(
        code: 'mfa_unavailable',
        message: 'Verification is unavailable. Please try again in a moment.',
      );
    }
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } on firebase_auth.FirebaseAuthException catch (error) {
      if (error.code == 'user-not-found' || error.code == 'invalid-email') {
        return;
      }
      rethrow;
    }
  }

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    try {
      return await _credentialFromUser(user, forceRefresh: true);
    } on firebase_auth.FirebaseAuthException {
      return null;
    }
  }

  @override
  Future<String?> currentIdToken() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    try {
      // Use cached token; Firebase auto-refreshes when it nears
      // expiry, so the call stays cheap on the hot path. Callers
      // that need a forced refresh use [refreshIdToken] instead.
      return await user.getIdToken();
    } on firebase_auth.FirebaseAuthException {
      return null;
    }
  }

  @override
  Future<void> signOut() {
    _mfaResolvers.clear();
    return _auth.signOut();
  }

  @override
  Future<void> revokeAllRefreshTokens() {
    final revoke = _revokeAllRefreshTokens;
    if (revoke == null) {
      throw StateError(
        'revokeAllRefreshTokens requires the proxy admin endpoint binding',
      );
    }
    return revoke();
  }

  FirebaseAuthSignInRequiresMfa _mfaRequired(
    firebase_auth.MultiFactorResolver resolver,
  ) {
    final handle = _resolverHandleFactory();
    _mfaResolvers[handle] = resolver;
    return FirebaseAuthSignInRequiresMfa(
      mfaSessionToken: handle,
      factorIds: List<String>.unmodifiable(
        resolver.hints.whereType<firebase_auth.TotpMultiFactorInfo>().map(
          (hint) => hint.uid,
        ),
      ),
    );
  }

  Future<FirebaseAuthCredential> _credentialFromUserCredential(
    firebase_auth.UserCredential credential,
  ) async {
    final user = credential.user;
    if (user == null) {
      throw StateError('Firebase sign-in returned no user');
    }
    return _credentialFromUser(user, forceRefresh: true);
  }

  Future<FirebaseAuthCredential> _credentialFromUser(
    firebase_auth.User user, {
    bool forceRefresh = false,
  }) async {
    final tokenResult = await user.getIdTokenResult(forceRefresh);
    final token = tokenResult.token ?? await user.getIdToken(forceRefresh);
    if (token == null || token.isEmpty) {
      throw StateError('Firebase returned no ID token');
    }
    final claims = Map<String, Object?>.from(tokenResult.claims ?? const {});
    claims['mfa_enrolled'] = tokenResult.signInSecondFactor != null;
    return FirebaseAuthCredential(
      userId: user.uid,
      idToken: token,
      idTokenIssuedAt:
          tokenResult.issuedAtTime?.toUtc() ?? DateTime.now().toUtc(),
      idTokenExpiresAt:
          tokenResult.expirationTime?.toUtc() ??
          DateTime.now().toUtc().add(const Duration(hours: 1)),
      lastFreshAuthAt: tokenResult.authTime?.toUtc() ?? DateTime.now().toUtc(),
      email: user.email,
      displayName: user.displayName,
      customClaims: claims,
    );
  }

  static String _messageForCode(String code) {
    switch (code) {
      case 'invalid-credential':
      case 'invalid-email':
      case 'user-not-found':
      case 'wrong-password':
        return 'Email or password is incorrect.';
      case 'user-disabled':
        return 'This account is disabled. Contact your manager.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'network-request-failed':
        return 'Network connection failed. Please try again.';
      default:
        return 'Sign-in failed. Please try again.';
    }
  }
}
