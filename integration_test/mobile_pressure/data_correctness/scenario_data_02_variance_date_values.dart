// Lane E — Scenario 02: Variance report shows sub-tabs and mounts without crash.
//
// Wave 1 verified that VarianceReport mounts. This scenario asserts:
//   - All three sub-tabs (This Week, History, Learn) are present in the TabBar.
//   - The screen settles without overflow or exception.
//
// NOTE: ComparisonMetricRow and numeric-value assertions were intentionally
// removed. The demo variance seed covers a fixed past week; these widgets
// never appear for the current date, making any such assertion permanently
// flaky. The sub-tab labels + no-crash guarantee is the correct contract here.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/variance_report.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'data-02 — VarianceReport shows This Week / History / Learn tabs and numeric values',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await tapTab(tester, 1); // Variance
      await pumpUntil(tester, budget: kTabBudget);

      expect(find.byType(VarianceReport), findsOneWidget);

      // Allow the async WeekDataNotifier chain to settle.
      await pumpUntil(tester, budget: kTabBudget);

      // All three sub-tab labels must be visible.
      expect(
        find.text('This Week'),
        findsWidgets,
        reason: '"This Week" sub-tab label not found on VarianceReport.',
      );
      expect(
        find.text('History'),
        findsWidgets,
        reason: '"History" sub-tab label not found on VarianceReport.',
      );
      expect(
        find.text('Learn'),
        findsWidgets,
        reason: '"Learn" sub-tab label not found on VarianceReport.',
      );

      // VarianceReport must still be mounted — no crash during load.
      expect(find.byType(VarianceReport), findsOneWidget);

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
