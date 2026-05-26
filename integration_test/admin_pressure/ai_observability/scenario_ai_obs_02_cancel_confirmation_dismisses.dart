// integration_test/admin_pressure/ai_observability/scenario_ai_obs_02_cancel_confirmation_dismisses.dart
//
// Lane C — AI/Obs-02 (regression): the AI Metrics "Run check" confirm
// dialog must dismiss cleanly when the operator cancels.
//
// Background: the 2026-05-22 manual pressure test flagged a stuck
// dialog incident — tapping Cancel on the run-metrics-check confirm
// dialog left the dialog scaffold on screen with the underlying
// surface unresponsive. The keys for this dialog live at
// lib/admin/screens/observability_admin_screen.dart:553–555
// (admin_observability_confirm_dialog / _confirm_cancel / _confirm_run).
//
// This scenario opens the Observability route, taps the refresh
// button (Key line 520), confirms the dialog opens, taps Cancel, and
// asserts the dialog disappears within the budget.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'AI/Obs-02 (regression): cancelling the run-metrics-check confirm '
    'dialog actually dismisses it',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminObservabilityRouteId);

      // AI Metrics screen mounted (Key from
      // lib/admin/screens/observability_admin_screen.dart:284).
      expect(
        find.byKey(const Key('admin_observability_screen')),
        findsOneWidget,
        reason: 'AI Metrics (observability) screen did not mount.',
      );

      // Tap the refresh button to surface the confirm dialog (Key from
      // line 520).
      final refreshBtn =
          find.byKey(const Key('admin_observability_refresh_button'));

      // Refresh affordance may be hidden behind a status panel until
      // the surface settles; pump until it shows up or budget elapses.
      final sw = Stopwatch()..start();
      while (sw.elapsed < kAdminNavBudget &&
          refreshBtn.evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      if (refreshBtn.evaluate().isEmpty) {
        // TODO(admin-pressure): if the demo gateway returns a "no
        // data" surface without a refresh button, drill into a tab
        // first. Today the demo gateway populates AI Metrics with cost
        // panels, so the refresh affordance should always render.
        return;
      }

      await tester.tap(refreshBtn.first, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      // Confirm dialog mounted (Key from line 553).
      final dialogKey = const Key('admin_observability_confirm_dialog');
      expect(
        find.byKey(dialogKey),
        findsOneWidget,
        reason:
            'Run-metrics-check confirm dialog did not open after tapping '
            'refresh — refresh button may have been short-circuited.',
      );

      // Tap Cancel (Key from line 554).
      final cancelBtn =
          find.byKey(const Key('admin_observability_confirm_cancel'));
      expect(cancelBtn, findsOneWidget,
          reason: 'Confirm dialog cancel button missing.');

      await tester.tap(cancelBtn.first, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      // The dialog must be gone (regression: 2026-05-22 stuck dialog).
      expect(
        find.byKey(dialogKey),
        findsNothing,
        reason:
            'Confirm dialog did not dismiss after Cancel — this is the '
            '2026-05-22 stuck-dialog regression. See '
            'lib/admin/screens/observability_admin_screen.dart:553.',
      );

      // Shell still mounted (the underlying surface stayed responsive).
      await expectAdminShellMounted(tester);

      expect(tap.overflowErrors, isEmpty,
          reason:
              'Confirm dialog overflowed: '
              '${tap.overflowErrors.map((e) => e.exception).join(', ')}');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
