// Phase 7.55d.1 + 7.55d.1a + 7.55d.1b + 7.55d.1c — SchedulePlanResolver Tests
//
// Verifies the shared SchedulePlan authority:
//   - Forecast covers from 60-day history resolve correctly
//   - Forecast sales always = covers × current profile targetPPA (not stale demand sales)
//   - FOH hours = covers / targetCPLH
//   - BOH hours = forecastSales / targetSPLH
//   - Theoretical labor dollars and target blended wage use wages + model hour mix
//   - Target PPA changes sales/BOH but not covers/FOH
//   - Source provenance is preserved
//   - Day-level plan rows reconcile exactly with weekly totals (covers, FOH, BOH)
//   - dayPlans list is immutable
//   - Unavailable demand does not become a fabricated plan

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/schedule_distribution_weights.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/schedule_plan.dart';
import 'package:forge_and_flow/domain/services/schedule_forecast_demand_resolver.dart';
import 'package:forge_and_flow/domain/services/schedule_plan_resolver.dart';
import 'package:forge_and_flow/services/labor_model.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';

ActiveTargetProfile _testProfile({
  double targetCPLH = 4.5,
  double targetSPLH = 180.0,
  double targetPPA = 42.0,
  double fohWage = 16.50,
  double bohWage = 21.35,
}) =>
    ActiveTargetProfile(
      targetProfileId: 'test',
      restaurantId: 'test_restaurant',
      sourceType: 'system_baseline',
      targetCPLH: targetCPLH,
      targetSPLH: targetSPLH,
      targetPPA: targetPPA,
      fohWage: fohWage,
      bohWage: bohWage,
      opzFloorCPLH: 3.5,
      opzCeilingCPLH: 5.8,
      theoreticalFohLaborPct: 8.6,
      theoreticalBohLaborPct: 11.9,
      theoreticalLaborPct: 20.5,
      builtAt: '2026-04-10T00:00:00',
    );

SchedulePlan _plan({
  int covers = 1200,
  double ppa = 42.0,
  double cplh = 4.5,
  double splh = 180.0,
  double fohWage = 16.50,
  double bohWage = 21.35,
  ForecastDemandSource source = ForecastDemandSource.appDerivedFromHistoricalAverage,
}) =>
    SchedulePlanResolver.resolveFromValues(
      forecastCovers: covers,
      targetPPA: ppa,
      targetCPLH: cplh,
      targetSPLH: splh,
      fohWage: fohWage,
      bohWage: bohWage,
      coversSource: source,
    );

