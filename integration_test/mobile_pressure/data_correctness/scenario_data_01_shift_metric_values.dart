// Lane E — Scenario 01: Shift dashboard shows real numeric values from demo seed.
//
// Wave 1 verified that ShiftDashboard mounts and renders section headers.
// This scenario goes further: MetricPill widgets must be present inside
// ShiftDashboard, and at least one must have a Text descendant containing a
// digit — proving the demo SQLite seed populated Shift data and the notifier
// rendered it (not all-dash / all-missing).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/widgets/metric_pill.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'data-01 — ShiftDashboard MetricPill cells show numeric values from demo seed',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Shift is tab 0; boot lands here. Wait for async SQLite load.
      await tapTab(tester, 0);
      await pumpUntilShiftSettled(tester);

      // MetricPill widgets must be present inside ShiftDashboard.
      final pillsInShift = find.descendant(
        of: find.byType(ShiftDashboard),
        matching: find.byType(MetricPill),
      );
      expect(
        pillsInShift,
        findsWidgets,
        reason:
            'No MetricPill found inside ShiftDashboard — data may not have '
            'loaded or the SHIFT OUTPUTS section is not rendered.',
      );

      // At least one pill must contain a Text descendant with a digit.
      // All-dash (—) output means the demo seed is absent for today's date.
      final numericInPills = find.descendant(
        of: pillsInShift,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.data != null &&
              RegExp(r'\d').hasMatch(w.data!),
        ),
      );
      expect(
        numericInPills,
        findsWidgets,
        reason:
            'All MetricPill values appear to be dashes (—). '
            'The demo seed may not cover today\'s date, or '
            'ShiftDashboardNotifier did not load.',
      );

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
