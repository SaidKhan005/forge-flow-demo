// integration_test/mobile_pressure/variance/scenario_variance_02_this_week_deep.dart
//
// Lane B Scenario Variance-02 — This Week tab deep assertions.
//
// Goes beyond mount-check:
//  - Asserts specific section labels the tab always renders when data exists.
//  - Taps InkWells found in the tab body, asserts no crash.
//  - Scrolls to the bottom of the tab's CustomScrollView.
//  - Asserts no stuck loading indicator.
//  - No RenderFlex overflows.
//
// Source: lib/screens/variance/variance_this_week_tab.dart
//   - 'PRIMARY DRIVER' section header (line 265)
//   - 'FULL WEEK PROJECTION' section header (line 359)
//   - 'This Week' sub-header text (line 228)
//   - Empty-state strings: kVarianceNoDataEmptyCopy, kVarianceWeekStartEmptyCopy

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/variance_report.dart';
import 'package:forge_and_flow/screens/variance/variance_this_week_tab.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'variance-02 — This Week tab renders metric content and survives scroll + taps',
    (WidgetTester tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);
      await tapTab(tester, 1);

      expect(find.byType(VarianceReport), findsOneWidget);

      // Ensure we are on This Week tab.
      await tester.tap(find.text('This Week').first);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // ThisWeekTab widget must be present.
      expect(
        find.byType(ThisWeekTab),
        findsOneWidget,
        reason: 'ThisWeekTab widget not found after tapping This Week tab.',
      );

      // No stuck spinner.
      expect(
        find.byType(CircularProgressIndicator).hitTestable().evaluate(),
        isEmpty,
        reason: 'This Week tab spinner is still hitTestable.',
      );

      // The tab is in one of two valid states: content or empty.
      final hasPrimaryDriver =
          find.text('PRIMARY DRIVER').evaluate().isNotEmpty;
      final hasFullWeekProjection =
          find.text('FULL WEEK PROJECTION').evaluate().isNotEmpty;
      final hasThisWeekSubHeader =
          find.text('This Week').evaluate().length > 1;
      final hasContent =
          hasPrimaryDriver || hasFullWeekProjection || hasThisWeekSubHeader;

      final hasEmptyNoData =
          find.text('No closed shifts yet.').evaluate().isNotEmpty;
      final hasEmptyNewWeek = find
          .text('New week, nothing closed yet. Check back after the first shift closes.')
          .evaluate()
          .isNotEmpty;
      final hasEmpty = hasEmptyNoData || hasEmptyNewWeek;

      expect(
        hasContent || hasEmpty,
        isTrue,
        reason:
            'This Week tab shows neither recognised content labels nor a '
            'known empty-state string.',
      );

      if (hasContent) {
        // Tap any InkWell in the tab body (e.g. StickyDisclosureSection
        // expand/collapse headers are InkWells). Assert no crash.
        final inkwells = find.byType(InkWell).evaluate().toList();
        for (int i = 0; i < inkwells.length && i < 3; i++) {
          final el = inkwells[i];
          if (el.mounted) {
            await tester.tap(find.byWidget(el.widget), warnIfMissed: false);
            await tester.pump();
            await pumpUntil(tester, budget: const Duration(seconds: 5));
          }
        }

        // Scroll to the bottom of the CustomScrollView.
        final scrollViews = find.byType(CustomScrollView);
        if (scrollViews.evaluate().isNotEmpty) {
          await tester.drag(scrollViews.first, const Offset(0, -5000));
          await tester.pump();
          await pumpUntil(tester, budget: kTabBudget);

          // Scroll back to top.
          await tester.drag(scrollViews.first, const Offset(0, 5000));
          await tester.pump();
          await pumpUntil(tester, budget: kTabBudget);
        }
      }

      // No RenderFlex overflows.
      expect(
        errorTap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflows:\n'
            '${errorTap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
