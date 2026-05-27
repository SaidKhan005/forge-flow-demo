// integration_test/mobile_pressure/auth/scenario_auth_01_demo_login.dart
//
// Lane A — Scenario Auth-01: Cold boot end-to-end demo login flow.
//
// Verifies: login screen is displayed on cold boot, demo-operator button
// is tappable, AppShell mounts, DemoModeBanner is in tree, BottomNav
// has 5 items (Shift, Variance, Plan, Benchmark, Advisor — the 5th was
// added by Slice D2 mobile, commit abc4da72), no RenderFlex overflows,
// and ShiftDashboard is the active tab on index 0 after login.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/main_forgeflow.dart' as ff_app;
import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/screens/auth/login_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Auth-01: cold boot shows login screen, demo tap mounts AppShell on Shift tab',
    (tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      if (!kDemoMode) {
        throw StateError(
          'Mobile pressure suite requires --dart-define=kDemoMode=true.',
        );
      }

      // Boot the app — partially settle so we can observe the login screen
      // before the demo tap completes.
      await ff_app.main();
      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 20));

      // Assertion 1: LoginScreen OR demo button key must be present
      // before we complete the login flow.
      final hasLoginScreen = find.byType(LoginScreen).evaluate().isNotEmpty;
      final hasDemoButton =
          find
              .byKey(const Key('login_demo_operator_button'))
              .evaluate()
              .isNotEmpty;
      expect(
        hasLoginScreen || hasDemoButton,
        isTrue,
        reason:
            'Expected LoginScreen or demo-operator button to be present '
            'on cold boot in demo mode, but found neither.',
      );

      // Tap demo button if present; pump to settle login.
      final demoKey = find.byKey(const Key('login_demo_operator_button'));
      if (demoKey.evaluate().isNotEmpty) {
        await tester.tap(demoKey);
        await tester.pump();
        await pumpUntil(tester, budget: kLoginBudget);
      }

      // Assertion 2: AppShell mounts within budget.
      await expectAppShellMounted(tester);

      // Assertion 3: DemoModeBanner is in the tree.
      expectDemoBanner();

      // Assertion 4: BottomNavigationBar with 5 items.
      // The 5th tab (Advisor) was added by Slice D2 mobile in
      // commit abc4da72; see lib/screens/advisor/advisor_mobile_chat_nav.dart
      // (`kAdvisorMobileNavItem`) and lib/forge_flow_app.dart:1727-1748.
      final bars = find.byType(BottomNavigationBar);
      expect(bars, findsAtLeast(1), reason: 'BottomNavigationBar not mounted.');
      final bar = tester.widget<BottomNavigationBar>(bars.first);
      expect(
        bar.items.length,
        equals(5),
        reason:
            'Expected 5 bottom nav items '
            '(Shift, Variance, Plan, Benchmark, Advisor).',
      );

      // Assertion 5: ShiftDashboard is visible (index 0 is active by default).
      expect(
        find.byType(ShiftDashboard),
        findsOneWidget,
        reason: 'ShiftDashboard should be visible on tab index 0 after login.',
      );

      // Assertion 6: No RenderFlex overflows on boot/login path.
      expect(
        errorTap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflows detected on cold boot: '
            '${errorTap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
