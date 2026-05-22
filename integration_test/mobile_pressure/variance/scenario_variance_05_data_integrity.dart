// integration_test/mobile_pressure/variance/scenario_variance_05_data_integrity.dart
//
// Lane B Scenario Variance-05 — This Week tab data integrity.
//
// Asserts that the Variance > This Week tab:
//  - Is NOT showing a pure error state (no ErrorWidget, no
//    'Something went wrong' copy).
//  - SOME numeric text appears in the tab body (proves demo seed
//    populated real data through the variance read model).
//  - No metric value is shown as 'NaN' or 'null' as displayed text.
//  - No RenderFlex overflows.
//
// Source: lib/screens/variance/variance_this_week_tab.dart
//   - kVarianceNoDataEmptyCopy = 'No closed shifts yet.'
//   - kVarianceWeekStartEmptyCopy = 'New week, nothing closed yet...'
//   - _ThisWeekHero renders dollar amounts and % strings
//   - _WtdTable renders numeric Covers/hours/CPLH/SPLH/PPA values

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/variance_report.dart';
import 'package:forge_and_flow/screens/variance/variance_this_week_tab.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'variance-05 — This Week tab data integrity: numbers present, no NaN/null text, no error',
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

      expect(find.byType(ThisWeekTab), findsOneWidget);

      // No ErrorWidget.
      expect(
        find.byType(ErrorWidget),
        findsNothing,
        reason: 'ErrorWidget in tree — This Week tab threw.',
      );

      // No 'Something went wrong' copy.
      expect(
        find.textContaining('Something went wrong'),
        findsNothing,
        reason: "Found 'Something went wrong' — error state displayed.",
      );

      // When the tab has data (not empty), assert numerics are present.
      final hasEmptyNoData =
          find.text('No closed shifts yet.').evaluate().isNotEmpty;
      final hasEmptyNewWeek = find
          .text(
            'New week, nothing closed yet. Check back after the first shift closes.',
          )
          .evaluate()
          .isNotEmpty;

      if (!hasEmptyNoData && !hasEmptyNewWeek) {
        // Should have real content — look for numeric text.
        final numericTexts = find
            .byType(Text)
            .evaluate()
            .where((e) {
              final w = e.widget as Text;
              final s = w.data ?? w.textSpan?.toPlainText() ?? '';
              // Match $12.34, 1234, 12.3%, etc.
              return RegExp(r'\$?\d+\.?\d*').hasMatch(s);
            })
            .toList();
        expect(
          numericTexts.length,
          greaterThan(0),
          reason:
              'This Week tab shows content labels but no numeric values. '
              'The demo seed may not have written week_records rows.',
        );
      }

      // No displayed 'NaN' text.
      final nanTexts = find
          .byType(Text)
          .evaluate()
          .where((e) {
            final w = e.widget as Text;
            return (w.data ?? '').contains('NaN');
          })
          .toList();
      expect(
        nanTexts,
        isEmpty,
        reason:
            'A Text widget displays "NaN" — a metric calculation produced '
            'an invalid result.',
      );

      // No displayed 'null' as literal text.
      final nullTexts = find
          .byType(Text)
          .evaluate()
          .where((e) {
            final w = e.widget as Text;
            return (w.data ?? '') == 'null';
          })
          .toList();
      expect(
        nullTexts,
        isEmpty,
        reason:
            'A Text widget displays the literal string "null" — a nullable '
            'metric was rendered without a null guard.',
      );

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
