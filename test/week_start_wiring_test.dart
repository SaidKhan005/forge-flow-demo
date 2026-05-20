// Phase 7.55n.4 + 7.55n.4a — Week-start wiring focused tests.
//
// Validates:
// A. WeeklyPlanSnapshotService reads configured weekStartDay
// B. Sunday-start snapshot has correct week span and key
// C. Snapshot day rows align with configured week start
// D. Monday default holds when timing config is unavailable
// E. _buildDayRows rotation produces correct label-to-date alignment
// F. Locked WTD business-date-based accumulation
// G. Locked WTD loads closed shifts by snapshot date span (7.55n.4a)
// H. closedDayNumber reflects configured week-start position (7.55n.4a)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/services/shift_service.dart';
import 'package:forge_and_flow/services/weekly_plan_snapshot_service.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_policy.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_record.dart';

import '_test_helpers/sqlite_demo_helpers.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = demoRestaurantId;
  // Default seeded business date: 2026-03-27 (Friday).
  const businessDate = '2026-03-27';

  setUp(() async {
    await setUpSqliteDemo();
    // reseedDemo does not reset restaurant_timing_configs (uses
    // ConflictAlgorithm.ignore). Restore the Monday-default demo config
    // explicitly so each test starts clean.
    final db = await SqliteDatabase.instance.database;
    await db.delete('restaurant_timing_configs');
    final now = DateTime.now().toUtc().toIso8601String();
    // Per-Daypart V1 Slice 1.5: `shift_close_authority` /
    // `local_close_fallback` dropped from this row.
    await db.insert('restaurant_timing_configs', {
      'restaurant_id': restaurantId,
      'business_day_start_local_time': '04:00',
      'week_start_day': DateTime.monday,
      'service_period_definitions_json': jsonEncode([
        {'id': 'lunch', 'label': 'Lunch', 'short_label': 'L', 'sort_order': 1, 'start_local_time': '11:00', 'end_local_time': '15:00', 'rolls_past_midnight': false, 'applicable_days': [1, 2, 3, 4, 5]},
        {'id': 'dinner', 'label': 'Dinner', 'short_label': 'D', 'sort_order': 2, 'start_local_time': '17:00', 'end_local_time': '23:00', 'rolls_past_midnight': false, 'applicable_days': [1, 2, 3, 4, 5, 6, 7]},
        {'id': 'late_night', 'label': 'Late Night', 'short_label': 'LN', 'sort_order': 3, 'start_local_time': '23:00', 'end_local_time': '02:00', 'rolls_past_midnight': true, 'applicable_days': [5, 6]},
      ]),
      'created_at': now,
      'updated_at': now,
    });
    SqliteRestaurantTimingConfigRepository.instance.resetDao();
  });

  // ── A: Configured weekStartDay is read by snapshot service ─────────────

  group('A — configured weekStartDay used by snapshot service', () {
    test('demo config defaults to Monday; snapshot uses Monday boundaries',
        () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      // 2026-03-27 (Friday) in a Monday-start week → Mon 2026-03-23
      final expectedStart = WeeklyPlanSnapshotPolicy.weekStartForDate(
          businessDate, weekStartDay: DateTime.monday);
      final expectedEnd = WeeklyPlanSnapshotPolicy.weekEndForDate(
          businessDate, weekStartDay: DateTime.monday);

      expect(snapshot!.weekStartDate, expectedStart);
      expect(snapshot.weekEndDate, expectedEnd);
    });

    test(
        'Sunday config produces Sunday-aligned snapshot after clearing old snapshot',
        () async {
      // Change timing config to Sunday week start.
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig(restaurantId);
      expect(config, isNotNull);

      final sundayConfig = RestaurantTimingConfig(
        restaurantId: restaurantId,
        businessTimezone: config!.businessTimezone,
        businessDayStartLocalTime: config.businessDayStartLocalTime,
        weekStartDay: DateTime.sunday,
        servicePeriodDefinitions: config.servicePeriodDefinitions,
        createdAt: config.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repo.saveTimingConfig(sundayConfig);
      repo.resetDao();

      // Clear any existing snapshot so the service generates a fresh one.
      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');

      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      // 2026-03-27 (Friday) in a Sunday-start week → Sun 2026-03-22
      final expectedStart = WeeklyPlanSnapshotPolicy.weekStartForDate(
          businessDate, weekStartDay: DateTime.sunday);
      final expectedEnd = WeeklyPlanSnapshotPolicy.weekEndForDate(
          businessDate, weekStartDay: DateTime.sunday);

      expect(snapshot!.weekStartDate, expectedStart);
      expect(snapshot.weekEndDate, expectedEnd);
    });
  });

  // ── B: Snapshot week key uses configured week start ────────────────────

  group('B — snapshot week key uses configured week start', () {
    test('Sunday-start snapshot has different weekKey than Monday-start',
        () async {
      // Generate Monday-start snapshot.
      final mondaySnapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(mondaySnapshot, isNotNull);
      final mondayKey = mondaySnapshot!.weekKey;

      // Switch to Sunday start and regenerate.
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig(restaurantId);
      final sundayConfig = RestaurantTimingConfig(
        restaurantId: restaurantId,
        businessTimezone: config!.businessTimezone,
        businessDayStartLocalTime: config.businessDayStartLocalTime,
        weekStartDay: DateTime.sunday,
        servicePeriodDefinitions: config.servicePeriodDefinitions,
        createdAt: config.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repo.saveTimingConfig(sundayConfig);
      repo.resetDao();

      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');

      final sundaySnapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(sundaySnapshot, isNotNull);
      final sundayKey = sundaySnapshot!.weekKey;

      // Different week start → different week key.
      expect(sundayKey, isNot(mondayKey));
    });
  });

  // ── C: Snapshot day rows align with configured week start ──────────────

  group('C — snapshot day rows alignment', () {
    test('Monday-start snapshot day rows start with Monday', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      expect(snapshot!.dayRows.isNotEmpty, isTrue);

      // First day row should be Monday ('Mon') for the Monday-start demo.
      expect(snapshot.dayRows.first.day, 'Mon');
      expect(snapshot.dayRows.first.businessDate, snapshot.weekStartDate);
    });

    test('Sunday-start snapshot day rows start with Sunday', () async {
      // Switch to Sunday start.
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig(restaurantId);
      final sundayConfig = RestaurantTimingConfig(
        restaurantId: restaurantId,
        businessTimezone: config!.businessTimezone,
        businessDayStartLocalTime: config.businessDayStartLocalTime,
        weekStartDay: DateTime.sunday,
        servicePeriodDefinitions: config.servicePeriodDefinitions,
        createdAt: config.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repo.saveTimingConfig(sundayConfig);
      repo.resetDao();

      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');

      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      expect(snapshot!.dayRows.isNotEmpty, isTrue);

      // First day row should be Sunday ('Sun') for Sunday-start.
      expect(snapshot.dayRows.first.day, 'Sun');
      expect(snapshot.dayRows.first.businessDate, snapshot.weekStartDate);

      // Last day row should be Saturday ('Sat').
      expect(snapshot.dayRows.last.day, 'Sat');
    });

    test('day row business dates are sequential from week start', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      expect(snapshot!.dayRows.length, 7);

      for (var i = 1; i < snapshot.dayRows.length; i++) {
        final prev = snapshot.dayRows[i - 1].businessDate;
        final curr = snapshot.dayRows[i].businessDate;
        expect(curr.compareTo(prev), greaterThan(0),
            reason: 'day $i should have a later date than day ${i - 1}');
      }
    });
  });

  // ── D: Monday default when timing config is unavailable ────────────────

  group('D — Monday default fallback', () {
    test('snapshot uses Monday when timing config is deleted', () async {
      // Delete the timing config row.
      final db = await SqliteDatabase.instance.database;
      await db.delete('restaurant_timing_configs');
      SqliteRestaurantTimingConfigRepository.instance.resetDao();

      // Also clear any existing snapshot.
      await db.delete('weekly_plan_snapshots');

      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      // Should fall back to Monday-start.
      final expectedStart = WeeklyPlanSnapshotPolicy.weekStartForDate(
          businessDate, weekStartDay: DateTime.monday);
      expect(snapshot!.weekStartDate, expectedStart);
      expect(snapshot.dayRows.first.day, 'Mon');
    });
  });

  // ── E: _buildDayRows rotation produces correct alignment ──────────────

  group('E — _buildDayRows rotation', () {
    test('rotation preserves total forecast covers across all day rows',
        () async {
      // Per-Daypart V1 (bottom-up locked snapshot): both the runtime
      // lock path AND the demo seed now reconcile bottom-up through the
      // SHARED `WeeklyPlanSnapshotBottomUpReconciler`, but they build
      // their per-period rows from two different (untouched) builders
      // (`_buildDayDaypartRowsForLock` vs `_buildSeedDayDaypartRows`),
      // whose largest-remainder cover allocation totals differ slightly.
      // This test's intent is rotation invariance (Mon-start vs
      // Sun-start should yield the same week total), so BOTH snapshots
      // must come from the SAME generator. Drop the seeded snapshot up
      // front so the Monday read is runtime-generated too — otherwise
      // we'd be comparing seed-reconciled vs runtime-reconciled, which
      // is a different (out-of-scope) cross-path fidelity question.
      final db0 = await SqliteDatabase.instance.database;
      await db0.delete('weekly_plan_snapshots');

      // Generate snapshot with Monday start (runtime path).
      final mondaySnap =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(mondaySnap, isNotNull);
      final mondayTotal = mondaySnap!.dayRows
          .fold<int>(0, (s, d) => s + d.forecastCovers);

      // Switch to Sunday start and regenerate.
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig(restaurantId);
      final sundayConfig = RestaurantTimingConfig(
        restaurantId: restaurantId,
        businessTimezone: config!.businessTimezone,
        businessDayStartLocalTime: config.businessDayStartLocalTime,
        weekStartDay: DateTime.sunday,
        servicePeriodDefinitions: config.servicePeriodDefinitions,
        createdAt: config.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repo.saveTimingConfig(sundayConfig);
      repo.resetDao();

      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');

      final sundaySnap =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(sundaySnap, isNotNull);
      final sundayTotal = sundaySnap!.dayRows
          .fold<int>(0, (s, d) => s + d.forecastCovers);

      // Total forecast covers should be the same regardless of week start
      // (same day weights, same demand context, just rotated).
      expect(sundayTotal, mondayTotal);
    });
  });

  // ── F: Seeded demo behavior unchanged under Monday config ─────────────

  group('F — demo behavior unchanged', () {
    test('existing snapshot service tests still hold with Monday default',
        () async {
      // This is a smoke test: under the default Monday config, snapshot
      // generation should behave identically to pre-7.55n.4 behavior.
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      // Monday-start week for 2026-03-27 is 2026-03-23 to 2026-03-29.
      expect(snapshot!.weekStartDate, '2026-03-23');
      expect(snapshot.weekEndDate, '2026-03-29');
      expect(snapshot.weekKey, '2026-03-23_2026-03-29');
      expect(snapshot.dayRows.length, 7);
      expect(snapshot.dayRows.first.day, 'Mon');
      expect(snapshot.dayRows.first.businessDate, '2026-03-23');
      expect(snapshot.dayRows.last.day, 'Sun');
      expect(snapshot.dayRows.last.businessDate, '2026-03-29');
    });

    test('second call returns same locked snapshot', () async {
      final first =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      final second =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(second!.snapshotId, first!.snapshotId);
    });
  });

  // ── G: Locked WTD loads closed shifts by snapshot date span (7.55n.4a) ──

  group('G — locked WTD uses snapshot date span', () {
    test('Monday-default locked WTD returns non-null from seeded data',
        () async {
      // Under Monday default, the locked path should produce WTD from
      // the snapshot date span (2026-03-23 through 2026-03-29).
      final weekData = await ShiftService.instance.getLiveWeekToDate();
      expect(weekData, isNotNull);
      expect(weekData!.shiftsCompleted, greaterThan(0));
      expect(weekData.totalCovers, greaterThan(0));
    });

    test('Monday-default locked WTD closedDayNumber matches demo behavior',
        () async {
      // Under Monday default, closedDayNumber should match the position
      // of the latest finalized business date inside the Mon–Sun week.
      final weekData = await ShiftService.instance.getLiveWeekToDate();
      expect(weekData, isNotNull);

      // Seeded demo has closed shifts through Friday (2026-03-27).
      // The operational business date is also 2026-03-27 (Friday).
      // Under appLocalCutoffFallback (7.55n.5), same-business-date
      // closed rows are excluded from finalized truth.
      // So the last finalized date is Thursday (2026-03-26) = Day 4.
      expect(weekData!.closedDayNumber, 4);
      expect(weekData.lastClosedDay, 'Thursday');
    });

    test('Sunday-start locked WTD reports closedDayNumber == 1 for first day',
        () async {
      // Switch to Sunday start.
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig(restaurantId);
      final sundayConfig = RestaurantTimingConfig(
        restaurantId: restaurantId,
        businessTimezone: config!.businessTimezone,
        businessDayStartLocalTime: config.businessDayStartLocalTime,
        weekStartDay: DateTime.sunday,
        servicePeriodDefinitions: config.servicePeriodDefinitions,
        createdAt: config.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repo.saveTimingConfig(sundayConfig);
      repo.resetDao();

      // Clear existing snapshots and shift records so the service
      // generates a fresh Sunday-start snapshot with only test shifts.
      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');
      await db.delete('shift_records');

      // Insert a single closed shift on Sunday 2026-03-22 (the first
      // day of the Sunday-start week containing 2026-03-27).
      final sundayWeekStart = WeeklyPlanSnapshotPolicy.weekStartForDate(
          businessDate, weekStartDay: DateTime.sunday);
      expect(sundayWeekStart, '2026-03-22'); // Sunday

      final sunRecord = ShiftRecord(
        restaurantId: restaurantId,
        status: 'closed',
        weekId: '2026-W12',
        dayLabel: 'Sun',
        daypart: 'dinner',
        businessDate: '2026-03-22',
        covers: 80,
        forecastCovers: 90,
        ppa: 25.0,
        cplh: 20.0,
        splh: 60.0,
        fohHours: 4,
        bohHours: 3,
        theoreticalLaborPct: 28.0,
        primaryLever: 'CPLH',
        scheduledFohHours: 5,
        scheduledBohHours: 4,
        storedFohLaborDollar: 60.0,
        storedBohLaborDollar: 45.0,
        targetProfileId: 'tp_demo',
        targetProfileVersionId: 'tpv_demo',
        targetSourceType: 'benchmark_recommended',
        targetCPLH: 22.0,
        targetSPLH: 65.0,
        targetPPA: 26.0,
        targetFohWage: 15.0,
        targetBohWage: 14.0,
        opzFloorCPLH: 18.0,
        opzCeilingCPLH: 30.0,
        theoreticalFohLaborPct: 16.0,
        theoreticalBohLaborPct: 12.0,
        sourceSystem: 'mock_replay',
        sourceShiftId: 'test_sun_locked_wtd',
      );
      await db.insert('shift_records', sunRecord.toMap()..remove('id'));

      // The locked WTD should find this Sunday shift via date-range
      // query and report it as Day 1 of 7 (not Day 7).
      final weekData = await ShiftService.instance.getLiveWeekToDate();
      expect(weekData, isNotNull);
      expect(weekData!.closedDayNumber, 1,
          reason: 'Sunday is Day 1 in a Sunday-start week');
      expect(weekData.lastClosedDay, 'Sunday');
    });

    test('Sunday-start locked WTD includes shift from snapshot date span',
        () async {
      // Switch to Sunday start and insert a shift on Sunday 2026-03-22.
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig(restaurantId);
      final sundayConfig = RestaurantTimingConfig(
        restaurantId: restaurantId,
        businessTimezone: config!.businessTimezone,
        businessDayStartLocalTime: config.businessDayStartLocalTime,
        weekStartDay: DateTime.sunday,
        servicePeriodDefinitions: config.servicePeriodDefinitions,
        createdAt: config.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repo.saveTimingConfig(sundayConfig);
      repo.resetDao();

      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');
      await db.delete('shift_records');

      // Insert closed shifts on Sunday 2026-03-22 and Monday 2026-03-23.
      // These are both within the Sunday-start week (03-22 to 03-28).
      for (final entry in [
        {'date': '2026-03-22', 'day': 'Sun', 'id': 'test_g_sun'},
        {'date': '2026-03-23', 'day': 'Mon', 'id': 'test_g_mon'},
      ]) {
        final rec = ShiftRecord(
          restaurantId: restaurantId,
          status: 'closed',
          weekId: '2026-W12',
          dayLabel: entry['day']!,
          daypart: 'dinner',
          businessDate: entry['date'],
          covers: 80,
          forecastCovers: 90,
          ppa: 25.0,
          cplh: 20.0,
          splh: 60.0,
          fohHours: 4,
          bohHours: 3,
          theoreticalLaborPct: 28.0,
          primaryLever: 'CPLH',
          scheduledFohHours: 5,
          scheduledBohHours: 4,
          storedFohLaborDollar: 60.0,
          storedBohLaborDollar: 45.0,
          targetProfileId: 'tp_demo',
          targetProfileVersionId: 'tpv_demo',
          targetSourceType: 'benchmark_recommended',
          targetCPLH: 22.0,
          targetSPLH: 65.0,
          targetPPA: 26.0,
          targetFohWage: 15.0,
          targetBohWage: 14.0,
          opzFloorCPLH: 18.0,
          opzCeilingCPLH: 30.0,
          theoreticalFohLaborPct: 16.0,
          theoreticalBohLaborPct: 12.0,
          sourceSystem: 'mock_replay',
          sourceShiftId: entry['id'],
        );
        await db.insert('shift_records', rec.toMap()..remove('id'));
      }

      final weekData = await ShiftService.instance.getLiveWeekToDate();
      expect(weekData, isNotNull);

      // Both shifts should be included via date-range query.
      // Sunday is Day 1, Monday is Day 2 in Sunday-start week.
      expect(weekData!.closedDayNumber, 2,
          reason: 'Monday is Day 2 in a Sunday-start week');
      expect(weekData.lastClosedDay, 'Monday');
      // Both shifts' covers should be aggregated.
      expect(weekData.totalCovers, greaterThanOrEqualTo(160));
    });
  });

  // ── H: closedDayNumber reflects configured week-start position ──────────

  group('H — closedDayNumber configured position', () {
    test('Wednesday-start: first closed Wednesday is Day 1', () async {
      // Switch to Wednesday start.
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig(restaurantId);
      final wedConfig = RestaurantTimingConfig(
        restaurantId: restaurantId,
        businessTimezone: config!.businessTimezone,
        businessDayStartLocalTime: config.businessDayStartLocalTime,
        weekStartDay: DateTime.wednesday,
        servicePeriodDefinitions: config.servicePeriodDefinitions,
        createdAt: config.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repo.saveTimingConfig(wedConfig);
      repo.resetDao();

      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');
      await db.delete('shift_records');

      // Wednesday-start week for 2026-03-27 (Friday):
      // Wed 2026-03-25 through Tue 2026-03-31.
      final wedWeekStart = WeeklyPlanSnapshotPolicy.weekStartForDate(
          businessDate, weekStartDay: DateTime.wednesday);
      expect(wedWeekStart, '2026-03-25');

      // Insert a single closed shift on Wed 2026-03-25.
      final wedRecord = ShiftRecord(
        restaurantId: restaurantId,
        status: 'closed',
        weekId: '2026-W13',
        dayLabel: 'Wed',
        daypart: 'dinner',
        businessDate: '2026-03-25',
        covers: 70,
        forecastCovers: 80,
        ppa: 24.0,
        cplh: 19.0,
        splh: 58.0,
        fohHours: 4,
        bohHours: 3,
        theoreticalLaborPct: 27.0,
        primaryLever: 'CPLH',
        scheduledFohHours: 5,
        scheduledBohHours: 4,
        storedFohLaborDollar: 60.0,
        storedBohLaborDollar: 42.0,
        targetProfileId: 'tp_demo',
        targetProfileVersionId: 'tpv_demo',
        targetSourceType: 'benchmark_recommended',
        targetCPLH: 22.0,
        targetSPLH: 65.0,
        targetPPA: 26.0,
        targetFohWage: 15.0,
        targetBohWage: 14.0,
        opzFloorCPLH: 18.0,
        opzCeilingCPLH: 30.0,
        theoreticalFohLaborPct: 16.0,
        theoreticalBohLaborPct: 12.0,
        sourceSystem: 'mock_replay',
        sourceShiftId: 'test_h_wed',
      );
      await db.insert('shift_records', wedRecord.toMap()..remove('id'));

      final weekData = await ShiftService.instance.getLiveWeekToDate();
      expect(weekData, isNotNull);
      expect(weekData!.closedDayNumber, 1,
          reason: 'Wednesday is Day 1 in a Wednesday-start week');
      expect(weekData.lastClosedDay, 'Wednesday');
    });
  });
}
