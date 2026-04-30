// Phase 9.4 - MFA policy + recovery code generator + hasher +
// removal flow + challenge screen tests.
//
// Runs entirely against fakes / pure logic. No Firebase SDK, no
// network, no DB. Production wiring of `firebase_auth` MFA APIs +
// the proxy-side `mfa_factors` persistence is the focused
// follow-up parallel to the 9.3 / 9.2 / 9.1 wiring gaps.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/auth/mfa_policy.dart';
import 'package:forge_and_flow/screens/auth/mfa_challenge_screen.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_removal_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_gateway.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_generator.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_hasher.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';

void main() {
  group('OperatorSubscriptionTier', () {
    test('fromKey is case-insensitive and returns null for unknowns', () {
      expect(
        OperatorSubscriptionTier.fromKey('Premium'),
        equals(OperatorSubscriptionTier.premium),
      );
      expect(
        OperatorSubscriptionTier.fromKey('  PRO '),
        equals(OperatorSubscriptionTier.pro),
      );
      expect(OperatorSubscriptionTier.fromKey('mystery'), isNull);
      expect(OperatorSubscriptionTier.fromKey(null), isNull);
    });

    test('requiresStaffMfa is false for every tier', () {
      expect(OperatorSubscriptionTier.pilot.requiresStaffMfa, isFalse);
      expect(OperatorSubscriptionTier.starter.requiresStaffMfa, isFalse);
      expect(OperatorSubscriptionTier.premium.requiresStaffMfa, isFalse);
      expect(OperatorSubscriptionTier.pro.requiresStaffMfa, isFalse);
      expect(OperatorSubscriptionTier.enterprise.requiresStaffMfa, isFalse);
    });
  });

  group('MfaPolicy.evaluate (launch enforcement deferred 2026-04-30)', () {
    test('admin tier is optional at launch, regardless of operator tier', () {
      for (final tier in OperatorSubscriptionTier.values) {
        for (final role in const <String>[
          'super_admin',
          'ff_support',
          'operator_owner',
          'operator_manager',
        ]) {
          expect(
            MfaPolicy.evaluate(
              authRoles: <String>[role],
              subscriptionTier: tier,
              mfaEnrolled: false,
            ),
            equals(MfaRequirement.optional),
            reason: '$role @ $tier (not enrolled) is optional at launch',
          );
          expect(
            MfaPolicy.evaluate(
              authRoles: <String>[role],
              subscriptionTier: tier,
              mfaEnrolled: true,
            ),
            equals(MfaRequirement.optional),
            reason: '$role @ $tier (enrolled) is still not forced',
          );
        }
      }
    });

    test('staff MFA is optional at every subscription tier', () {
      for (final tier in OperatorSubscriptionTier.values) {
        for (final role in const <String>[
          'operator_supervisor',
          'operator_staff',
        ]) {
          expect(
            MfaPolicy.evaluate(
              authRoles: <String>[role],
              subscriptionTier: tier,
              mfaEnrolled: false,
            ),
            equals(MfaRequirement.optional),
          );
        }
      }
    });

    test('mixed roles stay optional until post-launch enforcement', () {
      expect(
        MfaPolicy.evaluate(
          authRoles: const <String>['operator_staff', 'operator_owner'],
          subscriptionTier: OperatorSubscriptionTier.pilot,
          mfaEnrolled: false,
        ),
        equals(MfaRequirement.optional),
      );
    });

    test('null subscriptionTier defaults to optional for staff', () {
      // The proxy normally resolves the tier before evaluating; a null tier
      // means "we could not look it up." Launch policy stays optional.
      expect(
        MfaPolicy.evaluate(
          authRoles: const <String>['operator_staff'],
          subscriptionTier: null,
          mfaEnrolled: false,
        ),
        equals(MfaRequirement.optional),
      );
      expect(
        MfaPolicy.evaluate(
          authRoles: const <String>['super_admin'],
          subscriptionTier: null,
          mfaEnrolled: false,
        ),
        equals(MfaRequirement.optional),
      );
    });

    test('case-insensitive admin roles still do not force launch MFA', () {
      expect(
        MfaPolicy.evaluate(
          authRoles: const <String>['SUPER_ADMIN'],
          subscriptionTier: OperatorSubscriptionTier.pilot,
          mfaEnrolled: false,
        ),
        equals(MfaRequirement.optional),
      );
    });
  });

  group('RecoveryCodeGenerator', () {
    test('generates 10 codes by default with the XXXX-XXXX-XXXX shape', () {
      final gen = RecoveryCodeGenerator(random: _DeterministicRandom(42));
      final codes = gen.generate();
      expect(codes, hasLength(10));
      for (final code in codes) {
        expect(
          RegExp(
            r'^[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$',
          ).hasMatch(code),
          isTrue,
          reason: 'unexpected code shape: $code',
        );
      }
    });

    test('codes are unique within a single generation batch (high prob)', () {
      // Even with a low-entropy deterministic random, 10 distinct
      // 12-char draws from a 27-char alphabet are essentially never
      // duplicates. The test guards against an impl that accidentally
      // re-uses RNG state.
      final gen = RecoveryCodeGenerator(random: _DeterministicRandom(7));
      final codes = gen.generate();
      expect(codes.toSet(), hasLength(codes.length));
    });

    test('rejects non-positive count / groupCount / groupLength', () {
      final gen = RecoveryCodeGenerator(random: _DeterministicRandom(1));
      expect(() => gen.generate(count: 0), throwsArgumentError);
      expect(() => gen.generate(groupCount: 0), throwsArgumentError);
      expect(() => gen.generate(groupLength: 0), throwsArgumentError);
    });

    test('normalize strips dashes / whitespace and uppercases', () {
      expect(
        RecoveryCodeGenerator.normalize('abcd-efgh-jkmn'),
        equals('ABCDEFGHJKMN'),
      );
      expect(
        RecoveryCodeGenerator.normalize('  ABCD\tEFGH JKMN  '),
        equals('ABCDEFGHJKMN'),
      );
    });

    test('normalize returns null for out-of-alphabet characters', () {
      // `0`, `O`, `1`, `I`, `L` are intentionally excluded.
      expect(RecoveryCodeGenerator.normalize('0000-0000-0000'), isNull);
      expect(RecoveryCodeGenerator.normalize('OOOO-IIII-LLLL'), isNull);
      expect(RecoveryCodeGenerator.normalize('ABCD!EFGH'), isNull);
      expect(RecoveryCodeGenerator.normalize(''), isNull);
    });
  });

  group('Sha256RecoveryCodeHasher', () {
    test('hash + verify roundtrip with same salt + code returns true', () {
      const hasher = Sha256RecoveryCodeHasher();
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));
      final stored = hasher.hash(
        normalizedCode: 'ABCDEFGHJKMN',
        saltBytes: salt,
      );
      expect(
        hasher.verify(normalizedCode: 'ABCDEFGHJKMN', stored: stored),
        isTrue,
      );
    });

    test('verify returns false for a different code', () {
      const hasher = Sha256RecoveryCodeHasher();
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
      final stored = hasher.hash(
        normalizedCode: 'ABCDEFGHJKMN',
        saltBytes: salt,
      );
      expect(
        hasher.verify(normalizedCode: 'ABCDEFGHJKMP', stored: stored),
        isFalse,
      );
    });

    test('different salts produce different hashes for the same code', () {
      const hasher = Sha256RecoveryCodeHasher();
      final saltA = Uint8List.fromList(List<int>.generate(16, (i) => i));
      final saltB = Uint8List.fromList(List<int>.generate(16, (i) => i + 100));
      final hashA = hasher.hash(normalizedCode: 'ABCD', saltBytes: saltA);
      final hashB = hasher.hash(normalizedCode: 'ABCD', saltBytes: saltB);
      expect(hashA.hashBase64, isNot(equals(hashB.hashBase64)));
      expect(hashA.saltBase64, isNot(equals(hashB.saltBase64)));
    });

    test('verify tolerates a bad-base64 stored payload by returning false', () {
      const hasher = Sha256RecoveryCodeHasher();
      const stored = HashedRecoveryCode(
        saltBase64: '!!!notbase64!!!',
        hashBase64: '!!!notbase64!!!',
      );
      expect(hasher.verify(normalizedCode: 'ABCD', stored: stored), isFalse);
    });

    test('HashedRecoveryCode toJson + fromJson round-trip', () {
      const original = HashedRecoveryCode(
        saltBase64: 'AAECAwQFBgcICQoLDA0ODw==',
        hashBase64: 'YWJj',
      );
      final round = HashedRecoveryCode.fromJson(original.toJson());
      expect(round.saltBase64, equals(original.saltBase64));
      expect(round.hashBase64, equals(original.hashBase64));
    });
  });

  group('ScaffoldFailingRecoveryCodeHasher', () {
    test('throws StateError on hash + verify so production fails closed', () {
      const hasher = ScaffoldFailingRecoveryCodeHasher();
      expect(
        () => hasher.hash(normalizedCode: 'ABCD', saltBytes: Uint8List(0)),
        throwsStateError,
      );
      expect(
        () => hasher.verify(
          normalizedCode: 'ABCD',
          stored: const HashedRecoveryCode(saltBase64: '', hashBase64: ''),
        ),
        throwsStateError,
      );
    });
  });

  group('ScaffoldFailingMfaEnrollmentService', () {
    test('throws StateError on every entry point', () async {
      const svc = ScaffoldFailingMfaEnrollmentService();
      await expectLater(
        svc.beginTotpEnrollment(
          userId: 'u',
          userEmail: 'a@b.c',
          issuerName: 'F&F',
        ),
        throwsStateError,
      );
      await expectLater(
        svc.confirmTotpEnrollment(factorId: 'f', oneTimeCode: '123456'),
        throwsStateError,
      );
    });
  });

  group('MfaRemovalService (24-hour delay)', () {
    test('requestRemoval sets executeAfter = now + 24h by default', () {
      final clock = DateTime.utc(2026, 4, 26, 12);
      final svc = MfaRemovalService(
        delay: MfaRemovalService.defaultDelay,
        now: () => clock,
      );
      final req = svc.requestRemoval(
        requestId: 'req-1',
        userId: 'u',
        factorId: 'totp',
        stepUpProofId: 'audit-1',
      );
      expect(req.requestedAt, equals(clock));
      expect(req.executeAfter, equals(clock.add(const Duration(hours: 24))));
      expect(req.isPending, isTrue);
      expect(req.isCompleted, isFalse);
      expect(req.isCancelled, isFalse);
    });

    test('requestRemoval rejects blank step-up proof', () {
      final svc = MfaRemovalService(delay: const Duration(hours: 24));
      expect(
        () => svc.requestRemoval(
          requestId: 'r',
          userId: 'u',
          factorId: 'f',
          stepUpProofId: '   ',
        ),
        throwsArgumentError,
      );
    });

    test('executeRemoval returns NotYetExecutable inside the 24h window', () {
      var clock = DateTime.utc(2026, 4, 26, 12);
      final svc = MfaRemovalService(
        delay: const Duration(hours: 24),
        now: () => clock,
      );
      final req = svc.requestRemoval(
        requestId: 'req-1',
        userId: 'u',
        factorId: 'totp',
        stepUpProofId: 'audit-1',
      );
      // Advance 23h; still inside the window.
      clock = clock.add(const Duration(hours: 23));
      final result = svc.executeRemoval(req);
      expect(result, isA<MfaRemovalNotYetExecutable>());
      expect(req.isPending, isTrue);
    });

    test('executeRemoval completes once the 24h window elapses', () {
      var clock = DateTime.utc(2026, 4, 26, 12);
      final svc = MfaRemovalService(
        delay: const Duration(hours: 24),
        now: () => clock,
      );
      final req = svc.requestRemoval(
        requestId: 'req-1',
        userId: 'u',
        factorId: 'totp',
        stepUpProofId: 'audit-1',
      );
      clock = clock.add(const Duration(hours: 24, seconds: 1));
      final result = svc.executeRemoval(req);
      expect(result, isA<MfaRemovalCompleted>());
      expect(req.isCompleted, isTrue);
      expect(req.completedAt, equals(clock));
    });

    test('cancelRemoval flips state and blocks subsequent execute', () {
      var clock = DateTime.utc(2026, 4, 26, 12);
      final svc = MfaRemovalService(
        delay: const Duration(hours: 24),
        now: () => clock,
      );
      final req = svc.requestRemoval(
        requestId: 'r',
        userId: 'u',
        factorId: 'totp',
        stepUpProofId: 'audit-1',
      );
      expect(svc.cancelRemoval(req), isTrue);
      expect(req.isCancelled, isTrue);

      clock = clock.add(const Duration(hours: 25));
      final result = svc.executeRemoval(req);
      expect(result, isA<MfaRemovalAlreadyFinalized>());
    });

    test('cancelRemoval on a completed request returns false', () {
      var clock = DateTime.utc(2026, 4, 26, 12);
      final svc = MfaRemovalService(
        delay: const Duration(hours: 24),
        now: () => clock,
      );
      final req = svc.requestRemoval(
        requestId: 'r',
        userId: 'u',
        factorId: 'totp',
        stepUpProofId: 'audit-1',
      );
      clock = clock.add(const Duration(hours: 25));
      svc.executeRemoval(req);
      expect(svc.cancelRemoval(req), isFalse);
    });
  });

  group('MfaChallengeScreen widget', () {
    Widget wrap(
      AuthSessionNotifier notifier, {
      MfaRecoveryRequestGateway? recoveryRequestGateway,
    }) {
      return MaterialApp(
        home: ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: MfaChallengeScreen(
            recoveryRequestGateway: recoveryRequestGateway,
          ),
        ),
      );
    }

    AuthSession buildSession() {
      final now = DateTime.utc(2026, 4, 26, 12);
      return AuthSession(
        userId: 'u',
        operatorId: 'o',
        locationId: 'l',
        firebaseIdToken: 't',
        issuedAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
        lastFreshAuthAt: now,
        roles: const <String>['operator_owner'],
        mfaEnrolled: true,
      );
    }

    testWidgets('renders email + "Two-factor verification" title', (
      tester,
    ) async {
      final service = _FakeMfaService();
      final notifier = AuthSessionNotifier(
        loginService: service,
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetState(
        const AuthSessionMfaChallenge(
          email: 'mfa@example.test',
          mfaSessionToken: 'tok',
          factorIds: <String>['totp-1'],
        ),
      );
      await tester.pumpWidget(wrap(notifier));
      await tester.pumpAndSettle();
      expect(find.text('Two-factor verification'), findsOneWidget);
      expect(find.text('mfa@example.test'), findsOneWidget);
      expect(find.byKey(const Key('mfa_recovery_toggle')), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const Key('mfa_code_field'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('mfa_trailing_actions'))).dy,
        ),
      );
    });

    testWidgets('submit with empty code shows local error', (tester) async {
      final service = _FakeMfaService();
      final notifier = AuthSessionNotifier(
        loginService: service,
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetState(
        const AuthSessionMfaChallenge(
          email: 'mfa@example.test',
          mfaSessionToken: 'tok',
          factorIds: <String>['totp-1'],
        ),
      );
      await tester.pumpWidget(wrap(notifier));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('mfa_submit_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mfa_error_banner')), findsOneWidget);
      expect(service.totpCalls, equals(0));
    });

    testWidgets('happy submit with TOTP code transitions to authenticated', (
      tester,
    ) async {
      final service = _FakeMfaService(
        totpResult: AuthLoginSuccess(buildSession()),
      );
      final notifier = AuthSessionNotifier(
        loginService: service,
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetState(
        const AuthSessionMfaChallenge(
          email: 'mfa@example.test',
          mfaSessionToken: 'tok',
          factorIds: <String>['totp-1'],
        ),
      );
      await tester.pumpWidget(wrap(notifier));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('mfa_code_field')), '123456');
      await tester.tap(find.byKey(const Key('mfa_submit_button')));
      await tester.pumpAndSettle();

      expect(service.totpCalls, equals(1));
      expect(service.lastFactorId, equals('totp-1'));
      expect(service.lastOneTimeCode, equals('123456'));
      expect(notifier.state, isA<AuthSessionAuthenticated>());
    });

    testWidgets('cancel button calls signOutThisSession on the notifier', (
      tester,
    ) async {
      final service = _FakeMfaService();
      final notifier = AuthSessionNotifier(
        loginService: service,
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetState(
        const AuthSessionMfaChallenge(
          email: 'mfa@example.test',
          mfaSessionToken: 'tok',
          factorIds: <String>['totp-1'],
        ),
      );
      await tester.pumpWidget(wrap(notifier));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mfa_cancel_button')));
      await tester.pumpAndSettle();
      expect(service.signOutThisSessionCalls, equals(1));
    });

    testWidgets('contact admin requests MFA help', (tester) async {
      final service = _FakeMfaService();
      final recoveryGateway = _FakeMfaRecoveryRequestGateway();
      final notifier = AuthSessionNotifier(
        loginService: service,
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetState(
        const AuthSessionMfaChallenge(
          email: 'mfa@example.test',
          mfaSessionToken: 'tok',
          factorIds: <String>['totp-1'],
        ),
      );
      await tester.pumpWidget(
        wrap(notifier, recoveryRequestGateway: recoveryGateway),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('mfa_contact_admin_button')));
      await tester.pumpAndSettle();

      expect(recoveryGateway.commands.single.email, equals('mfa@example.test'));
      expect(
        find.text(
          'Help request recorded. Contact your restaurant admin directly if you need urgent access.',
        ),
        findsOneWidget,
      );
    });
  });
}

