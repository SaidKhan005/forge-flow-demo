// Lane F — Scenario 04: After each SettingsPointerRow tap the navigator is in
// a valid state and SettingsScreen is still reachable.
//
// Extends scenario-08 (no-crash check) with a stricter invariant: after every
// pointer row tap, the test pops any pushed route and asserts SettingsScreen
// is still present. This proves no row escapes to an unrecoverable stack.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings/settings_pointer_row.dart';
import 'package:forge_and_flow/screens/settings_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'form-04 — SettingsPointerRow taps leave navigator in valid state',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);
      await openSettings(tester);
      expectSettings();

      Future<void> exerciseTabPointerRows(int tabIndex) async {
        await tapSettingsTab(tester, tabIndex);
        await pumpUntil(tester, budget: const Duration(seconds: 5));

        final count = find.byType(SettingsPointerRow).evaluate().length;

        for (var i = 0; i < count; i++) {
          final currentRows = find.byType(SettingsPointerRow);
          if (i >= currentRows.evaluate().length) break;

          final row = currentRows.at(i);
          final buttons = find.descendant(
            of: row,
            matching: find.byType(FilledButton),
          );
          if (buttons.evaluate().isEmpty) continue;

          await tester.tap(buttons.first, warnIfMissed: false);
          await tester.pump();
          await pumpUntil(tester, budget: const Duration(seconds: 5));

          // Pop any pushed route.
          final nav =
              tester.state<NavigatorState>(find.byType(Navigator).last);
          if (nav.canPop()) {
            nav.pop();
            await tester.pump();
            await pumpUntil(tester, budget: const Duration(seconds: 3));
          }

          // Dismiss any dialog that opened.
          if (find.byType(AlertDialog).evaluate().isNotEmpty) {
            final closeBtn = find.descendant(
              of: find.byType(AlertDialog).first,
              matching: find.byType(TextButton),
            );
            if (closeBtn.evaluate().isNotEmpty) {
              await tester.tap(closeBtn.first, warnIfMissed: false);
              await tester.pump();
            }
          }

          // SettingsScreen must still be reachable.
          expect(
            find.byType(SettingsScreen),
            findsOneWidget,
            reason:
                'SettingsScreen missing after pointer row $i on tab $tabIndex '
                '— navigator may have escaped to an unrecoverable route.',
          );
        }
      }

      for (var tab = 0; tab < 4; tab++) {
        await exerciseTabPointerRows(tab);
      }

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
