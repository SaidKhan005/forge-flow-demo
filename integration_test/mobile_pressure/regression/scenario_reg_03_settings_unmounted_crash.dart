// Lane D — Regression Scenario 03: Settings unmounted setState crash.
//
// Regression for the bug fixed in PR #821:
//   `_refreshAfterWrite` (settings_screen.dart line 174) called
//   `setState()` after the widget was disposed, throwing:
//   'setState() called after dispose()'
//
// Root cause: async data-action closures (reseed / date-advance / clear)
// awaited a long write, then called `_refreshAfterWrite` which read
// `State.context` on a defunct State. The fix guards with `State.mounted`
// (not `context.mounted`) before every `setState` and context read.
//
// Reproduction path:
//   1. Open Settings → Data tab (index 2).
//   2. Trigger a data-refresh action (pull-to-refresh or tap a FilledButton
//      in the Data reset / Demo date sections).
//   3. IMMEDIATELY navigate away before the async write completes.
//   4. Pump for 5+ seconds to let callbacks fire.
//   5. Assert no 'setState() called after dispose()' exception.
//
// The test does NOT need to verify that the write completed — only that
// the callback returning to a disposed widget does not crash the app.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/forge_flow_app.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'regression 03 — no setState-after-dispose crash when navigating away during refresh',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      await openSettings(tester);
      expectSettings();

      // Navigate to the Data tab (index 2) where refresh actions live.
      await tapSettingsTab(tester, 2);
      await pumpUntil(tester, budget: kTabBudget);

      // Confirm the Data tab is visible.
      expect(
        find.text('Sync status'),
        findsAtLeast(1),
        reason: 'Data tab did not render — cannot exercise the regression path.',
      );

      // Trigger a refresh: attempt pull-to-refresh on the CustomScrollView.
      // This fires _handlePullToRefresh → _refreshAppState which awaits async
      // work and then calls setState. We want to navigate away before it finishes.
      final scrollViews = find.byType(CustomScrollView);
      if (scrollViews.evaluate().isNotEmpty) {
        // Simulate a pull-to-refresh gesture by dragging down.
        await tester.drag(scrollViews.first, const Offset(0, 300));
        await tester.pump(); // start the animation
        // Immediately navigate away before the refresh completes.
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).last,
        );
        if (navigator.canPop()) {
          navigator.pop();
          await tester.pump();
        }
      } else {
        // Fallback: if no scroll view found, try tapping the first FilledButton
        // in the Data tab (e.g. reseed button in Data reset section) and
        // immediately navigate away.
        final buttons = find.byType(FilledButton);
        if (buttons.evaluate().isNotEmpty) {
          await tester.tap(buttons.first, warnIfMissed: false);
          await tester.pump(); // start the async action
          final navigator = tester.state<NavigatorState>(
            find.byType(Navigator).last,
          );
          if (navigator.canPop()) {
            navigator.pop();
            await tester.pump();
          }
        }
      }

      // Pump for 5 seconds to let any in-flight async callbacks complete
      // and attempt setState on the (now disposed) SettingsScreen state.
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Core regression assertion: no 'setState() called after dispose()'.
      final stateErrors = tap.all.where(
        (e) => e.exception.toString().contains('setState() called after dispose()'),
      ).toList();
      expect(
        stateErrors,
        isEmpty,
        reason:
            'Regression regressed: setState() called after dispose() was thrown.\n'
            '${stateErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );

      // App should still be in a usable state.
      expect(
        find.byType(AppShell),
        findsOneWidget,
        reason:
            'AppShell unmounted after navigating away from Settings — '
            'app is in an unusable state.',
      );
      expect(
        find.byType(BottomNavigationBar),
        findsAtLeast(1),
        reason: 'BottomNavigationBar missing — app shell may have crashed.',
      );
    },
  );
}
