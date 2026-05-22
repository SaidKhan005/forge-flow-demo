// Lane D — Scenario 04: Settings Integrations tab renders without crash.
//
// Tab order in SettingsScreen (settings_screen.dart lines 276-289):
//   Setup (index 0), Integrations (index 1), Data (index 2), Account (index 3).
// The Integrations tab is index 1.
//
// Integrations tab body (settings_screen.dart lines 433-453):
//   A single _settingsSection with title 'Integrations' containing
//   SettingsIntegrationsSection.
//
// SettingsIntegrationsSection (settings_integrations_section.dart):
//   - _CategoryStatusList — three status rows: POS, Reservations, Labor
//     Keys: 'settings_integrations_status_pos',
//           'settings_integrations_status_reservation',
//           'settings_integrations_status_labor'
//   - SettingsDemoLiveSwitch (key: 'settings_demo_live_switch_card')
//   - SettingsPointerRow "Manage Integrations on Ops Web"
//     (key: 'settings_integrations_console_pointer')
//
// Status pills (keys: 'settings_integrations_status_pill_pos' etc.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'scenario 04 — Integrations tab renders category rows and demo switch',
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

      // Section header.
      expect(
        find.text('Integrations'),
        findsAtLeast(1),
        reason: 'Integrations section header not rendered.',
      );

      // Per-category status rows by widget key.
      expect(
        find.byKey(const Key('settings_integrations_status_pos')),
        findsOneWidget,
        reason: 'POS status row not found in Integrations tab.',
      );
      expect(
        find.byKey(const Key('settings_integrations_status_reservation')),
        findsOneWidget,
        reason: 'Reservation status row not found in Integrations tab.',
      );
      expect(
        find.byKey(const Key('settings_integrations_status_labor')),
        findsOneWidget,
        reason: 'Labor status row not found in Integrations tab.',
      );

      // Category label text from _CategoryStatusRow._labelFor.
      expect(find.text('POS'), findsAtLeast(1));
      expect(find.text('Reservations'), findsAtLeast(1));
      expect(find.text('Labor'), findsAtLeast(1));

      // SettingsDemoLiveSwitch card.
      expect(
        find.byKey(const Key('settings_demo_live_switch_card')),
        findsOneWidget,
        reason: 'Demo live switch card not found in Integrations tab.',
      );

      // Ops-web pointer row.
      expect(
        find.byKey(const Key('settings_integrations_console_pointer')),
        findsOneWidget,
        reason: 'Manage Integrations pointer row not found.',
      );
      expect(
        find.text('Manage Integrations on Ops Web'),
        findsAtLeast(1),
        reason: 'Pointer row label text not found.',
      );

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow on Integrations tab:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
