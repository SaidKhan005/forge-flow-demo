// Lane E — Scenario 03: ScheduleBuilder shows day rows with numeric hour values.
//
// Wave 1 verified ScheduleBuilder mounts with section headers and expand/collapse.
// This scenario asserts that ScheduleDayRow widgets are present and that at
// least one row contains a pure-integer value — confirming the weekly plan
// seed loaded its required hours data.
//
// ScheduleDayRow renders requiredFohHours / requiredBohHours as plain integers
// via .toString() with no suffix (e.g. "12", not "12h").

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/schedule_builder.dart';
import 'package:forge_and_flow/widgets/schedule_day_row.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'data-03 — ScheduleBuilder day rows contain numeric hour values from plan seed',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await tapTab(tester, 2); // Plan
      await pumpUntil(tester, budget: kTabBudget);
      // Extra pump to allow the SQLite plan load to complete.
      await tester.pump(const Duration(seconds: 2));
      await pumpUntil(tester, budget: kTabBudget);

      expect(find.byType(ScheduleBuilder), findsOneWidget);

      // ScheduleDayRow widgets must be present (at least one per day of the week).
      expect(
        find.byType(ScheduleDayRow),
        findsWidgets,
        reason:
            'No ScheduleDayRow widgets found — ScheduleBuilder may not have '
            'loaded the weekly plan from the demo seed.',
      );

      // At least one row must show a pure-integer value (plain int toString).
      final numericInRows = find.descendant(
        of: find.byType(ScheduleDayRow),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.data != null &&
              RegExp(r'^\d+$').hasMatch(w.data!.trim()),
        ),
      );
      expect(
        numericInRows,
        findsWidgets,
        reason:
            'All ScheduleDayRow hour cells show zero or blank. '
            'The weekly plan seed may not contain required-hours data.',
      );

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
