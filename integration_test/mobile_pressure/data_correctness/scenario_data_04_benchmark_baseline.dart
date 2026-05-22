// Lane E — Scenario 04: BaselineTracker renders CPLH decimal values from seed.
//
// Wave 1 verified BaselineTracker mounts with section headers. This scenario
// asserts that the CPLH range bar shows at least one decimal-format number
// (nn.nn pattern from toStringAsFixed(2)), confirming the baseline seed loaded.
// If the seed is absent, all values show the honest-missing sentinel (—).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/baseline_tracker.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'data-04 — BaselineTracker CPLH range shows decimal values from baseline seed',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await tapTab(tester, 3); // Benchmark
      await pumpUntil(tester, budget: kTabBudget);

      expect(find.byType(BaselineTracker), findsOneWidget);

      // Section header must be present.
      expect(
        find.text('CPLH RANGE & TARGET', skipOffstage: false),
        findsAtLeast(1),
        reason: 'CPLH RANGE & TARGET section header not found on BaselineTracker.',
      );

      // The _CplhRangeBar renders values via toStringAsFixed(2).
      // We look for any Text matching nn.nn inside the BaselineTracker subtree.
      final decimalValues = find.descendant(
        of: find.byType(BaselineTracker),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.data != null &&
              RegExp(r'^\d+\.\d{2}$').hasMatch(w.data!.trim()),
        ),
      );
      expect(
        decimalValues,
        findsWidgets,
        reason:
            'No decimal CPLH values found in BaselineTracker. '
            'The baseline seed may not be loaded (all values showing —).',
      );

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
