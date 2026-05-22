// Lane G — Scenario 01: Settings opens, all 4 tabs visited, closes, then
// re-opens without route-stack accumulation or duplicate SettingsScreen.
//
// Verifies that the Settings push-route pattern does not leave orphan routes
// after repeated open/close cycles (3 full cycles tested).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'deep-01 — Settings 3-cycle open/tab-visit/close leaves a clean route stack',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      for (var cycle = 0; cycle < 3; cycle++) {
        // Open Settings.
        await openSettings(tester);

        // Exactly one SettingsScreen — no duplicates.
        expect(
          find.byType(SettingsScreen),
          findsOneWidget,
          reason:
              'More than one SettingsScreen found on open cycle $cycle — '
              'route stack accumulated from a previous cycle.',
        );

        // Visit all 4 tabs.
        for (var i = 0; i < 4; i++) {
          await tapSettingsTab(tester, i);
          await pumpUntil(tester, budget: const Duration(seconds: 5));
        }

        // Close Settings.
        await navigateBack(tester);
        await expectAppShellMounted(tester);

        // No SettingsScreen left after close.
        expect(
          find.byType(SettingsScreen),
          findsNothing,
          reason:
              'SettingsScreen still in tree after close on cycle $cycle — '
              'route was not fully popped.',
        );
      }

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
