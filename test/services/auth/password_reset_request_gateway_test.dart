// Phase 9.UX.7 - RepositoryPasswordResetRequestGateway tests.
//
// Focuses on the privacy-preserving contract: both unknown- and
// known-email branches always call Firebase, swallow EMAIL_NOT_FOUND,
// audit only when the lookup matched, and pad to a constant-time
// latency floor so a client cannot distinguish presence by timing.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/auth/password_reset_request_gateway.dart';

void main() {
  group('RepositoryPasswordResetRequestGateway', () {
    test('always calls Firebase, even when the email is unknown', () async {
      final firebase = _RecordingFirebaseAdminAuthClient();
      final gateway = RepositoryPasswordResetRequestGateway.fromDependencies(
        firebaseAdmin: firebase,
        lookup: (_) async => null,
        auditWriter: (_) async => fail('audit must not run for unknown email'),
        sleep: (_) async {},
        stopwatchFactory: () => Stopwatch(),
      );

      await gateway.requestReset(
        const PasswordResetRequestCommand(email: 'unknown@example.test'),
      );

      expect(firebase.sentEmails, equals(<String>['unknown@example.test']));
    });

    test('audits only on known-email match', () async {
      final firebase = _RecordingFirebaseAdminAuthClient();
      final auditedFor = <String>[];
      final gateway = RepositoryPasswordResetRequestGateway.fromDependencies(
        firebaseAdmin: firebase,
        lookup: (_) async => const UserAuthLookupRow(
          userId: 'u-1',
          operatorId: 'op-1',
          locationId: 'loc-1',
          email: 'known@forgeflow.test',
        ),
        auditWriter: (user) async => auditedFor.add(user.userId),
        sleep: (_) async {},
        stopwatchFactory: () => Stopwatch(),
      );

      await gateway.requestReset(
        const PasswordResetRequestCommand(email: 'known@forgeflow.test'),
      );

      expect(firebase.sentEmails, equals(<String>['known@forgeflow.test']));
      expect(auditedFor, equals(<String>['u-1']));
    });

    test(
      'swallows EMAIL_NOT_FOUND from Firebase so the response stays uniform',
      () async {
        final firebase = _RecordingFirebaseAdminAuthClient(
          throwOnSend: () => const FirebaseAdminAuthError(
            'EMAIL_NOT_FOUND',
            statusCode: 404,
          ),
        );
        final gateway = RepositoryPasswordResetRequestGateway.fromDependencies(
          firebaseAdmin: firebase,
          // Lookup returns a non-null user but Firebase still answers
          // EMAIL_NOT_FOUND (e.g., user was deleted in Firebase but
          // local row still active). Should not raise.
          lookup: (_) async => const UserAuthLookupRow(
            userId: 'u-1',
            operatorId: 'op-1',
            locationId: 'loc-1',
            email: 'stale@forgeflow.test',
          ),
          auditWriter: (_) async {},
          sleep: (_) async {},
          stopwatchFactory: () => Stopwatch(),
        );

        await expectLater(
          gateway.requestReset(
            const PasswordResetRequestCommand(email: 'stale@forgeflow.test'),
          ),
          completes,
        );
      },
    );

    test('maps Firebase rate-limit error to PasswordResetRequestThrottled',
        () async {
      final firebase = _RecordingFirebaseAdminAuthClient(
        throwOnSend: () => const FirebaseAdminAuthError(
          'TOO_MANY_ATTEMPTS_TRY_LATER',
        ),
      );
      final gateway = RepositoryPasswordResetRequestGateway.fromDependencies(
        firebaseAdmin: firebase,
        lookup: (_) async => null,
        auditWriter: (_) async {},
        sleep: (_) async {},
        stopwatchFactory: () => Stopwatch(),
      );

      await expectLater(
        gateway.requestReset(
          const PasswordResetRequestCommand(email: 'rate@forgeflow.test'),
        ),
        throwsA(isA<PasswordResetRequestThrottled>()),
      );
    });

    test(
      'propagates lookup errors so the route returns 503 rather than '
      'sending unaudited Firebase emails',
      () async {
        final firebase = _RecordingFirebaseAdminAuthClient();
        final gateway = RepositoryPasswordResetRequestGateway.fromDependencies(
          firebaseAdmin: firebase,
          lookup: (_) async => throw Exception('postgres blip'),
          auditWriter: (_) async =>
              fail('audit must not run when lookup blew'),
          sleep: (_) async {},
          stopwatchFactory: () => Stopwatch(),
        );

        await expectLater(
          gateway.requestReset(
            const PasswordResetRequestCommand(email: 'blip@forgeflow.test'),
          ),
          throwsA(isA<Exception>()),
        );
        // Crucially: Firebase did NOT run. A transient Postgres
        // outage cannot send a reset email to a real account
        // without the corresponding audit row.
        expect(firebase.sentEmails, isEmpty);
      },
    );

    test(
      'pads short-running paths to the latency floor so wall-clock latency '
      'does not leak presence',
      () async {
        final firebase = _RecordingFirebaseAdminAuthClient();
        final sleeps = <Duration>[];
        final stopwatch = _FakeStopwatch(elapsed: const Duration(milliseconds: 50));
        final gateway = RepositoryPasswordResetRequestGateway.fromDependencies(
          firebaseAdmin: firebase,
          lookup: (_) async => null,
          auditWriter: (_) async {},
          latencyFloor: const Duration(milliseconds: 350),
          sleep: (d) async => sleeps.add(d),
          stopwatchFactory: () => stopwatch,
        );

        await gateway.requestReset(
          const PasswordResetRequestCommand(email: 'fast@forgeflow.test'),
        );

        expect(sleeps, equals(<Duration>[const Duration(milliseconds: 300)]));
      },
    );

    test('does not extend latency past the floor on slow paths', () async {
      final firebase = _RecordingFirebaseAdminAuthClient();
      final sleeps = <Duration>[];
      final stopwatch = _FakeStopwatch(elapsed: const Duration(seconds: 2));
      final gateway = RepositoryPasswordResetRequestGateway.fromDependencies(
        firebaseAdmin: firebase,
        lookup: (_) async => const UserAuthLookupRow(
          userId: 'u-1',
          operatorId: 'op-1',
          locationId: 'loc-1',
          email: 'slow@forgeflow.test',
        ),
        auditWriter: (_) async {},
        latencyFloor: const Duration(milliseconds: 350),
        sleep: (d) async => sleeps.add(d),
        stopwatchFactory: () => stopwatch,
      );

      await gateway.requestReset(
        const PasswordResetRequestCommand(email: 'slow@forgeflow.test'),
      );

      // Already past the floor — no extra padding sleep.
      expect(sleeps, isEmpty);
    });

    test('still pads when the throttle path rethrows', () async {
      final firebase = _RecordingFirebaseAdminAuthClient(
        throwOnSend: () => const FirebaseAdminAuthError(
          'TOO_MANY_ATTEMPTS_TRY_LATER',
        ),
      );
      final sleeps = <Duration>[];
      final stopwatch = _FakeStopwatch(elapsed: const Duration(milliseconds: 50));
      final gateway = RepositoryPasswordResetRequestGateway.fromDependencies(
        firebaseAdmin: firebase,
        lookup: (_) async => null,
        auditWriter: (_) async {},
        latencyFloor: const Duration(milliseconds: 350),
        sleep: (d) async => sleeps.add(d),
        stopwatchFactory: () => stopwatch,
      );

      await expectLater(
        gateway.requestReset(
          const PasswordResetRequestCommand(email: 'rate@forgeflow.test'),
        ),
        throwsA(isA<PasswordResetRequestThrottled>()),
      );
      expect(sleeps, equals(<Duration>[const Duration(milliseconds: 300)]));
    });
  });
}

