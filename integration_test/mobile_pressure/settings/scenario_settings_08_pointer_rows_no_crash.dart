// Lane D — Scenario 08: All SettingsPointerRow widgets are tappable without crash.
//
// SettingsPointerRow (settings_pointer_row.dart) renders a FilledButton.icon
// that either launches an op-web URL (via HandoffCodeGateway) or copies to
// clipboard. In the demo shell no HandoffCodeGateway is wired, so tapping
// will fall through to the clipboard fallback or show an error snackbar —
// both are valid, non-crashing outcomes.
//
// Known SettingsPointerRow instances in the Settings screen
// (settings_screen.dart):
//   - Setup tab (index 0):
//       'Manage Timing on Ops Web'   navId: 'business_setup'
//       'Manage Wage on Ops Web'     navId: 'wage_authority'
//   - Integrations tab (index 1):
//       'Manage Integrations on Ops Web'  key: 'settings_integrations_console_pointer'
//
// This scenario taps each pointer row button in each tab, confirms no
// crash, and back-navigates from any sub-route that opened.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings/settings_pointer_row.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'scenario 08 — all SettingsPointerRow widgets tappable without crash',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await openSettings(tester);
      expectSettings();

      // Helper: tap every SettingsPointerRow on the current tab and
      // back-navigate from any sub-route that opened.
      Future<void> tapAllPointerRowsOnCurrentTab() async {
        await pumpUntil(tester, budget: const Duration(seconds: 3));
        final rows = find.byType(SettingsPointerRow);
        final count = rows.evaluate().length;
        for (var i = 0; i < count; i++) {
          // Re-find after each interaction in case the tree rebuilt.
          final currentRows = find.byType(SettingsPointerRow);
          if (i >= currentRows.evaluate().length) break;

          // Find the tappable button inside this row.
          final row = currentRows.at(i);
          final buttons = find.descendant(
            of: row,
            matching: find.byType(FilledButton),
          );
          if (buttons.evaluate().isEmpty) continue;

          await tester.tap(buttons.first, warnIfMissed: false);
          await tester.pump();
          await pumpUntil(tester, budget: const Duration(seconds: 3));

          // If a new route pushed, pop back.
          final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
          if (navigator.canPop()) {
            navigator.pop();
            await tester.pump();
            await pumpUntil(tester, budget: const Duration(seconds: 3));
          }

          // Dismiss any snackbar or dialog that appeared.
          if (find.byType(AlertDialog).evaluate().isNotEmpty) {
            final closeButtons = find.descendant(
              of: find.byType(AlertDialog).first,
              matching: find.byType(TextButton),
            );
            if (closeButtons.evaluate().isNotEmpty) {
              await tester.tap(closeButtons.first);
              await tester.pump();
            }
          }
        }
      }

      // Setup tab (index 0) — pointer rows: Manage Timing, Manage Wage.
      await tapSettingsTab(tester, 0);
      await tapAllPointerRowsOnCurrentTab();

      // Integrations tab (index 1) — pointer row: Manage Integrations.
      await tapSettingsTab(tester, 1);
      await tapAllPointerRowsOnCurrentTab();

      // Data tab (index 2) — pointer rows: none currently in the standard build.
      await tapSettingsTab(tester, 2);
      await tapAllPointerRowsOnCurrentTab();

      // Account tab (index 3) — pointer rows: none currently.
      await tapSettingsTab(tester, 3);
      await tapAllPointerRowsOnCurrentTab();

      // After all taps: assert no exceptions accumulated.
      expect(
        tap.all,
        isEmpty,
        reason:
            'Exceptions thrown during pointer row taps:\n'
            '${tap.all.map((e) => e.exceptionAsString()).join('\n')}',
      );

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow during pointer row scenario:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
