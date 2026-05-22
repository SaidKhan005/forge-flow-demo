// integration_test/mobile_pressure/variance/scenario_variance_04_learn_tab.dart
//
// Lane B Scenario Variance-04 — Learn tab assertions.
//
// Asserts:
//  - LearnTab widget is mounted after tapping the Learn tab.
//  - The content area is non-empty (at least one non-empty Text widget).
//  - No RenderFlex overflows, no exceptions.
//
// Source: lib/screens/variance/variance_learn_tab.dart
//   - LearnTab class (line 35)
//   - Uses FutureBuilder wrapping _LearnData from ShiftDataSource.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/variance_report.dart';
import 'package:forge_and_flow/screens/variance/variance_learn_tab.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'variance-04 — Learn tab mounts and content area is non-empty; no overflow',
    (WidgetTester tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);
      await tapTab(tester, 1);

      expect(find.byType(VarianceReport), findsOneWidget);

      // Tap Learn tab.
      await tester.tap(find.text('Learn').first);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // LearnTab widget must be mounted.
      expect(
        find.byType(LearnTab),
        findsOneWidget,
        reason: 'LearnTab widget not found after tapping Learn tab.',
      );

      // No stuck spinner.
      expect(
        find.byType(CircularProgressIndicator).hitTestable().evaluate(),
        isEmpty,
        reason: 'Learn tab spinner still hitTestable after kTabBudget.',
      );

      // No ErrorWidget.
      expect(
        find.byType(ErrorWidget),
        findsNothing,
        reason: 'ErrorWidget is in the tree — Learn tab threw.',
      );

      // Content area is non-empty — at least one Text with > 0 chars.
      final nonEmptyTexts = find
          .byType(Text)
          .evaluate()
          .where((e) {
            final w = e.widget as Text;
            return (w.data ?? w.textSpan?.toPlainText() ?? '').trim().isNotEmpty;
          })
          .toList();
      expect(
        nonEmptyTexts.length,
        greaterThan(0),
        reason: 'Learn tab has no non-empty Text widgets — appears blank.',
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
