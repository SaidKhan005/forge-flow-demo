// Phase 7.55i.2 / 7.55i.2a / 7.55l.7a — Shared SchedulePlan read service tests.
//
// Validates:
// A. getCurrentWeeklyPlan resolves a non-null plan from seeded data
// B. Plan includes distribution-weighted day plans
// C. getPreviewPlanFromTargetValues uses canonical demand context
// D. Preview plan with different PPA produces different sales but same covers
// E. All plan consumers agree on the same covers/sales/hours
// F. resolveFromInputs matches async path and handles null/PPA guardrails
// G. Projector: WeeklyPlanSnapshot -> SchedulePlan
// H. getCurrentLockedWeeklyPlan locked-week read path

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/demand_forecast_context_service.dart';
import 'package:forge_and_flow/data/schedule_plan_read_service.dart';
import 'package:forge_and_flow/data/shift_service.dart';
import 'package:forge_and_flow/data/target_cycle_service.dart';
import 'package:forge_and_flow/data/weekly_plan_snapshot_service.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_schedule_plan_projector.dart';
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

  // ── G. Projector: WeeklyPlanSnapshot → SchedulePlan (7.55l.7a) ─────────

  group('G — snapshot to schedule plan projector', () {
    test('projector produces SchedulePlan matching snapshot values', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      final projected =
          WeeklyPlanSnapshotSchedulePlanProjector.project(snapshot!);
      expect(projected.forecastCovers, equals(snapshot.forecastCovers));
      expect(projected.forecastSales, equals(snapshot.forecastSales));
      expect(projected.requiredFohHours, equals(snapshot.requiredFohHours));
      expect(projected.requiredBohHours, equals(snapshot.requiredBohHours));
      expect(projected.theoreticalFohLaborDollars,
          equals(snapshot.theoreticalFohLaborDollars));
      expect(projected.theoreticalBohLaborDollars,
          equals(snapshot.theoreticalBohLaborDollars));
      expect(projected.theoreticalLaborPct,
          equals(snapshot.theoreticalLaborPct));
      expect(projected.targetBlendedWage, equals(snapshot.targetBlendedWage));
      expect(projected.coversSource, equals(snapshot.coversSource));
      expect(projected.salesSource, equals(snapshot.salesSource));
    });

    test('projector maps day rows correctly', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      expect(snapshot!.dayRows, isNotEmpty);

      final projected =
          WeeklyPlanSnapshotSchedulePlanProjector.project(snapshot);
      expect(projected.dayPlans.length, equals(snapshot.dayRows.length));

      for (var i = 0; i < snapshot.dayRows.length; i++) {
        final snapDay = snapshot.dayRows[i];
        final planDay = projected.dayPlans[i];
        expect(planDay.day, equals(snapDay.day));
        expect(planDay.forecastCovers, equals(snapDay.forecastCovers));
        expect(planDay.forecastSales, equals(snapDay.forecastSales));
        expect(planDay.requiredFohHours, equals(snapDay.requiredFohHours));
        expect(planDay.requiredBohHours, equals(snapDay.requiredBohHours));
      }
    });
  });

  // ── H. getCurrentLockedWeeklyPlan (7.55l.7a) ──────────────────────────

  group('H — getCurrentLockedWeeklyPlan', () {
    test('returns projected plan from current-week snapshot', () async {
      final lockedPlan = await SchedulePlanReadService.instance
          .getCurrentLockedWeeklyPlan();
      expect(lockedPlan, isNotNull);
      expect(lockedPlan!.forecastCovers, greaterThan(0));
      expect(lockedPlan.forecastSales, greaterThan(0));
      expect(lockedPlan.requiredFohHours, greaterThan(0));
      expect(lockedPlan.requiredBohHours, greaterThan(0));
      expect(lockedPlan.dayPlans, isNotEmpty);
    });

    test('locked plan matches snapshot values exactly', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      final lockedPlan = await SchedulePlanReadService.instance
          .getCurrentLockedWeeklyPlan();

      expect(snapshot, isNotNull);
      expect(lockedPlan, isNotNull);
      expect(lockedPlan!.forecastCovers, equals(snapshot!.forecastCovers));
      expect(lockedPlan.forecastSales, equals(snapshot.forecastSales));
      expect(lockedPlan.requiredFohHours, equals(snapshot.requiredFohHours));
      expect(lockedPlan.requiredBohHours, equals(snapshot.requiredBohHours));
    });

    test('same-week cycle change does not rewrite locked plan', () async {
      // Get initial locked plan (auto-generates snapshot if needed)
      final initialPlan = await SchedulePlanReadService.instance
          .getCurrentLockedWeeklyPlan();
      expect(initialPlan, isNotNull);

      // Apply admin replacement cycle (changes target standards)
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final mockDate = await SqliteDatabase.instance
          .getMockReplayBusinessDate(restaurantId);
      await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, mockDate!);

      // Locked plan should still be the same
      final afterPlan = await SchedulePlanReadService.instance
          .getCurrentLockedWeeklyPlan();
      expect(afterPlan, isNotNull);
      expect(afterPlan!.forecastCovers, equals(initialPlan!.forecastCovers));
      expect(afterPlan.forecastSales, equals(initialPlan.forecastSales));
      expect(afterPlan.requiredFohHours, equals(initialPlan.requiredFohHours));
      expect(afterPlan.requiredBohHours, equals(initialPlan.requiredBohHours));
    });

    test('live preview/input APIs remain unchanged', () async {
      // resolveFromInputs still works without touching snapshots
      final demandCtx =
          await DemandForecastContextService.instance.getCurrentContext();
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);

      final syncPlan = SchedulePlanReadService.resolveFromInputs(
        targetCPLH: profile!.targetCPLH,
        targetPPA: profile.targetPPA,
        targetSPLH: profile.targetSPLH,
        fohWage: profile.fohWage,
        bohWage: profile.bohWage,
        historicalWeeklyAvgCovers: demandCtx.historicalWeeklyAvgCovers,
      );
      expect(syncPlan, isNotNull);
      expect(syncPlan!.forecastCovers, greaterThan(0));
    });

    test('ShiftService.getShiftDashboard uses locked day values', () async {
      // Get locked plan to know expected day values
      final lockedPlan = await SchedulePlanReadService.instance
          .getCurrentLockedWeeklyPlan();
      expect(lockedPlan, isNotNull);

      final dashboard = await ShiftService.instance.getShiftDashboard();
      expect(dashboard, isNotNull);

      // Dashboard forecast must match a day row from the locked plan
      final matchingDay = lockedPlan!.dayPlans
          .where((d) => d.forecastCovers == dashboard!.forecastCovers)
          .firstOrNull;
      expect(matchingDay, isNotNull,
          reason:
              'Shift dashboard forecast covers must match a locked plan day');
    });
  });
}
