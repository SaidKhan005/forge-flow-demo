// integration_test/mobile_pressure/shell/scenario_shell_04_rapid_nav_stress.dart
//
// Lane A — Scenario Shell-04: Rapid tab switching stress test.
//
// Simulates rapid bottom-nav tab switching cycling through all 4 tabs
// 15 times with minimal pump between each switch. After the cycle,
// fully settles the widget tree and verifies all 4 widgets are still
// reachable and the app is in a usable state.
//
// This test specifically guards against:
//   - State corruption from rapid IndexedStack switching.
//   - Provider read failures under rapid rebuild pressure.
//   - Timer/stream leaks that accumulate and cause slowdown.
//   - The CrashReporter recursive-freeze regression (PR #754) under load.
//
// Verifies:
//   - 15 rapid tab switches complete without exception.
//   - All 4 screen widgets are reachable after the stress cycle.
//   - BottomNavigationBar is still mounted (app is usable).
//   - No errors in FlutterErrorTap.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/screens/variance_report.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';
import 'package:forge_and_flow/screens/baseline_tracker.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Shell-04: 15 rapid tab switches do not crash or freeze',
    (tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Perform 15 rapid tab switches cycling 0→1→2→3→0→1→2→3→…
      // Minimal pump between each: just tester.pump() with no settle.
      final bars = find.byType(BottomNavigationBar);
      expect(bars, findsAtLeast(1), reason: 'BottomNavigationBar not mounted before stress cycle.');
      final bar = tester.widget<BottomNavigationBar>(bars.first);

      for (int i = 0; i < 15; i++) {
        final tabIndex = i % 4;
        bar.onTap?.call(tabIndex);
        // Single pump only — this is the stress: no full settle between taps.
        await tester.pump();
      }

      // After the rapid cycle, pump fully until settled.
      await pumpUntil(tester, budget: kBootBudget);

      // All 4 screen widgets must still be reachable.
      // (IndexedStack keeps them all alive; we verify by tapping each tab.)
      await tapTab(tester, 0);
      expect(
        find.byType(ShiftDashboard),
        findsOneWidget,
        reason: 'ShiftDashboard must survive rapid tab stress cycle.',
      );

      await tapTab(tester, 1);
      expect(
        find.byType(VarianceReport),
        findsOneWidget,
        reason: 'VarianceReport must survive rapid tab stress cycle.',
      );

      await tapTab(tester, 2);
      expect(
        find.byType(ScheduleBuilder),
        findsOneWidget,
        reason: 'ScheduleBuilder must survive rapid tab stress cycle.',
      );

      await tapTab(tester, 3);
      expect(
        find.byType(BaselineTracker),
        findsOneWidget,
        reason: 'BaselineTracker must survive rapid tab stress cycle.',
      );

      // BottomNavigationBar must still be present (app is usable).
      expect(
        find.byType(BottomNavigationBar),
        findsAtLeast(1),
        reason: 'BottomNavigationBar missing after stress cycle — app may be in broken state.',
      );

      // No errors accumulated during the stress cycle.
      expect(
        errorTap.all,
        isEmpty,
        reason:
            'Flutter errors during rapid tab stress: '
            '${errorTap.all.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
