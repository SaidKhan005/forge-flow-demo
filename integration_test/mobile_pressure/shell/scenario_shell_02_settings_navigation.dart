// integration_test/mobile_pressure/shell/scenario_shell_02_settings_navigation.dart
//
// Lane A — Scenario Shell-02: Settings entry and exit navigation.
//
// The settings icon (Icons.settings_outlined) lives in the standalone
// app bar as an _AppShellIconButton (InkWell wrapping a Container with
// the icon). Tapping it pushes SettingsScreen via Navigator.push.
// Tapping back (pageBack) pops it and restores AppShell.
//
// Verifies:
//   - Settings icon is reachable from AppShell app bar.
//   - SettingsScreen mounts after tapping the icon.
//   - Navigating back removes SettingsScreen from tree.
//   - AppShell is still mounted after back navigation.
//   - No exceptions during settings entry/exit.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/screens/settings_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Shell-02: settings entry and exit via app-bar icon',
    (tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Tap the settings icon in the standalone app bar.
      // forge_flow_app.dart standaloneAppBar row contains
      // _AppShellIconButton(icon: Icons.settings_outlined, ...).
      final settingsIcon = find.byIcon(Icons.settings_outlined);
      expect(
        settingsIcon,
        findsAtLeast(1),
        reason:
            'Icons.settings_outlined not found in AppShell app bar. '
            'Check _AppShellIconButton in forge_flow_app.dart.',
      );
      await tester.tap(settingsIcon.first);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // SettingsScreen must be in the tree.
      expectSettings();

      // Navigate back using the Flutter navigator (matches real back-button).
      await tester.pageBack();
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // SettingsScreen must be gone after back navigation.
      expect(
        find.byType(SettingsScreen),
        findsNothing,
        reason: 'SettingsScreen should be popped after back navigation.',
      );

      // AppShell must still be mounted (was not popped).
      expect(
        find.byType(AppShell),
        findsOneWidget,
        reason: 'AppShell must remain mounted after returning from Settings.',
      );

      // No errors during settings navigation.
      expect(
        errorTap.all,
        isEmpty,
        reason:
            'Unexpected Flutter errors during settings navigation: '
            '${errorTap.all.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
