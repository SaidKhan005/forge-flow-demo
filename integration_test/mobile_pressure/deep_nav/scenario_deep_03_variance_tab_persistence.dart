// Lane G — Scenario 03: Variance sub-tabs survive a round-trip to Shift and back.
//
// After visiting This Week -> History -> Learn on the Variance TabBar,
// navigating away to Shift, and returning, at least one sub-tab label must
// be visible and no crash must have occurred.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/variance_report.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'deep-03 — Variance sub-tabs survive round-trip to Shift and back',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Navigate to Variance and visit all three sub-tabs.
      await tapTab(tester, 1); // Variance
      await pumpUntil(tester, budget: kTabBudget);
      expect(find.byType(VarianceReport), findsOneWidget);

      final historyTab = find.text('History');
      if (historyTab.evaluate().isNotEmpty) {
        await tester.tap(historyTab.first, warnIfMissed: false);
        await tester.pump();
        await pumpUntil(tester, budget: kTabBudget);
      }

      final learnTab = find.text('Learn');
      if (learnTab.evaluate().isNotEmpty) {
        await tester.tap(learnTab.first, warnIfMissed: false);
        await tester.pump();
        await pumpUntil(tester, budget: kTabBudget);
      }

      // Navigate away to Shift.
      await tapTab(tester, 0);
      await pumpUntilShiftSettled(tester);

      // Return to Variance.
      await tapTab(tester, 1);
      await pumpUntil(tester, budget: kTabBudget);

      // At least one sub-tab label must be visible (Variance loaded).
      final hasAnyTab =
          find.text('This Week').evaluate().isNotEmpty ||
          find.text('History').evaluate().isNotEmpty ||
          find.text('Learn').evaluate().isNotEmpty;
      expect(
        hasAnyTab,
        isTrue,
        reason:
            'No Variance sub-tab label visible after returning from Shift. '
            'VarianceReport may have crashed or failed to reload.',
      );

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
