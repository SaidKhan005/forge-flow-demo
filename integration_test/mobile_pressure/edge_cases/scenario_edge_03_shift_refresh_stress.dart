// Lane H — Scenario 03: Three rapid pull-to-refresh gestures on ShiftDashboard
// do not cause a use-after-dispose crash.
//
// ShiftDashboard wraps its CustomScrollView in a RefreshIndicator that calls
// refreshBoth(), which concurrently refreshes ShiftDashboardNotifier and
// ShiftServicePeriodNotifier. Rapid back-to-back refreshes exercise the
// dispose guards added in wave-1 triage (both notifiers are guarded).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/shift_dashboard.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'edge-03 — 3 rapid pull-to-refresh gestures do not crash ShiftDashboard',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await tapTab(tester, 0); // Shift
      await pumpUntilShiftSettled(tester);

      final shiftScrollViews = find.descendant(
        of: find.byType(ShiftDashboard),
        matching: find.byType(CustomScrollView),
      );

      // Three rapid pull-to-refresh gestures.
      // Drag downward (positive y) to trigger the RefreshIndicator overscroll.
      for (var i = 0; i < 3; i++) {
        if (shiftScrollViews.evaluate().isEmpty) break;
        await tester.drag(
          shiftScrollViews.first,
          const Offset(0, 400),
          warnIfMissed: false,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      // Wait for all in-flight refreshes to complete.
      await pumpUntil(tester, budget: const Duration(seconds: 15));

      // ShiftDashboard must still be mounted — no crash from dispose race.
      expectShiftDashboard();

      // No exceptions from the dispose-guarded notifiers.
      expect(
        tap.all,
        isEmpty,
        reason:
            'Exceptions thrown during rapid pull-to-refresh:\n'
            '${tap.all.map((e) => e.exceptionAsString()).join('\n')}',
      );
      expect(tap.overflowErrors, isEmpty);
    },
  );
}
