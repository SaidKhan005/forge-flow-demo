// Lane G — Scenario 05: Rapid tab switches during async loads do not crash.
//
// Taps Variance (triggers WeekDataNotifier async SQLite load), then
// immediately switches to Plan, then Benchmark — all before the earlier
// tabs finish loading. Exercises the dispose guards added in wave-1 triage
// under real concurrent pressure.
//
// Round 1: Variance -> Plan -> Benchmark (forward)
// Round 2: Plan -> Variance -> Shift (reverse)
// After each round, the final tab must be loaded and no exceptions thrown.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/baseline_tracker.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'deep-05 — rapid tab switches during async loads do not crash',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      BottomNavigationBar getBar() =>
          tester.widget<BottomNavigationBar>(
            find.byType(BottomNavigationBar).first,
          );

      // Round 1: Variance -> Plan -> Benchmark in quick succession.
      getBar().onTap?.call(1); // Variance — starts async load
      await tester.pump(const Duration(milliseconds: 50));
      getBar().onTap?.call(2); // Plan — before Variance finishes
      await tester.pump(const Duration(milliseconds: 50));
      getBar().onTap?.call(3); // Benchmark — before Plan finishes
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // Benchmark must have settled without crash.
      expect(
        find.byType(BaselineTracker),
        findsOneWidget,
        reason: 'BaselineTracker not found after round-1 rapid tab switching.',
      );

      // Round 2: Plan -> Variance -> Shift (reverse order).
      getBar().onTap?.call(2);
      await tester.pump(const Duration(milliseconds: 50));
      getBar().onTap?.call(1);
      await tester.pump(const Duration(milliseconds: 50));
      getBar().onTap?.call(0);
      await tester.pump();
      await pumpUntilShiftSettled(tester);

      // No exceptions from any dispose-guarded notifier across either round.
      expect(
        tap.all,
        isEmpty,
        reason:
            'Exceptions thrown during rapid tab switching:\n'
            '${tap.all.map((e) => e.exceptionAsString()).join('\n')}',
      );
      expect(tap.overflowErrors, isEmpty);
    },
  );
}
