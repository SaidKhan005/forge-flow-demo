// integration_test/mobile_pressure/benchmark/scenario_bench_05_back_navigation.dart
//
// Lane C — Back-navigation from BaselineManagerScreen.
//
// Tests:
//   1. Drill to BaselineManagerScreen, then pop back via the CANCEL
//      button (which calls Navigator.of(context).pop() — _cancel()).
//   2. Assert BaselineTracker is restored as the top widget.
//   3. Assert BottomNavigationBar is present and Benchmark tab (index 3)
//      is still selectable after pop.
//   4. Regression guard for PR #821 pattern: navigate away from
//      BaselineManagerScreen quickly (before async load finishes if
//      possible) and assert no 'setState() called after dispose()' in
//      FlutterErrorTap. The _loadCandidates / _loadDemandContext paths
//      both check `if (!mounted) return;` — these must not fire after
//      the screen is popped.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'BaselineManagerScreen: CANCEL pops back to BaselineTracker, no dispose crash',
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
        markTestSkipped('Benchmark view data not available; back-nav test skipped.');
        return;
      }

      // ── Drill to BaselineManagerScreen ────────────────────────────────
      await tester.tap(chevronFinder.first);
      await tester.pump();
      // Intentionally pump only briefly before navigating back — this
      // exercises the PR #821 pattern: pop while async loads are still
      // in flight. The `if (!mounted) return;` guards in
      // _loadCandidates / _loadDemandContext must fire cleanly.
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(BaselineManagerScreen), findsOneWidget);

      // ── Pop via CANCEL ────────────────────────────────────────────────
      final cancelFinder = find.text('CANCEL');
      if (cancelFinder.evaluate().isNotEmpty) {
        await tester.tap(cancelFinder.first);
      } else {
        // Fall back to Navigator.pop via the back arrow (Icons.arrow_back_ios).
        final backArrow = find.byIcon(Icons.arrow_back_ios);
        if (backArrow.evaluate().isNotEmpty) {
          await tester.tap(backArrow.first);
        } else {
          await tester.pageBack();
        }
      }

      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 10));

      // ── Assert BaselineTracker restored ───────────────────────────────
      expect(
        find.byType(BaselineTracker),
        findsOneWidget,
        reason: 'BaselineTracker must be restored after popping BaselineManagerScreen.',
      );

      // BaselineManagerScreen must not be in the tree.
      expect(
        find.byType(BaselineManagerScreen),
        findsNothing,
        reason: 'BaselineManagerScreen must not be in the tree after pop.',
      );

      // ── BottomNavigationBar still present and selectable ─────────────
      final bars = find.byType(BottomNavigationBar);
      expect(
        bars,
        findsAtLeast(1),
        reason: 'BottomNavigationBar must be present after popping back.',
      );
      final bar = tester.widget<BottomNavigationBar>(bars.first);
      // Benchmark tab is index 3; re-select it.
      bar.onTap?.call(3);
      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 5));

      expect(
        find.byType(BaselineTracker),
        findsOneWidget,
        reason: 'Benchmark tab (index 3) must re-mount BaselineTracker.',
      );

      // ── Pump extra time to let any pending async callbacks fire ───────
      // If the _loadCandidates / _loadDemandContext futures complete after
      // dispose, and the `if (!mounted) return;` guard is missing, the
      // error would appear here.
      await pumpUntil(tester, budget: const Duration(seconds: 8));

      // ── PR #821 regression: no 'setState called after dispose' ────────
      final disposeErrors = errorTap.all.where(
        (e) =>
            e.exception.toString().contains('setState') &&
            e.exception.toString().contains('dispose'),
      );
      expect(
        disposeErrors.toList(),
        isEmpty,
        reason:
            'No "setState called after dispose" errors — '
            'PR #821 regression guard.',
      );

      // No overflows.
      expect(
        errorTap.overflowErrors,
        isEmpty,
        reason: 'No RenderFlex overflows during back-navigation.',
      );
    },
  );
}
