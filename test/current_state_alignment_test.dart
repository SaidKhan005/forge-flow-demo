// Phase 7.5c â€” Current state alignment tests.
//
// Validates:
// A. Fixture replay seeds current/open state
// B. Shift dashboard read model comes from persisted current state
// C. Variance Full Week state comes from merged current-week state
// D. Fixture replay can drive the aligned app read surfaces

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/shift_data_source.dart';
import 'package:forge_and_flow/data/shift_service.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import 'package:forge_and_flow/models/current_week_state.dart';

void main() {
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
    test('getShiftDashboard returns non-null read model', () async {
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm, isNotNull);
    });

    test('read model has non-empty context fields', () async {
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm!.daypart, isNotEmpty);
      expect(rm.day, isNotEmpty);
      expect(rm.timeLabel, isNotEmpty);
      expect(rm.serviceElapsedLabel, isNotEmpty);
    });

    test('read model has current metrics', () async {
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm!.actualCovers, greaterThan(0));
      expect(rm.forecastCovers, greaterThan(0));
      expect(rm.actualCPLH, greaterThan(0));
    });

    test('read model has active lever', () async {
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm!.primaryLeverId, isNotEmpty);
      expect(rm.primaryLeverCard.whatHappened, isNotEmpty);
    });

    test('read model has metric cards', () async {
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm!.metricCards, isNotEmpty);
      final heroes = rm.metricCards.where((c) => c.isHero);
      expect(heroes.length, 1);
    });

    test('read model OPZ status is valid', () async {
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

    test('Shift dashboard query works', () async {
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm, isNotNull);
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
    test('getCurrentWeekId resolves from persisted open state', () async {
      final weekId = await ShiftService.instance.getCurrentWeekId();
      expect(weekId, isNotNull);
      expect(weekId, '2026-W13');
    });

    test('getLiveWeekToDate returns WTD without WeekToDate constants', () async {
      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);
      expect(wtd!.weekId, '2026-W13');
      expect(wtd.totalCovers, greaterThan(0));
    });

    test('LiveShiftDataSource.getWeekToDate uses live resolution', () async {
      const source = LiveShiftDataSource();
      final wtd = await source.getWeekToDate();
      expect(wtd, isNotNull);
      expect(wtd!.weekId, '2026-W13');
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
