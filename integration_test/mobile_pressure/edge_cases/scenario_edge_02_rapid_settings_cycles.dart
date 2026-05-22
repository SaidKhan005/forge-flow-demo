// Lane H — Scenario 02: Opening and closing Settings 5 times in quick
// succession does not accumulate routes or corrupt shell state.
//
// Each cycle: open Settings (all 4 tabs visible) -> close -> verify AppShell.
// After all cycles: no SettingsScreen in tree, no overflow, no exception.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'edge-02 — 5 rapid Settings open/close cycles leave a clean shell',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      for (var i = 0; i < 5; i++) {
        await openSettings(tester);

        // Exactly one SettingsScreen (no duplicates from prior cycles).
        expect(
          find.byType(SettingsScreen),
          findsOneWidget,
          reason:
              'Multiple SettingsScreen instances on cycle $i — '
              'route stack accumulated.',
        );

        await navigateBack(tester);
      }

      // Shell must be clean: no SettingsScreen, AppShell present.
      await expectAppShellMounted(tester);
      expect(
        find.byType(SettingsScreen),
        findsNothing,
        reason:
            'SettingsScreen still in tree after all 5 close cycles — '
            'route was not fully popped.',
      );

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
