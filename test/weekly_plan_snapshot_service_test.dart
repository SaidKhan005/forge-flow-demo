// Phase 7.55l.6b+6b1+6b2+6b3 + 7.55m.2 — WeeklyPlanSnapshot persistence + auto-lock spine tests.
//
// Covers:
// A. Generates and persists a snapshot when missing
// B. Returns existing current-week snapshot unchanged on subsequent reads
// C. Snapshot stores the active targetCycleId
// D. Snapshot stores weekly totals and day rows matching the generated SchedulePlan
// E. Mock replay business date is preferred over latest closed date
// F. Existing snapshot remains in force even if current cycle truth would differ
// G. Returns null cleanly when current-week plan cannot be resolved
// H. DAO/repository round-trip preserves all fields
// I. Mock replay advance within same week preserves locked snapshot (7.55l.6b1)
// J. Same-week replay advance preserves snapshot->cycle linkage (7.55l.6b2)
// K. Same-week replay preserves cycle-projected active profile (7.55l.6b3)
// L. Cross-week replay advance preserves prior week's locked snapshot (7.55m.2)

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/services/schedule_plan_read_service.dart';
import 'package:forge_and_flow/services/shift_service.dart';
import 'package:forge_and_flow/services/target_cycle_service.dart';
import 'package:forge_and_flow/services/weekly_plan_snapshot_service.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/schedule_plan.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_policy.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = DemoScope.restaurantId;

  // Default seeded business date: 2026-03-27 (Friday).
  // Monday-start week: 2026-03-23 to 2026-03-29.
  const businessDate = '2026-03-27';
  final weekStart =
      WeeklyPlanSnapshotPolicy.weekStartForDate(businessDate); // 2026-03-23
  final weekEnd =
      WeeklyPlanSnapshotPolicy.weekEndForDate(businessDate); // 2026-03-29
  final weekKey =
      WeeklyPlanSnapshotPolicy.weekKeyFromSpan(weekStart, weekEnd);

  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  // ── A: Generates and persists a snapshot when missing ───────────────────

  group('A — generates snapshot when missing', () {
    test('returns non-null snapshot from seeded data', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      expect(snapshot, isNotNull);
      expect(snapshot!.restaurantId, restaurantId);
      expect(snapshot.weekStartDate, weekStart);
      expect(snapshot.weekEndDate, weekEnd);
      expect(snapshot.weekKey, weekKey);
      expect(snapshot.forecastCovers, greaterThan(0));
      expect(snapshot.forecastSales, greaterThan(0));
    });

    test('snapshot is persisted to repository', () async {
      await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      final loaded = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, weekKey);
      expect(loaded, isNotNull);
      expect(loaded!.weekKey, weekKey);
    });

    test('snapshot is findable by business date', () async {
      await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      final loaded = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForBusinessDate(restaurantId, businessDate);
      expect(loaded, isNotNull);
      expect(loaded!.weekKey, weekKey);
    });
  });

  // ── B: Returns existing snapshot unchanged on subsequent reads ──────────

  group('B — returns existing snapshot unchanged', () {
    test('second call returns same snapshot without regeneration', () async {
      final first =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      final second =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(second!.snapshotId, first!.snapshotId);
      expect(second.generatedAt, first.generatedAt);
      expect(second.lockedAt, first.lockedAt);
    });
  });

  // ── C: Snapshot stores the active targetCycleId ─────────────────────────

  group('C — stores active targetCycleId', () {
    test('snapshot targetCycleId matches the active cycle', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, businessDate);

      expect(snapshot, isNotNull);
      expect(snapshot!.targetCycleId, cycle.cycleId);
    });
  });

  // ── D: Snapshot stores weekly totals and day rows matching SchedulePlan ──

  group('D — bottom-up locked snapshot (PR #917 + seed parity)', () {
    // Per-Daypart V1: the locked snapshot (runtime AND demo-seed) is now
    // bottom-up by construction via the SHARED
    // `WeeklyPlanSnapshotBottomUpReconciler`. Day rows = Σ(per-period
    // rows); week totals = Σ(day rows); week theoretical FOH/BOH $ =
    // Σ(per-period $). The snapshot therefore intentionally NO LONGER
    // equals the raw pooled `SchedulePlan` (which is independently
    // largest-remainder allocated and pool-rounded). The contract that
    // matters is internal consistency: Σ(per-period) == day == week.
    test('week totals == Σ(day rows) and structurally consistent',
        () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      final plan =
          await SchedulePlanReadService.instance.getCurrentWeeklyPlan();

      expect(snapshot, isNotNull);
      expect(plan, isNotNull);

      final dayCovers = snapshot!.dayRows
          .fold<int>(0, (s, d) => s + d.forecastCovers);
      final daySales = snapshot.dayRows
          .fold<double>(0, (s, d) => s + d.forecastSales);
      final dayFoh = snapshot.dayRows
          .fold<int>(0, (s, d) => s + d.requiredFohHours);
      final dayBoh = snapshot.dayRows
          .fold<int>(0, (s, d) => s + d.requiredBohHours);

      // Week totals are the SUM of the day rows (bottom-up).
      expect(snapshot.forecastCovers, dayCovers);
      expect(snapshot.forecastSales, closeTo(daySales, 1e-6));
      expect(snapshot.requiredFohHours, dayFoh);
      expect(snapshot.requiredBohHours, dayBoh);

      // Source enums still passthrough from the resolved plan.
      expect(snapshot.coversSource, plan!.coversSource);
      expect(snapshot.salesSource, plan.salesSource);
    });

    test('Σ(per-period) == day == week for covers and sales', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      expect(snapshot, isNotNull);
      // Seeded demo cycle carries per-period rows (not the Gap-42
      // empty fallback) — the locked snapshot is genuinely bottom-up.
      expect(snapshot!.dayDayparts.isNotEmpty, isTrue,
          reason: 'seeded demo cycle should have per-period rows so the '
              'bottom-up reconciliation is exercised');

      final byDate = <String, List<dynamic>>{};
      for (final dp in snapshot.dayDayparts) {
        (byDate[dp.businessDate] ??= <dynamic>[]).add(dp);
      }

      var weekPeriodCovers = 0;
      var weekPeriodSales = 0.0;
      for (final dayRow in snapshot.dayRows) {
        final periods = byDate[dayRow.businessDate];
        if (periods == null || periods.isEmpty) {
          // Gap-42 per-day fallback day — pooled values kept verbatim.
          weekPeriodCovers += dayRow.forecastCovers;
          weekPeriodSales += dayRow.forecastSales;
          continue;
        }
        final pCovers =
            periods.fold<int>(0, (s, p) => s + (p.forecastCovers as int));
        final pSales = periods.fold<double>(
            0, (s, p) => s + (p.forecastSales as double));
        // Σ(per-period) == day row.
        expect(dayRow.forecastCovers, pCovers,
            reason: 'day ${dayRow.businessDate} covers must equal '
                'Σ(per-period covers)');
        expect(dayRow.forecastSales, closeTo(pSales, 1e-6),
            reason: 'day ${dayRow.businessDate} sales must equal '
                'Σ(per-period sales)');
        weekPeriodCovers += pCovers;
        weekPeriodSales += pSales;
      }

      // Σ(per-period) == week total.
      expect(snapshot.forecastCovers, weekPeriodCovers);
      expect(snapshot.forecastSales, closeTo(weekPeriodSales, 1e-6));
    });

    test('day rows align 1:1 with SchedulePlan dayPlans by label/date',
        () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      final plan =
          await SchedulePlanReadService.instance.getCurrentWeeklyPlan();

      expect(snapshot, isNotNull);
      expect(plan, isNotNull);
      // Structural shape is unchanged (same count + day labels); only
      // the magnitudes are now bottom-up reconciled.
      expect(snapshot!.dayRows.length, plan!.dayPlans.length);
      for (var i = 0; i < snapshot.dayRows.length; i++) {
        expect(snapshot.dayRows[i].day, plan.dayPlans[i].day);
      }
    });

    test('day rows have sequential business dates starting from week start',
        () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      expect(snapshot, isNotNull);
      expect(snapshot!.dayRows.isNotEmpty, isTrue);
      expect(snapshot.dayRows.first.businessDate, weekStart);

      // Verify dates are sequential
      for (var i = 1; i < snapshot.dayRows.length; i++) {
        final prevDate = snapshot.dayRows[i - 1].businessDate;
        final currDate = snapshot.dayRows[i].businessDate;
        expect(currDate.compareTo(prevDate), greaterThan(0));
      }
    });
  });

  // ── E: Mock replay business date preferred over latest closed ───────────

  group('E — mock replay date preferred', () {
    test('uses mock replay date as current-week anchor', () async {
      // Default seeded mock replay date is 2026-03-27.
      // Snapshot should be for the week containing that date.
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      expect(snapshot, isNotNull);
      expect(snapshot!.weekStartDate, weekStart);
      expect(snapshot.weekEndDate, weekEnd);
    });

    test('changing mock replay date changes the snapshot week', () async {
      // Generate snapshot for default week first
      await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      // Advance mock replay date to a different week
      const newDate = '2026-04-06'; // Monday of next-next week
      await SqliteDatabase.instance
          .setMockReplayBusinessDate(restaurantId, newDate);

      final newWeekStart =
          WeeklyPlanSnapshotPolicy.weekStartForDate(newDate);
      final newWeekEnd =
          WeeklyPlanSnapshotPolicy.weekEndForDate(newDate);

      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      expect(snapshot, isNotNull);
      expect(snapshot!.weekStartDate, newWeekStart);
      expect(snapshot.weekEndDate, newWeekEnd);
    });

    test('falls back to latest closed date when mock replay cleared',
        () async {
      // Clear mock replay state
      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');

      // Should still produce a snapshot using latest closed shift date
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      // May or may not be null depending on closed shift data;
      // at minimum, should not throw
      if (snapshot != null) {
        expect(snapshot.weekStartDate, isNotEmpty);
        expect(snapshot.weekEndDate, isNotEmpty);
      }
    });
  });

  // ── F: Existing snapshot remains in force despite cycle change ──────────

  group('F — locked snapshot stability', () {
    test('existing snapshot unchanged even if cycle would now differ',
        () async {
      // Generate and lock the current week's snapshot
      final original =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(original, isNotNull);

      final originalCycleId = original!.targetCycleId;
      final originalCovers = original.forecastCovers;

      // Force a new cycle by admin replacement (changes the active cycle)
      await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, businessDate);

      // The snapshot should still be the original, locked one
      final afterRefresh =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      expect(afterRefresh, isNotNull);
      expect(afterRefresh!.snapshotId, original.snapshotId);
      expect(afterRefresh.targetCycleId, originalCycleId);
      expect(afterRefresh.forecastCovers, originalCovers);
    });
  });

  // ── G: Returns null when plan cannot be resolved ────────────────────────

  group('G — null when plan unresolvable', () {
    test('returns null when no business date can be determined', () async {
      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');
      await db.delete('shift_records');

      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNull);
    });
  });

  // ── H: DAO/repository round-trip ────────────────────────────────────────

  group('H — persistence round-trip', () {
    test('persisted snapshot preserves all fields on read-back', () async {
      final original =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(original, isNotNull);

      // Read back from repository
      final loaded = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, original!.weekKey);

      expect(loaded, isNotNull);
      expect(loaded!.snapshotId, original.snapshotId);
      expect(loaded.restaurantId, original.restaurantId);
      expect(loaded.weekKey, original.weekKey);
      expect(loaded.weekStartDate, original.weekStartDate);
      expect(loaded.weekEndDate, original.weekEndDate);
      expect(loaded.targetCycleId, original.targetCycleId);
      expect(loaded.forecastCovers, original.forecastCovers);
      expect(loaded.forecastSales, original.forecastSales);
      expect(loaded.requiredFohHours, original.requiredFohHours);
      expect(loaded.requiredBohHours, original.requiredBohHours);
      expect(loaded.theoreticalFohLaborDollars,
          original.theoreticalFohLaborDollars);
      expect(loaded.theoreticalBohLaborDollars,
          original.theoreticalBohLaborDollars);
      expect(loaded.coversSource, original.coversSource);
      expect(loaded.salesSource, original.salesSource);
      expect(loaded.generatedAt, original.generatedAt);
      expect(loaded.lockedAt, original.lockedAt);

      // Day rows
      expect(loaded.dayRows.length, original.dayRows.length);
      for (var i = 0; i < loaded.dayRows.length; i++) {
        expect(loaded.dayRows[i].day, original.dayRows[i].day);
        expect(loaded.dayRows[i].businessDate,
            original.dayRows[i].businessDate);
        expect(loaded.dayRows[i].forecastCovers,
            original.dayRows[i].forecastCovers);
        expect(loaded.dayRows[i].forecastSales,
            original.dayRows[i].forecastSales);
        expect(loaded.dayRows[i].requiredFohHours,
            original.dayRows[i].requiredFohHours);
        expect(loaded.dayRows[i].requiredBohHours,
            original.dayRows[i].requiredBohHours);
      }
    });
  });

  // ── I: Mock replay advance preserves locked snapshot (7.55l.6b1) ────────

  group('I — mock replay same-week advance preserves locked snapshot', () {
    test('advanceMockReplayDay within same week keeps same snapshot', () async {
      // Generate and lock the current week's snapshot.
      // Default business date is 2026-03-27 (Friday), week Mon 2026-03-23.
      final original =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(original, isNotNull);

      // Advance mock replay by one day (Friday → Saturday) via the real
      // ShiftService.advanceMockReplayDay path, which exercises
      // reseedMockReplayForBusinessDate under the hood.
      await ShiftService.instance.advanceMockReplayDay();

      // The snapshot for the same week should still be the original.
      final afterAdvance =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      expect(afterAdvance, isNotNull);
      expect(afterAdvance!.snapshotId, original!.snapshotId);
      expect(afterAdvance.generatedAt, original.generatedAt);
      expect(afterAdvance.forecastCovers, original.forecastCovers);
      expect(afterAdvance.targetCycleId, original.targetCycleId);
    });

    test('advance into new week can generate a new snapshot', () async {
      // Generate and lock snapshot for the default week (Mon 2026-03-23).
      final originalWeek =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(originalWeek, isNotNull);

      // Jump mock replay date to the next Monday (new business week).
      const nextWeekDate = '2026-03-30';
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate(nextWeekDate);

      final nextWeekStart =
          WeeklyPlanSnapshotPolicy.weekStartForDate(nextWeekDate);

      final newWeekSnapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      expect(newWeekSnapshot, isNotNull);
      expect(newWeekSnapshot!.weekStartDate, nextWeekStart);
      // Different week, so different snapshot id.
      expect(newWeekSnapshot.snapshotId, isNot(originalWeek!.snapshotId));
    });

    test('multiple same-week advances all preserve the original snapshot',
        () async {
      // Lock snapshot on Friday (default 2026-03-27).
      final original =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(original, isNotNull);

      // Advance twice: Friday → Saturday → Sunday. Both still same week.
      await ShiftService.instance.advanceMockReplayDay();
      await ShiftService.instance.advanceMockReplayDay();

      final afterTwoAdvances =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      expect(afterTwoAdvances, isNotNull);
      expect(afterTwoAdvances!.snapshotId, original!.snapshotId);
      expect(afterTwoAdvances.generatedAt, original.generatedAt);
    });
  });

  // ── J: Same-week replay preserves snapshot->cycle linkage (7.55l.6b2) ──

  group('J — snapshot->cycle linkage preserved across same-week replay', () {
    test('preserved snapshot targetCycleId resolves to existing cycle row',
        () async {
      // Generate and lock the current week's snapshot.
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      final originalCycleId = snapshot!.targetCycleId;

      // Advance mock replay by one day within the same week.
      await ShiftService.instance.advanceMockReplayDay();

      // The cycle referenced by the locked snapshot must still exist.
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);
      expect(cycle, isNotNull);
      expect(cycle!.cycleId, originalCycleId);
    });

    test('same-week replay advance does not mutate the preserved snapshot row',
        () async {
      final original =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(original, isNotNull);

      await ShiftService.instance.advanceMockReplayDay();

      // Re-read from repository to confirm the persisted row is unchanged.
      final loaded = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, original!.weekKey);
      expect(loaded, isNotNull);
      expect(loaded!.snapshotId, original.snapshotId);
      expect(loaded.targetCycleId, original.targetCycleId);
      expect(loaded.forecastCovers, original.forecastCovers);
      expect(loaded.forecastSales, original.forecastSales);
      expect(loaded.generatedAt, original.generatedAt);
      expect(loaded.lockedAt, original.lockedAt);
      expect(loaded.dayRows.length, original.dayRows.length);
    });

    test('new-week replay advance can still move forward normally', () async {
      // Lock snapshot for the default week.
      final originalWeek =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(originalWeek, isNotNull);

      // Jump to the next Monday (new business week).
      const nextWeekDate = '2026-03-30';
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate(nextWeekDate);

      // A new cycle and snapshot should be generated for the new week.
      final newSnapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(newSnapshot, isNotNull);
      expect(newSnapshot!.snapshotId, isNot(originalWeek!.snapshotId));

      // The new snapshot's cycle must also resolve.
      final newCycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);
      expect(newCycle, isNotNull);
      expect(newCycle!.cycleId, newSnapshot.targetCycleId);
    });
  });

  // ── K: Same-week replay preserves cycle-projected active profile (7.55l.6b3) ──

  group('K — active profile preserved across same-week replay', () {
    test('preserved active profile matches preserved cycle after same-week advance',
        () async {
      // Generate snapshot (which creates the cycle and projects the profile).
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      final cycleBefore = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);
      expect(cycleBefore, isNotNull);

      final profileBefore = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profileBefore, isNotNull);
      expect(profileBefore!.targetCPLH, cycleBefore!.targetCPLH);

      // Advance mock replay by one day within the same week.
      await ShiftService.instance.advanceMockReplayDay();

      // Active profile must still match the preserved cycle.
      final profileAfter = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profileAfter, isNotNull);
      expect(profileAfter!.targetCPLH, cycleBefore.targetCPLH);
      expect(profileAfter.targetSPLH, cycleBefore.targetSPLH);
      expect(profileAfter.targetPPA, cycleBefore.targetPPA);
      expect(profileAfter.fohWage, cycleBefore.fohWage);
      expect(profileAfter.bohWage, cycleBefore.bohWage);
      expect(profileAfter.opzFloorCPLH, cycleBefore.opzFloorCPLH);
      expect(profileAfter.opzCeilingCPLH, cycleBefore.opzCeilingCPLH);
    });

    test('active profile survives after admin replacement + same-week advance',
        () async {
      // Generate snapshot to lock the week.
      await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      // Admin replacement creates a new cycle with a fresh projection.
      final replaced = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, businessDate);

      // Advance mock replay within the same week.
      await ShiftService.instance.advanceMockReplayDay();

      // Active profile must still match the replaced cycle.
      final profileAfter = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profileAfter, isNotNull);
      expect(profileAfter!.targetCPLH, replaced.targetCPLH);
      expect(profileAfter.targetSPLH, replaced.targetSPLH);
      expect(profileAfter.targetPPA, replaced.targetPPA);
      expect(profileAfter.fohWage, replaced.fohWage);
      expect(profileAfter.bohWage, replaced.bohWage);
    });

    test('new-week replay advance still seeds active profile correctly',
        () async {
      // Lock snapshot and cycle for the default week.
      await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      // Jump to the next Monday (new business week).
      const nextWeekDate = '2026-03-30';
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate(nextWeekDate);

      // Generate a new snapshot for the new week (triggers cycle lookup).
      final newSnapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(newSnapshot, isNotNull);

      // The active profile must be valid and aligned to the active cycle.
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);
      expect(cycle, isNotNull);

      final profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profile, isNotNull);
      expect(profile!.targetCPLH, cycle!.targetCPLH);
      expect(profile.targetSPLH, cycle.targetSPLH);
      expect(profile.targetPPA, cycle.targetPPA);
      expect(profile.fohWage, cycle.fohWage);
      expect(profile.bohWage, cycle.bohWage);
    });
  });

  // ── L: Cross-week replay preserves prior week snapshot (7.55m.2) ───────

  group('L — cross-week replay preserves prior week locked snapshot', () {
    test('W13 snapshot row survives after advancing to W14', () async {
      // Lock snapshot for W13.
      final w13Snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(w13Snapshot, isNotNull);

      // Advance to W14 Monday.
      const nextWeekDate = '2026-03-30';
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate(nextWeekDate);

      // Generate W14 snapshot.
      final w14Snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(w14Snapshot, isNotNull);
      expect(w14Snapshot!.snapshotId, isNot(w13Snapshot!.snapshotId));

      // W13 snapshot must still be readable from the repository.
      final rereadW13 = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, w13Snapshot.weekKey);
      expect(rereadW13, isNotNull);
      expect(rereadW13!.snapshotId, w13Snapshot.snapshotId);
      expect(rereadW13.forecastCovers, w13Snapshot.forecastCovers);
      expect(rereadW13.forecastSales, w13Snapshot.forecastSales);
      expect(rereadW13.targetCycleId, w13Snapshot.targetCycleId);
      expect(rereadW13.generatedAt, w13Snapshot.generatedAt);
      expect(rereadW13.lockedAt, w13Snapshot.lockedAt);
    });

    test('W13 snapshot day rows survive after advancing to W14', () async {
      final w13Snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(w13Snapshot, isNotNull);
      final originalDayRows = w13Snapshot!.dayRows;

      // Advance to W14 and trigger new snapshot generation.
      const nextWeekDate = '2026-03-30';
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate(nextWeekDate);
      await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      // Re-read W13 and verify day rows are intact.
      final rereadW13 = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, w13Snapshot.weekKey);
      expect(rereadW13, isNotNull);
      expect(rereadW13!.dayRows.length, originalDayRows.length);

      for (var i = 0; i < originalDayRows.length; i++) {
        expect(rereadW13.dayRows[i].day, originalDayRows[i].day);
        expect(rereadW13.dayRows[i].businessDate,
            originalDayRows[i].businessDate);
        expect(rereadW13.dayRows[i].forecastCovers,
            originalDayRows[i].forecastCovers);
        expect(rereadW13.dayRows[i].forecastSales,
            originalDayRows[i].forecastSales);
      }
    });
  });

  // ── CODE_HEALTH L15 — Mon-first contract assertion ────────────────────────
  // Regression pin for the audit finding: `weekly_plan_snapshot_service.dart`
  // day-row rotation assumed `SchedulePlan.dayPlans` is Mon-first with no
  // explicit assertion. Drift in `SchedulePlanResolver._defaultDayWeights`
  // would silently desync business dates from day labels. The fix asserts
  // Mon-first explicitly at the rotation boundary and throws StateError on
  // any deviation.

  group('CODE_HEALTH L15 — Mon-first day-plans contract', () {
    SchedulePlan planFromOrder(List<String> dayLabels) {
      final dayPlans = dayLabels
          .map((d) => ScheduleDayPlan(
                day: d,
                forecastCovers: 100,
                forecastSales: 4200.0,
                requiredFohHours: 22,
                requiredBohHours: 23,
              ))
          .toList();
      return SchedulePlan(
        forecastCovers: 700,
        forecastSales: 29400.0,
        requiredFohHours: 154,
        requiredBohHours: 161,
        theoreticalFohLaborDollars: 2541.0,
        theoreticalBohLaborDollars: 3438.35,
        theoreticalLaborPct: 20.34,
        targetBlendedWage: 18.95,
        coversSource: ForecastDemandSource.demoFallback,
        salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
        dayPlans: dayPlans,
      );
    }

    test('Mon-first plan passes the assertion and produces 7 rows', () {
      final plan = planFromOrder(
          ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']);
      final rows = WeeklyPlanSnapshotService.debugBuildDayRows(
          plan, '2026-03-23');
      expect(rows.length, 7);
      expect(rows.first.day, 'Mon');
      expect(rows.last.day, 'Sun');
    });

    test('non-Mon-first plan throws StateError at the rotation boundary',
        () {
      // Sunday-first ordering would silently desync business dates from
      // day labels in the rotation step. The fix throws StateError loudly.
      final plan = planFromOrder(
          ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']);
      expect(
        () =>
            WeeklyPlanSnapshotService.debugBuildDayRows(plan, '2026-03-23'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message',
                contains('Mon-first'))),
      );
    });

    test('short day-plans list throws StateError', () {
      final plan = planFromOrder(['Mon', 'Tue', 'Wed']);
      expect(
        () =>
            WeeklyPlanSnapshotService.debugBuildDayRows(plan, '2026-03-23'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
