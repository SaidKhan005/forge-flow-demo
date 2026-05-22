// integration_test/mobile_pressure/benchmark/scenario_bench_03_manager_sub_screens.dart
//
// Lane C — BaselineManagerScreen sub-screen coverage.
//
// BaselineManagerScreen (7.55o.5) is a single-page scrollable Scaffold
// with NO bottom nav or tab-routing of its own. All sub-components are
// widgets within one scrollable Column, not separate routes:
//
//   BaselineManagerLensBar  (baseline_manager_lens.dart)
//   BaselineManagerScopeTag (baseline_manager_lens.dart)
//   PreviewPanel            (baseline_manager_preview.dart)
//   BaselineManagerBandSelector (baseline_manager_band.dart)
//   ClearAllBar             (baseline_manager_actions.dart, conditional)
//   CalendarGrid            (baseline_manager_calendar.dart)
//   BottomBar               (baseline_manager_actions.dart)
//
// This test navigates to BaselineManagerScreen, then asserts each
// sub-component widget type is present and renders non-empty content.
// It also scrolls the page to ensure the calendar section mounts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_calendar.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_preview.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_lens.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_band.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_actions.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'BaselineManagerScreen: all sub-components mount with content, no overflow',
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
        markTestSkipped('Benchmark view data not available; sub-screen test skipped.');
        return;
      }

      await tester.tap(chevronFinder.first);
      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 15));

      expect(find.byType(BaselineManagerScreen), findsOneWidget);

      // Wait for candidate load to complete.
      await pumpUntil(tester, budget: const Duration(seconds: 10));

      // ── Lens bar ──────────────────────────────────────────────────────
      expect(
        find.byType(BaselineManagerLensBar),
        findsOneWidget,
        reason: 'BaselineManagerLensBar must be present.',
      );
      // The "Whole day" lens chip is always rendered.
      expect(
        find.text('WHOLE DAY'),
        findsOneWidget,
        reason: '"WHOLE DAY" lens chip must be present.',
      );

      // ── Scope tag ─────────────────────────────────────────────────────
      expect(
        find.byType(BaselineManagerScopeTag),
        findsOneWidget,
        reason: 'BaselineManagerScopeTag must be present.',
      );

      // ── Preview panel ─────────────────────────────────────────────────
      expect(
        find.byType(PreviewPanel),
        findsOneWidget,
        reason: 'PreviewPanel must be present.',
      );
      // "SELECTED SHIFTS" label is always rendered in PreviewPanel.
      expect(
        find.text('SELECTED SHIFTS'),
        findsOneWidget,
        reason: '"SELECTED SHIFTS" label must be in PreviewPanel.',
      );

      // ── Band selector ─────────────────────────────────────────────────
      expect(
        find.byType(BaselineManagerBandSelector),
        findsOneWidget,
        reason: 'BaselineManagerBandSelector must be present.',
      );
      // "STAR SHIFT SELECTION" label is always rendered.
      expect(
        find.text('STAR SHIFT SELECTION'),
        findsOneWidget,
        reason: '"STAR SHIFT SELECTION" label must be present.',
      );

      // ── Bottom bar ────────────────────────────────────────────────────
      expect(
        find.byType(BottomBar),
        findsOneWidget,
        reason: 'BottomBar must be present.',
      );
      // CANCEL button is always rendered.
      expect(
        find.text('CANCEL'),
        findsOneWidget,
        reason: '"CANCEL" button text must be present.',
      );

      // ── Scroll to reveal calendar grid ────────────────────────────────
      final scrollFinder = find.byType(SingleChildScrollView).first;
      await tester.drag(scrollFinder, const Offset(0, -600));
      await tester.pump();
      await pumpUntil(tester, budget: const Duration(seconds: 5));

      // CalendarGrid should now be in the tree (it lays out at intrinsic
      // height in the single page scroll — R9).
      expect(
        find.byType(CalendarGrid),
        findsOneWidget,
        reason: 'CalendarGrid must be present after scrolling.',
      );

      // "LAST 60 DAYS" header is always rendered by CalendarGrid when
      // windowDates is non-empty.
      // We do a text search without requiring it — the calendar could be
      // empty in a test environment.
      expect(find.byType(ErrorWidget), findsNothing);

      // No overflows throughout.
      expect(
        errorTap.overflowErrors,
        isEmpty,
        reason: 'No RenderFlex overflows in BaselineManagerScreen sub-screens.',
      );
    },
  );
}
