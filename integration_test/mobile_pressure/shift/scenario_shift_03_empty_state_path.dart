// integration_test/mobile_pressure/shift/scenario_shift_03_empty_state_path.dart
//
// Lane B Scenario Shift-03 — dashboard valid-state classification.
//
// Asserts that the Shift dashboard is in exactly one of two valid states:
//  (a) Live/closed data — section headers present AND at least one numeric
//      text visible (proves the demo seed populated real numbers).
//  (b) Empty state — _ShiftEmptyState copy present, no error widget.
//
// In neither case may the tree contain an ErrorWidget or a red error screen.
// No RenderFlex overflows and no stuck spinner.
//
// Empty-state strings from shift_dashboard.dart:
//   headline: 'NO LIVE SHIFT' | 'LOCKED PLAN UNAVAILABLE'
//   body:     'No open or projected shift is available.'
//           | 'No locked weekly plan is available for the current week.'

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/shift_dashboard.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'shift-03 — dashboard is in a valid state; no ErrorWidget; no stuck spinner',
    (WidgetTester tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);
      await tapTab(tester, 0);

      expect(
        find.byType(ShiftDashboard),
        findsOneWidget,
        reason: 'ShiftDashboard must mount on tab 0.',
      );

      // Classify state.
      final hasOutputsHeader =
          find.text('SHIFT OUTPUTS').evaluate().isNotEmpty;
      final hasInputsHeader = find.text('SHIFT INPUTS').evaluate().isNotEmpty;
      final hasFohHeader = find.text('FOH PRODUCTIVITY').evaluate().isNotEmpty;
      final hasDataState =
          hasOutputsHeader && hasInputsHeader && hasFohHeader;

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

      // Must be in one of the two valid states.
      expect(
        hasDataState || hasEmptyState,
        isTrue,
        reason:
            'Dashboard is in neither the data state (section headers) nor the '
            'empty state (recognised copy). Possible unknown failure mode.',
      );

      if (hasDataState) {
        // In state (a): assert at least one numeric text in the body.
        final numericTexts = find.byType(Text).evaluate().where((e) {
          final w = e.widget as Text;
          final s = w.data ?? w.textSpan?.toPlainText() ?? '';
          return RegExp(r'\d').hasMatch(s);
        });
        expect(
          numericTexts.length,
          greaterThan(0),
          reason:
              'Dashboard shows section headers but no numeric text — the demo '
              'seed may not have written real shift_records rows.',
        );
      }

      if (hasEmptyState) {
        // In state (b): the empty-state widget must contain a human-readable
        // message (already asserted above via hasEmptyHeadline / hasEmptyBody).
        // Extra guard: text must be non-trivially long (> 5 chars).
        final emptyTexts = find.byType(Text).evaluate().where((e) {
          final w = e.widget as Text;
          return (w.data ?? '').length > 5;
        });
        expect(
          emptyTexts.isNotEmpty,
          isTrue,
          reason: 'Empty-state shows no meaningful copy string.',
        );
      }

      // No ErrorWidget in the tree (red error screen).
      expect(
        find.byType(ErrorWidget),
        findsNothing,
        reason: 'An ErrorWidget is in the tree — the dashboard threw.',
      );

      // No stuck CircularProgressIndicator.
      expect(
        find.byType(CircularProgressIndicator).hitTestable().evaluate(),
        isEmpty,
        reason: 'A spinner is still hitTestable — dashboard stuck loading.',
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
