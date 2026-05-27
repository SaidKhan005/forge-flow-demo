// integration_test/mobile_pressure/shell/scenario_shell_01_all_tabs_mount.dart
//
// Lane A — Scenario Shell-01: Every bottom-nav tab mounts the correct widget.
//
// Bottom-nav index mapping (from forge_flow_app.dart _AppBottomNav):
//   0 = Shift      → ShiftDashboard
//   1 = Variance   → VarianceReport
//   2 = Plan       → ScheduleBuilder
//   3 = Benchmark  → BaselineTracker
//   4 = Advisor    → AdvisorMobileChatScreen   (Slice D2 mobile, commit abc4da72)
//
// The AppShell uses an IndexedStack, so all widgets are built once and
// shown/hidden via visibility. We tap each tab and verify the expected
// widget type is in the tree and that there are no RenderFlex overflows.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/screens/variance_report.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';
import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/screens/advisor/advisor_mobile_chat_screen.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Shell-01: all 5 bottom-nav tabs mount their expected screen widget',
    (tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Tab 0 — Shift → ShiftDashboard (should already be active).
      await tapTab(tester, 0);
      expect(
        find.byType(ShiftDashboard),
        findsOneWidget,
        reason: 'Tab 0 (Shift) should show ShiftDashboard.',
      );

      // Tab 1 — Variance → VarianceReport.
      await tapTab(tester, 1);
      expect(
        find.byType(VarianceReport),
        findsOneWidget,
        reason: 'Tab 1 (Variance) should show VarianceReport.',
      );

      // Tab 2 — Plan → ScheduleBuilder.
      await tapTab(tester, 2);
      expect(
        find.byType(ScheduleBuilder),
        findsOneWidget,
        reason: 'Tab 2 (Plan) should show ScheduleBuilder.',
      );

      // Tab 3 — Benchmark → BaselineTracker.
      await tapTab(tester, 3);
      expect(
        find.byType(BaselineTracker),
        findsOneWidget,
        reason: 'Tab 3 (Benchmark) should show BaselineTracker.',
      );

      // Tab 4 — Advisor → AdvisorMobileChatScreen (added Slice D2 mobile).
      await tapTab(tester, 4);
      expect(
        find.byType(AdvisorMobileChatScreen),
        findsOneWidget,
        reason: 'Tab 4 (Advisor) should show AdvisorMobileChatScreen.',
      );

      // Round-trip back to Shift (tab 0) — must be non-destructive.
      await tapTab(tester, 0);
      expect(
        find.byType(ShiftDashboard),
        findsOneWidget,
        reason:
            'Round-trip to tab 0 (Shift) after visiting all tabs should '
            'still show ShiftDashboard — IndexedStack must not have destroyed it.',
      );

      // No RenderFlex overflows across any tab transition.
      expect(
        errorTap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflows detected during tab navigation: '
            '${errorTap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
