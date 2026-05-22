// Lane D — Scenario 02: Settings Setup/Authority tab renders without crash.
//
// Tab order in SettingsScreen (settings_screen.dart lines 276-289):
//   Setup (index 0), Integrations (index 1), Data (index 2), Account (index 3).
// The Setup tab is index 0.
//
// Setup tab sections (settings_screen.dart lines 340-431):
//   - "Covers setup"    → SettingsCoversSetupSection
//   - "Business timing" → TimingAuthoritySection
//   - Pointer row "Manage Timing on Ops Web"
//   - "Wage setup"      → WageAuthoritySection (key: 'settings_wage_setup_section')
//   - Pointer row "Manage Wage on Ops Web"
//
// WageAuthoritySection renders:
//   - A blended-wage summary card (key: 'settings_wage_setup_summary_card')
//   - Source label row (key: 'settings_wage_setup_source')
//   - Three bucket cards: foh, boh, manager
//     (keys: 'settings_wage_setup_bucket_foh' etc.)
//
// TimingAuthoritySection renders a SettingsCard once the FutureBuilder resolves.
// In demo mode SQLite is seeded, so config should resolve.
//
// SettingsCoversSetupSection:
//   Header title: 'Record cover counts' (settings_covers_setup_section.dart line 684)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'scenario 02 — Setup/Authority tab renders wage, timing, and covers without crash',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await openSettings(tester);
      expectSettings();

      // Setup is index 0 in the Settings bar.
      await tapSettingsTab(tester, 0);
      await pumpUntil(tester, budget: kTabBudget);

      // Section headers rendered by StickySectionDelegate.
      expect(
        find.text('Wage setup'),
        findsAtLeast(1),
        reason: 'Wage setup section header not rendered on Setup tab.',
      );
      expect(
        find.text('Business timing'),
        findsAtLeast(1),
        reason: 'Business timing section header not rendered on Setup tab.',
      );
      expect(
        find.text('Covers setup'),
        findsAtLeast(1),
        reason: 'Covers setup section header not rendered on Setup tab.',
      );

      // WageAuthoritySection: the section widget itself has a key.
      expect(
        find.byKey(const Key('settings_wage_setup_section')),
        findsOneWidget,
        reason: 'WageAuthoritySection container key not found.',
      );

      // Covers setup section header text
      // (settings_covers_setup_section.dart _Header title).
      expect(
        find.text('Record cover counts'),
        findsAtLeast(1),
        reason: 'Covers setup header text not rendered.',
      );

      // Pointer rows for ops-web navigation.
      expect(
        find.text('Manage Wage on Ops Web'),
        findsAtLeast(1),
        reason: 'Manage Wage pointer row label not found.',
      );
      expect(
        find.text('Manage Timing on Ops Web'),
        findsAtLeast(1),
        reason: 'Manage Timing pointer row label not found.',
      );

      // No stuck spinner — no CircularProgressIndicator remaining after pump.
      await pumpUntil(tester, budget: const Duration(seconds: 5));

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow on Setup tab:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
