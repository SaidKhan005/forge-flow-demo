// Phase 11A.0 — Admin auth gate tests.
//
// Verifies:
//   * super_admin / ff_support sessions get the admin shell
//   * non-admin Firebase sessions land on the fail-closed forbidden
//     surface (NOT the shell)
//   * unauthenticated sessions render the branded sign-in card
//   * the demo source's sign-in lookup admits known fixtures and
//     fail-closes the operator fixture
//   * forbidden surface's sign-out affordance routes through the
//     source

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/main_admin.dart' as admin_entrypoint;
import 'package:forge_and_flow/services/auth/firebase_auth_client.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget gateWith(AdminAuthSource source) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: AdminAuthGate(
      source: source,
      adminShellBuilder: (context, session) => Scaffold(
        key: const Key('test_admin_shell'),
        body: Center(child: Text('Admin shell — ${session.email}')),
      ),
    ),
  );

  testWidgets('super_admin session admits to the shell', (tester) async {
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('test_admin_shell')), findsOneWidget);
    expect(find.byKey(const Key('admin_signin_card')), findsNothing);
    expect(find.byKey(const Key('admin_forbidden_card')), findsNothing);
  });

  testWidgets('ff_support session admits to the shell', (tester) async {
    final source = DemoAdminAuthSource(
      initial: const AdminAuthAuthenticated(
        AdminAuthSession(
          uid: 'demo-ff-support',
          email: 'support@forgeflow.test',
          displayName: 'Demo F&F Support',
          roles: <String>['ff_support'],
        ),
      ),
    );
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('test_admin_shell')), findsOneWidget);
  });

  testWidgets('non-admin session fails closed to the forbidden surface', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsNonAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_forbidden_card')), findsOneWidget);
    expect(find.byKey(const Key('test_admin_shell')), findsNothing);
    expect(find.text('Admin access required'), findsOneWidget);
  });

  testWidgets('unauthenticated session renders the branded sign-in card', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedOut();
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_signin_card')), findsOneWidget);
    expect(find.byKey(const Key('admin_email_field')), findsOneWidget);
    expect(find.byKey(const Key('admin_password_field')), findsOneWidget);
    expect(find.byKey(const Key('admin_signin_submit')), findsOneWidget);
  });

  testWidgets('demo sign-in admits the super-admin fixture', (tester) async {
    final source = DemoAdminAuthSource.signedOut();
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_email_field')),
      'super.admin@forgeflow.test',
    );
    await tester.enterText(
      find.byKey(const Key('admin_password_field')),
      'demo-password',
    );
    await tester.tap(find.byKey(const Key('admin_signin_submit')));
    await tester.pumpAndSettle();

    expect(source.current, isA<AdminAuthAuthenticated>());
    expect(find.byKey(const Key('test_admin_shell')), findsOneWidget);
  });

  testWidgets('demo sign-in fails closed for the operator fixture', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedOut();
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_email_field')),
      'operator@forgeflow.test',
    );
    await tester.enterText(
      find.byKey(const Key('admin_password_field')),
      'demo-password',
    );
    await tester.tap(find.byKey(const Key('admin_signin_submit')));
    await tester.pumpAndSettle();

    expect(source.current, isA<AdminAuthForbidden>());
    expect(find.byKey(const Key('admin_forbidden_card')), findsOneWidget);
    expect(find.byKey(const Key('test_admin_shell')), findsNothing);
  });

  testWidgets('demo sign-in surfaces the unknown-email error', (tester) async {
    final source = DemoAdminAuthSource.signedOut();
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_email_field')),
      'unknown@forgeflow.test',
    );
    await tester.enterText(
      find.byKey(const Key('admin_password_field')),
      'demo-password',
    );
    await tester.tap(find.byKey(const Key('admin_signin_submit')));
    await tester.pumpAndSettle();

    expect(source.current, isA<AdminAuthUnauthenticated>());
    expect(find.byKey(const Key('admin_signin_error_banner')), findsOneWidget);
  });

  testWidgets('mfa challenge renders the shared TOTP view', (tester) async {
    final source = DemoAdminAuthSource(
      initial: const AdminAuthMfaChallenge(
        email: 'admin.mfa@forgeflow.test',
        mfaSessionToken: 'mfa-token',
        factorIds: <String>['totp-1'],
      ),
    );
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    expect(find.text('Two-factor verification'), findsOneWidget);
    expect(find.text('admin.mfa@forgeflow.test'), findsOneWidget);
    expect(find.byKey(const Key('mfa_code_field')), findsOneWidget);
    expect(find.byKey(const Key('mfa_submit_button')), findsOneWidget);
    expect(find.byKey(const Key('admin_signin_card')), findsNothing);
  });

  testWidgets('mfa submit passes the first factor id to the source', (
    tester,
  ) async {
    final source = _RecordingAdminAuthSource(
      const AdminAuthMfaChallenge(
        email: 'admin.mfa@forgeflow.test',
        mfaSessionToken: 'mfa-token',
        factorIds: <String>['totp-1', 'totp-2'],
      ),
    );
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('mfa_code_field')), '123456');
    await tester.tap(find.byKey(const Key('mfa_submit_button')));
    await tester.pumpAndSettle();

    expect(source.completeTotpCalls, equals(1));
    expect(source.lastFactorId, equals('totp-1'));
    expect(source.lastOneTimeCode, equals('123456'));
  });

  testWidgets('mfa submit with empty code stays local', (tester) async {
    final source = _RecordingAdminAuthSource(
      const AdminAuthMfaChallenge(
        email: 'admin.mfa@forgeflow.test',
        mfaSessionToken: 'mfa-token',
        factorIds: <String>['totp-1'],
      ),
    );
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mfa_submit_button')));
    await tester.pumpAndSettle();

    expect(source.completeTotpCalls, equals(0));
    expect(find.byKey(const Key('mfa_error_banner')), findsOneWidget);
    expect(find.text('Enter a code to continue.'), findsOneWidget);
  });

  testWidgets('mfa failure stays on the challenge surface', (tester) async {
    final source = DemoAdminAuthSource(
      initial: const AdminAuthMfaChallenge(
        email: 'admin.mfa@forgeflow.test',
        mfaSessionToken: 'mfa-token',
        factorIds: <String>['totp-1'],
      ),
    );
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('mfa_code_field')), '000000');
    await tester.tap(find.byKey(const Key('mfa_submit_button')));
    await tester.pumpAndSettle();

    expect(source.current, isA<AdminAuthMfaChallenge>());
    expect(find.byKey(const Key('mfa_error_banner')), findsOneWidget);
    expect(find.byKey(const Key('test_admin_shell')), findsNothing);
  });

  testWidgets('mfa cancel signs out', (tester) async {
    final source = DemoAdminAuthSource(
      initial: const AdminAuthMfaChallenge(
        email: 'admin.mfa@forgeflow.test',
        mfaSessionToken: 'mfa-token',
        factorIds: <String>['totp-1'],
      ),
    );
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mfa_cancel_button')));
    await tester.pumpAndSettle();

    expect(source.current, isA<AdminAuthUnauthenticated>());
    expect(find.byKey(const Key('admin_signin_card')), findsOneWidget);
  });

  testWidgets('forbidden surface sign-out routes through the source', (
    tester,
  ) async {
    final source = DemoAdminAuthSource.signedInAsNonAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    expect(source.current, isA<AdminAuthForbidden>());
    await tester.tap(find.byKey(const Key('admin_forbidden_signout')));
    await tester.pumpAndSettle();

    expect(source.current, isA<AdminAuthUnauthenticated>());
    expect(find.byKey(const Key('admin_signin_card')), findsOneWidget);
  });

  group('AdminAuthSession.isAdmin', () {
    test('admits the super_admin role', () {
      const session = AdminAuthSession(
        uid: 'u',
        email: 'e',
        displayName: 'd',
        roles: <String>['super_admin'],
      );
      expect(session.isAdmin, isTrue);
    });

    test('admits the ff_support role', () {
      const session = AdminAuthSession(
        uid: 'u',
        email: 'e',
        displayName: 'd',
        roles: <String>['ff_support'],
      );
      expect(session.isAdmin, isTrue);
    });

    test('rejects operator-only role lists', () {
      const session = AdminAuthSession(
        uid: 'u',
        email: 'e',
        displayName: 'd',
        roles: <String>['operator_owner', 'operator_manager'],
      );
      expect(session.isAdmin, isFalse);
    });

    test('rejects empty role lists', () {
      const session = AdminAuthSession(
        uid: 'u',
        email: 'e',
        displayName: 'd',
        roles: <String>[],
      );
      expect(session.isAdmin, isFalse);
    });
  });

  group('kAdminConsoleRoles catalog', () {
    test('contains super_admin + ff_support and nothing else', () {
      expect(kAdminConsoleRoles, equals(<String>{'super_admin', 'ff_support'}));
    });
  });

  group('FirebaseAdminAuthSource.extractRolesFromClaims', () {
    // The locked Phase 9 admin claim shape is the boolean pair
    // `is_super_admin` + `is_ff_support`. The operator app projects
    // the same shape in
    // `lib/services/auth/firebase_auth_login_service.dart`; the
    // admin gate must agree so a real super-admin's ID token is not
    // mis-classified as "no roles" and fail-closed by accident.

    test('projects is_super_admin: true to the super_admin role', () {
      final roles = FirebaseAdminAuthSource.extractRolesFromClaims(
        const <String, Object?>{'is_super_admin': true},
      );
      expect(roles, equals(<String>['super_admin']));
    });

    test('projects is_ff_support: true to the ff_support role', () {
      final roles = FirebaseAdminAuthSource.extractRolesFromClaims(
        const <String, Object?>{'is_ff_support': true},
      );
      expect(roles, equals(<String>['ff_support']));
    });

    test('projects both flags simultaneously and preserves order', () {
      final roles = FirebaseAdminAuthSource.extractRolesFromClaims(
        const <String, Object?>{'is_super_admin': true, 'is_ff_support': true},
      );
      expect(roles, equals(<String>['super_admin', 'ff_support']));
    });

    test('omits a role when its flag is false', () {
      final roles = FirebaseAdminAuthSource.extractRolesFromClaims(
        const <String, Object?>{'is_super_admin': false, 'is_ff_support': true},
      );
      expect(roles, equals(<String>['ff_support']));
    });

    test('returns an empty list when neither flag is set', () {
      expect(
        FirebaseAdminAuthSource.extractRolesFromClaims(const <String, Object?>{
          'operator_id': 'op-a',
          'roles_version': 4,
        }),
        isEmpty,
      );
    });

    test('non-boolean-true values do not admit (e.g. truthy string)', () {
      // The contract is an explicit boolean true; defending against
      // a misissued claim that shipped the string "true" instead of
      // the boolean keeps the gate fail-closed.
      final roles = FirebaseAdminAuthSource.extractRolesFromClaims(
        const <String, Object?>{'is_super_admin': 'true', 'is_ff_support': 1},
      );
      expect(roles, isEmpty);
    });

    test('rejects the legacy `roles` array shape (Phase 9 lock)', () {
      // The decision lock disallows shipping a `roles` array on the
      // JWT — the payload stays tiny via the boolean flags. If the
      // proxy ever issues a `roles` array, this test fails the
      // build and forces the wiring decision back to the auth-plan
      // owner.
      final roles = FirebaseAdminAuthSource.extractRolesFromClaims(
        const <String, Object?>{
          'roles': <String>['super_admin', 'ff_support'],
        },
      );
      expect(roles, isEmpty);
    });
  });

  group('FirebaseAdminAuthSource MFA mapping', () {
    test('maps requires-MFA sign-in and successful completion', () async {
      final client = _FakeFirebaseAuthClient()
        ..signInOutcome = const FirebaseAuthSignInRequiresMfa(
          mfaSessionToken: 'mfa-token',
          factorIds: <String>['totp-1'],
        )
        ..completeOutcome = FirebaseAuthSignInSucceeded(
          _superAdminCredential(),
        );
      final source = FirebaseAdminAuthSource(client: client);
      addTearDown(source.dispose);
      await Future<void>.delayed(Duration.zero);

      await source.signInWithEmailPassword(
        email: 'admin.mfa@forgeflow.test',
        password: 'password',
      );

      final challenge = source.current;
      expect(challenge, isA<AdminAuthMfaChallenge>());
      expect(
        (challenge as AdminAuthMfaChallenge).mfaSessionToken,
        equals('mfa-token'),
      );

      await source.completeTotpChallenge(
        factorId: 'totp-1',
        oneTimeCode: '123456',
      );

      final authenticated = source.current;
      expect(authenticated, isA<AdminAuthAuthenticated>());
      expect(
        (authenticated as AdminAuthAuthenticated).session.email,
        equals('admin.mfa@forgeflow.test'),
      );
      expect(authenticated.session.roles, equals(<String>['super_admin']));
    });

    test('keeps MFA challenge visible after failed completion', () async {
      final client = _FakeFirebaseAuthClient()
        ..signInOutcome = const FirebaseAuthSignInRequiresMfa(
          mfaSessionToken: 'mfa-token',
          factorIds: <String>['totp-1'],
        )
        ..completeOutcome = const FirebaseAuthSignInFailed(
          code: 'invalid-verification-code',
          message: 'Sign-in failed. Please try again.',
        );
      final source = FirebaseAdminAuthSource(client: client);
      addTearDown(source.dispose);
      await Future<void>.delayed(Duration.zero);

      await source.signInWithEmailPassword(
        email: 'admin.mfa@forgeflow.test',
        password: 'password',
      );
      await source.completeTotpChallenge(
        factorId: 'totp-1',
        oneTimeCode: '000000',
      );

      final challenge = source.current;
      expect(challenge, isA<AdminAuthMfaChallenge>());
      expect(
        (challenge as AdminAuthMfaChallenge).lastErrorMessage,
        equals('Sign-in failed. Please try again.'),
      );
    });
  });

  group('kAdminFirebaseOptions', () {
    test('mirrors the committed staging web Firebase config', () {
      const options = admin_entrypoint.kAdminFirebaseOptions;

      expect(options.projectId, equals('forge-flow-staging'));
      expect(options.appId, equals('1:78630909582:web:d716c986475899f13a7bdf'));
      expect(options.apiKey, equals('AIzaSyBeTA2ye7U1gsrwZyGcMVDOAfo7Seh2oqM'));
      expect(options.authDomain, equals('forge-flow-staging.firebaseapp.com'));
      expect(
        options.storageBucket,
        equals('forge-flow-staging.firebasestorage.app'),
      );
      expect(options.messagingSenderId, equals('78630909582'));
    });
  });
}

