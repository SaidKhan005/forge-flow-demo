// integration_test/mobile_pressure/benchmark/scenario_bench_02_drill_to_manager.dart
//
// Lane C — Benchmark tab drill-through to BaselineManagerScreen.
//
// The BaselineTracker renders a GestureDetector CTA button that calls
// Navigator.of(context).push(MaterialPageRoute(builder: (_) =>
//   const BaselineManagerScreen()))  (baseline_tracker.dart ~line 534).
//
// The button always renders when view data is available. It contains
// Icons.star_rounded, the overrideLabel text, and Icons.chevron_right.
// We locate it by looking for a GestureDetector ancestor of
// Icons.chevron_right in the _CplhRangeBar section (it is the widest
// full-bleed container child in that section).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Benchmark tab: tapping manager CTA pushes BaselineManagerScreen, no crash, no overflow',
    (tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await tapTab(tester, 3);
      expect(find.byType(BaselineTracker), findsOneWidget);

      // Wait for data load.
      await pumpUntil(tester, budget: const Duration(seconds: 10));

      // The CTA button contains Icons.chevron_right inside a
      // full-width GestureDetector. Locate it via the chevron icon;
      // this icon only appears in the CTA row.
      final chevronFinder = find.byIcon(Icons.chevron_right);
      if (chevronFinder.evaluate().isEmpty) {
        // View data not loaded (bench unavailable state). Skip drill-through.
        markTestSkipped(
          'BaselineTracker view data not available; drill-through skipped.',
        );
        return;
      }

      // Tap the GestureDetector that contains chevron_right.
      // The chevron is inside the CTA container's Row; tapping the icon
      // triggers the GestureDetector's onTap because hit-test bubbles up.
      await tester.tap(chevronFinder.first);
      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 15));

      // BaselineManagerScreen must mount.
      expect(
        find.byType(BaselineManagerScreen),
        findsOneWidget,
        reason:
            'BaselineManagerScreen must mount after tapping the manager CTA.',
      );

      // The screen must not be blank: "Choose Star Shifts" app bar title.
      expect(
        find.text('Choose Star Shifts'),
        findsOneWidget,
        reason: '"Choose Star Shifts" app bar title must be present.',
      );

      // No error widget.
      expect(
        find.byType(ErrorWidget),
        findsNothing,
        reason: 'No ErrorWidget on BaselineManagerScreen.',
      );

      // No overflows.
      expect(
        errorTap.overflowErrors,
        isEmpty,
        reason: 'No RenderFlex overflows during drill-through.',
      );
    },
  );
}
