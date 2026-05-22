// integration_test/mobile_pressure/regression/scenario_reg_02_demo_banner_lifecycle.dart
//
// Lane A — Scenario Reg-02: DemoModeBanner persists across tab switches
// and settings entry/exit.
//
// DemoModeBanner is a shell-level widget mounted directly in AppShell.build
// (forge_flow_app.dart) inside the Column above the IndexedStack. It is NOT
// tab-specific. Switching tabs only changes the IndexedStack index; the
// DemoModeBanner is always in the tree regardless of which tab is active.
//
// Verifies:
//   - DemoModeBanner is in tree after login (Shift tab).
//   - DemoModeBanner is still in tree after switching to each of the 4 tabs.
//   - DemoModeBanner is still in tree after opening Settings.
//   - DemoModeBanner is still in tree after returning from Settings.
//   - No exceptions throughout.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/widgets/demo_mode_banner.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Reg-02: DemoModeBanner persists across all tab switches and settings entry/exit',
    (tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // DemoModeBanner must be in tree at the initial Shift tab.
      expect(
        find.byType(DemoModeBanner),
        findsWidgets,
        reason: 'DemoModeBanner must be in tree at Shift tab (index 0) after login.',
      );

      // Switch to each tab and verify banner persists.
      for (int tabIndex = 0; tabIndex < 4; tabIndex++) {
        await tapTab(tester, tabIndex);
        expect(
          find.byType(DemoModeBanner),
          findsWidgets,
          reason:
              'DemoModeBanner must persist at tab index $tabIndex. '
              'It is a shell-level widget above the IndexedStack and '
              'must not be unmounted when the tab changes.',
        );
      }

      // Open settings — banner must persist during settings overlay.
      final settingsIcon = find.byIcon(Icons.settings_outlined);
      expect(settingsIcon, findsAtLeast(1), reason: 'Settings icon not found.');
      await tester.tap(settingsIcon.first);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      expect(
        find.byType(DemoModeBanner),
        findsWidgets,
        reason:
            'DemoModeBanner must still be in tree while SettingsScreen is open. '
            'The banner is mounted in AppShell which remains in the Navigator stack.',
      );

      // Return from settings — banner must still be present.
      await tester.pageBack();
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      expect(
        find.byType(DemoModeBanner),
        findsWidgets,
        reason:
            'DemoModeBanner must persist after returning from SettingsScreen.',
      );

      // AppShell still mounted.
      expect(
        find.byType(AppShell),
        findsOneWidget,
        reason: 'AppShell must be mounted after full banner lifecycle test.',
      );

      // No exceptions throughout.
      expect(
        errorTap.all,
        isEmpty,
        reason:
            'Unexpected Flutter errors during DemoModeBanner lifecycle test: '
            '${errorTap.all.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
