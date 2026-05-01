// Phase 9.UX.7 - login_screen "Forgot password?" link presence + nav.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/screens/auth/auth_gate.dart';
import 'package:forge_and_flow/screens/auth/login_screen.dart';
import 'package:forge_and_flow/screens/auth/password_reset_request_screen.dart';
import 'package:forge_and_flow/services/auth/password_reset_gateway.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';
import 'package:provider/provider.dart';

void main() {
  group('LoginScreen Forgot password link', () {
    Widget wrap({required LoginScreen screen}) {
      final notifier = AuthSessionNotifier(
        loginService: const _NoopLoginService(),
        storage: InMemorySecureSessionStorage(),
      );
      notifier.debugSetState(const AuthSessionUnauthenticated());
      return MaterialApp(
        home: ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: screen,
        ),
      );
    }

    testWidgets('renders link on the login card', (tester) async {
      await tester.pumpWidget(
        wrap(
          screen: const LoginScreen(
            passwordResetGateway: DemoPasswordResetGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('login_forgot_password_link')),
        findsOneWidget,
      );
      expect(find.text('Forgot password?'), findsOneWidget);
      expect(
        find.byKey(const Key('login_forgot_password_button')),
        findsNothing,
      );
      expect(find.byKey(const Key('login_reset_link_hint')), findsNothing);
    });

    testWidgets('tapping the link navigates to PasswordResetRequestScreen', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          screen: const LoginScreen(
            passwordResetGateway: DemoPasswordResetGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('login_forgot_password_link')));
      await tester.pumpAndSettle();

      expect(find.byType(PasswordResetRequestScreen), findsOneWidget);
    });

    testWidgets('forwards typed email to the request screen as initial value', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          screen: const LoginScreen(
            passwordResetGateway: DemoPasswordResetGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('login_email_field')),
        'demo@forgeflow.test',
      );
      await tester.tap(find.byKey(const Key('login_forgot_password_link')));
      await tester.pumpAndSettle();

      final requestScreen = tester.widget<PasswordResetRequestScreen>(
        find.byType(PasswordResetRequestScreen),
      );
      expect(requestScreen.initialEmail, equals('demo@forgeflow.test'));
    });

    testWidgets(
      'AuthGate forwards passwordResetGateway into the LoginScreen so the '
      'production link is wired (regression for review finding P1)',
      (tester) async {
        const gateway = DemoPasswordResetGateway();
        final notifier = AuthSessionNotifier(
          loginService: const _NoopLoginService(),
          storage: InMemorySecureSessionStorage(),
        );
        notifier.debugSetState(const AuthSessionUnauthenticated());

        await tester.pumpWidget(
          MaterialApp(
            home: ChangeNotifierProvider<AuthSessionNotifier>.value(
              value: notifier,
              child: const AuthGate(
                authenticatedChild: SizedBox.shrink(),
                passwordResetGateway: gateway,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final login = tester.widget<LoginScreen>(find.byType(LoginScreen));
        expect(login.passwordResetGateway, same(gateway));
      },
    );
  });
}

class _NoopLoginService implements AuthLoginService {
  const _NoopLoginService();

  @override
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    return const AuthLoginFailure(code: 'noop', message: 'noop');
  }

  @override
  Future<AuthLoginResult> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    return const AuthLoginFailure(code: 'noop', message: 'noop');
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<AuthSession?> refreshSession(AuthSession current) async => current;

  @override
  Future<void> signOutThisSession() async {}

  @override
  Future<void> signOutAllSessions() async {}
}
