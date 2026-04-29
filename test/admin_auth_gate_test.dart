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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/main_admin.dart' as admin_entrypoint;
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

  testWidgets('non-admin session fails closed to the forbidden surface',
      (tester) async {
    final source = DemoAdminAuthSource.signedInAsNonAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(gateWith(source));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_forbidden_card')), findsOneWidget);
    expect(find.byKey(const Key('test_admin_shell')), findsNothing);
    expect(find.text('Admin access required'), findsOneWidget);
  });

  testWidgets('unauthenticated session renders the branded sign-in card',
      (tester) async {
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

  testWidgets('demo sign-in fails closed for the operator fixture',
      (tester) async {
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
    expect(
      find.byKey(const Key('admin_signin_error_banner')),
      findsOneWidget,
    );
  });

  testWidgets('forbidden surface sign-out routes through the source',
      (tester) async {
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
        const <String, Object?>{
          'is_super_admin': true,
          'is_ff_support': true,
        },
      );
      expect(roles, equals(<String>['super_admin', 'ff_support']));
    });

    test('omits a role when its flag is false', () {
      final roles = FirebaseAdminAuthSource.extractRolesFromClaims(
        const <String, Object?>{
          'is_super_admin': false,
          'is_ff_support': true,
        },
      );
      expect(roles, equals(<String>['ff_support']));
    });

    test('returns an empty list when neither flag is set', () {
      expect(
        FirebaseAdminAuthSource.extractRolesFromClaims(
          const <String, Object?>{
            'operator_id': 'op-a',
            'roles_version': 4,
          },
        ),
        isEmpty,
      );
    });

    test('non-boolean-true values do not admit (e.g. truthy string)', () {
      // The contract is an explicit boolean true; defending against
      // a misissued claim that shipped the string "true" instead of
      // the boolean keeps the gate fail-closed.
      final roles = FirebaseAdminAuthSource.extractRolesFromClaims(
        const <String, Object?>{
          'is_super_admin': 'true',
          'is_ff_support': 1,
        },
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

  group('kAdminFirebaseOptions', () {
    test('mirrors the committed staging web Firebase config', () {
      const options = admin_entrypoint.kAdminFirebaseOptions;

      expect(options.projectId, equals('forge-flow-staging'));
      expect(
        options.appId,
        equals('1:78630909582:web:d716c986475899f13a7bdf'),
      );
      expect(
        options.apiKey,
        equals('AIzaSyBeTA2ye7U1gsrwZyGcMVDOAfo7Seh2oqM'),
      );
      expect(
        options.authDomain,
        equals('forge-flow-staging.firebaseapp.com'),
      );
      expect(
        options.storageBucket,
        equals('forge-flow-staging.firebasestorage.app'),
      );
      expect(options.messagingSenderId, equals('78630909582'));
    });
  });
}