void main() {
  // ── A+B: Forecast resolution and sales derivation ────────────────────────

  group('A — forecast resolution and sales derivation', () {
    test('60-day history resolves; unavailable returns null plan', () {
      final demand = ScheduleForecastDemandResolver.resolve(
        targetPPA: 42.0,
        historicalWeeklyAvgCovers: 1200,
      );
      final plan = SchedulePlanResolver.resolve(
        demand: demand,
        profile: _testProfile(),
      );
      expect(plan, isNotNull);
      expect(plan!.forecastCovers, 1200);

      // Unavailable demand
      final nullPlan = SchedulePlanResolver.resolve(
        demand: ScheduleForecastDemand.unavailable,
        profile: _testProfile(),
      );
      expect(nullPlan, isNull);
    });

    test('forecast sales = covers × target PPA; changing PPA changes sales', () {
      final plan42 = _plan(ppa: 42.0);
      final plan45 = _plan(ppa: 45.0);
      expect(plan42.forecastSales, 1200 * 42.0);
      expect(plan45.forecastSales, 1200 * 45.0);
      expect(plan42.forecastCovers, plan45.forecastCovers);
      expect(plan45.forecastSales, isNot(plan42.forecastSales));
    });
  });

  // ── B2: Stale PPA prevention ─────────────────────────────────────────────

  group('B2 — stale PPA prevention', () {
    test('resolve() uses profile PPA, not demand PPA; PPA changes BOH not FOH', () {
      final demand = ScheduleForecastDemandResolver.resolve(
        targetPPA: 42.0,
        historicalWeeklyAvgCovers: 1200,
      );
      expect(demand.forecastSales, 1200 * 42.0);

      final plan42 = SchedulePlanResolver.resolve(
        demand: demand,
        profile: _testProfile(targetPPA: 42.0),
      );
      final plan45 = SchedulePlanResolver.resolve(
        demand: demand,
        profile: _testProfile(targetPPA: 45.0),
      );

      // Plan sales use profile PPA (45), not demand PPA (42)
      expect(plan45!.forecastSales, 1200 * 45.0);
      expect(plan45.forecastSales, isNot(1200 * 42.0));

      // FOH unchanged (covers/CPLH), BOH changed (sales/SPLH)
      expect(plan42!.requiredFohHours, plan45.requiredFohHours);
      expect(plan42.requiredBohHours, isNot(plan45.requiredBohHours));
      expect(plan45.requiredBohHours,
          LaborModel.modelBohHoursFromSales(1200 * 45.0, 180.0));
    });
  });

  // ── C: FOH and BOH hours ─────────────────────────────────────────────────

  group('C — FOH and BOH hours', () {
    test('FOH = covers/CPLH, BOH = sales/SPLH; PPA changes BOH not FOH', () {
      final plan = _plan();
      expect(plan.requiredFohHours, LaborModel.modelFohHours(1200, 4.5));
      expect(plan.requiredBohHours,
          LaborModel.modelBohHoursFromSales(1200 * 42.0, 180.0));

      final plan50 = _plan(ppa: 50.0);
      expect(plan.requiredFohHours, plan50.requiredFohHours);
      expect(plan50.requiredBohHours, isNot(plan.requiredBohHours));
    });
  });

  // ── D: Labor dollars, blended wage, labor % ──────────────────────────────

  group('D — labor outputs derive from plan hours and wages', () {
    test('labor dollars, blended wage, and labor % all consistent', () {
      final plan = _plan();
      expect(plan.theoreticalFohLaborDollars, plan.requiredFohHours * 16.50);
      expect(plan.theoreticalBohLaborDollars, plan.requiredBohHours * 21.35);

      final expectedWage = plan.theoreticalTotalLaborDollars /
          plan.totalRequiredHours;
      expect(plan.targetBlendedWage, closeTo(expectedWage, 0.001));

      final expectedPct = plan.theoreticalTotalLaborDollars /
          plan.forecastSales * 100;
      expect(plan.theoreticalLaborPct, closeTo(expectedPct, 0.001));
    });
  });

  // ── E: Source provenance ─────────────────────────────────────────────────

  group('E — source provenance', () {
    test('historical and demo sources preserved correctly', () {
      final demand = ScheduleForecastDemandResolver.resolve(
        targetPPA: 42.0,
        historicalWeeklyAvgCovers: 1200,
      );
      final plan = SchedulePlanResolver.resolve(
        demand: demand,
        profile: _testProfile(),
      );
      expect(plan!.coversSource,
          ForecastDemandSource.appDerivedFromHistoricalAverage);
      expect(plan.salesSource,
          ForecastDemandSource.appDerivedFromCoversAndPpa);
      expect(plan.coversSourceLabel, '60-day weekly average');

      final demo = _plan(source: ForecastDemandSource.demoFallback);
      expect(demo.coversSource, ForecastDemandSource.demoFallback);
      expect(demo.coversSourceLabel, 'Demo fallback');
    });
  });

  // ── F: Notifier delegates to SchedulePlan ────────────────────────────────

  group('F — notifier delegates to plan', () {
    test('notifier weekly values match resolver output', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.5,
        targetPPA: 42.0,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        theoreticalLaborPct: 20.5,
        initialCovers: 1200,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      );

      final plan = _plan();

      expect(notifier.weeklyCovers, plan.forecastCovers);
      expect(notifier.forecastedSales, plan.forecastSales);
      expect(notifier.requiredFohHours, plan.requiredFohHours);
      expect(notifier.requiredBohHours, plan.requiredBohHours);
      expect(notifier.forecastedFohLaborDollar, plan.theoreticalFohLaborDollars);
      expect(notifier.forecastedBohLaborDollar, plan.theoreticalBohLaborDollars);
      expect(notifier.forecastedTotalLaborDollar, plan.theoreticalTotalLaborDollars);
      expect(notifier.forecastSourceLabel, plan.coversSourceLabel);

      // Notifier also exposes SchedulePlan object
      expect(notifier.plan, isNotNull);
      expect(notifier.plan, isA<SchedulePlan>());
      expect(notifier.plan!.forecastCovers, notifier.weeklyCovers);

      notifier.dispose();
    });
  });

  // ── G: Day-level plan rows ───────────────────────────────────────────────

  group('G — day-level plan rows', () {
    test('7 day rows with correct day labels and sales = covers × PPA', () {
      final plan = _plan();
      expect(plan.dayPlans, hasLength(7));
      expect(plan.dayPlans.map((d) => d.day).toList(),
          ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']);
      for (final dp in plan.dayPlans) {
        expect(dp.forecastSales, dp.forecastCovers * 42.0);
      }
    });

    test('day sums reconcile to weekly totals at multiple cover levels', () {
      for (final covers in [1200, 1066, 1067, 3]) {
        final plan = _plan(covers: covers);
        final dayCovers = plan.dayPlans.fold<int>(0, (s, d) => s + d.forecastCovers);
        final dayFoh = plan.dayPlans.fold<int>(0, (s, d) => s + d.requiredFohHours);
        final dayBoh = plan.dayPlans.fold<int>(0, (s, d) => s + d.requiredBohHours);
        expect(dayCovers, covers, reason: 'covers reconciliation at $covers');
        expect(dayFoh, plan.requiredFohHours, reason: 'FOH reconciliation at $covers');
        expect(dayBoh, plan.requiredBohHours, reason: 'BOH reconciliation at $covers');
        for (final dp in plan.dayPlans) {
          expect(dp.forecastCovers, greaterThanOrEqualTo(0));
          expect(dp.requiredFohHours, greaterThanOrEqualTo(0));
          expect(dp.requiredBohHours, greaterThanOrEqualTo(0));
        }
      }
    });

    test('day rows update when target PPA changes', () {
      final plan42 = _plan(ppa: 42.0);
      final plan50 = _plan(ppa: 50.0);
      for (int i = 0; i < 7; i++) {
        expect(plan42.dayPlans[i].forecastCovers, plan50.dayPlans[i].forecastCovers);
        expect(plan50.dayPlans[i].forecastSales,
            isNot(plan42.dayPlans[i].forecastSales));
      }
    });

    test('dayPlans list is immutable — add/remove/clear throw', () {
      final plan = _plan();
      expect(
        () => plan.dayPlans.add(ScheduleDayPlan(
          day: 'X', forecastCovers: 0, forecastSales: 0,
          requiredFohHours: 0, requiredBohHours: 0,
        )),
        throwsUnsupportedError,
      );
      expect(() => plan.dayPlans.removeAt(0), throwsUnsupportedError);
      expect(() => plan.dayPlans.clear(), throwsUnsupportedError);
    });

    test('notifier adjustedDayViews matches plan dayPlans', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.5,
        targetPPA: 42.0,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        theoreticalLaborPct: 20.5,
        initialCovers: 1200,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      );
      final views = notifier.adjustedDayViews;
      final dayPlans = notifier.plan!.dayPlans;
      expect(views.length, dayPlans.length);
      for (int i = 0; i < views.length; i++) {
        expect(views[i].forecastCovers, dayPlans[i].forecastCovers);
        expect(views[i].forecastSales, dayPlans[i].forecastSales);
        expect(views[i].requiredFohHours, dayPlans[i].requiredFohHours);
        expect(views[i].requiredBohHours, dayPlans[i].requiredBohHours);
      }
      notifier.dispose();
    });
  });

  // ── H: Unavailable demand behavior ───────────────────────────────────────

  group('H — unavailable demand behavior', () {
    test('unavailable demand produces null plan with safe defaults', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.5,
        targetPPA: 42.0,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        theoreticalLaborPct: 20.5,
        initialCovers: null,
        coversSource: ForecastDemandSource.unavailable,
      );
      expect(notifier.plan, isNull);
      expect(notifier.hasPlan, isFalse);
      expect(notifier.weeklyCovers, 0);
      expect(notifier.forecastedSales, 0);
      expect(notifier.coversSource, ForecastDemandSource.unavailable);
      expect(notifier.forecastSourceLabel, 'Unavailable');
      expect(notifier.adjustedDayViews, isEmpty);
      // Safe fold on empty
      expect(notifier.adjustedDayViews.fold<int>(0, (s, d) => s + d.forecastCovers), 0);
      notifier.dispose();
    });

    test('demo fallback with explicit covers is honestly marked', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.5,
        targetPPA: 42.0,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        theoreticalLaborPct: 20.5,
        coversSource: ForecastDemandSource.demoFallback,
      );
      expect(notifier.plan, isNotNull);
      expect(notifier.weeklyCovers, 1200);
      expect(notifier.coversSource, ForecastDemandSource.demoFallback);
      expect(notifier.forecastSourceLabel, 'Demo fallback');
      notifier.dispose();
    });

    test('fromProfile with unavailable demand produces null plan', () {
      final demand = ScheduleForecastDemandResolver.resolve(targetPPA: 42.0);
      expect(demand.isAvailable, isFalse);

      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.5,
        targetPPA: 42.0,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        theoreticalLaborPct: 20.5,
        initialCovers: demand.forecastCovers,
        coversSource: demand.coversSource,
      );
      expect(notifier.plan, isNull);
      expect(notifier.hasPlan, isFalse);
      notifier.dispose();
    });
  });

  // ── I: Data-driven day distribution weights ──────────────────────────────

  group('I — data-driven day distribution weights', () {
    /// Helper: build available ScheduleDistributionWeights with given day weights.
    ScheduleDistributionWeights makeAvailableWeights(Map<String, int> dayWeights) {
      return ScheduleDistributionWeights.available(
        dayWeights: dayWeights,
        daypartWeightsByDay: const {},
        closedShiftCount: 42,
        closedBusinessDayCount: 21,
        totalCovers: dayWeights.values.fold(0, (s, v) => s + v),
      );
    }

    test('uses available distribution weights instead of defaults', () {
      // Friday heavily weighted, Monday very light
      final weights = makeAvailableWeights({
        'Mon': 50,
        'Tue': 100,
        'Wed': 100,
        'Thu': 100,
        'Fri': 500,
        'Sat': 200,
        'Sun': 80,
      });
      final plan = SchedulePlanResolver.resolveFromValues(
        forecastCovers: 1200,
        targetPPA: 42.0,
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        distributionWeights: weights,
      );

      final mon = plan.dayPlans.firstWhere((d) => d.day == 'Mon');
      final fri = plan.dayPlans.firstWhere((d) => d.day == 'Fri');
      expect(fri.forecastCovers, greaterThan(mon.forecastCovers));
      // Friday should get roughly 500/1130 ≈ 44% of covers
      expect(fri.forecastCovers, greaterThan(400));
      expect(mon.forecastCovers, lessThan(100));
    });

    test('preserves canonical Mon-Sun order regardless of map insertion order', () {
      // Insert in non-canonical order
      final weights = makeAvailableWeights({
        'Sat': 200,
        'Thu': 100,
        'Mon': 100,
        'Sun': 80,
        'Wed': 100,
        'Fri': 300,
        'Tue': 100,
      });
      final plan = SchedulePlanResolver.resolveFromValues(
        forecastCovers: 1200,
        targetPPA: 42.0,
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        distributionWeights: weights,
      );

      expect(plan.dayPlans.map((d) => d.day).toList(),
          ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']);
    });

    test('exact reconciliation holds with distribution weights', () {
      final weights = makeAvailableWeights({
        'Mon': 80,
        'Tue': 120,
        'Wed': 140,
        'Thu': 180,
        'Fri': 350,
        'Sat': 400,
        'Sun': 90,
      });

      for (final covers in [1200, 1066, 1067, 3, 7]) {
        final plan = SchedulePlanResolver.resolveFromValues(
          forecastCovers: covers,
          targetPPA: 42.0,
          targetCPLH: 4.5,
          targetSPLH: 180.0,
          fohWage: 16.50,
          bohWage: 21.35,
          coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
          distributionWeights: weights,
        );

        final dayCovers =
            plan.dayPlans.fold<int>(0, (s, d) => s + d.forecastCovers);
        final dayFoh =
            plan.dayPlans.fold<int>(0, (s, d) => s + d.requiredFohHours);
        final dayBoh =
            plan.dayPlans.fold<int>(0, (s, d) => s + d.requiredBohHours);
        expect(dayCovers, covers,
            reason: 'covers reconciliation at $covers with custom weights');
        expect(dayFoh, plan.requiredFohHours,
            reason: 'FOH reconciliation at $covers with custom weights');
        expect(dayBoh, plan.requiredBohHours,
            reason: 'BOH reconciliation at $covers with custom weights');
      }
    });

    test('falls back to default weights when distributionWeights is null', () {
      final planNull = SchedulePlanResolver.resolveFromValues(
        forecastCovers: 1200,
        targetPPA: 42.0,
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      );
      final planExplicitNull = SchedulePlanResolver.resolveFromValues(
        forecastCovers: 1200,
        targetPPA: 42.0,
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        distributionWeights: null,
      );

      // Both should produce identical day distributions
      for (int i = 0; i < 7; i++) {
        expect(planNull.dayPlans[i].forecastCovers,
            planExplicitNull.dayPlans[i].forecastCovers);
        expect(planNull.dayPlans[i].requiredFohHours,
            planExplicitNull.dayPlans[i].requiredFohHours);
        expect(planNull.dayPlans[i].requiredBohHours,
            planExplicitNull.dayPlans[i].requiredBohHours);
      }
    });

    test('falls back to default weights when distributionWeights is unavailable', () {
      final unavailable = ScheduleDistributionWeights.unavailable(
        closedShiftCount: 10,
        closedBusinessDayCount: 5,
        totalCovers: 500,
      );
      final planDefault = _plan();
      final planUnavailable = SchedulePlanResolver.resolveFromValues(
        forecastCovers: 1200,
        targetPPA: 42.0,
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        distributionWeights: unavailable,
      );

      for (int i = 0; i < 7; i++) {
        expect(planDefault.dayPlans[i].forecastCovers,
            planUnavailable.dayPlans[i].forecastCovers);
        expect(planDefault.dayPlans[i].requiredFohHours,
            planUnavailable.dayPlans[i].requiredFohHours);
        expect(planDefault.dayPlans[i].requiredBohHours,
            planUnavailable.dayPlans[i].requiredBohHours);
      }
    });

    test('falls back to default weights when available weights are all zero', () {
      final allZero = ScheduleDistributionWeights.available(
        dayWeights: {
          'Mon': 0, 'Tue': 0, 'Wed': 0, 'Thu': 0,
          'Fri': 0, 'Sat': 0, 'Sun': 0,
        },
        daypartWeightsByDay: const {},
        closedShiftCount: 42,
        closedBusinessDayCount: 21,
        totalCovers: 0,
      );
      final planDefault = _plan();
      final planZero = SchedulePlanResolver.resolveFromValues(
        forecastCovers: 1200,
        targetPPA: 42.0,
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        distributionWeights: allZero,
      );

      for (int i = 0; i < 7; i++) {
        expect(planDefault.dayPlans[i].forecastCovers,
            planZero.dayPlans[i].forecastCovers);
      }
    });

    test('target PPA affects day sales and BOH but not day covers with custom weights', () {
      final weights = makeAvailableWeights({
        'Mon': 100, 'Tue': 100, 'Wed': 100, 'Thu': 100,
        'Fri': 300, 'Sat': 250, 'Sun': 80,
      });
      final plan42 = SchedulePlanResolver.resolveFromValues(
        forecastCovers: 1200,
        targetPPA: 42.0,
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        distributionWeights: weights,
      );
      final plan50 = SchedulePlanResolver.resolveFromValues(
        forecastCovers: 1200,
        targetPPA: 50.0,
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        distributionWeights: weights,
      );

      for (int i = 0; i < 7; i++) {
        // Covers unchanged
        expect(plan42.dayPlans[i].forecastCovers,
            plan50.dayPlans[i].forecastCovers);
        // Sales changed
        expect(plan50.dayPlans[i].forecastSales,
            isNot(plan42.dayPlans[i].forecastSales));
        // FOH unchanged (driven by covers/CPLH)
        expect(plan42.dayPlans[i].requiredFohHours,
            plan50.dayPlans[i].requiredFohHours);
      }
      // BOH totals differ (driven by sales/SPLH)
      expect(plan42.requiredBohHours, isNot(plan50.requiredBohHours));
    });

    test('weekly totals unchanged whether custom or default weights used', () {
      final weights = makeAvailableWeights({
        'Mon': 50, 'Tue': 300, 'Wed': 100, 'Thu': 100,
        'Fri': 500, 'Sat': 200, 'Sun': 80,
      });
      final planDefault = _plan();
      final planCustom = SchedulePlanResolver.resolveFromValues(
        forecastCovers: 1200,
        targetPPA: 42.0,
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        distributionWeights: weights,
      );

      expect(planCustom.forecastCovers, planDefault.forecastCovers);
      expect(planCustom.forecastSales, planDefault.forecastSales);
      expect(planCustom.requiredFohHours, planDefault.requiredFohHours);
      expect(planCustom.requiredBohHours, planDefault.requiredBohHours);
      expect(planCustom.theoreticalFohLaborDollars,
          planDefault.theoreticalFohLaborDollars);
      expect(planCustom.theoreticalBohLaborDollars,
          planDefault.theoreticalBohLaborDollars);
      expect(planCustom.theoreticalLaborPct, planDefault.theoreticalLaborPct);
      expect(planCustom.targetBlendedWage, planDefault.targetBlendedWage);

      // But day-level distribution is different
      final defaultFri =
          planDefault.dayPlans.firstWhere((d) => d.day == 'Fri');
      final customFri =
          planCustom.dayPlans.firstWhere((d) => d.day == 'Fri');
      expect(customFri.forecastCovers, isNot(defaultFri.forecastCovers));
    });
  });

  // ── J: Schedule daypart subrow distribution weights ─────────────────────────

  group('J — Schedule daypart subrow distribution weights', () {
    /// Helper: build available ScheduleDistributionWeights with day + daypart weights.
    ScheduleDistributionWeights makeWeightsWithDayparts({
      required Map<String, int> dayWeights,
      required Map<String, Map<String, int>> daypartWeightsByDay,
    }) {
      return ScheduleDistributionWeights.available(
        dayWeights: dayWeights,
        daypartWeightsByDay: daypartWeightsByDay,
        closedShiftCount: 42,
        closedBusinessDayCount: 21,
        totalCovers: dayWeights.values.fold(0, (s, v) => s + v),
      );
    }

    /// Helper: build a notifier with given distribution weights.
    ScheduleForecastNotifier makeNotifier({
      ScheduleDistributionWeights? distributionWeights,
      int covers = 1200,
      double targetPPA = 42.0,
      double targetCPLH = 4.5,
      double targetSPLH = 180.0,
      double fohWage = 16.50,
      double bohWage = 21.35,
    }) {
      return ScheduleForecastNotifier(
        targetCPLH: targetCPLH,
        targetPPA: targetPPA,
        targetSPLH: targetSPLH,
        fohWage: fohWage,
        bohWage: bohWage,
        theoreticalLaborPct: 20.5,
        initialCovers: covers,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        distributionWeights: distributionWeights,
      );
    }

    test('Friday subrows use Friday-specific daypart weights', () {
      final weights = makeWeightsWithDayparts(
        dayWeights: {
          'Mon': 100, 'Tue': 100, 'Wed': 100, 'Thu': 100,
          'Fri': 300, 'Sat': 200, 'Sun': 100,
        },
        daypartWeightsByDay: {
          'Fri': {'lunch': 100, 'dinner': 300, 'late_night': 200},
        },
      );
      final notifier = makeNotifier(distributionWeights: weights);
      final views = notifier.adjustedDayViews;
      final fri = views.firstWhere((v) => v.day == 'Fri');

      expect(fri.subrows.length, 3);
      final lunch = fri.subrows.firstWhere((s) => s.label == 'Lunch');
      final dinner = fri.subrows.firstWhere((s) => s.label == 'Dinner');
      final lateNight = fri.subrows.firstWhere((s) => s.label == 'Late Night');
      // Dinner (300/600) should get more covers than Lunch (100/600)
      expect(dinner.forecastCovers, greaterThan(lunch.forecastCovers));
      // Late Night (200/600) should exist with positive covers
      expect(lateNight.forecastCovers, greaterThan(0));
      notifier.dispose();
    });

    test('Tuesday and Saturday dinner differ with day-specific daypart weights', () {
      final weights = makeWeightsWithDayparts(
        dayWeights: {
          'Mon': 100, 'Tue': 200, 'Wed': 100, 'Thu': 100,
          'Fri': 200, 'Sat': 300, 'Sun': 100,
        },
        daypartWeightsByDay: {
          'Tue': {'lunch': 300, 'dinner': 100},
          'Sat': {'lunch': 50, 'dinner': 400},
        },
      );
      final notifier = makeNotifier(distributionWeights: weights);
      final views = notifier.adjustedDayViews;

      final tue = views.firstWhere((v) => v.day == 'Tue');
      final sat = views.firstWhere((v) => v.day == 'Sat');

      final tueDinner = tue.subrows.firstWhere((s) => s.label == 'Dinner');
      final satDinner = sat.subrows.firstWhere((s) => s.label == 'Dinner');

      // Tuesday dinner is 100/400 = 25%, Saturday dinner is 400/450 ≈ 89%
      // Sat has more total covers too (300 vs 200 weight), so Sat dinner >> Tue dinner
      expect(satDinner.forecastCovers, greaterThan(tueDinner.forecastCovers));
      notifier.dispose();
    });

    test('subrow forecast covers sum exactly to parent day forecastCovers', () {
      final weights = makeWeightsWithDayparts(
        dayWeights: {
          'Mon': 140, 'Tue': 150, 'Wed': 160, 'Thu': 190,
          'Fri': 220, 'Sat': 230, 'Sun': 110,
        },
        daypartWeightsByDay: {
          'Mon': {'lunch': 200, 'dinner': 300},
          'Tue': {'lunch': 180, 'dinner': 250},
          'Wed': {'lunch': 150, 'dinner': 280},
          'Thu': {'lunch': 160, 'dinner': 310},
          'Fri': {'lunch': 100, 'dinner': 300, 'late_night': 200},
          'Sat': {'dinner': 350, 'late_night': 150},
          'Sun': {'dinner': 400},
        },
      );

      for (final covers in [1200, 1066, 7, 3]) {
        final notifier = makeNotifier(
          distributionWeights: weights,
          covers: covers,
        );
        final views = notifier.adjustedDayViews;
        for (final view in views) {
          final subCoverSum = view.subrows.fold<int>(
              0, (s, r) => s + r.forecastCovers);
          expect(subCoverSum, view.forecastCovers,
              reason:
                  '${view.day} subrow covers sum at weekly=$covers');
        }
        notifier.dispose();
      }
    });

    test('subrow FOH hours sum exactly to parent day requiredFohHours', () {
      final weights = makeWeightsWithDayparts(
        dayWeights: {
          'Mon': 140, 'Tue': 150, 'Wed': 160, 'Thu': 190,
          'Fri': 220, 'Sat': 230, 'Sun': 110,
        },
        daypartWeightsByDay: {
          'Mon': {'lunch': 200, 'dinner': 300},
          'Fri': {'lunch': 100, 'dinner': 300, 'late_night': 200},
          'Sat': {'dinner': 350, 'late_night': 150},
        },
      );
      final notifier = makeNotifier(distributionWeights: weights);
      final views = notifier.adjustedDayViews;

      for (final view in views) {
        final subFohSum = view.subrows.fold<int>(
            0, (s, r) => s + r.requiredFohHours);
        expect(subFohSum, view.requiredFohHours,
            reason: '${view.day} subrow FOH hours sum');
      }
      notifier.dispose();
    });

    test('subrow BOH hours sum exactly to parent day requiredBohHours', () {
      final weights = makeWeightsWithDayparts(
        dayWeights: {
          'Mon': 140, 'Tue': 150, 'Wed': 160, 'Thu': 190,
          'Fri': 220, 'Sat': 230, 'Sun': 110,
        },
        daypartWeightsByDay: {
          'Mon': {'lunch': 200, 'dinner': 300},
          'Fri': {'lunch': 100, 'dinner': 300, 'late_night': 200},
          'Sat': {'dinner': 350, 'late_night': 150},
        },
      );
      final notifier = makeNotifier(distributionWeights: weights);
      final views = notifier.adjustedDayViews;

      for (final view in views) {
        final subBohSum = view.subrows.fold<int>(
            0, (s, r) => s + r.requiredBohHours);
        expect(subBohSum, view.requiredBohHours,
            reason: '${view.day} subrow BOH hours sum');
      }
      notifier.dispose();
    });

    test('known daypart order is lunch, dinner, late_night regardless of map order', () {
      final weights = makeWeightsWithDayparts(
        dayWeights: {
          'Mon': 100, 'Tue': 100, 'Wed': 100, 'Thu': 100,
          'Fri': 300, 'Sat': 200, 'Sun': 100,
        },
        daypartWeightsByDay: {
          // Insert in non-canonical order
          'Fri': {'late_night': 200, 'lunch': 100, 'dinner': 300},
        },
      );
      final notifier = makeNotifier(distributionWeights: weights);
      final views = notifier.adjustedDayViews;
      final fri = views.firstWhere((v) => v.day == 'Fri');

      expect(fri.subrows.map((s) => s.label).toList(),
          ['Lunch', 'Dinner', 'Late Night']);
      notifier.dispose();
    });

    test('unknown daypart ids sort after known ids and render as raw id', () {
      final weights = makeWeightsWithDayparts(
        dayWeights: {
          'Mon': 100, 'Tue': 100, 'Wed': 100, 'Thu': 100,
          'Fri': 300, 'Sat': 200, 'Sun': 100,
        },
        daypartWeightsByDay: {
          'Fri': {
            'brunch': 50,
            'late_night': 200,
            'lunch': 100,
            'dinner': 300,
            'after_hours': 30,
          },
        },
      );
      final notifier = makeNotifier(distributionWeights: weights);
      final views = notifier.adjustedDayViews;
      final fri = views.firstWhere((v) => v.day == 'Fri');

      final labels = fri.subrows.map((s) => s.label).toList();
      // Known ids first in canonical order, then unknown alphabetically
      expect(labels,
          ['Lunch', 'Dinner', 'Late Night', 'after_hours', 'brunch']);
      notifier.dispose();
    });

    test('fallback to static daypart split when distributionWeights is null', () {
      final notifier = makeNotifier(distributionWeights: null);
      final views = notifier.adjustedDayViews;

      // Mon-Thu should have lunch + dinner (from WeekDayOrder fallback)
      final mon = views.firstWhere((v) => v.day == 'Mon');
      expect(mon.subrows.length, 2);
      expect(mon.subrows.map((s) => s.label).toList(), ['Lunch', 'Dinner']);

      // Fri should have lunch + dinner + late_night
      final fri = views.firstWhere((v) => v.day == 'Fri');
      expect(fri.subrows.length, 3);

      // Subrow covers still reconcile
      for (final view in views) {
        final subCoverSum = view.subrows.fold<int>(
            0, (s, r) => s + r.forecastCovers);
        expect(subCoverSum, view.forecastCovers,
            reason: '${view.day} fallback subrow covers sum');
      }
      notifier.dispose();
    });

    test('fallback when distributionWeights unavailable or day has no positive daypart weights', () {
      // Unavailable weights
      final unavailable = ScheduleDistributionWeights.unavailable(
        closedShiftCount: 10,
        closedBusinessDayCount: 5,
        totalCovers: 500,
      );
      final notifier1 = makeNotifier(distributionWeights: unavailable);
      final views1 = notifier1.adjustedDayViews;
      final mon1 = views1.firstWhere((v) => v.day == 'Mon');
      expect(mon1.subrows.length, 2); // fallback: lunch + dinner

      // Available but day has no daypart weights → fallback
      final weightsNoDayparts = makeWeightsWithDayparts(
        dayWeights: {
          'Mon': 100, 'Tue': 100, 'Wed': 100, 'Thu': 100,
          'Fri': 200, 'Sat': 200, 'Sun': 100,
        },
        daypartWeightsByDay: {
          // Only Fri has daypart data; Mon has none
          'Fri': {'lunch': 100, 'dinner': 300},
        },
      );
      final notifier2 = makeNotifier(distributionWeights: weightsNoDayparts);
      final views2 = notifier2.adjustedDayViews;
      final mon2 = views2.firstWhere((v) => v.day == 'Mon');
      // Mon falls back to fixture: lunch + dinner
      expect(mon2.subrows.length, 2);
      expect(mon2.subrows.map((s) => s.label).toList(), ['Lunch', 'Dinner']);

      // Fri uses data-driven: lunch + dinner (no late_night in data)
      final fri2 = views2.firstWhere((v) => v.day == 'Fri');
      expect(fri2.subrows.length, 2);
      expect(fri2.subrows.map((s) => s.label).toList(), ['Lunch', 'Dinner']);

      notifier1.dispose();
      notifier2.dispose();
    });

    test('updateTargets preserves distributionWeights when rebuilding the plan', () {
      final weights = makeWeightsWithDayparts(
        dayWeights: {
          'Mon': 100, 'Tue': 100, 'Wed': 100, 'Thu': 100,
          'Fri': 500, 'Sat': 200, 'Sun': 100,
        },
        daypartWeightsByDay: {
          'Fri': {'lunch': 100, 'dinner': 400, 'late_night': 100},
        },
      );
      final notifier = makeNotifier(distributionWeights: weights);

      // Verify initial state uses data-driven weights
      final viewsBefore = notifier.adjustedDayViews;
      final friBefore = viewsBefore.firstWhere((v) => v.day == 'Fri');
      final dinnerBefore = friBefore.subrows.firstWhere((s) => s.label == 'Dinner');

      // Update targets — distribution weights should be preserved
      final newProfile = _testProfile(targetPPA: 50.0);
      notifier.updateTargets(newProfile);

      final viewsAfter = notifier.adjustedDayViews;
      final friAfter = viewsAfter.firstWhere((v) => v.day == 'Fri');
      final dinnerAfter = friAfter.subrows.firstWhere((s) => s.label == 'Dinner');

      // Covers unchanged (same covers, same distribution weights)
      expect(dinnerAfter.forecastCovers, dinnerBefore.forecastCovers);
      // Sales changed (PPA went from 42 to 50)
      expect(dinnerAfter.forecastSales,
          isNot(equals(dinnerBefore.forecastSales)));
      // Friday still uses data-driven daypart split (3 subrows, not 2)
      expect(friAfter.subrows.length, 3);

      notifier.dispose();
    });
  });
}
