// Phase 7.55d.2 — Shift whole-day SchedulePlan alignment tests.
//
// Verifies that Shift forecast/plan values come from the whole-day
// SchedulePlan day row, and actual values are whole-business-day
// running totals aggregated from closed + open snapshots.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/services/schedule_forecast_demand_resolver.dart';
import 'package:forge_and_flow/domain/services/schedule_plan_resolver.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/services/labor_model.dart';

ActiveTargetProfile _profile() => ActiveTargetProfile(
      targetProfileId: 'test_active',
      restaurantId: 'demo_restaurant_001',
      sourceType: 'system_baseline',
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      fohWage: MeridianConfig.fohWage,
      bohWage: MeridianConfig.bohWage,
      opzFloorCPLH: BaselineData.opzFloorCPLH,
      opzCeilingCPLH: BaselineData.opzCeilingCPLH,
      theoreticalFohLaborPct: BaselineData.derivedFohTheoreticalLaborPct,
      theoreticalBohLaborPct: BaselineData.derivedBohTheoreticalLaborPct,
      theoreticalLaborPct: BaselineData.derivedTheoreticalLaborPct,
      builtAt: '2026-03-27T19:42:00',
    );

/// Build the same SchedulePlan the notifier resolves.
void main() {
  final profile = _profile();
  final demand = ScheduleForecastDemandResolver.resolve(
    targetPPA: profile.targetPPA,
    historicalWeeklyAvgCovers: BaselineData.historicalWeeklyAvgCovers,
  );
  final plan = SchedulePlanResolver.resolve(demand: demand, profile: profile)!;
  final fridayPlan = plan.dayPlans.firstWhere((d) => d.day == 'Fri');

  // Whole-day demo snapshots
  final lunchClosed = OpenShiftSnapshot(
    restaurantId: 'demo_restaurant_001',
    weekId: '2026-W13',
    dayLabel: 'Fri',
    daypart: 'lunch',
    status: 'closed',
    businessDate: '2026-03-27',
    forecastCovers: 180,
    currentCovers: 150,
    scheduledFohHours: 29,
    scheduledBohHours: 30,
    currentPPA: 41.00,
    currentCPLH: 5.17,
    currentSPLH: 205.0,
    blendedWage: 18.74,
    updatedAt: '2026-03-27T14:00:00',
  );

  final dinnerOpen = OpenShiftSnapshot(
    restaurantId: 'demo_restaurant_001',
    weekId: '2026-W13',
    dayLabel: 'Fri',
    daypart: 'dinner',
    status: 'open',
    businessDate: '2026-03-27',
    forecastCovers: ShiftSnapshot.shiftForecastCovers,
    currentCovers: ShiftSnapshot.actualCovers,
    scheduledFohHours: ShiftSnapshot.scheduledFohHours,
    scheduledBohHours: ShiftSnapshot.scheduledBohHours,
    currentPPA: ShiftSnapshot.actualPPA,
    currentCPLH: ShiftSnapshot.actualCPLH,
    currentSPLH: ShiftSnapshot.actualSPLH,
    blendedWage: ShiftSnapshot.blendedWage,
    timeLabel: ShiftSnapshot.time,
    serviceElapsedLabel: ShiftSnapshot.serviceElapsed,
    updatedAt: '2026-03-27T19:42:00',
  );

  final lateNightProjected = OpenShiftSnapshot(
    restaurantId: 'demo_restaurant_001',
    weekId: '2026-W13',
    dayLabel: 'Fri',
    daypart: 'late_night',
    status: 'projected',
    businessDate: '2026-03-27',
    forecastCovers: 90,
    currentCovers: 90,
    scheduledFohHours: 20,
    scheduledBohHours: 21,
    currentPPA: 42.00,
    currentCPLH: 4.50,
    currentSPLH: 180.0,
    blendedWage: 18.98,
    updatedAt: '2026-03-27T19:42:00',
  );

  final snapshots = [lunchClosed, dinnerOpen, lateNightProjected];

  late ShiftDashboardReadModel rm;
  setUp(() {
    rm = ShiftDashboardReadModel.buildWholeDay(
      snapshots: snapshots,
      profile: profile,
      forecastCovers: fridayPlan.forecastCovers,
      forecastSales: fridayPlan.forecastSales,
      planFohHours: fridayPlan.requiredFohHours,
      planBohHours: fridayPlan.requiredBohHours,
      inTheBooksCovers: 72,
    );
  });

  // ── A+I: Plan values match SchedulePlan and LaborModel ─────────────────

  group('A — plan values from SchedulePlan', () {
    test('forecast covers, sales, FOH, BOH all match Friday day row', () {
      expect(rm.forecastCovers, equals(fridayPlan.forecastCovers));
      expect(rm.forecastSales, equals(fridayPlan.forecastSales));
      expect(rm.planFohHours, equals(fridayPlan.requiredFohHours));
      expect(rm.planBohHours, equals(fridayPlan.requiredBohHours));
    });

    test('weekly plan hours use LaborModel; day sums reconcile', () {
      final weeklyFoh = LaborModel.modelFohHours(
          plan.forecastCovers, profile.targetCPLH);
      final weeklyBoh = LaborModel.modelBohHoursFromSales(
          plan.forecastSales, profile.targetSPLH);
      expect(plan.requiredFohHours, equals(weeklyFoh));
      expect(plan.requiredBohHours, equals(weeklyBoh));

      final dayFohSum = plan.dayPlans.fold<int>(0, (s, d) => s + d.requiredFohHours);
      final dayBohSum = plan.dayPlans.fold<int>(0, (s, d) => s + d.requiredBohHours);
      expect(dayFohSum, equals(weeklyFoh));
      expect(dayBohSum, equals(weeklyBoh));
    });
  });

  // ── B+E+G: Actual values — whole-day totals, projected excluded ────────

  group('B — actual values and projected exclusion', () {
    test('actual covers/sales/PPA use closed+open only, not projected', () {
      // lunch (150) + dinner (52) — late_night projected excluded
      expect(rm.actualCovers, equals(202));
      final expectedSales = 150 * 41.00 + 52 * 41.20;
      expect(rm.actualSales, closeTo(expectedSales, 0.01));
      expect(rm.actualPPA, closeTo(expectedSales / 202, 0.01));
    });

    test('actual hours and productivity exclude projected dayparts', () {
      // Actual hours: closed + open only
      expect(rm.actualFohHours, equals(29 + 20));
      expect(rm.actualBohHours, equals(30 + 21));

      // CPLH/SPLH use actual-to-date hours
      expect(rm.actualCPLH, closeTo(202 / 49, 0.01));
      expect(rm.actualCPLH, isNot(closeTo(202 / 69, 0.01))); // not full-day scheduled

      final expectedSales = 150 * 41.00 + 52 * 41.20;
      expect(rm.actualSPLH, closeTo(expectedSales / 51, 0.01));
      expect(rm.actualSPLH, isNot(closeTo(expectedSales / 72, 0.01)));
    });

    test('scheduled hours include all dayparts including projected', () {
      expect(rm.scheduledFohHours, equals(69));
      expect(rm.scheduledBohHours, equals(72));
    });

    test('OPZ uses actual-to-date CPLH', () {
      final expectedCPLH = 202 / 49;
      final p = _profile();
      if (expectedCPLH < p.opzFloorCPLH) {
        expect(rm.opzStatus, equals('below'));
      } else if (expectedCPLH > p.opzCeilingCPLH) {
        expect(rm.opzStatus, equals('above'));
      } else {
        expect(rm.opzStatus, equals('in'));
      }
    });
  });

  // ── C+K: Target PPA guardrail ──────────────────────────────────────────

  group('C — target PPA does not rewrite actuals', () {
    test('changing target PPA changes plan sales and targetLaborPct but not actuals', () {
      final modifiedProfile = ActiveTargetProfile(
        targetProfileId: 'test_modified',
        restaurantId: 'demo_restaurant_001',
        sourceType: 'manager_override',
        targetCPLH: profile.targetCPLH,
        targetSPLH: profile.targetSPLH,
        targetPPA: 50.00,
        fohWage: profile.fohWage,
        bohWage: profile.bohWage,
        opzFloorCPLH: profile.opzFloorCPLH,
        opzCeilingCPLH: profile.opzCeilingCPLH,
        theoreticalFohLaborPct: profile.theoreticalFohLaborPct,
        theoreticalBohLaborPct: profile.theoreticalBohLaborPct,
        theoreticalLaborPct: profile.theoreticalLaborPct,
        builtAt: '2026-03-27T19:42:00',
      );
      final newDemand = ScheduleForecastDemandResolver.resolve(
        targetPPA: modifiedProfile.targetPPA,
        historicalWeeklyAvgCovers: BaselineData.historicalWeeklyAvgCovers,
      );
      final newPlan = SchedulePlanResolver.resolve(
          demand: newDemand, profile: modifiedProfile)!;
      final newFriday = newPlan.dayPlans.firstWhere((d) => d.day == 'Fri');

      final modifiedRm = ShiftDashboardReadModel.buildWholeDay(
        snapshots: snapshots,
        profile: modifiedProfile,
        forecastCovers: newFriday.forecastCovers,
        forecastSales: newFriday.forecastSales,
        planFohHours: newFriday.requiredFohHours,
        planBohHours: newFriday.requiredBohHours,
      );

      // Plan forecast sales changed
      expect(modifiedRm.forecastSales, greaterThan(rm.forecastSales));
      // Actual values unchanged
      expect(modifiedRm.actualSales, equals(rm.actualSales));
      expect(modifiedRm.actualCovers, equals(rm.actualCovers));
      expect(modifiedRm.actualLaborPct, closeTo(rm.actualLaborPct, 0.001));
      expect(modifiedRm.actualLaborDollars, closeTo(rm.actualLaborDollars, 0.01));
      // Target labor % changed
      expect(modifiedRm.targetLaborPct, isNot(closeTo(rm.targetLaborPct, 0.1)));
    });
  });

  // ── D: Reservation in-the-books is contextual ──────────────────────────

  group('D — reservation in-the-books is contextual only', () {
    test('inTheBooksCovers does not change actual or forecast covers', () {
      final rmWith = ShiftDashboardReadModel.buildWholeDay(
        snapshots: snapshots, profile: profile,
        forecastCovers: fridayPlan.forecastCovers,
        forecastSales: fridayPlan.forecastSales,
        planFohHours: fridayPlan.requiredFohHours,
        planBohHours: fridayPlan.requiredBohHours,
        inTheBooksCovers: 100,
      );
      final rmWithout = ShiftDashboardReadModel.buildWholeDay(
        snapshots: snapshots, profile: profile,
        forecastCovers: fridayPlan.forecastCovers,
        forecastSales: fridayPlan.forecastSales,
        planFohHours: fridayPlan.requiredFohHours,
        planBohHours: fridayPlan.requiredBohHours,
      );
      expect(rmWith.actualCovers, equals(rmWithout.actualCovers));
      expect(rmWith.forecastCovers, equals(rmWithout.forecastCovers));
    });
  });

  // ── F: Whole-day header ────────────────────────────────────────────────

  group('F — whole-day header', () {
    test('multi-snapshot: daypart empty, day label full name', () {
      expect(rm.daypart, equals(''));
      expect(rm.day, equals('Friday'));
    });
  });

  // ── H: No daypart fallback ─────────────────────────────────────────────

  group('H — no daypart fallback', () {
    test('single-snapshot build works for test paths', () {
      final singleRm = ShiftDashboardReadModel.build(dinnerOpen, profile);
      expect(singleRm.forecastCovers, equals(ShiftSnapshot.shiftForecastCovers));
      expect(singleRm.daypart, equals('Dinner'));
    });
  });

  // ── J: Whole-day labor % from read model ───────────────────────────────

  group('J — whole-day labor % from read model', () {
    test('labor dollars, percentages, and variance all consistent', () {
      final lunchWageDollars = 18.74 * (29 + 30);
      final dinnerWageDollars = ShiftSnapshot.blendedWage * (20 + 21);
      final actualLaborDollars = lunchWageDollars + dinnerWageDollars;
      final actualSales = 150 * 41.00 + 52 * 41.20;

      // Actual labor dollars
      expect(rm.actualLaborDollars, closeTo(actualLaborDollars, 0.01));
      // Actual labor %
      expect(rm.actualLaborPct, closeTo(actualLaborDollars / actualSales * 100, 0.01));

      // Projected excluded from actual labor %
      final projectedDollars = 18.98 * (20 + 21);
      final projectedSales = 90 * 42.00;
      final withProjected = (actualLaborDollars + projectedDollars) /
          (actualSales + projectedSales) * 100;
      expect(rm.actualLaborPct, isNot(closeTo(withProjected, 0.5)));

      // Target labor dollars and %
      final targetDollars =
          fridayPlan.requiredFohHours * MeridianConfig.fohWage +
          fridayPlan.requiredBohHours * MeridianConfig.bohWage;
      expect(rm.targetLaborDollars, closeTo(targetDollars, 0.01));
      expect(rm.targetLaborPct,
          closeTo(targetDollars / fridayPlan.forecastSales * 100, 0.01));

      // Variance
      expect(rm.laborVariancePts,
          closeTo(rm.actualLaborPct - rm.targetLaborPct, 0.001));
    });
  });
}
