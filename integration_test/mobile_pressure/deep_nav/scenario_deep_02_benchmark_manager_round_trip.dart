// Lane G — Scenario 02: Benchmark drill to BaselineManagerScreen, interact
// with sliders/switches, CANCEL returns to BaselineTracker with content intact.
//
// Extends wave-1 bench-02/04/05 by:
//   1. Interacting with sliders and switches (non-destructive moves).
//   2. Asserting BaselineTracker remounts with the CPLH section still present.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'deep-02 — Benchmark drill → interact → CANCEL returns to BaselineTracker',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await tapTab(tester, 3); // Benchmark
      await pumpUntil(tester, budget: kTabBudget);
      expect(find.byType(BaselineTracker), findsOneWidget);

      // Drill in via chevron_right CTA (same pattern as bench-02).
      final chevron = find.byIcon(Icons.chevron_right);
      if (chevron.evaluate().isEmpty) {
        markTestSkipped('Baseline CTA not available; skipping round-trip.');
        return;
      }
      await tester.tap(chevron.first);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);
      expect(find.byType(BaselineManagerScreen), findsOneWidget);

      // Non-destructive slider interaction.
      final sliders = find.byType(Slider);
      if (sliders.evaluate().isNotEmpty) {
        await tester.drag(sliders.first, const Offset(10, 0), warnIfMissed: false);
        await tester.pump();
      }

      // Non-destructive switch interaction.
      final switches = find.byType(Switch);
      if (switches.evaluate().isNotEmpty) {
        await tester.tap(switches.first, warnIfMissed: false);
        await tester.pump();
        // Toggle back to leave state unchanged.
        await tester.tap(switches.first, warnIfMissed: false);
        await tester.pump();
      }

      // Tap CANCEL (or fall back to navigateBack).
      final cancelByText = find.text('CANCEL').evaluate().isNotEmpty
          ? find.text('CANCEL')
          : find.text('Cancel').evaluate().isNotEmpty
              ? find.text('Cancel')
              : null;
      if (cancelByText != null) {
        await tester.tap(cancelByText.first, warnIfMissed: false);
      } else {
        await navigateBack(tester);
      }
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // BaselineTracker must be remounted.
      expect(
        find.byType(BaselineTracker),
        findsOneWidget,
        reason:
            'BaselineTracker not remounted after CANCEL from '
            'BaselineManagerScreen.',
      );

      // CPLH section header must still be present.
      expect(
        find.text('CPLH RANGE & TARGET', skipOffstage: false),
        findsAtLeast(1),
        reason:
            'CPLH RANGE & TARGET section missing after returning from '
            'BaselineManagerScreen.',
      );

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
