// Phase 9.3 - Auth session + notifier + login service + storage
// + BarrioPreviewRole.fromAuthRoles tests.
//
// Runs entirely against fakes — no Firebase SDK, no platform channel,
// no live network. Production wiring of `firebase_auth` and
// `flutter_secure_storage` is a focused follow-up parallel to the
// 9.1 RS256 backend gap and the 9.2 `package:postgres` binding.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_preview_role.dart';
import 'package:forge_and_flow/screens/auth/auth_gate.dart';
import 'package:forge_and_flow/screens/auth/login_screen.dart';
import 'package:forge_and_flow/screens/auth/mfa_challenge_screen.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';

void main() {
  group('AuthSession value class', () {
    AuthSession build({
      DateTime? lastFreshAuthAt,
      DateTime? expiresAt,
      List<String> roles = const <String>['operator_owner'],
      bool mfaEnrolled = true,
    }) {
      final now = DateTime.utc(2026, 4, 26, 12);
      return AuthSession(
        userId: 'user_abc',
        operatorId: 'op_777',
        locationId: 'loc_999',
        firebaseIdToken: 'header.payload.sig',
        issuedAt: now.subtract(const Duration(minutes: 1)),
        expiresAt: expiresAt ?? now.add(const Duration(hours: 1)),
        lastFreshAuthAt: lastFreshAuthAt ?? now.subtract(const Duration(minutes: 1)),
        roles: roles,
        mfaEnrolled: mfaEnrolled,
      );
    }

    test('isAuthFresh returns true within the 5-minute window', () {
      final session = build(
        lastFreshAuthAt: DateTime.utc(2026, 4, 26, 11, 58),
      );
      expect(
        session.isAuthFresh(now: DateTime.utc(2026, 4, 26, 12, 2)),
        isTrue,
      );
    });

    test('isAuthFresh returns false past the 5-minute window', () {
      final session = build(
        lastFreshAuthAt: DateTime.utc(2026, 4, 26, 11, 50),
      );
      expect(
        session.isAuthFresh(now: DateTime.utc(2026, 4, 26, 12, 0)),
        isFalse,
      );
    });

    test('isLive uses expiresAt', () {
      final session = build(expiresAt: DateTime.utc(2026, 4, 26, 13));
      expect(session.isLive(now: DateTime.utc(2026, 4, 26, 12)), isTrue);
      expect(session.isLive(now: DateTime.utc(2026, 4, 26, 14)), isFalse);
    });

    test('toJson + fromJson round-trip preserves all fields', () {
      final original = build(roles: <String>['super_admin', 'roles_version:7']);
      final round = AuthSession.fromJson(original.toJson());
      expect(round.userId, equals(original.userId));
      expect(round.operatorId, equals(original.operatorId));
      expect(round.locationId, equals(original.locationId));
      expect(round.firebaseIdToken, equals(original.firebaseIdToken));
      expect(round.issuedAt, equals(original.issuedAt));
      expect(round.expiresAt, equals(original.expiresAt));
      expect(round.lastFreshAuthAt, equals(original.lastFreshAuthAt));
      expect(round.roles, equals(original.roles));
      expect(round.mfaEnrolled, equals(original.mfaEnrolled));
    });

    test('toString never echoes the firebase ID token', () {
      const token = 'super-secret-firebase-id-token-value';
      final session = AuthSession(
        userId: 'u',
        operatorId: 'o',
        locationId: 'l',
        firebaseIdToken: token,
        issuedAt: DateTime.utc(2026, 4, 26),
        expiresAt: DateTime.utc(2026, 4, 26, 1),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26),
        roles: const <String>[],
        mfaEnrolled: false,
      );
      expect(session.toString(), isNot(contains(token)));
    });
  });

  group('BarrioPreviewRole.fromAuthRoles (9.3)', () {
    test('empty roles -> admin (preview/dev fallback)', () {
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>[]),
        equals(BarrioPreviewRole.admin),
      );
    });

    test('super_admin -> admin', () {
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>['super_admin']),
        equals(BarrioPreviewRole.admin),
      );
    });

    test('ff_support -> admin (full surface visibility)', () {
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>['ff_support']),
        equals(BarrioPreviewRole.admin),
      );
    });

    test('operator_owner -> admin', () {
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>['operator_owner']),
        equals(BarrioPreviewRole.admin),
      );
    });

    test('operator_manager -> manager', () {
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>['operator_manager']),
        equals(BarrioPreviewRole.manager),
      );
    });

    test('operator_supervisor -> supervisor', () {
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>['operator_supervisor']),
        equals(BarrioPreviewRole.supervisor),
      );
    });

    test('operator_staff -> staff', () {
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>['operator_staff']),
        equals(BarrioPreviewRole.staff),
      );
    });

    test('multiple roles: highest tier wins', () {
      // Mixed grant — owner + supervisor should still render the
      // owner surface (admin tier in preview), not the smaller one.
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>[
          'operator_supervisor',
          'operator_owner',
        ]),
        equals(BarrioPreviewRole.admin),
      );
      // Manager + staff resolves to manager, not staff.
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>[
          'operator_staff',
          'operator_manager',
        ]),
        equals(BarrioPreviewRole.manager),
      );
    });

    test('unknown roles + a known role: known wins, unknowns ignored', () {
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>[
          'roles_version:7',
          'made_up_role',
          'operator_supervisor',
        ]),
        equals(BarrioPreviewRole.supervisor),
      );
    });

    test('only unknown roles -> staff (most restrictive default)', () {
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>[
          'roles_version:1',
          'made_up_role',
        ]),
        equals(BarrioPreviewRole.staff),
      );
    });

    test('case-insensitive match on canonical role keys', () {
      expect(
        BarrioPreviewRole.fromAuthRoles(const <String>['Operator_Manager']),
        equals(BarrioPreviewRole.manager),
      );
    });
  });

  group('SecureSessionStorage', () {
    test('InMemorySecureSessionStorage stores + reads + clears', () async {
      final storage = InMemorySecureSessionStorage();
      expect(await storage.readSessionJson(), isNull);
      await storage.writeSessionJson('{"k":1}');
      expect(await storage.readSessionJson(), equals('{"k":1}'));
      await storage.clear();
      expect(await storage.readSessionJson(), isNull);
    });

    test('readSession + writeSession round-trip via JSON', () async {
      final storage = InMemorySecureSessionStorage();
      final session = AuthSession(
        userId: 'u',
        operatorId: 'o',
        locationId: 'l',
        firebaseIdToken: 't',
        issuedAt: DateTime.utc(2026, 4, 26),
        expiresAt: DateTime.utc(2026, 4, 26, 1),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26),
        roles: const <String>['operator_owner'],
        mfaEnrolled: true,
      );
      await storage.writeSession(session);
      final loaded = await storage.readSession();
      expect(loaded?.userId, equals('u'));
      expect(loaded?.roles, equals(<String>['operator_owner']));
    });

    test('ScaffoldFailingSecureSessionStorage throws on every method',
        () async {
      final storage = ScaffoldFailingSecureSessionStorage();
      await expectLater(storage.readSessionJson(), throwsStateError);
      await expectLater(storage.writeSessionJson(''), throwsStateError);
      await expectLater(storage.clear(), throwsStateError);
    });
  });

  group('ScaffoldFailingAuthLoginService', () {
    test('every entry point throws so production fails closed', () async {
      const svc = ScaffoldFailingAuthLoginService();
      await expectLater(
        svc.signInWithEmailPassword(email: 'a@b.c', password: 'x'),
        throwsStateError,
      );
      await expectLater(
        svc.completeTotpChallenge(
          mfaSessionToken: 't',
          factorId: 'f',
          oneTimeCode: '123',
        ),
        throwsStateError,
      );
      await expectLater(
        svc.requestPasswordReset(email: 'a@b.c'),
        throwsStateError,
      );
    });
  });

  group('AuthSessionNotifier', () {
    AuthSessionNotifier buildNotifier({
      AuthLoginService? service,
      SecureSessionStorage? storage,
      DateTime Function()? now,
      Duration freshnessWindow = const Duration(minutes: 5),
    }) {
      return AuthSessionNotifier(
        loginService: service ?? _FakeAuthLoginService(),
        storage: storage ?? InMemorySecureSessionStorage(),
        now: now ?? () => DateTime.utc(2026, 4, 26, 12),
        freshnessWindow: freshnessWindow,
      );
    }

    AuthSession buildSession({
      DateTime? lastFreshAuthAt,
      DateTime? expiresAt,
      List<String> roles = const <String>['operator_owner'],
    }) {
      final now = DateTime.utc(2026, 4, 26, 12);
      return AuthSession(
        userId: 'user_abc',
        operatorId: 'op_777',
        locationId: 'loc_999',
        firebaseIdToken: 'header.payload.sig',
        issuedAt: now.subtract(const Duration(minutes: 1)),
        expiresAt: expiresAt ?? now.add(const Duration(hours: 1)),
        lastFreshAuthAt: lastFreshAuthAt ?? now.subtract(const Duration(minutes: 1)),
        roles: roles,
        mfaEnrolled: true,
      );
    }

    test('starts in loading state until rehydrate runs', () {
      final notifier = buildNotifier();
      expect(notifier.state, isA<AuthSessionLoading>());
    });

    test('rehydrate with no persisted session -> unauthenticated', () async {
      final notifier = buildNotifier();
      await notifier.rehydrate();
      expect(notifier.state, isA<AuthSessionUnauthenticated>());
    });

    test('rehydrate with live persisted session -> authenticated', () async {
      final storage = InMemorySecureSessionStorage();
      await storage.writeSession(buildSession());
      final notifier = buildNotifier(storage: storage);
      await notifier.rehydrate();
      expect(notifier.state, isA<AuthSessionAuthenticated>());
      expect(notifier.session?.userId, equals('user_abc'));
    });

    test('rehydrate with expired persisted session -> unauthenticated + '
        'storage cleared', () async {
      final storage = InMemorySecureSessionStorage();
      await storage.writeSession(buildSession(
        expiresAt: DateTime.utc(2026, 4, 26, 11),
      ));
      final notifier = buildNotifier(storage: storage);
      await notifier.rehydrate();
      expect(notifier.state, isA<AuthSessionUnauthenticated>());
      expect(await storage.readSessionJson(), isNull);
    });

    test('rehydrate tolerates ScaffoldFailingSecureSessionStorage and '
        'falls through to unauthenticated', () async {
      final notifier = buildNotifier(
        storage: ScaffoldFailingSecureSessionStorage(),
      );
      await notifier.rehydrate();
      expect(notifier.state, isA<AuthSessionUnauthenticated>());
    });

    test('signIn success -> persists session + transitions to '
        'authenticated', () async {
      final storage = InMemorySecureSessionStorage();
      final service = _FakeAuthLoginService(
        signInResult: AuthLoginSuccess(buildSession()),
      );
      final notifier = buildNotifier(service: service, storage: storage);
      await notifier.rehydrate();

      final result = await notifier.signInWithEmailPassword(
        email: 'a@b.c',
        password: 'pw',
      );

      expect(result, isA<AuthLoginSuccess>());
      expect(notifier.state, isA<AuthSessionAuthenticated>());
      expect(await storage.readSession(), isNotNull);
    });

    test('signIn MFA required -> mfa-challenge state with email + token',
        () async {
      final service = _FakeAuthLoginService(
        signInResult: const AuthLoginMfaRequired(
          mfaSessionToken: 'mfa-tok',
          factorIds: <String>['totp-1'],
        ),
      );
      final notifier = buildNotifier(service: service);
      await notifier.rehydrate();

      await notifier.signInWithEmailPassword(
        email: 'mfa@example.test',
        password: 'pw',
      );

      final state = notifier.state;
      expect(state, isA<AuthSessionMfaChallenge>());
      expect((state as AuthSessionMfaChallenge).email,
          equals('mfa@example.test'));
      expect(state.mfaSessionToken, equals('mfa-tok'));
      expect(state.factorIds, equals(<String>['totp-1']));
    });

    test('signIn failure -> unauthenticated with code + message', () async {
      final service = _FakeAuthLoginService(
        signInResult: const AuthLoginFailure(
          code: 'invalid_credentials',
          message: 'Sorry, that did not match',
        ),
      );
      final notifier = buildNotifier(service: service);
      await notifier.rehydrate();

      await notifier.signInWithEmailPassword(email: 'a@b.c', password: 'x');

      final state = notifier.state;
      expect(state, isA<AuthSessionUnauthenticated>());
      expect((state as AuthSessionUnauthenticated).lastErrorCode,
          equals('invalid_credentials'));
      expect(state.lastErrorMessage, equals('Sorry, that did not match'));
    });

    test('completeTotpChallenge requires mfa-challenge state', () async {
      final notifier = buildNotifier();
      await notifier.rehydrate();
      await expectLater(
        notifier.completeTotpChallenge(factorId: 'f', oneTimeCode: '000000'),
        throwsStateError,
      );
    });

    test('completeTotpChallenge transitions to authenticated on success',
        () async {
      final service = _FakeAuthLoginService(
        signInResult: const AuthLoginMfaRequired(
          mfaSessionToken: 'mfa-tok',
          factorIds: <String>['totp-1'],
        ),
      );
      final notifier = buildNotifier(service: service);
      await notifier.rehydrate();
      await notifier.signInWithEmailPassword(email: 'mfa@example.test', password: 'pw');

      service.totpResult = AuthLoginSuccess(buildSession());
      await notifier.completeTotpChallenge(
        factorId: 'totp-1',
        oneTimeCode: '123456',
      );
      expect(notifier.state, isA<AuthSessionAuthenticated>());
    });

    test('requireFreshAuth returns null when not authenticated', () async {
      final notifier = buildNotifier();
      await notifier.rehydrate();
      expect(notifier.requireFreshAuth(), isNull);
      expect(notifier.isAuthFresh, isFalse);
    });

    test('requireFreshAuth returns the session when within 5-minute window',
        () async {
      final storage = InMemorySecureSessionStorage();
      await storage.writeSession(buildSession(
        lastFreshAuthAt: DateTime.utc(2026, 4, 26, 11, 58),
      ));
      final notifier = buildNotifier(storage: storage);
      await notifier.rehydrate();

      expect(notifier.requireFreshAuth(), isNotNull);
      expect(notifier.isAuthFresh, isTrue);
    });

    test('requireFreshAuth returns null past the window', () async {
      final storage = InMemorySecureSessionStorage();
      await storage.writeSession(buildSession(
        lastFreshAuthAt: DateTime.utc(2026, 4, 26, 11, 50),
      ));
      final notifier = buildNotifier(storage: storage);
      await notifier.rehydrate();

      expect(notifier.requireFreshAuth(), isNull);
      expect(notifier.isAuthFresh, isFalse);
      // Acceptance: state stays authenticated; the gate just refuses
      // sensitive ops until re-prompt completes.
      expect(notifier.state, isA<AuthSessionAuthenticated>());
    });

    test('signOutThisSession clears storage + transitions to '
        'unauthenticated', () async {
      final storage = InMemorySecureSessionStorage();
      await storage.writeSession(buildSession());
      final service = _FakeAuthLoginService();
      final notifier = buildNotifier(service: service, storage: storage);
      await notifier.rehydrate();

      await notifier.signOutThisSession();

      expect(notifier.state, isA<AuthSessionUnauthenticated>());
      expect(await storage.readSessionJson(), isNull);
      expect(service.signOutThisSessionCalls, equals(1));
      expect(service.signOutAllSessionsCalls, equals(0));
    });

    test('signOutAllSessions calls service revoke + clears storage',
        () async {
      final storage = InMemorySecureSessionStorage();
      await storage.writeSession(buildSession());
      final service = _FakeAuthLoginService();
      final notifier = buildNotifier(service: service, storage: storage);
      await notifier.rehydrate();

      await notifier.signOutAllSessions();

      expect(notifier.state, isA<AuthSessionUnauthenticated>());
      expect(service.signOutAllSessionsCalls, equals(1));
    });
  });

  group('AuthGate widget', () {
    Widget wrap(AuthSessionNotifier notifier, {Widget? authenticatedChild}) {
      return MaterialApp(
        home: ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: AuthGate(
            authenticatedChild:
                authenticatedChild ?? const _ScaffoldHomeStub(),
          ),
        ),
      );
    }

    testWidgets('loading state renders default loading view', (tester) async {
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      );
      await tester.pumpWidget(wrap(notifier));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('unauthenticated renders LoginScreen', (tester) async {
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetState(const AuthSessionUnauthenticated());
      await tester.pumpWidget(wrap(notifier));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('mfa-challenge renders MfaChallengeScreen', (tester) async {
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetState(const AuthSessionMfaChallenge(
        email: 'mfa@example.test',
        mfaSessionToken: 'tok',
        factorIds: <String>['totp-1'],
      ));
      await tester.pumpWidget(wrap(notifier));
      await tester.pumpAndSettle();
      expect(find.byType(MfaChallengeScreen), findsOneWidget);
    });

    testWidgets('authenticated renders the supplied child', (tester) async {
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetSession(AuthSession(
        userId: 'u',
        operatorId: 'o',
        locationId: 'l',
        firebaseIdToken: 't',
        issuedAt: DateTime.utc(2026, 4, 26),
        expiresAt: DateTime.utc(2026, 4, 26, 1),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26),
        roles: const <String>['operator_owner'],
        mfaEnrolled: true,
      ));
      await tester.pumpWidget(wrap(
        notifier,
        authenticatedChild: const Scaffold(
          body: Center(child: Text('app-shell-here')),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('app-shell-here'), findsOneWidget);
    });
  });

  group('LoginScreen widget', () {
    Widget wrap(AuthSessionNotifier notifier) {
      return MaterialApp(
        home: ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: const LoginScreen(),
        ),
      );
    }

    testWidgets('disabled until both fields have content + tap submits',
        (tester) async {
      final session = AuthSession(
        userId: 'u',
        operatorId: 'o',
        locationId: 'l',
        firebaseIdToken: 't',
        issuedAt: DateTime.utc(2026, 4, 26),
        expiresAt: DateTime.utc(2026, 4, 26, 1),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26),
        roles: const <String>['operator_owner'],
        mfaEnrolled: true,
      );
      final service = _FakeAuthLoginService(
        signInResult: AuthLoginSuccess(session),
      );
      final notifier = AuthSessionNotifier(
        loginService: service,
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetState(const AuthSessionUnauthenticated());

      await tester.pumpWidget(wrap(notifier));
      await tester.pumpAndSettle();

      // Empty fields: tapping submit is a no-op (no service call).
      await tester.tap(find.byKey(const Key('login_submit_button')));
      await tester.pump();
      expect(service.signInCalls, equals(0));

      await tester.enterText(
        find.byKey(const Key('login_email_field')),
        'a@b.c',
      );
      await tester.enterText(
        find.byKey(const Key('login_password_field')),
        'password',
      );
      await tester.tap(find.byKey(const Key('login_submit_button')));
      await tester.pumpAndSettle();

      expect(service.signInCalls, equals(1));
      expect(notifier.state, isA<AuthSessionAuthenticated>());
    });

    testWidgets('error banner renders when notifier carries failure code',
        (tester) async {
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetState(const AuthSessionUnauthenticated(
        lastErrorCode: 'invalid_credentials',
        lastErrorMessage: 'Email or password is incorrect.',
      ));
      await tester.pumpWidget(wrap(notifier));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login_error_banner')), findsOneWidget);
      expect(
        find.text('Email or password is incorrect.'),
        findsOneWidget,
      );
    });
  });
}

class _ScaffoldHomeStub extends StatelessWidget {
  const _ScaffoldHomeStub();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: SizedBox.shrink());
  }
}

class _FakeAuthLoginService implements AuthLoginService {
  _FakeAuthLoginService({this.signInResult});

  AuthLoginResult? signInResult;
  AuthLoginResult? totpResult;
  int signInCalls = 0;
  int signOutThisSessionCalls = 0;
  int signOutAllSessionsCalls = 0;

  @override
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    signInCalls += 1;
    return signInResult ??
        const AuthLoginFailure(
          code: 'unconfigured',
          message: 'fake service did not specify a result',
        );
  }

  @override
  Future<AuthLoginResult> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    return totpResult ??
        const AuthLoginFailure(
          code: 'unconfigured',
          message: 'fake service did not specify a result',
        );
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<AuthSession?> refreshSession(AuthSession current) async {
    return current;
  }

  @override
  Future<void> signOutThisSession() async {
    signOutThisSessionCalls += 1;
  }

  @override
  Future<void> signOutAllSessions() async {
    signOutAllSessionsCalls += 1;
  }
}