class _RecordingFirebaseAdminAuthClient implements FirebaseAdminAuthClient {
  _RecordingFirebaseAdminAuthClient({this.throwOnSend});

  final FirebaseAdminAuthError Function()? throwOnSend;
  final sentEmails = <String>[];

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    String? continueUrl,
  }) async {
    sentEmails.add(email);
    if (throwOnSend != null) {
      throw throwOnSend!();
    }
  }

  @override
  Future<void> createUser({
    required String uid,
    required String email,
    required Map<String, Object?> customClaims,
  }) async => throw UnimplementedError();

  @override
  Future<void> setCustomClaims({
    required String uid,
    required Map<String, Object?> customClaims,
  }) async => throw UnimplementedError();

  @override
  Future<void> setDisabled({required String uid, required bool disabled}) async =>
      throw UnimplementedError();

  @override
  Future<FirebasePasswordResetCodeInfo> verifyPasswordResetCode({
    required String oobCode,
  }) async => throw UnimplementedError();

  @override
  Future<void> confirmPasswordReset({
    required String oobCode,
    required String newPassword,
  }) async => throw UnimplementedError();

  @override
  Future<bool> verifyPassword({
    required String email,
    required String password,
    required String expectedUid,
  }) async => throw UnimplementedError();

  @override
  Future<void> updatePassword({
    required String uid,
    required String password,
  }) async => throw UnimplementedError();

  @override
  Future<void> revokeRefreshTokens({required String uid}) async =>
      throw UnimplementedError();

  @override
  Future<void> clearMfaEnrollments({required String uid}) async =>
      throw UnimplementedError();
}

/// Test stopwatch that returns a pinned [elapsed]. Implements the
/// surface the gateway uses; other Stopwatch members are inert.
class _FakeStopwatch implements Stopwatch {
  _FakeStopwatch({required this.elapsed});

  @override
  final Duration elapsed;

  @override
  void start() {}
  @override
  void stop() {}
  @override
  void reset() {}
  @override
  bool get isRunning => false;
  @override
  int get elapsedMicroseconds => elapsed.inMicroseconds;
  @override
  int get elapsedMilliseconds => elapsed.inMilliseconds;
  @override
  int get elapsedTicks => elapsed.inMicroseconds;
  @override
  int get frequency => 1000000;
}
