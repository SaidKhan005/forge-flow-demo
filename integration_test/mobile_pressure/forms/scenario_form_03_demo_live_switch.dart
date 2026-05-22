// Lane F — Scenario 03: Demo/Live switch card renders on Integrations tab and
// a tap does not crash.
//
// SettingsDemoLiveSwitch renders a card keyed 'settings_demo_live_switch_card'.
// In demo mode the SyncProxyClient may be absent (switch disabled). Either
// state is valid — the test asserts the card is present, the tap does not
// crash, the card is still mounted afterward, and no overflow occurs.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'form-03 — Demo/Live switch card present on Integrations tab; tap does not crash',
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

      // Demo/Live switch card must be present.
      final switchCard =
          find.byKey(const Key('settings_demo_live_switch_card'));
      expect(
        switchCard,
        findsOneWidget,
        reason:
            'settings_demo_live_switch_card not found on Integrations tab.',
      );

      // Tap the card; action may be a no-op if the gateway client is absent.
      await tester.tap(switchCard, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // Card must still be present after the tap (no crash dismissed it).
      expect(
        find.byKey(const Key('settings_demo_live_switch_card')),
        findsOneWidget,
        reason:
            'settings_demo_live_switch_card disappeared after tap — '
            'an unexpected crash or navigation may have occurred.',
      );

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
