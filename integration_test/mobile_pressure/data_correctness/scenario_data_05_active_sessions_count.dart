// Lane E — Scenario 05: Active Sessions section shows exactly 3 demo sessions.
//
// DemoActiveSessionsFixtures seeds exactly 3 sessions when
// allowDemoGatewayFallback=true. Each session row is keyed as
// Key('active_sessions_row_$sessionId'). This scenario scrolls to the
// Active Sessions section on the Account tab and asserts the count.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'data-05 — Active Sessions section shows exactly 3 demo session rows',
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

      // Scroll to build all SliverMainAxisGroup sections below the fold.
      final scrollViews = find.byType(CustomScrollView);
      if (scrollViews.evaluate().isNotEmpty) {
        await tester.drag(scrollViews.first, const Offset(0, -4000));
        await tester.pump();
        await pumpUntil(tester, budget: kTabBudget);
      }

      // Active sessions section header must be present.
      expect(
        find.text('Active sessions', skipOffstage: false),
        findsAtLeast(1),
        reason: 'Active sessions section header not found on Account tab.',
      );

      // Each _ActiveSessionRow is keyed Key('active_sessions_row_<sessionId>').
      // DemoActiveSessionsFixtures seeds exactly 3 entries.
      final sessionRows = find.byWidgetPredicate(
        (w) {
          final k = w.key;
          return k is ValueKey<String> &&
              k.value.startsWith('active_sessions_row_');
        },
        skipOffstage: false,
      );
      expect(
        sessionRows,
        findsNWidgets(3),
        reason:
            'Expected exactly 3 active session rows (DemoActiveSessionsFixtures '
            'seeds 3). Found ${sessionRows.evaluate().length} rows instead.',
      );

      expect(tap.overflowErrors, isEmpty);
    },
  );
}
