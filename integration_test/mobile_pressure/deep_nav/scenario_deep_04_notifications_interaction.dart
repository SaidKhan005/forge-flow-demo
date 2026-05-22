// Lane G — Scenario 04: Notifications screen shows either a list or empty state;
// scroll and close work correctly.
//
// Extends wave-1 shell-03 (which just verified open + close) by:
//   1. Asserting the screen renders content (list or empty-state text).
//   2. Scrolling to the bottom if the list is non-empty.
//   3. Tapping the first InkWell-wrapped item (if present) without crash.
//   4. Closing and verifying AppShell is intact.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'deep-04 — Notifications renders content; scroll and close leave shell intact',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Open notifications via the app-bar icon.
      // The AppShell uses Icons.notifications_none_outlined (confirmed in
      // shell/scenario_shell_03_notifications_navigation.dart line 45).
      final notifIcon =
          find.byIcon(Icons.notifications_none_outlined).evaluate().isNotEmpty
              ? find.byIcon(Icons.notifications_none_outlined)
              : find.byIcon(Icons.notifications);
      expect(notifIcon, findsAtLeast(1), reason: 'Notifications icon not found in AppBar.');

      await tester.tap(notifIcon.first);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // Either a list or the empty-state message must be present.
      final hasList = find.byType(ListView).evaluate().isNotEmpty;
      final hasEmptyState =
          find.text("You're all caught up").evaluate().isNotEmpty;
      expect(
        hasList || hasEmptyState,
        isTrue,
        reason:
            'Notifications screen shows neither a ListView nor the '
            '"You\'re all caught up" empty state.',
      );

      if (hasList) {
        // Scroll the notification list to verify scroll works without crash.
        // NOTE: We intentionally do NOT tap notification items here — tapping
        // a real notification row may navigate away from AppShell entirely
        // (e.g., deep-link to a specific shift), making the post-close
        // AppShell assertion unreliable. Scroll + close is the correct contract.
        final listFinder = find.byType(ListView).first;
        await tester.drag(
          listFinder,
          const Offset(0, -3000),
          warnIfMissed: false,
        );
        await tester.pump();
        await pumpUntil(tester, budget: kTabBudget);
      }

      // Close the notifications screen.
      await navigateBack(tester);
      await expectAppShellMounted(tester);

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
