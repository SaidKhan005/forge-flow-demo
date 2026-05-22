// integration_test/mobile_pressure/shift/scenario_shift_02_daypart_interactions.dart
//
// Lane B Scenario Shift-02 — daypart period selector interactions.
//
// The shift dashboard renders a _ShiftPeriodSelector strip with InkWell-
// backed _PeriodPill widgets: "Whole Day" + one pill per configured
// service period. This scenario taps each pill (via its InkWell), asserts
// no crash, then scrolls the primary CustomScrollView to the bottom and
// back to the top — asserting no exception at any step.
//
// Source references:
//   lib/screens/shift_dashboard.dart:1854-1875 — _ShiftPeriodSelector / _PeriodPill
//   lib/screens/shift_dashboard.dart:1916-1917 — InkWell(onTap: onTap)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/shift_dashboard.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'shift-02 — period selector pills are tappable; scroll works; no crash',
    (WidgetTester tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);
      await tapTab(tester, 0);

      expect(
        find.byType(ShiftDashboard),
        findsOneWidget,
        reason: 'ShiftDashboard must be mounted before interacting.',
      );

      // Only interact with the period selector when the dashboard has data
      // (i.e., not in empty-state, where _ShiftPeriodSelector is absent).
      final hasOutputsHeader =
          find.text('SHIFT OUTPUTS').evaluate().isNotEmpty;
      if (!hasOutputsHeader) {
        // Empty state — no period selector to tap. Verify empty state has a
        // human-readable message and call it a pass.
        final hasAnyText = find
            .byType(Text)
            .evaluate()
            .where((e) {
              final w = e.widget as Text;
              return (w.data ?? '').trim().isNotEmpty;
            })
            .isNotEmpty;
        expect(hasAnyText, isTrue,
            reason: 'Empty-state shows no text at all.');
        return;
      }

      // ── Tap each InkWell in the period selector strip ────────────────────
      // _PeriodPill renders an InkWell whose onTap is () => onChanged(id).
      // We collect all InkWells that are descendants of the
      // SingleChildScrollView inside the period selector container.
      // Because the selector is a horizontal SingleChildScrollView we find
      // all InkWells in the whole tree and tap the first few (Whole Day +
      // service periods). At minimum there is always "Whole Day" (index 0).
      final inkwells = find.byType(InkWell);
      final inkwellCount = inkwells.evaluate().length;
      expect(
        inkwellCount,
        greaterThan(0),
        reason: 'No InkWell found — period selector not rendered.',
      );

      // Tap up to the first 5 InkWells (period pills), asserting no crash.
      final tapCount = inkwellCount < 5 ? inkwellCount : 5;
      for (int i = 0; i < tapCount; i++) {
        final target = inkwells.at(i);
        // Only tap if the widget is still mounted (tree may rebuild between taps).
        if (target.evaluate().isNotEmpty) {
          await tester.tap(target, warnIfMissed: false);
          await tester.pump();
          await pumpUntil(tester, budget: kTabBudget);
        }
      }

      // ── Scroll to bottom then back to top ────────────────────────────────
      final scrollViews = find.byType(CustomScrollView);
      if (scrollViews.evaluate().isNotEmpty) {
        // Drag from center of screen upward to simulate scroll-to-bottom.
        await tester.drag(
          scrollViews.first,
          const Offset(0, -3000),
        );
        await tester.pump();
        await pumpUntil(tester, budget: kTabBudget);

        // Drag back to top.
        await tester.drag(
          scrollViews.first,
          const Offset(0, 3000),
        );
        await tester.pump();
        await pumpUntil(tester, budget: kTabBudget);
      }

      // ShiftDashboard still mounted after all interactions.
      expect(find.byType(ShiftDashboard), findsOneWidget);

      // No RenderFlex overflows throughout.
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
