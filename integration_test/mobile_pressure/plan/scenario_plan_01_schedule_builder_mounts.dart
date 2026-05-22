// integration_test/mobile_pressure/plan/scenario_plan_01_schedule_builder_mounts.dart
//
// Lane C — Plan tab mount check.
//
// Verifies the ScheduleBuilder widget tree mounts after tapping tab 2
// (Plan), that no CircularProgressIndicator is stuck, and that the
// screen's always-present section headers are visible.
//
// Tab indices (forge_flow_app.dart _AppShellState._buildBody):
//   0 = Shift, 1 = Variance, 2 = Plan, 3 = Benchmark.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/schedule_builder.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Plan tab: ScheduleBuilder mounts with section headers, no stuck spinner, no overflow',
    (tester) async {
      final errorTap = FlutterErrorTap.install();
      addTearDown(errorTap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);

      // Navigate to Plan tab (index 2).
      await tapTab(tester, 2);

      // Assert ScheduleBuilder is in the widget tree.
      expect(
        find.byType(ScheduleBuilder),
        findsOneWidget,
        reason: 'ScheduleBuilder must be mounted on Plan tab.',
      );

      // Assert no stuck CircularProgressIndicator.
      // A brief spinner during load is acceptable; we pump enough time
      // for the locked plan to finish or surface its unavailable state.
      await pumpUntil(
        tester,
        budget: const Duration(seconds: 10),
      );
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason:
            'No CircularProgressIndicator should remain after plan load budget.',
      );

      // Assert the screen is not blank: the "LABOR PLAN" section header
      // is rendered by StickySectionDelegate and is always present
      // regardless of whether the locked plan is available.
      expect(
        find.text('LABOR PLAN'),
        findsOneWidget,
        reason: 'LABOR PLAN section header must always be present.',
      );

      // The "COVER FORECAST ADJUSTED BY DAY" and "DAY-BY-DAY PLAN"
      // headers are also always-rendered slivers.
      expect(
        find.text('COVER FORECAST ADJUSTED BY DAY'),
        findsOneWidget,
        reason: 'COVER FORECAST ADJUSTED BY DAY section header must be present.',
      );
      expect(
        find.text('DAY-BY-DAY PLAN'),
        findsOneWidget,
        reason: 'DAY-BY-DAY PLAN section header must be present.',
      );

      // Screen header title is always rendered.
      expect(
        find.text('Weekly Operating Plan'),
        findsOneWidget,
        reason: 'Screen title "Weekly Operating Plan" must be present.',
      );

      // No RenderFlex overflows.
      expect(
        errorTap.overflowErrors,
        isEmpty,
        reason: 'No RenderFlex overflows expected on Plan tab.',
      );
    },
  );
}
