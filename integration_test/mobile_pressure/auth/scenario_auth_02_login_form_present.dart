// integration_test/mobile_pressure/auth/scenario_auth_02_login_form_present.dart
//
// Lane A — Scenario Auth-02: Login form elements are present.
//
// Verifies: all required form widget keys are present on the login
// screen before demo-operator tap, and the login screen is no longer
// in the tree after a successful demo login.
//
// Keys asserted (all defined in lib/screens/auth/login_screen.dart):
//   login_email_field, login_password_field, login_submit_button,
//   login_demo_operator_button, login_forgot_password_link.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/main_forgeflow.dart' as ff_app;
import 'package:forge_and_flow/screens/auth/login_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Auth-02: login form has all required keys; LoginScreen absent after demo login',
    (tester) async {
      if (!kDemoMode) {
        throw StateError(
          'Mobile pressure suite requires --dart-define=kDemoMode=true.',
        );
      }

      // Boot the app and wait for the login screen to appear.
      await ff_app.main();
      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 20));

      // --- Pre-login assertions ---

      // LoginScreen widget must be in the tree.
      expect(
        find.byType(LoginScreen),
        findsOneWidget,
        reason: 'LoginScreen should be the initial route in demo mode.',
      );

      // All required form keys must be present.
      expect(
        find.byKey(const Key('login_email_field')),
        findsOneWidget,
        reason: 'login_email_field key not found in LoginScreen.',
      );
      expect(
        find.byKey(const Key('login_password_field')),
        findsOneWidget,
        reason: 'login_password_field key not found in LoginScreen.',
      );
      expect(
        find.byKey(const Key('login_submit_button')),
        findsOneWidget,
        reason: 'login_submit_button key not found in LoginScreen.',
      );
      expect(
        find.byKey(const Key('login_demo_operator_button')),
        findsOneWidget,
        reason:
            'login_demo_operator_button key not found — either the demo '
            'button is missing or the build was not compiled with '
            '--dart-define=kDemoMode=true.',
      );
      expect(
        find.byKey(const Key('login_forgot_password_link')),
        findsOneWidget,
        reason: 'login_forgot_password_link key not found in LoginScreen.',
      );

      // --- Perform demo login ---
      await tester.tap(find.byKey(const Key('login_demo_operator_button')));
      await tester.pump();
      await pumpUntil(tester, budget: kLoginBudget);

      // AppShell must mount after successful demo login.
      await expectAppShellMounted(tester);

      // --- Post-login assertion ---
      // LoginScreen must be gone from the tree (AuthGate swapped it out).
      expect(
        find.byType(LoginScreen),
        findsNothing,
        reason:
            'LoginScreen should not be in the tree after successful '
            'demo-operator sign-in; AuthGate should have replaced it with AppShell.',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
