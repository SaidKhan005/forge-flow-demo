// Lane D — Scenario 03: Settings Data tab renders and demo carve-outs present.
//
// Tab order in SettingsScreen (settings_screen.dart lines 276-289):
//   Setup (index 0), Integrations (index 1), Data (index 2), Account (index 3).
// The Data tab is index 2.
//
// Data tab sections (settings_screen.dart lines 455-493):
//   - "Sync status"      → SettingsDataStatusSection
//   - "Latest updates"   → SettingsDataFreshnessSection
//   - "Data reset"       → SettingsDataManagementSection (kDemoMode gate, line 473)
//   - "Demo date"        → SettingsMockReplaySection     (kDemoMode gate, line 480)
//   - "Data alignment"   → SettingsAuditSection          (showFFSupport gate)
//
// kDemoMode carve-out #3 (CLAUDE.md + settings_screen.dart line 44-50):
// Both "Data reset" and "Demo date" sections must render in a kDemoMode=true build.
//
// SettingsDataManagementSection and SettingsMockReplaySection are defined
// in settings_data_sections.dart. The interaction test taps the first
// button found inside the "Data reset" section, checks for a dialog or
// response, then dismisses it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'scenario 03 — Data tab renders sync, freshness, and demo carve-out sections',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await openSettings(tester);
      expectSettings();

      // Data tab is index 2.
      await tapSettingsTab(tester, 2);
      await pumpUntil(tester, budget: kTabBudget);

      // Scroll to bottom so all SliverMainAxisGroup sections are built.
      // "Demo date" is a kDemoMode-only section that may be below the fold.
      final scrollViews = find.byType(CustomScrollView);
      if (scrollViews.evaluate().isNotEmpty) {
        await tester.drag(scrollViews.first, const Offset(0, -4000));
        await tester.pump();
        await pumpUntil(tester, budget: kTabBudget);
      }

      // Required section headers.
      // skipOffstage: false handles headers scrolled out of the viewport.
      expect(
        find.text('Sync status', skipOffstage: false),
        findsAtLeast(1),
        reason: 'Sync status section not found on Data tab.',
      );
      expect(
        find.text('Latest updates', skipOffstage: false),
        findsAtLeast(1),
        reason: 'Latest updates section not found on Data tab.',
      );

      // kDemoMode carve-out #3 — both demo-only sections must render.
      expect(
        find.text('Data reset', skipOffstage: false),
        findsAtLeast(1),
        reason:
            'Demo carve-out #3 violated: "Data reset" section not rendered '
            'in a kDemoMode=true build.',
      );
      expect(
        find.text('Demo date', skipOffstage: false),
        findsAtLeast(1),
        reason:
            'Demo carve-out #3 violated: "Demo date" section not rendered '
            'in a kDemoMode=true build.',
      );

      // Attempt to interact with the first ElevatedButton or FilledButton
      // in the Data tab to confirm it responds without crashing.
      // The SettingsDataManagementSection typically renders a reseed button.
      final buttons = find.byType(FilledButton);
      if (buttons.evaluate().isNotEmpty) {
        await tester.tap(buttons.first);
        await tester.pump();
        await pumpUntil(tester, budget: const Duration(seconds: 3));

        // If a dialog opened, dismiss it.
        final dialogs = find.byType(AlertDialog);
        if (dialogs.evaluate().isNotEmpty) {
          // Tap the first text button in the dialog to dismiss.
          final dialogButtons = find.descendant(
            of: dialogs.first,
            matching: find.byType(TextButton),
          );
          if (dialogButtons.evaluate().isNotEmpty) {
            await tester.tap(dialogButtons.first);
            await tester.pump();
            await pumpUntil(tester, budget: const Duration(seconds: 3));
          }
        }
      }

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow on Data tab:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
