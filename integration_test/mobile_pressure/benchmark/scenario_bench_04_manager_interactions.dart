// integration_test/mobile_pressure/benchmark/scenario_bench_04_manager_interactions.dart
//
// Lane C — BaselineManagerScreen interaction exercise.
//
// Interactive elements in BaselineManagerScreen (from source read):
//
//   1. RESET pill (ValueKey 'reset_pill') — restores default Balanced draft.
//   2. Band chips (ValueKey 'band_lean', 'band_balanced', 'band_generous').
//   3. Lens chips (ValueKey 'lens___whole_day__', plus period chips).
//   4. PLAN IMPACT toggle (ValueKey 'plan_impact_toggle') — expands metrics.
//   5. Calendar day cells (ValueKey 'cal_$dateStr') — open bottom sheet.
//   6. CLEAR ALL bar (GestureDetector, conditional on non-empty draft).
//
// The bottom sheet (showBaselineDayBottomSheet) is modal; we dismiss it
// via the CLOSE button text.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'BaselineManagerScreen: interactive elements respond without crash or overflow',
    (tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await tapTab(tester, 3);
      expect(find.byType(BaselineTracker), findsOneWidget);
      await pumpUntil(tester, budget: const Duration(seconds: 10));

      final chevronFinder = find.byIcon(Icons.chevron_right);
      if (chevronFinder.evaluate().isEmpty) {
        markTestSkipped('Benchmark view data not available; interactions skipped.');
        return;
      }

      await tester.tap(chevronFinder.first);
      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 15));

      expect(find.byType(BaselineManagerScreen), findsOneWidget);
      await pumpUntil(tester, budget: const Duration(seconds: 10));

      // ── 1. Tap LEAN band chip ─────────────────────────────────────────
      final leanChip = find.byKey(const ValueKey<String>('band_lean'));
      if (leanChip.evaluate().isNotEmpty) {
        await tester.tap(leanChip);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 3));
        expect(find.byType(ErrorWidget), findsNothing,
            reason: 'No ErrorWidget after tapping Lean band.');
      }

      // ── 2. Tap GENEROUS band chip ────────────────────────────────────
      final generousChip = find.byKey(const ValueKey<String>('band_generous'));
      if (generousChip.evaluate().isNotEmpty) {
        await tester.tap(generousChip);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 3));
        expect(find.byType(ErrorWidget), findsNothing,
            reason: 'No ErrorWidget after tapping Generous band.');
      }

      // ── 3. Tap BALANCED band chip (restore default) ───────────────────
      final balancedChip = find.byKey(const ValueKey<String>('band_balanced'));
      if (balancedChip.evaluate().isNotEmpty) {
        await tester.tap(balancedChip);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 3));
        expect(find.byType(ErrorWidget), findsNothing,
            reason: 'No ErrorWidget after tapping Balanced band.');
      }

      // ── 4. Tap PLAN IMPACT toggle ─────────────────────────────────────
      final planImpactToggle =
          find.byKey(const ValueKey<String>('plan_impact_toggle'));
      if (planImpactToggle.evaluate().isNotEmpty) {
        await tester.tap(planImpactToggle);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 3));
        expect(find.byType(ErrorWidget), findsNothing,
            reason: 'No ErrorWidget after expanding PLAN IMPACT.');

        // Collapse again.
        await tester.tap(planImpactToggle);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 3));
        expect(find.byType(ErrorWidget), findsNothing,
            reason: 'No ErrorWidget after collapsing PLAN IMPACT.');
      }

      // ── 5. Tap RESET pill ─────────────────────────────────────────────
      final resetPill = find.byKey(const ValueKey<String>('reset_pill'));
      if (resetPill.evaluate().isNotEmpty) {
        await tester.tap(resetPill);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 3));
        expect(find.byType(ErrorWidget), findsNothing,
            reason: 'No ErrorWidget after tapping RESET pill.');
      }

      // ── 6. Scroll and tap a calendar day cell ─────────────────────────
      // Scroll to bring CalendarGrid into view.
      final scrollFinder = find.byType(SingleChildScrollView).first;
      await tester.drag(scrollFinder, const Offset(0, -800));
      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 5));

      // Look for any cal_ keyed GestureDetector (a day cell with shifts).
      // We use byType(GestureDetector) filtered via key prefix in a loop.
      // Simpler approach: find any visible calendar day cell by its key
      // pattern. We use a custom finder via evaluate().
      final calCells = find.byWidgetPredicate(
        (widget) =>
            widget is GestureDetector &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('cal_') &&
            !(widget.key! as ValueKey<String>).value.startsWith('cal_legend') &&
            !(widget.key! as ValueKey<String>).value.startsWith('cal_badge'),
      );

      if (calCells.evaluate().isNotEmpty) {
        await tester.tap(calCells.first);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 5));

        // If a bottom sheet appeared, assert it mounted and dismiss it.
        final closeFinder = find.text('CLOSE');
        if (closeFinder.evaluate().isNotEmpty) {
          expect(
            closeFinder,
            findsOneWidget,
            reason: 'Bottom sheet CLOSE button must be present.',
          );
          await tester.tap(closeFinder);
          await tester.pump();
          await pumpUntil(tester, budget: const Duration(seconds: 3));
          expect(find.byType(ErrorWidget), findsNothing,
              reason: 'No ErrorWidget after dismissing day sheet.');
        }
      }

      // ── 7. CLEAR ALL (if draft is non-empty) ─────────────────────────
      final clearAll = find.text('CLEAR ALL');
      if (clearAll.evaluate().isNotEmpty) {
        await tester.tap(clearAll.first);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 3));
        expect(find.byType(ErrorWidget), findsNothing,
            reason: 'No ErrorWidget after tapping CLEAR ALL.');
      }

      // Final state: still on BaselineManagerScreen.
      expect(find.byType(BaselineManagerScreen), findsOneWidget);

      // No overflows throughout.
      expect(
        errorTap.overflowErrors,
        isEmpty,
        reason: 'No RenderFlex overflows during BaselineManagerScreen interactions.',
      );
    },
  );
}
