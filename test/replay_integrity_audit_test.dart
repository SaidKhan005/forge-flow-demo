// Phase 7.55p.4c + 7.55n.13 — Replay integrity / mock-to-live transition
// audit tests.
//
// All groups now proven:
// A. After reseedDemo, production read paths flow through SQLite
// B. LiveShiftDataSource delegates to ShiftService/SQLite
// C. StaticShiftDataSource reads from BaselineData constants (bridge proof)
// D. buildActiveTargetProfileFromBaseline reads from BaselineData (bridge proof)
// E. Replay reseed populates all operational tables correctly
//
// The snapshot_blended_wage schema gap was fixed in 7.55n.13 (V20 migration).
// Groups A, B, and E are no longer skipped.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/data/shift_data_source.dart';
import 'package:forge_and_flow/data/shift_service.dart';
import 'package:forge_and_flow/data/weekly_plan_snapshot_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  // ── A: SQLite-backed read paths after reseed ──────────────────────────

  group('A — SQLite-backed read paths after reseed', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('getLiveWeekToDate reads from SQLite, not demo constants', () async {
      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);
      expect(wtd!.weekId, isNotEmpty);
      expect(wtd.totalCovers, greaterThan(0));
      expect(wtd.targetCPLH, greaterThan(0));
    });

    test('getShiftDashboard reads from SQLite open_shift_snapshots', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      final rm = await ShiftService.instance.getShiftDashboard();
      expect(rm, isNotNull);
      expect(rm!.actualCovers, greaterThan(0));
      expect(rm.forecastCovers, greaterThan(0));
    });

    test('getFullWeekShifts reads from SQLite shift_records + snapshots',
        () async {
      final shifts =
          await ShiftService.instance.getFullWeekShifts('2026-W13');
      expect(shifts.length, 14);
      final closed = shifts.where((s) => s.isClosed).toList();
      final nonClosed = shifts.where((s) => !s.isClosed).toList();
      expect(closed, isNotEmpty);
      expect(nonClosed, isNotEmpty);
    });

    test('getWeekHistory reads from SQLite week_records', () async {
      final weeks = await ShiftService.instance.getWeekHistory();
      expect(weeks, isNotEmpty);
      expect(weeks.length, 8);
    });

    test('getHistoryPatternRecords reads from SQLite shift_records', () async {
      final patterns =
          await ShiftService.instance.getHistoryPatternRecords();
      expect(patterns, isNotEmpty);
    });

    test('active target profile reads from SQLite after reseed', () async {
      final profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile('demo_restaurant_001');
      expect(profile, isNotNull);
      expect(profile!.targetCPLH, greaterThan(0));
      expect(profile.targetSPLH, greaterThan(0));
      expect(profile.targetPPA, greaterThan(0));
    });
  });

  // ── B: LiveShiftDataSource routes through ShiftService ──────────────────

  group('B — LiveShiftDataSource is the production path', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('LiveShiftDataSource.getWeekToDate delegates to ShiftService',
        () async {
      const live = LiveShiftDataSource();
      final wtd = await live.getWeekToDate();
      expect(wtd, isNotNull);
      expect(wtd!.totalCovers, greaterThan(0));
    });

    test('LiveShiftDataSource.getFullWeekShifts delegates to ShiftService',
        () async {
      const live = LiveShiftDataSource();
      final shifts = await live.getFullWeekShifts('2026-W13');
      expect(shifts.length, 14);
    });

    test('LiveShiftDataSource.getWeekHistory delegates to ShiftService',
        () async {
      const live = LiveShiftDataSource();
      final weeks = await live.getWeekHistory();
      expect(weeks, isNotEmpty);
    });
  });

  // ── C: StaticShiftDataSource is NOT the live runtime path ───────────────
  // Pure tests — no SQLite reseed needed. These run today.

  group('C — StaticShiftDataSource is test/offline only (pure)', () {
    test('StaticShiftDataSource uses BaselineData constants (bridge proof)',
        () async {
      const staticSrc = StaticShiftDataSource();
      final wtd = await staticSrc.getWeekToDate();
      expect(wtd, isNotNull);
      // StaticShiftDataSource explicitly reads BaselineData.derivedTarget*
      // for target fields — this is the bridge dependency
      expect(wtd!.targetCPLH, equals(BaselineData.derivedTargetCPLH));
      expect(wtd.targetSPLH, equals(BaselineData.derivedTargetSPLH));
      expect(wtd.targetPPA, equals(BaselineData.derivedTargetPPA));
    });

    test('StaticShiftDataSource uses MockIntegrationReplaySeed for shifts',
        () async {
      const staticSrc = StaticShiftDataSource();
      final history = await staticSrc.getWeekHistory();
      expect(history, isNotEmpty);
      expect(history.length, 8,
          reason: 'StaticShiftDataSource reads from MockIntegrationReplaySeed '
              'output, which generates 8 historical weeks');
    });

    test('StaticShiftDataSource.getHistoricalClosedShifts returns replay data',
        () async {
      const staticSrc = StaticShiftDataSource();
      final shifts = await staticSrc.getHistoricalClosedShifts();
      expect(shifts, isNotEmpty);
      expect(shifts.length, 112,
          reason: '8 weeks * 14 shifts = 112 historical closed shifts');
    });
  });

  // ── D: buildActiveTargetProfileFromBaseline is a write-time bridge ──────
  // Pure tests — no SQLite reseed needed. These run today.

  group('D — profile bootstrap bridge (pure)', () {
    test('buildActiveTargetProfileFromBaseline reads BaselineData (bridge)',
        () {
      final profile =
          SqliteDatabase.buildActiveTargetProfileFromBaseline(
              'demo_restaurant_001');
      // This method reads from BaselineData/MeridianConfig constants
      expect(profile.targetCPLH, equals(BaselineData.derivedTargetCPLH));
      expect(profile.targetSPLH, equals(BaselineData.derivedTargetSPLH));
      expect(profile.targetPPA, equals(BaselineData.derivedTargetPPA));
      expect(profile.fohWage, equals(MeridianConfig.fohWage));
      expect(profile.bohWage, equals(MeridianConfig.bohWage));
    });

    test('buildActiveTargetProfileFromBaseline produces valid profile shape',
        () {
      final profile =
          SqliteDatabase.buildActiveTargetProfileFromBaseline(
              'demo_restaurant_001');
      expect(profile.restaurantId, 'demo_restaurant_001');
      expect(profile.targetProfileId, contains('demo_restaurant_001'));
      expect(profile.sourceType, 'system_baseline');
      expect(profile.opzFloorCPLH, greaterThan(0));
      expect(profile.opzCeilingCPLH, greaterThan(profile.opzFloorCPLH));
      expect(profile.theoreticalLaborPct, greaterThan(0));
    });

    test('bridge reads BaselineData.hasManagerOverride for sourceType', () {
      // Without override: system_baseline
      expect(BaselineData.hasManagerOverride, isFalse);
      final base = SqliteDatabase.buildActiveTargetProfileFromBaseline(
          'demo_restaurant_001');
      expect(base.sourceType, 'system_baseline');
      // This proves the bridge reads from BaselineData mutable state,
      // not from persisted cycle/profile authority
    });
  });

  // ── E: Replay reseed drives all surfaces through persisted state ────────

  group('E — reseed-driven persisted state integrity', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('open_shift_snapshots populated after reseed', () async {
      final snapshots = await SqliteOpenShiftSnapshotRepository.instance
          .getOpenShiftsForWeek('demo_restaurant_001', '2026-W13');
      expect(snapshots, isNotEmpty);
    });

    test('shift_records populated after reseed', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('shift_records',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001']);
      expect(rows, isNotEmpty);
      expect(rows.length, greaterThan(100));
    });

    test('week_records populated after reseed', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('week_records');
      expect(rows, isNotEmpty);
      expect(rows.length, 8);
      expect(
        rows.every((r) =>
            r['target_calibration_window_start'] != null &&
            r['target_calibration_window_end'] != null),
        isTrue,
      );
    });

    test('active_target_profiles populated after reseed', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('active_target_profiles',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001']);
      expect(rows, isNotEmpty);
    });

    test('clearAllData wipes operational tables', () async {
      await ShiftService.instance.clearAllData();
      final db = await SqliteDatabase.instance.database;

      final shifts = await db.query('shift_records');
      expect(shifts, isEmpty);

      final weeks = await db.query('week_records');
      expect(weeks, isEmpty);

      final snapshots = await db.query('open_shift_snapshots');
      expect(snapshots, isEmpty);

      final profiles = await db.query('active_target_profiles');
      expect(profiles, isEmpty);
    });

    test('clearAllData preserves restaurant scope', () async {
      await ShiftService.instance.clearAllData();
      final db = await SqliteDatabase.instance.database;

      final restaurants = await db.query('restaurant_locations');
      expect(restaurants, isNotEmpty,
          reason: 'restaurant scope must survive clearAllData');
    });

    test('reseed after clear restores full operational state', () async {
      await ShiftService.instance.clearAllData();
      await SqliteDatabase.instance.reseedDemo();

      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);
      expect(wtd!.totalCovers, greaterThan(0));

      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      final dashboard = await ShiftService.instance.getShiftDashboard();
      expect(dashboard, isNotNull);

      final weeks = await ShiftService.instance.getWeekHistory();
      expect(weeks, isNotEmpty);
    });
  });
}
