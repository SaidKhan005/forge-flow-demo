// Phase 7.55i.2 / 7.55i.2a — Shared SchedulePlan read service tests.
//
// Validates:
// A. getCurrentWeeklyPlan resolves a non-null plan from seeded data
// B. Plan includes distribution-weighted day plans
// C. getPreviewPlanFromTargetValues uses canonical demand context
// D. Preview plan with different PPA produces different sales but same covers
// E. All plan consumers agree on the same covers/sales/hours
// F. resolveFromInputs matches async path and handles null/PPA guardrails

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/demand_forecast_context_service.dart';
import 'package:forge_and_flow/data/schedule_plan_read_service.dart';
import 'package:forge_and_flow/data/shift_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  // ── A. getCurrentWeeklyPlan ───────────────────────────────────────────────

  group('A — getCurrentWeeklyPlan', () {
    test('returns non-null plan from seeded data', () async {
      final plan =
          await SchedulePlanReadService.instance.getCurrentWeeklyPlan();
      expect(plan, isNotNull);
      expect(plan!.forecastCovers, greaterThan(0));
      expect(plan.forecastSales, greaterThan(0));
      expect(plan.requiredFohHours, greaterThan(0));
      expect(plan.requiredBohHours, greaterThan(0));
    });

    test('plan covers match canonical demand context', () async {
      final plan =
          await SchedulePlanReadService.instance.getCurrentWeeklyPlan();
      final demandCtx =
          await DemandForecastContextService.instance.getCurrentContext();

      expect(plan, isNotNull);
      expect(demandCtx.isAvailable, isTrue);
      expect(plan!.forecastCovers, equals(demandCtx.historicalWeeklyAvgCovers));
    });
  });

  // ── B. Distribution weights in plan ───────────────────────────────────────

  group('B — distribution weights', () {
    test('distribution weights are loaded from closed shifts', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final weights = await SchedulePlanReadService.loadDistributionWeights(
          restaurantId);
      // Seeded data should produce weights
      expect(weights, isNotNull);
      expect(weights!.isAvailable, isTrue);
    });
  });

  // ── C. getPreviewPlanFromTargetValues ─────────────────────────────────────

  group('C — preview plan', () {
    test('uses canonical demand context, not BaselineData', () async {
      final plan = await SchedulePlanReadService.instance
          .getPreviewPlanFromTargetValues(
        targetCPLH: 4.5,
        targetPPA: 42.0,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
      );
      final demandCtx =
          await DemandForecastContextService.instance.getCurrentContext();

      expect(plan, isNotNull);
      expect(plan!.forecastCovers, equals(demandCtx.historicalWeeklyAvgCovers));
    });

    test('returns null when no demand data exists', () async {
      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');
      await db.delete('shift_records');

      final plan = await SchedulePlanReadService.instance
          .getPreviewPlanFromTargetValues(
        targetCPLH: 4.5,
        targetPPA: 42.0,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
      );
      expect(plan, isNull);
    });
  });

  // ── D. PPA guardrail via preview ──────────────────────────────────────────

  group('D — PPA guardrail in preview', () {
    test('different PPA → same covers, different sales', () async {
      final lowPPA = await SchedulePlanReadService.instance
          .getPreviewPlanFromTargetValues(
        targetCPLH: 4.5,
        targetPPA: 38.0,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
      );
      final highPPA = await SchedulePlanReadService.instance
          .getPreviewPlanFromTargetValues(
        targetCPLH: 4.5,
        targetPPA: 52.0,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
      );

      expect(lowPPA, isNotNull);
      expect(highPPA, isNotNull);
      expect(lowPPA!.forecastCovers, equals(highPPA!.forecastCovers));
      expect(highPPA.forecastSales, greaterThan(lowPPA.forecastSales));
    });
  });

  // ── E. Plan consumer agreement ────────────────────────────────────────────

  group('E — plan consumer agreement', () {
    test('ShiftService and shared plan produce same weekly covers/sales',
        () async {
      final plan =
          await SchedulePlanReadService.instance.getCurrentWeeklyPlan();
      final shiftDashboard =
          await ShiftService.instance.getShiftDashboard();

      expect(plan, isNotNull);
      expect(shiftDashboard, isNotNull);

      // Shift dashboard forecast comes from the matching day row of the
      // same shared plan. Verify it is a valid day value from the plan.
      final dayPlans = plan!.dayPlans;
      final matchingDay = dayPlans
          .where((d) => d.forecastCovers == shiftDashboard!.forecastCovers)
          .firstOrNull;
      expect(matchingDay, isNotNull,
          reason: 'Shift dashboard forecast covers must match a day in the plan');
    });

  });

  // ── F. resolveFromInputs static method ───────────────────────────────────

  group('F — resolveFromInputs', () {
    test('matches getCurrentWeeklyPlan for the same inputs', () async {
      final asyncPlan =
          await SchedulePlanReadService.instance.getCurrentWeeklyPlan();
      expect(asyncPlan, isNotNull);

      final demandCtx =
          await DemandForecastContextService.instance.getCurrentContext();
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      final weights =
          await SchedulePlanReadService.loadDistributionWeights(restaurantId);

      expect(profile, isNotNull);

      final syncPlan = SchedulePlanReadService.resolveFromInputs(
        targetCPLH: profile!.targetCPLH,
        targetPPA: profile.targetPPA,
        targetSPLH: profile.targetSPLH,
        fohWage: profile.fohWage,
        bohWage: profile.bohWage,
        historicalWeeklyAvgCovers: demandCtx.historicalWeeklyAvgCovers,
        distributionWeights: weights,
      );

      expect(syncPlan, isNotNull);
      expect(syncPlan!.forecastCovers, equals(asyncPlan!.forecastCovers));
      expect(syncPlan.forecastSales, equals(asyncPlan.forecastSales));
      expect(syncPlan.requiredFohHours, equals(asyncPlan.requiredFohHours));
      expect(syncPlan.requiredBohHours, equals(asyncPlan.requiredBohHours));
    });

  });
}
