// Lane F — Scenario 05: Covers setup field accepts numeric input on the
// Setup/Authority tab without crash.
//
// settings_covers_setup_section.dart exposes a TextField keyed
// 'settings_covers_setup_covers_field' (digits only, no decimal).
// This scenario navigates to Setup tab, scrolls to the field, enters
// a value, and verifies the save button is present. The save button
// may be disabled if a business date / daypart selection is required first
// — that is acceptable; the test only asserts no crash and no overflow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'form-05 — Covers setup field accepts numeric input; no crash or overflow',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);
      await openSettings(tester);
      expectSettings();

      // Setup/Authority tab is index 0.
      await tapSettingsTab(tester, 0);
      await pumpUntil(tester, budget: kTabBudget);

      // Scroll down in passes to bring the covers field into view.
      final scrollViews = find.byType(CustomScrollView);
      for (var pass = 0; pass < 3; pass++) {
        if (find
            .byKey(const Key('settings_covers_setup_covers_field'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
        if (scrollViews.evaluate().isNotEmpty) {
          await tester.drag(scrollViews.first, const Offset(0, -2000));
          await tester.pump();
          await pumpUntil(tester, budget: const Duration(seconds: 3));
        }
      }

      final coversField =
          find.byKey(const Key('settings_covers_setup_covers_field'));
      expect(
        coversField,
        findsOneWidget,
        reason:
            'settings_covers_setup_covers_field not found on Setup tab. '
            'Scroll may not have reached the Covers Setup section.',
      );

      // Scroll the field fully into view before tapping.
      await tester.ensureVisible(coversField);
      await tester.pump();

      await tester.tap(coversField, warnIfMissed: false);
      await tester.pump();
      await tester.enterText(coversField, '50');
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // Save button must be present (enabled state depends on date selection).
      expect(
        find.byKey(const Key('settings_covers_setup_save_button')),
        findsOneWidget,
        reason:
            'settings_covers_setup_save_button not found after entering covers.',
      );

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
