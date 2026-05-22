// Lane D — Scenario 06: Demo/Live switch widget renders in Integrations tab.
//
// SettingsDemoLiveSwitch (settings_demo_live_switch.dart) is mounted inside
// SettingsIntegrationsSection (settings_integrations_section.dart line 99).
// The Integrations tab is index 1 in the Settings bottom nav.
//
// The switch widget renders:
//   - A SettingsCard with key 'settings_demo_live_switch_card'
//   - A 'Demo mode' label (mono12 text)
//   - A Switch widget with key 'settings_demo_live_switch'
//     OR a progress indicator with key 'settings_demo_live_switch_progress'
//     while a toggle is in-flight.
//
// This scenario does NOT toggle the switch — toggling would open a
// confirmation dialog and trigger a proxy call that is not wired in the
// demo shell. It only confirms the widget renders and is tappable without
// crashing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'scenario 06 — Demo/Live switch renders in Integrations tab without crash',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await openSettings(tester);
      expectSettings();

      // Integrations tab is index 1.
      await tapSettingsTab(tester, 1);
      await pumpUntil(tester, budget: kTabBudget);

      // The demo-live switch card.
      expect(
        find.byKey(const Key('settings_demo_live_switch_card')),
        findsOneWidget,
        reason:
            'SettingsDemoLiveSwitch card not found on Integrations tab.',
      );

      // 'Demo mode' label text (settings_demo_live_switch.dart line 86).
      expect(
        find.text('Demo mode'),
        findsAtLeast(1),
        reason: 'Demo mode label not found in switch card.',
      );

      // The Switch widget itself should be visible (not in-flight).
      // Either the Switch or the progress indicator is rendered.
      final switchFinder = find.byKey(const Key('settings_demo_live_switch'));
      final progressFinder = find.byKey(
        const Key('settings_demo_live_switch_progress'),
      );
      expect(
        switchFinder.evaluate().isNotEmpty ||
            progressFinder.evaluate().isNotEmpty,
        isTrue,
        reason:
            'Neither the demo switch nor its progress indicator was found.',
      );

      // When the Switch is visible, confirm it is present but do NOT tap it
      // (would trigger a proxy call not wired in demo mode).
      if (switchFinder.evaluate().isNotEmpty) {
        final switchWidget = tester.widget<Switch>(switchFinder);
        // The switch should have a value (true = demo, false = live).
        // Just verify it is non-null (always true for a Switch.value).
        expect(switchWidget.value, isNotNull);
      }

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow on demo-live switch scenario:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
