// integration_test/mobile_pressure/shift/scenario_shift_01_sections_render.dart
//
// Lane B Scenario Shift-01 — shift dashboard section headers render.
//
// Asserts that after demo boot + login the Shift tab (index 0) shows
// either the three pinned section headers (SHIFT OUTPUTS / SHIFT INPUTS /
// FOH PRODUCTIVITY) OR a recognised empty-state message. In either case:
// no stuck CircularProgressIndicator, no RenderFlex overflow, and the
// ShiftDashboard widget itself must be in the tree.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/shift_dashboard.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'shift-01 — section headers or empty state render; no overflow; no stuck spinner',
    (WidgetTester tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Index 0 is the Shift tab — already the default; ensure we are on it.
      await tapTab(tester, 0);

      // ShiftDashboard must be mounted.
      expect(
        find.byType(ShiftDashboard),
        findsOneWidget,
        reason: 'ShiftDashboard did not mount on tab index 0.',
      );

      // The dashboard is in one of two valid states:
      //  (a) live/closed data — three pinned section headers are visible
      //  (b) empty state — _ShiftEmptyState shows a human-readable message
      final hasOutputsHeader =
          find.text('SHIFT OUTPUTS').evaluate().isNotEmpty;
      final hasInputsHeader = find.text('SHIFT INPUTS').evaluate().isNotEmpty;
      final hasFohHeader = find.text('FOH PRODUCTIVITY').evaluate().isNotEmpty;
      final hasData = hasOutputsHeader && hasInputsHeader && hasFohHeader;

      // Known empty-state strings from _ShiftEmptyState:
      //   'NO LIVE SHIFT', 'LOCKED PLAN UNAVAILABLE',
      //   'No open or projected shift is available.',
      //   'No locked weekly plan is available for the current week.'
      final hasEmptyHeadline =
          find.text('NO LIVE SHIFT').evaluate().isNotEmpty ||
          find.text('LOCKED PLAN UNAVAILABLE').evaluate().isNotEmpty;
      final hasEmptyBody =
          find
              .text('No open or projected shift is available.')
              .evaluate()
              .isNotEmpty ||
          find
              .text('No locked weekly plan is available for the current week.')
              .evaluate()
              .isNotEmpty;
      final hasEmptyState = hasEmptyHeadline || hasEmptyBody;

      expect(
        hasData || hasEmptyState,
        isTrue,
        reason:
            'ShiftDashboard is neither showing section headers nor a recognised '
            'empty-state message. Possible SQLite seed failure or widget-tree '
            'structural change.',
      );

      // No stuck CircularProgressIndicator (hitTestable).
      final spinners = find
          .byType(CircularProgressIndicator)
          .hitTestable()
          .evaluate();
      expect(
        spinners,
        isEmpty,
        reason:
            'A CircularProgressIndicator is still hitTestable — the dashboard '
            'appears stuck in a loading state.',
      );

      // If we have data, assert something beyond a blank screen.
      if (hasData) {
        // At least one Text widget with non-empty string in the body area.
        final nonEmptyTexts = find
            .byType(Text)
            .evaluate()
            .where((e) {
              final widget = e.widget as Text;
              final s =
                  widget.data ?? widget.textSpan?.toPlainText() ?? '';
              return s.trim().isNotEmpty;
            })
            .toList();
        expect(
          nonEmptyTexts.length,
          greaterThan(3),
          reason:
              'Dashboard claims to have data but very few Text widgets are '
              'populated. The seed may not have written shift records.',
        );
      }

      // No RenderFlex overflows.
      expect(
        errorTap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflows detected:\n'
            '${errorTap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
