// Phase 7.55i.2a — Schedule Builder notifier shared-plan authority test.
//
// Validates:
// A. ScheduleForecastNotifier delegates plan resolution to SchedulePlanReadService
//
// Mirror-widget tests (Groups A–D from the original file) were removed because
// they reimplemented simplified copies of production UI and duplicated notifier
// value assertions already covered by schedule_plan_resolver_test (Groups F, D)
// and schedule_forecast_demand_resolver_test (Group B).

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
}
