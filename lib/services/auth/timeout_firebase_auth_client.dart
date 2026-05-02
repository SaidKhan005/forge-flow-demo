// Timeout decorator for the FirebaseAuthClient seam.
//
// The concrete Firebase SDK owns persistence and network behavior. This
// wrapper keeps those details behind the auth seam while making launch and
// sign-in failure bounded for every surface that uses the shared client.

import 'dart:async';

import 'firebase_auth_client.dart';

class TimeoutFirebaseAuthClient implements FirebaseAuthClient {
  TimeoutFirebaseAuthClient({
    required FirebaseAuthClient delegate,
    Duration timeout = const Duration(seconds: 15),
  }) : _delegate = delegate,
       _timeout = timeout;

  final FirebaseAuthClient _delegate;
  final Duration _timeout;

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    try {
      return await _delegate
          .signInWithEmailPassword(email: email, password: password)
          .timeout(_timeout);
    } on TimeoutException {
      return _timeoutSignInFailure();
    }
  }

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    try {
      return await _delegate
          .completeTotpChallenge(
            mfaSessionToken: mfaSessionToken,
            factorId: factorId,
            oneTimeCode: oneTimeCode,
          )
          .timeout(_timeout);
    } on TimeoutException {
      return _timeoutSignInFailure();
    }
  }

  @override
  Future<void> requestPasswordReset({required String email}) {
    return _delegate.requestPasswordReset(email: email).timeout(_timeout);
  }

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() async {
    try {
      return await _delegate.refreshIdToken().timeout(_timeout);
    } on TimeoutException {
      return null;
    }
  }

  @override
  Future<String?> currentIdToken() async {
    try {
      return await _delegate.currentIdToken().timeout(_timeout);
    } on TimeoutException {
      return null;
    }
  }

  @override
  Future<void> signOut() {
    return _delegate.signOut().timeout(_timeout);
  }

  @override
  Future<void> revokeAllRefreshTokens() {
    return _delegate.revokeAllRefreshTokens().timeout(_timeout);
  }

  FirebaseAuthSignInFailed _timeoutSignInFailure() {
    return const FirebaseAuthSignInFailed(
      code: 'network-request-failed',
      message: 'Network connection failed. Please try again.',
    );
  }
}
