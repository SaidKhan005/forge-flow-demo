// Lane H — Scenario 05: Plan tab re-entry after a Settings interruption loads
// cleanly without a stuck spinner or crash.
//
// Pattern: tap Plan (starts async load) -> immediately open Settings ->
// close Settings -> tap Plan again -> verify content loaded.
// This exercises the interplay between IndexedStack visibility changes and
// the async load that was in flight when Settings was opened.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/schedule_builder.dart';
import 'package:forge_and_flow/widgets/schedule_day_row.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'edge-05 — Plan tab re-entry after Settings interruption loads cleanly',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Tap Plan tab (starts async plan load).
      tester
          .widget<BottomNavigationBar>(
            find.byType(BottomNavigationBar).first,
          )
          .onTap
          ?.call(2); // Plan

      // Open Settings after a short delay — Plan load is still in flight.
      await tester.pump(const Duration(milliseconds: 80));
      await openSettings(tester);
      await pumpUntil(tester, budget: kTabBudget);

      // Close Settings.
      await navigateBack(tester);
      await expectAppShellMounted(tester);

      // Re-enter Plan tab.
      await tapTab(tester, 2);
      await pumpUntil(tester, budget: kTabBudget);
      await tester.pump(const Duration(seconds: 2));
      await pumpUntil(tester, budget: kTabBudget);

      // ScheduleBuilder must be present.
      expect(
        find.byType(ScheduleBuilder),
        findsOneWidget,
        reason: 'ScheduleBuilder not found on Plan tab after re-entry.',
      );

      // Some content must have loaded (section header or day rows).
      final hasContent =
          find.byType(ScheduleDayRow).evaluate().isNotEmpty ||
          find.text('LABOR PLAN', skipOffstage: false).evaluate().isNotEmpty ||
          find.text('DAY-BY-DAY PLAN', skipOffstage: false).evaluate().isNotEmpty;
      expect(
        hasContent,
        isTrue,
        reason:
            'Plan tab shows no content after re-entry — ScheduleBuilder '
            'may be stuck in a loading state.',
      );

      expect(
        tap.all,
        isEmpty,
        reason:
            'Exceptions thrown during Plan tab re-entry:\n'
            '${tap.all.map((e) => e.exceptionAsString()).join('\n')}',
      );
      expect(tap.overflowErrors, isEmpty);
    },
  );
}
