// integration_test/mobile_pressure/plan/scenario_plan_02_interactions.dart
//
// Lane C — Plan tab interaction exercise.
//
// The ScheduleBuilder body has one interactive element: the _DayTable
// rows, each wrapped in a GestureDetector that expands/collapses daypart
// subrows. We tap the first available day row (if any data is present),
// assert the tree does not crash, assert the expand_more/expand_less icon
// toggles, then collapse it. The CustomScrollView scroll path is also
// exercised.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/schedule_builder.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Plan tab: day-row expand/collapse and scroll do not crash or overflow',
    (tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await tapTab(tester, 2);

      expect(find.byType(ScheduleBuilder), findsOneWidget);

      // Pump to let plan data load (or surface its unavailable state).
      await pumpUntil(tester, budget: const Duration(seconds: 10));

      // ── Try tapping expand_more icons (day rows with subrows) ──────────
      //
      // The _DayTable wraps each row in a GestureDetector when hasSubrows
      // is true, and the trailing icon is Icons.expand_more.
      final expandMoreFinder = find.byIcon(Icons.expand_more);
      if (expandMoreFinder.evaluate().isNotEmpty) {
        // The first expand icon may be below the fold (y > screen height).
        // Scroll it into the viewport before tapping.
        await tester.ensureVisible(expandMoreFinder.first);
        await tester.pump();
        // Tap the first expandable row.
        await tester.tap(expandMoreFinder.first, warnIfMissed: false);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 3));

        // Assert no error widget appeared.
        expect(
          find.byType(ErrorWidget),
          findsNothing,
          reason: 'No ErrorWidget after tapping expand_more.',
        );

        // The row should now show expand_less.
        final expandLessFinder = find.byIcon(Icons.expand_less);
        expect(
          expandLessFinder,
          findsAtLeast(1),
          reason: 'expand_less icon expected after expanding a day row.',
        );

        // Collapse by tapping expand_less.
        await tester.ensureVisible(expandLessFinder.first);
        await tester.pump();
        await tester.tap(expandLessFinder.first, warnIfMissed: false);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 3));

        expect(
          find.byType(ErrorWidget),
          findsNothing,
          reason: 'No ErrorWidget after tapping expand_less.',
        );
      }

      // ── Scroll the CustomScrollView ────────────────────────────────────
      //
      // The ScheduleBuilder body is a CustomScrollView. Drag down to
      // expose lower slivers (DAY-BY-DAY PLAN section).
      final scrollFinder = find.byType(CustomScrollView).first;
      await tester.drag(scrollFinder, const Offset(0, -300));
      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 3));

      expect(
        find.byType(ErrorWidget),
        findsNothing,
        reason: 'No ErrorWidget after scrolling Plan view.',
      );

      // ScheduleBuilder still in tree (no unexpected navigation).
      expect(find.byType(ScheduleBuilder), findsOneWidget);

      // No overflows throughout.
      expect(
        errorTap.overflowErrors,
        isEmpty,
        reason: 'No RenderFlex overflows during Plan interactions.',
      );
    },
  );
}