class _RecordingAdminAuthSource implements AdminAuthSource {
  _RecordingAdminAuthSource(this._state) {
    _controller.add(_state);
  }

  final StreamController<AdminAuthState> _controller =
      StreamController<AdminAuthState>.broadcast();
  AdminAuthState _state;
  int completeTotpCalls = 0;
  String? lastFactorId;
  String? lastOneTimeCode;

  @override
  Stream<AdminAuthState> get stream => _controller.stream;

  @override
  AdminAuthState get current => _state;

  @override
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> completeTotpChallenge({
    required String factorId,
    required String oneTimeCode,
  }) async {
    completeTotpCalls += 1;
    lastFactorId = factorId;
    lastOneTimeCode = oneTimeCode;
  }

  @override
  Future<void> signOut() async {
    _state = const AdminAuthUnauthenticated();
    _controller.add(_state);
  }

  @override
  void dispose() {
    _controller.close();
  }
}

class _FakeFirebaseAuthClient implements FirebaseAuthClient {
  FirebaseAuthSignInOutcome signInOutcome = const FirebaseAuthSignInFailed(
    code: 'unconfigured',
    message: 'unconfigured',
  );
  FirebaseAuthSignInOutcome completeOutcome = const FirebaseAuthSignInFailed(
    code: 'unconfigured',
    message: 'unconfigured',
  );

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    return signInOutcome;
  }

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    return completeOutcome;
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() async => null;

  @override
  Future<String?> currentIdToken() async => 'id-token';

  @override
  Future<void> signOut() async {}

  @override
  Future<void> revokeAllRefreshTokens() async {}
}

FirebaseAuthCredential _superAdminCredential() {
  final now = DateTime.utc(2026, 5, 2, 12);
  return FirebaseAuthCredential(
    userId: 'firebase-admin',
    idToken: 'id-token',
    idTokenIssuedAt: now,
    idTokenExpiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: now,
    email: 'admin.mfa@forgeflow.test',
    displayName: 'Admin MFA',
    customClaims: const <String, Object?>{'is_super_admin': true},
  );
}
