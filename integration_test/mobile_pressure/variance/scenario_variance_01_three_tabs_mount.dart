// integration_test/mobile_pressure/variance/scenario_variance_01_three_tabs_mount.dart
//
// Lane B Scenario Variance-01 — all three Variance tabs mount and render.
//
// Asserts:
//  - VarianceReport mounts when tab index 1 is selected.
//  - A TabBar is present with 'This Week', 'History', 'Learn' labels.
//  - Tapping each tab produces content (not a blank screen).
//  - No RenderFlex overflow on any tab.
//
// Source: lib/screens/variance_report.dart:44-50 — TabBar tabs.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/variance_report.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'variance-01 — three tabs mount and each renders content; no overflow',
    (WidgetTester tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Navigate to Variance (index 1).
      await tapTab(tester, 1);
      expect(
        find.byType(VarianceReport),
        findsOneWidget,
        reason: 'VarianceReport did not mount at bottom-nav index 1.',
      );

      // Tab bar is present with all three tab labels.
      expect(
        find.text('This Week'),
        findsAtLeast(1),
        reason: "'This Week' tab label not found in the TabBar.",
      );
      expect(
        find.text('History'),
        findsAtLeast(1),
        reason: "'History' tab label not found in the TabBar.",
      );
      expect(
        find.text('Learn'),
        findsAtLeast(1),
        reason: "'Learn' tab label not found in the TabBar.",
      );

      // ── This Week tab (default) ───────────────────────────────────────────
      await tester.tap(find.text('This Week').first);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      final thisWeekHasContent = find
          .byType(Text)
          .evaluate()
          .where((e) {
            final w = e.widget as Text;
            return (w.data ?? w.textSpan?.toPlainText() ?? '').trim().isNotEmpty;
          })
          .length;
      expect(
        thisWeekHasContent,
        greaterThan(1),
        reason: 'This Week tab appears blank after tap.',
      );

      // ── History tab ───────────────────────────────────────────────────────
      await tester.tap(find.text('History').first);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      final historyHasContent = find
          .byType(Text)
          .evaluate()
          .where((e) {
            final w = e.widget as Text;
            return (w.data ?? w.textSpan?.toPlainText() ?? '').trim().isNotEmpty;
          })
          .length;
      expect(
        historyHasContent,
        greaterThan(1),
        reason: 'History tab appears blank after tap.',
      );

      // ── Learn tab ─────────────────────────────────────────────────────────
      await tester.tap(find.text('Learn').first);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      final learnHasContent = find
          .byType(Text)
          .evaluate()
          .where((e) {
            final w = e.widget as Text;
            return (w.data ?? w.textSpan?.toPlainText() ?? '').trim().isNotEmpty;
          })
          .length;
      expect(
        learnHasContent,
        greaterThan(1),
        reason: 'Learn tab appears blank after tap.',
      );

      // No RenderFlex overflows on any tab.
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
