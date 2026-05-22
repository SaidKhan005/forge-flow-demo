// Lane H — Scenario 04: Tapping the Settings icon while a bottom-nav tab
// switch is in flight does not crash.
//
// The app uses an IndexedStack for tabs (visibility toggling, not full
// route pushes), but the notifiers still start async loads on tab switch.
// This scenario fires a tab switch, then immediately taps Settings before
// the tab's load settles — exercising concurrent route-push + async-load.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'edge-04 — Settings tap during tab transition does not crash',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Fire the tab switch (starts async notifier load).
      tester
          .widget<BottomNavigationBar>(
            find.byType(BottomNavigationBar).first,
          )
          .onTap
          ?.call(2); // Plan tab

      // Minimal pump — just enough for the tab switch to register
      // but NOT long enough for the async load to complete.
      await tester.pump(const Duration(milliseconds: 80));

      // Immediately tap Settings.
      final settingsIcon = find.byIcon(Icons.settings_outlined);
      if (settingsIcon.evaluate().isNotEmpty) {
        await tester.tap(settingsIcon.first, warnIfMissed: false);
      }

      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // Either Settings opened or the shell is on Plan — both are valid.
      // The invariant: no crash, navigator is in a valid state.
      final hasSettings =
          find.byType(SettingsScreen).evaluate().isNotEmpty;
      if (hasSettings) {
        await navigateBack(tester);
      }

      await expectAppShellMounted(tester);

      expect(
        tap.all,
        isEmpty,
        reason:
            'Exceptions during concurrent Settings tap + tab-switch:\n'
            '${tap.all.map((e) => e.exceptionAsString()).join('\n')}',
      );
      expect(tap.overflowErrors, isEmpty);
    },
  );
}
