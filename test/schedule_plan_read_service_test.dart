// Phase 7.55i.2 / 7.55i.2a / 7.55l.7a — Shared SchedulePlan read service tests.
// Phase 7.55q.2-review-fix — Read-only locked plan path.
//
// Validates:
// A. getCurrentWeeklyPlan resolves a non-null plan from seeded data
// B. Plan includes distribution-weighted day plans
// C. getPreviewPlanFromTargetValues uses canonical demand context
// D. Preview plan with different PPA produces different sales but same covers
// E. All plan consumers agree on the same covers/sales/hours
// F. resolveFromInputs matches async path and handles null/PPA guardrails
// G. Projector: WeeklyPlanSnapshot -> SchedulePlan
// H. getCurrentLockedWeeklyPlan locked-week read path (auto-generates)
// I. getExistingCurrentLockedWeeklyPlan read-only path (7.55q.2-review-fix)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/business_date_authority_service.dart';
import 'package:forge_and_flow/services/demand_forecast_context_service.dart';
import 'package:forge_and_flow/services/schedule_plan_read_service.dart';
import 'package:forge_and_flow/services/shift_service.dart';
import 'package:forge_and_flow/services/target_cycle_service.dart';
import 'package:forge_and_flow/services/weekly_plan_snapshot_service.dart';
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
      await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
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
      final expectedTheoPct = snapshot.forecastSales > 0
          ? snapshot.theoreticalTotalLaborDollars /
              snapshot.forecastSales *
              100
          : 0.0;
      final expectedBlendedWage = snapshot.totalRequiredHours > 0
          ? snapshot.theoreticalTotalLaborDollars /
              snapshot.totalRequiredHours
          : 0.0;
      expect(projected.theoreticalLaborPct, closeTo(expectedTheoPct, 0.001));
      expect(projected.targetBlendedWage,
          closeTo(expectedBlendedWage, 0.001));
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

  // ── I. Read-only locked plan path (7.55q.2-review-fix) ────────────────
  //
  // The original 7.55q.2 routed Schedule's locked-authority load through
  // getCurrentLockedWeeklyPlan(), which silently auto-generated a snapshot
  // from the live plan when none was persisted — keeping the second
  // current-week authority alive under a "locked" label.
  //
  // The review-fix splits the read-only path from the auto-generate path.
  // These tests prove:
  //   I1. getExistingCurrentLockedWeeklyPlan returns null when no snapshot
  //       is persisted, even with anchor + demand still present.
  //   I2. The read-only call has NO side effects — no snapshot is created.
  //   I3. The auto-generating getCurrentLockedWeeklyPlan path STILL works
  //       (preserved for week-roll bootstrap, Audit/Shift initial gen).

  group('I — getExistingCurrentLockedWeeklyPlan (read-only, '
      '7.55q.2-review-fix)', () {
    test('I1+I2: returns null when snapshot is missing (anchor + demand '
        'still present); does NOT auto-generate a replacement', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      // Ensure a snapshot exists first by triggering the auto-generate
      // path. (reseedDemo seeds tables but doesn't pre-create the
      // current-week snapshot — that happens on first request.)
      final initial = await WeeklyPlanSnapshotService.instance
          .getCurrentWeekSnapshot();
      expect(initial, isNotNull,
          reason: 'sanity: auto-generate must have created a snapshot');

      // Delete ONLY the snapshot — leave anchor + demand intact.
      // This is the real failure mode the review caught: the original
      // D3 test cleared everything and so missed this case.
      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');

      // Sanity: anchor still resolvable (mock_replay_state intact).
      final anchorDate = await BusinessDateAuthorityService.instance
          .resolvePlanningAnchorDate(restaurantId);
      expect(anchorDate, isNotNull,
          reason: 'sanity: anchor must still resolve after snapshot delete');

      // Sanity: demand context still available (shift_records intact).
      final demandCtx = await DemandForecastContextService.instance
          .getCurrentContext();
      expect(demandCtx.isAvailable, isTrue,
          reason: 'sanity: demand must still be available');

      // The read-only path must return null (no auto-generation).
      final readOnly = await SchedulePlanReadService.instance
          .getExistingCurrentLockedWeeklyPlan();
      expect(readOnly, isNull,
          reason:
              '7.55q.2-review-fix: read-only path MUST NOT generate from '
              'the live plan when snapshot is missing');

      // No snapshot recreated as a side effect of the read-only call.
      final stillEmpty = await WeeklyPlanSnapshotService.instance
          .getExistingCurrentWeekSnapshot();
      expect(stillEmpty, isNull,
          reason: 'read-only call MUST NOT create a snapshot');

      // Sanity: the LIVE path WAS available — proves Schedule chose
      // not to fall back to it. This is the "real risk" check the
      // review-fix prompt called out.
      final livePlan = await SchedulePlanReadService.instance
          .getCurrentWeeklyPlan();
      expect(livePlan, isNotNull,
          reason:
              'sanity: live path WAS available — Schedule chose not to use '
              'it via the read-only path');

      // Final sanity: the read-only snapshot lookup STILL returns null
      // even after the live-path call above (the live call is pure;
      // it does not persist a snapshot itself).
      final stillEmpty2 = await WeeklyPlanSnapshotService.instance
          .getExistingCurrentWeekSnapshot();
      expect(stillEmpty2, isNull,
          reason:
              'sanity: getCurrentWeeklyPlan must not persist a snapshot');
    });

    test('I3: the auto-generating getCurrentLockedWeeklyPlan path is '
        'preserved unchanged (legitimate generation callers still work)',
        () async {
      // Delete the snapshot to force the generate-on-miss branch.
      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');

      // Auto-generating path returns a non-null plan and persists a
      // fresh snapshot from the live plan. This is the legitimate
      // behaviour for week-roll bootstrap / Audit / Shift initial gen.
      final autoGen = await SchedulePlanReadService.instance
          .getCurrentLockedWeeklyPlan();
      expect(autoGen, isNotNull,
          reason: 'auto-generate path preserved for legitimate callers');

      // Snapshot now exists — confirms the side effect happened.
      final created = await WeeklyPlanSnapshotService.instance
          .getExistingCurrentWeekSnapshot();
      expect(created, isNotNull,
          reason:
              'auto-generate path must have persisted a fresh snapshot');

      // And the read-only path now returns the same thing (because the
      // snapshot was created out-of-band by the auto-generate call).
      final readOnlyAfterGen = await SchedulePlanReadService.instance
          .getExistingCurrentLockedWeeklyPlan();
      expect(readOnlyAfterGen, isNotNull);
      expect(readOnlyAfterGen!.forecastCovers,
          equals(autoGen!.forecastCovers));
    });

    test('returns null when both snapshot and anchor are absent', () async {
      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');
      await db.delete('mock_replay_state');
      await db.delete('shift_records');

      final readOnly = await SchedulePlanReadService.instance
          .getExistingCurrentLockedWeeklyPlan();
      expect(readOnly, isNull);
    });
  });
}
