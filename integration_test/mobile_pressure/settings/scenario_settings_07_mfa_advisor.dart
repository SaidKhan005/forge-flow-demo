// Lane D — Scenario 07: MFA section on Account tab renders without crash.
//
// SettingsMfaSection (settings_mfa_section.dart) is mounted on the Account
// tab (index 3) under the section title "Two-factor sign-in"
// (settings_screen.dart lines 511-525).
//
// SettingsAdvisorCorpusSection and SettingsAdvisorModelSection are dev-only
// (gated on kDebugMode) and are NOT mounted in the standard SettingsScreen
// build. They require explicit service injection and are not reachable via
// normal navigation in a demo-mode integration test.
//
// This scenario:
//   1. Navigates to the Account tab (index 3).
//   2. Asserts "Two-factor sign-in" section header renders.
//   3. Asserts SettingsMfaSection mounts (finds the section's content area
//      which contains the MFA status / enroll button).
//   4. Confirms no blank section and no crashes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings/settings_mfa_section.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'scenario 07 — MFA section renders on Account tab without crash',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await openSettings(tester);
      expectSettings();

      // Account tab is index 3.
      await tapSettingsTab(tester, 3);
      await pumpUntil(tester, budget: kTabBudget);

      // "Two-factor sign-in" section header.
      expect(
        find.text('Two-factor sign-in'),
        findsAtLeast(1),
        reason:
            'Two-factor sign-in section header not found on Account tab.',
      );

      // SettingsMfaSection widget should be mounted.
      expect(
        find.byType(SettingsMfaSection),
        findsOneWidget,
        reason: 'SettingsMfaSection widget not found in Account tab.',
      );

      // The section renders non-empty content. After allowing async
      // loading to settle, at least one Text widget should be visible
      // inside the MFA section.
      await pumpUntil(tester, budget: const Duration(seconds: 5));

      final mfaSection = find.byType(SettingsMfaSection);
      final contentInSection = find.descendant(
        of: mfaSection,
        matching: find.byType(Text),
      );
      expect(
        contentInSection.evaluate().isNotEmpty,
        isTrue,
        reason: 'SettingsMfaSection rendered with no text content (blank section).',
      );

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow on MFA scenario:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
