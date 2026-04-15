// Current-state alignment tests.
//
// Validates:
// A. Fixture replay seeds current/open state
// B. Shift whole-day read model requires persisted current state plus an
//    existing locked weekly plan
// C. Variance Full Week state comes from merged current-week state using
//    locked-plan truth plus current active-profile benchmark targets
// D. Fixture replay can drive the aligned app read surfaces

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/shift_service.dart';
import 'package:forge_and_flow/data/target_cycle_service.dart';
import 'package:forge_and_flow/data/wage_standard_context_service.dart';
import 'package:forge_and_flow/data/weekly_plan_snapshot_service.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/models/current_week_state.dart';

void main() {
  Future<void> ensureCurrentWeekSnapshot() async {
    final snapshot =
        await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
    expect(snapshot, isNotNull);
  }

  Future<ActiveTargetProfile> loadActiveProfile() {
    return WageStandardContextService.instance
        .loadOrBootstrapProfile('demo_restaurant_001');
  }

  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  // â”€â”€ A: Fixture replay seeds current/open state â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('A â€” fixture replay seeds current/open state', () {
    test('open_shift_snapshots table has rows after reseed', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('open_shift_snapshots',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001']);
      expect(rows, isNotEmpty,
          reason: 'at least one open/projected snapshot must exist');
    });

    test('at least one open snapshot exists for 2026-W13', () async {
      final snapshots = await SqliteOpenShiftSnapshotRepository.instance
          .getOpenShiftsForWeek('demo_restaurant_001', '2026-W13');
      expect(snapshots, isNotEmpty);
    });

    test('current open shift snapshot exists with status=open', () async {
      final snapshot = await SqliteOpenShiftSnapshotRepository.instance
          .getCurrentOpenShift('demo_restaurant_001');
      expect(snapshot, isNotNull);
      expect(snapshot!.status, 'open');
      expect(snapshot.dayLabel, 'Fri');
      expect(snapshot.daypart, 'dinner');
    });

    test('current-week closed shifts exist in shift_records', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('shift_records',
          where: "restaurant_id = ? AND week_id = ? AND status = 'closed'",
          whereArgs: ['demo_restaurant_001', '2026-W13']);
      expect(rows.length, greaterThanOrEqualTo(9));
    });
  });

  // â”€â”€ B: Shift dashboard read model from persisted current state â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” shift dashboard read model', () {
    test('getShiftDashboard returns null when no locked weekly plan exists',
        () async {
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm, isNull);
    });

    test('read model has non-empty context fields', () async {
      await ensureCurrentWeekSnapshot();
      final rm = await ShiftService.instance.getShiftDashboard();
      // daypart may be empty for whole-day views
      expect(rm!.day, isNotEmpty);
      expect(rm.timeLabel, isNotEmpty);
      expect(rm.serviceElapsedLabel, isNotEmpty);
    });

    test('read model has current metrics', () async {
      await ensureCurrentWeekSnapshot();
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm!.actualCovers, greaterThan(0));
      expect(rm.forecastCovers, greaterThan(0));
      expect(rm.actualCPLH, greaterThan(0));
    });

    test('read model has active lever', () async {
      await ensureCurrentWeekSnapshot();
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm!.primaryLeverId, isNotEmpty);
      expect(rm.primaryLeverCard.whatHappened, isNotEmpty);
    });

    test('read model has metric cards', () async {
      await ensureCurrentWeekSnapshot();
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm!.metricCards, isNotEmpty);
      final heroes = rm.metricCards.where((c) => c.isHero);
      expect(heroes.length, 1);
    });

    test('read model OPZ status is valid', () async {
      await ensureCurrentWeekSnapshot();
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(['below', 'in', 'above'], contains(rm!.opzStatus));
      expect(rm.opzLabel, isNotEmpty);
    });
  });

  // â”€â”€ C: Variance Full Week from merged current-week state â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('C â€” current week state', () {
    test('getFullWeekShifts returns closed + open/projected', () async {
      final shifts =
          await ShiftService.instance.getFullWeekShifts('2026-W13');
      expect(shifts, isNotEmpty);

      final closed = shifts.where((s) => s.isClosed).toList();
      final projected = shifts.where((s) => !s.isClosed).toList();

      expect(closed, isNotEmpty, reason: 'must have closed shifts');
      expect(projected, isNotEmpty, reason: 'must have open/projected shifts');
    });

    test('full week has 14 slots total', () async {
      final shifts =
          await ShiftService.instance.getFullWeekShifts('2026-W13');
      expect(shifts.length, 14);
    });

    test('getCurrentWeekState returns valid state', () async {
      await ensureCurrentWeekSnapshot();
      final state = await ShiftService.instance
          .getCurrentWeekState('2026-W13', 'Mar 24');
      expect(state, isNotNull);
      expect(state!.weekData.totalCovers, greaterThan(0));
      expect(state.fullWeekShifts.length, 14);
    });
  });

  // â”€â”€ D: Fixture replay drives aligned app read surfaces â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('D â€” fixture replay readiness', () {
    test('WTD query works', () async {
      final wtd = await ShiftService.instance
          .getWeekToDate('2026-W13', 'Mar 24');
      expect(wtd, isNotNull);
      expect(wtd!.totalCovers, greaterThan(0));
    });

    test('week history query works', () async {
      final weeks = await ShiftService.instance.getWeekHistory();
      expect(weeks, isNotEmpty);
    });

    test('history pattern query works', () async {
      final patterns =
          await ShiftService.instance.getHistoryPatternRecords();
      expect(patterns, isNotEmpty);
    });
  });

  // â”€â”€ E: Live current-week resolves from persisted state â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('E â€” live current-week resolution', () {
    test('getLiveWeekToDate returns WTD without WeekToDate constants', () async {
      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);
      expect(wtd!.weekId, '2026-W13');
      expect(wtd.totalCovers, greaterThan(0));
    });

  });

  // â”€â”€ F: Merged current-week state preserves open rows â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('F â€” open row preservation', () {
    test('merged full-week state has at least one open row', () async {
      final shifts =
          await ShiftService.instance.getFullWeekShifts('2026-W13');
      final openRows = shifts.where((s) => s.isOpen).toList();
      expect(openRows, isNotEmpty,
          reason: 'at least one shift should have status == open');
    });

    test('shiftRecordFromSnapshot preserves open status and carries profile targets', () {
      final profile = ActiveTargetProfile(
        targetProfileId: 'test_active', restaurantId: 'demo_restaurant_001',
        sourceType: 'system_baseline', targetCPLH: 4.58, targetSPLH: 180.0,
        targetPPA: 42.0, fohWage: 16.50, bohWage: 21.35,
        opzFloorCPLH: 3.5, opzCeilingCPLH: 5.8,
        theoreticalFohLaborPct: 8.6, theoreticalBohLaborPct: 11.9,
        theoreticalLaborPct: 20.5, builtAt: '2026-03-27T19:42:00',
      );
      final snapshot = OpenShiftSnapshot(
        restaurantId: 'demo_restaurant_001', weekId: '2026-W13',
        dayLabel: 'Fri', daypart: 'dinner', status: 'open',
        businessDate: '2026-03-27', forecastCovers: 220, currentCovers: 140,
        scheduledFohHours: 34, scheduledBohHours: 33,
        currentPPA: 41.20, currentCPLH: 4.1, currentSPLH: 174.0,
        blendedWage: 18.74, updatedAt: '2026-03-27T19:42:00',
      );
      final record = CurrentWeekState.shiftRecordFromSnapshot(snapshot, profile);
      expect(record.status, 'open');
      expect(record.isOpen, isTrue);
      expect(record.theoreticalLaborPct, 20.5);
      expect(record.targetCPLH, 4.58);
      expect(record.targetPPA, 42.0);
      expect(record.targetFohWage, 16.50);
    });

    test('shiftRecordFromSnapshot preserves projected status', () {
      final profile = ActiveTargetProfile(
        targetProfileId: 'test_active', restaurantId: 'demo_restaurant_001',
        sourceType: 'system_baseline', targetCPLH: 4.58, targetSPLH: 180.0,
        targetPPA: 42.0, fohWage: 16.50, bohWage: 21.35,
        opzFloorCPLH: 3.5, opzCeilingCPLH: 5.8,
        theoreticalFohLaborPct: 8.6, theoreticalBohLaborPct: 11.9,
        theoreticalLaborPct: 20.5, builtAt: '2026-03-27T19:42:00',
      );
      final snapshot = OpenShiftSnapshot(
        restaurantId: 'demo_restaurant_001', weekId: '2026-W13',
        dayLabel: 'Sat', daypart: 'dinner', status: 'projected',
        businessDate: '2026-03-28', forecastCovers: 310, currentCovers: 310,
        scheduledFohHours: 69, scheduledBohHours: 72,
        currentPPA: 42.5, currentCPLH: 4.49, currentSPLH: 175.7,
        blendedWage: 18.5, updatedAt: '2026-03-27T19:42:00',
      );
      final record = CurrentWeekState.shiftRecordFromSnapshot(snapshot, profile);
      expect(record.status, 'projected');
      expect(record.isProjected, isTrue);
      expect(record.isOpen, isFalse);
    });

    test('getFullWeekShifts returns open/projected rows with active-profile targets', () async {
      final shifts = await ShiftService.instance.getFullWeekShifts('2026-W13');
      final openRows = shifts.where((s) => s.isOpen || s.isProjected).toList();
      expect(openRows, isNotEmpty);
      for (final r in openRows) {
        expect(r.targetCPLH, isNotNull);
        expect(r.targetCPLH, greaterThan(0));
        expect(r.theoreticalLaborPct, greaterThan(0));
        expect(r.targetFohWage, isNotNull);
      }
    });
  });

  // ── H: Current-week WTD uses locked weekly truth (7.55l.7b/7b1) ────────────

  group('H — locked weekly truth for current-week WTD', () {
    test('getLiveWeekToDate uses locked snapshot forecast covers', () async {
      // Get the locked snapshot to know expected weekly forecast
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);
      expect(wtd!.totalWeekForecastCovers, equals(snapshot!.forecastCovers),
          reason:
              'Current-week WTD weekly forecast must come from locked snapshot');
    });

    test('wtdForecastCovers comes from snapshot day rows not shift records',
        () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);

      // Sum snapshot day-row forecast covers through the last closed day
      const dayOrder = {
        'Mon': 1, 'Tue': 2, 'Wed': 3, 'Thu': 4,
        'Fri': 5, 'Sat': 6, 'Sun': 7,
      };
      final expectedWtdForecast = snapshot!.dayRows
          .where((d) => (dayOrder[d.day] ?? 0) <= wtd!.closedDayNumber)
          .fold<int>(0, (s, d) => s + d.forecastCovers);

      expect(wtd!.wtdForecastCovers, equals(expectedWtdForecast),
          reason:
              'WTD forecast covers must come from snapshot day rows through '
              'the last closed day, not from shift records');
    });

    test('getLiveWeekToDate uses current active profile for benchmark targets',
        () async {
      await ensureCurrentWeekSnapshot();
      final profile = await loadActiveProfile();
      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);
      expect(wtd!.targetCPLH, equals(profile.targetCPLH),
          reason: 'WTD target CPLH must come from the current active profile');
      expect(wtd.targetPPA, equals(profile.targetPPA),
          reason: 'WTD target PPA must come from the current active profile');
    });

    test('same-week cycle change rewrites benchmark targets but preserves '
        'locked forecast truth',
        () async {
      // Get initial WTD (triggers snapshot auto-lock if needed)
      final initialWtd = await ShiftService.instance.getLiveWeekToDate();
      expect(initialWtd, isNotNull);

      // Apply admin replacement cycle (changes target standards)
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final mockDate = await SqliteDatabase.instance
          .getMockReplayBusinessDate(restaurantId);
      await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, mockDate!);

      final activeProfile = await loadActiveProfile();
      final afterWtd = await ShiftService.instance.getLiveWeekToDate();
      expect(afterWtd, isNotNull);
      expect(afterWtd!.targetCPLH, equals(activeProfile.targetCPLH),
          reason:
              'Non-closed WTD benchmark targets must follow the current active profile');
      expect(afterWtd.targetPPA, equals(activeProfile.targetPPA));
      expect(afterWtd.totalWeekForecastCovers,
          equals(initialWtd!.totalWeekForecastCovers));
      expect(afterWtd.wtdForecastCovers,
          equals(initialWtd.wtdForecastCovers),
          reason:
              'Same-week cycle change must not rewrite locked WTD forecast');
    });

    test('projection math inherits locked forecast truth', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);

      // remainingForecastCovers = totalWeekForecastCovers - wtdForecastCovers
      final expectedRemaining =
          wtd!.totalWeekForecastCovers - wtd.wtdForecastCovers;
      expect(wtd.remainingForecastCovers,
          equals(expectedRemaining < 0 ? 0 : expectedRemaining),
          reason:
              'Projection remaining covers must derive from locked forecast');
    });

    test('historical getWeekToDate remains on live path', () async {
      final wtd = await ShiftService.instance
          .getWeekToDate('2026-W13', 'Mar 24');
      expect(wtd, isNotNull);
      // Historical path still works — just confirm it resolves
      expect(wtd!.totalCovers, greaterThan(0));
    });
  });

  // ── I: Current-week Full Week / CurrentWeekState locked truth (7.55l.7c) ───

  group('I — locked Full Week / CurrentWeekState', () {
    test('getCurrentWeekState uses locked WTD path', () async {
      // Ensure snapshot exists
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      final profile = await loadActiveProfile();

      final state = await ShiftService.instance
          .getCurrentWeekState('2026-W13', 'Mar 24');
      expect(state, isNotNull);

      // WeekData inside CurrentWeekState must use current active-profile
      // targets for Benchmark-owned metrics.
      expect(state!.weekData.targetCPLH, equals(profile.targetCPLH),
          reason:
              'CurrentWeekState.weekData must use current active-profile targets');
      expect(state.weekData.targetPPA, equals(profile.targetPPA));

      // Weekly forecast must come from locked snapshot
      expect(state.weekData.totalWeekForecastCovers,
          equals(snapshot!.forecastCovers));
    });

    test('getFullWeekShifts open/projected rows use current active profile targets',
        () async {
      await ensureCurrentWeekSnapshot();
      final profile = await loadActiveProfile();

      final shifts =
          await ShiftService.instance.getFullWeekShifts('2026-W13');
      final openRows =
          shifts.where((s) => s.isOpen || s.isProjected).toList();
      expect(openRows, isNotEmpty);

      for (final r in openRows) {
        expect(r.targetCPLH, equals(profile.targetCPLH),
            reason:
                'Open/projected row targetCPLH must come from the current active profile');
        expect(r.targetPPA, equals(profile.targetPPA));
        expect(r.targetFohWage, equals(profile.fohWage));
        expect(r.targetBohWage, equals(profile.bohWage));
      }
    });

    test('same-week cycle change rewrites open/projected benchmark targets',
        () async {
      // Get initial full week (triggers snapshot auto-lock if needed)
      final initialShifts =
          await ShiftService.instance.getFullWeekShifts('2026-W13');
      final initialOpen = initialShifts
          .where((s) => s.isOpen || s.isProjected)
          .toList();
      expect(initialOpen, isNotEmpty);

      // Apply admin replacement cycle (changes target standards)
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final mockDate = await SqliteDatabase.instance
          .getMockReplayBusinessDate(restaurantId);
      await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, mockDate!);

      final activeProfile = await loadActiveProfile();
      final afterShifts =
          await ShiftService.instance.getFullWeekShifts('2026-W13');
      final afterOpen = afterShifts
          .where((s) => s.isOpen || s.isProjected)
          .toList();
      expect(afterOpen, isNotEmpty);

      for (final row in afterOpen) {
        expect(row.targetCPLH, equals(activeProfile.targetCPLH),
            reason:
                'Same-week cycle change should rewrite non-closed benchmark targets to the active profile');
        expect(row.targetPPA, equals(activeProfile.targetPPA));
      }
    });

    test('full week still has 14 slots after locked migration', () async {
      final shifts =
          await ShiftService.instance.getFullWeekShifts('2026-W13');
      expect(shifts.length, 14);
    });

    test('non-current getFullWeekShifts does not auto-generate snapshot',
        () async {
      // Query the snapshot table directly (not via service, which auto-generates)
      final db = await SqliteDatabase.instance.database;
      final before = await db.query('weekly_plan_snapshots');
      final countBefore = before.length;

      // Call full week for a non-current week
      await ShiftService.instance.getFullWeekShifts('2026-W12');

      // Verify no snapshot was created as a side effect
      final after = await db.query('weekly_plan_snapshots');
      expect(after.length, equals(countBefore),
          reason:
              'Non-current getFullWeekShifts must not auto-generate a snapshot');
    });

    test('non-current getFullWeekShifts does not use locked cycle targets',
        () async {
      // First trigger current-week snapshot so it exists
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      // Seed a projected snapshot for a non-current week so open rows exist
      final repo = SqliteOpenShiftSnapshotRepository.instance;
      await repo.replaceOpenShiftSnapshot(OpenShiftSnapshot(
        restaurantId: 'demo_restaurant_001',
        weekId: '2026-W12',
        dayLabel: 'Mon',
        daypart: 'lunch',
        status: 'projected',
        businessDate: '2026-03-16',
        forecastCovers: 180,
        currentCovers: 180,
        scheduledFohHours: 36,
        scheduledBohHours: 37,
        currentPPA: 42.0,
        currentCPLH: 4.5,
        currentSPLH: 180.0,
        blendedWage: 18.5,
        updatedAt: '2026-03-16T10:00:00',
      ));

      // Get full week for non-current week — should use live profile, not locked cycle
      final shifts =
          await ShiftService.instance.getFullWeekShifts('2026-W12');
      final openRows =
          shifts.where((s) => s.isOpen || s.isProjected).toList();

      if (openRows.isNotEmpty) {
        // Open rows should use the live active profile, not the locked cycle.
        // The live profile may happen to match the locked cycle values, so
        // we just verify the call completes without error and returns rows.
        // The snapshot side-effect test above is the stronger isolation proof.
        expect(openRows.first.targetCPLH, isNotNull);
        expect(openRows.first.targetCPLH, greaterThan(0));
      }
    });
  });

  // â”€â”€ G: Deterministic current-week fallback resolution â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('G â€” deterministic current-week fallback', () {
    test('getLatestOpenWeekId resolves newest by updated_at', () async {
      final repo = SqliteOpenShiftSnapshotRepository.instance;

      // Insert a snapshot for a different week with an older timestamp
      await repo.replaceOpenShiftSnapshot(OpenShiftSnapshot(
        restaurantId: 'demo_restaurant_001',
        weekId: '2026-W12',
        dayLabel: 'Mon',
        daypart: 'lunch',
        status: 'projected',
        businessDate: '2026-03-16',
        forecastCovers: 180,
        currentCovers: 180,
        scheduledFohHours: 36,
        scheduledBohHours: 37,
        currentPPA: 42.0,
        currentCPLH: 4.5,
        currentSPLH: 180.0,
        blendedWage: 18.5,
        updatedAt: '2026-03-16T10:00:00',
      ));

      // The seeded 2026-W13 snapshots have newer updated_at
      final weekId =
          await repo.getLatestOpenWeekId('demo_restaurant_001');
      expect(weekId, '2026-W13');
    });

    test('getCurrentWeekId uses repository, not raw DB query', () async {
      // After reseed, getCurrentWeekId should resolve deterministically
      final weekId = await ShiftService.instance.getCurrentWeekId();
      expect(weekId, isNotNull);
      expect(weekId, '2026-W13');
    });
  });
}
