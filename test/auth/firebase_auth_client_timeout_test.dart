import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/firebase_auth_client.dart';
import 'package:forge_and_flow/services/auth/timeout_firebase_auth_client.dart';

void main() {
  group('TimeoutFirebaseAuthClient', () {
    test('maps a hung sign-in to the existing safe network failure', () async {
      final client = TimeoutFirebaseAuthClient(
        delegate: _HangingFirebaseAuthClient(),
        timeout: const Duration(milliseconds: 10),
      );

      final outcome = await client.signInWithEmailPassword(
        email: 'admin@example.com',
        password: 'password',
      );

      expect(outcome, isA<FirebaseAuthSignInFailed>());
      final failure = outcome as FirebaseAuthSignInFailed;
      expect(failure.code, equals('network-request-failed'));
      expect(
        failure.message,
        equals('Network connection failed. Please try again.'),
      );
    });

    test(
      'maps a hung MFA completion to the existing safe network failure',
      () async {
        final client = TimeoutFirebaseAuthClient(
          delegate: _HangingFirebaseAuthClient(),
          timeout: const Duration(milliseconds: 10),
        );

        final outcome = await client.completeTotpChallenge(
          mfaSessionToken: 'mfa-1',
          factorId: 'factor-1',
          oneTimeCode: '123456',
        );

        expect(outcome, isA<FirebaseAuthSignInFailed>());
        expect(
          (outcome as FirebaseAuthSignInFailed).code,
          equals('network-request-failed'),
        );
      },
    );

    test('returns null for a hung refresh/current token read', () async {
      final client = TimeoutFirebaseAuthClient(
        delegate: _HangingFirebaseAuthClient(),
        timeout: const Duration(milliseconds: 10),
      );

      expect(await client.refreshIdToken(), isNull);
      expect(await client.currentIdToken(), isNull);
    });

    test('delegates successful token reads unchanged', () async {
      final credential = _credential();
      final client = TimeoutFirebaseAuthClient(
        delegate: _StaticFirebaseAuthClient(
          refreshCredential: credential,
          currentToken: 'token-1',
        ),
        timeout: const Duration(seconds: 1),
      );

      expect(await client.refreshIdToken(), same(credential));
      expect(await client.currentIdToken(), equals('token-1'));
    });
  });
}

FirebaseAuthCredential _credential() {
  return FirebaseAuthCredential(
    userId: 'user-1',
    idToken: 'id-token',
    idTokenIssuedAt: DateTime.utc(2026, 5, 2, 10),
    idTokenExpiresAt: DateTime.utc(2026, 5, 2, 11),
    lastFreshAuthAt: DateTime.utc(2026, 5, 2, 10),
    email: 'admin@example.com',
    customClaims: const <String, Object?>{'is_super_admin': true},
  );
}

class _HangingFirebaseAuthClient implements FirebaseAuthClient {
  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) {
    return Completer<FirebaseAuthSignInOutcome>().future;
  }

  @override
  Future<FirebaseAuthSignInOutcome> signInWithCustomToken({
    required String customToken,
  }) {
    return Completer<FirebaseAuthSignInOutcome>().future;
  }

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) {
    return Completer<FirebaseAuthSignInOutcome>().future;
  }

  @override
  Future<void> requestPasswordReset({required String email}) {
    return Completer<void>().future;
  }

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() {
    return Completer<FirebaseAuthCredential?>().future;
  }

  @override
  Future<String?> currentIdToken() {
    return Completer<String?>().future;
  }

  @override
  Future<void> signOut() {
    return Completer<void>().future;
  }

  @override
  Future<void> revokeAllRefreshTokens() {
    return Completer<void>().future;
  }
}

class _StaticFirebaseAuthClient implements FirebaseAuthClient {
  const _StaticFirebaseAuthClient({
    required this.refreshCredential,
    required this.currentToken,
  });

  final FirebaseAuthCredential? refreshCredential;
  final String? currentToken;

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    return FirebaseAuthSignInSucceeded(refreshCredential ?? _credential());
  }

  @override
  Future<FirebaseAuthSignInOutcome> signInWithCustomToken({
    required String customToken,
  }) async {
    return FirebaseAuthSignInSucceeded(refreshCredential ?? _credential());
  }

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    return FirebaseAuthSignInSucceeded(refreshCredential ?? _credential());
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() async => refreshCredential;

  @override
  Future<String?> currentIdToken() async => currentToken;

  @override
  Future<void> signOut() async {}

  @override
  Future<void> revokeAllRefreshTokens() async {}
}
