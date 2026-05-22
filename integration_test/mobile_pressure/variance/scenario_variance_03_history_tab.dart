// integration_test/mobile_pressure/variance/scenario_variance_03_history_tab.dart
//
// Lane B Scenario Variance-03 — History tab deep assertions.
//
// Asserts:
//  - HistoryTab widget is in the tree after tapping the History tab.
//  - Some content is visible (not blank).
//  - Scrolls down then back up — no exception.
//  - No RenderFlex overflow.
//
// Source: lib/screens/variance/variance_history_tab.dart
//   - HistoryTab class (line 142)
//   - 'Previous Weeks' sub-header text (line 332)
//   - 'CPLH VS YOUR OPZ · 60-DAY' pinned header (line 361)
//   - 'Error loading history.' error string (line 241-244)
//   - _HistoryData with weeks / patternRecords

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/variance_report.dart';
import 'package:forge_and_flow/screens/variance/variance_history_tab.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'variance-03 — History tab mounts and renders content; scroll works; no overflow',
    (WidgetTester tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);
      await tapTab(tester, 1);

      expect(find.byType(VarianceReport), findsOneWidget);

      // Tap History tab.
      await tester.tap(find.text('History').first);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // HistoryTab widget must be mounted.
      expect(
        find.byType(HistoryTab),
        findsOneWidget,
        reason: 'HistoryTab widget not found after tapping History tab.',
      );

      // No stuck spinner.
      expect(
        find.byType(CircularProgressIndicator).hitTestable().evaluate(),
        isEmpty,
        reason: 'History tab spinner still hitTestable.',
      );

      // Not showing an error.
      expect(
        find.text('Error loading history.'),
        findsNothing,
        reason: 'History tab is showing an error state.',
      );

      // Some content is visible — at minimum the 'Previous Weeks' sub-header
      // or the CPLH band header, or at least multiple non-empty Text widgets.
      final hasPreviousWeeksHeader =
          find.text('Previous Weeks').evaluate().isNotEmpty;
      final hasCplhHeader =
          find.text('CPLH VS YOUR OPZ · 60-DAY').evaluate().isNotEmpty;
      final nonEmptyTextCount = find
          .byType(Text)
          .evaluate()
          .where((e) {
            final w = e.widget as Text;
            return (w.data ?? w.textSpan?.toPlainText() ?? '').trim().isNotEmpty;
          })
          .length;

      expect(
        hasPreviousWeeksHeader || hasCplhHeader || nonEmptyTextCount > 2,
        isTrue,
        reason:
            'History tab shows no recognisable content. Possible empty data '
            'or structural change.',
      );

      // Scroll down then back up.
      final scrollViews = find.byType(CustomScrollView);
      if (scrollViews.evaluate().isNotEmpty) {
        await tester.drag(scrollViews.first, const Offset(0, -3000));
        await tester.pump();
        await pumpUntil(tester, budget: kTabBudget);

        await tester.drag(scrollViews.first, const Offset(0, 3000));
        await tester.pump();
        await pumpUntil(tester, budget: kTabBudget);
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
