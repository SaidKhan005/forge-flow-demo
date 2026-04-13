// Phase 7.55i.2a — Schedule Builder notifier shared-plan authority test.
// Phase 7.55m.6a — Real ScheduleBuilder widget regression coverage for
// section labels added in 7.55m.6.
//
// Validates:
// A. ScheduleForecastNotifier delegates plan resolution to SchedulePlanReadService
// B. Real ScheduleBuilder content renders the three section labels and does
//    not render the old in-card chart caption

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/schedule_plan_read_service.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';

void main() {
  const testCPLH = 4.5;
  const testPPA = 42.0;
  const testSPLH = 180.0;
  const testFohWage = 16.50;
  const testBohWage = 21.35;
  const testCovers = 1200;

  // ── A: Shared plan authority alignment ───────────────────────────────────

  group('A — Shared plan authority alignment', () {
    test('notifier plan matches SchedulePlanReadService.resolveFromInputs', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );

      final servicePlan = SchedulePlanReadService.resolveFromInputs(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );

      expect(notifier.plan, isNotNull);
      expect(servicePlan, isNotNull);
      expect(notifier.plan!.forecastCovers, equals(servicePlan!.forecastCovers));
      expect(notifier.plan!.forecastSales, equals(servicePlan.forecastSales));
      expect(notifier.plan!.requiredFohHours, equals(servicePlan.requiredFohHours));
      expect(notifier.plan!.requiredBohHours, equals(servicePlan.requiredBohHours));
      expect(notifier.plan!.theoreticalLaborPct,
          equals(servicePlan.theoreticalLaborPct));

      notifier.dispose();
    });
  });

  // ── B: Plan section labels — real widget (7.55m.6a) ─────────────────────

  group('B — Plan section labels (7.55m.6a)', () {
    testWidgets('real ScheduleBuilder content renders section labels',
        (tester) async {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleBuilder.testContent(notifier),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('WEEKLY PLAN SUMMARY'), findsOneWidget);
      expect(find.text('COVER FORECAST BY DAY'), findsOneWidget);
      expect(find.text('DAY-BY-DAY PLAN'), findsOneWidget);

      notifier.dispose();
    });

    testWidgets('old in-card chart caption is absent from real widget tree',
        (tester) async {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleBuilder.testContent(notifier),
          ),
        ),
      );
      await tester.pump();

      // The old caption was removed in 7.55m.6 and replaced by the
      // COVER FORECAST BY DAY section label.
      expect(
        find.text('COVER FORECAST DISTRIBUTED BY DAY', skipOffstage: false),
        findsNothing,
      );

      notifier.dispose();
    });
  });
}