class _DeterministicRandom implements Random {
  _DeterministicRandom(this._seed);

  int _seed;

  @override
  int nextInt(int max) {
    // LCG so tests get a reproducible byte stream without depending
    // on the platform's secure RNG. Range is [0, max).
    _seed = (1103515245 * _seed + 12345) & 0x7fffffff;
    return _seed % max;
  }

  @override
  bool nextBool() => nextInt(2) == 0;

  @override
  double nextDouble() => nextInt(1 << 30) / (1 << 30);
}

class _FakeMfaService implements AuthLoginService {
  _FakeMfaService({this.totpResult});

  AuthLoginResult? totpResult;
  int totpCalls = 0;
  int signOutThisSessionCalls = 0;
  String? lastFactorId;
  String? lastOneTimeCode;

  @override
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    return const AuthLoginFailure(
      code: 'unconfigured',
      message: 'fake mfa service does not run sign-in',
    );
  }

  @override
  Future<AuthLoginResult> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    totpCalls += 1;
    lastFactorId = factorId;
    lastOneTimeCode = oneTimeCode;
    return totpResult ??
        const AuthLoginFailure(
          code: 'unconfigured',
          message: 'fake mfa service did not specify a totp result',
        );
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<AuthSession?> refreshSession(AuthSession current) async => current;

  @override
  Future<void> signOutThisSession() async {
    signOutThisSessionCalls += 1;
  }

  @override
  Future<void> signOutAllSessions() async {}
}

class _FakeMfaRecoveryRequestGateway implements MfaRecoveryRequestGateway {
  final commands = <MfaRecoveryRequestCommand>[];

  @override
  Future<MfaRecoveryRequestAccepted> requestRecovery(
    MfaRecoveryRequestCommand command,
  ) async {
    commands.add(command);
    return const MfaRecoveryRequestAccepted(
      queued: true,
      requestId: 'recovery-request-1',
    );
  }
}
