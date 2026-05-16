// Phase 7.55f.1 — business_date foundation tests.
//
// Validates:
// A. ShiftRecord serializes/deserializes businessDate
// B. MockIntegrationReplaySeed ShiftRecords have non-null ISO businessDate
// C. SQLite seed carries business_date on shift_records
// D. DAO date-range query is inclusive, closed-only, restaurant-scoped
// E. ShiftService close path persists businessDate from ClosedShiftInput

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/shift_record_dao.dart';

void main() {
  // ── A. ShiftRecord businessDate serialization ───────────────────────────

  group('A — ShiftRecord businessDate serialization', () {
    test('toMap includes business_date when set', () {
      final record = ShiftRecord(
        weekId: '2026-W13',
        dayLabel: 'Mon',
        daypart: 'lunch',
        status: 'closed',
        businessDate: '2026-03-23',
        covers: 100,
        forecastCovers: 110,
        ppa: 41.50,
        cplh: 4.58,
        splh: 180.0,
        fohHours: 22,
        bohHours: 23,
        primaryLever: 'ON_MODEL',
      );

      final map = record.toMap();
      expect(map['business_date'], '2026-03-23');
    });

    test('toMap includes null business_date when not set', () {
      final record = ShiftRecord(
        weekId: '2026-W13',
        dayLabel: 'Mon',
        daypart: 'lunch',
        status: 'closed',
        covers: 100,
        forecastCovers: 110,
        ppa: 41.50,
        cplh: 4.58,
        splh: 180.0,
        fohHours: 22,
        bohHours: 23,
        primaryLever: 'ON_MODEL',
      );

      final map = record.toMap();
      expect(map.containsKey('business_date'), isTrue);
      expect(map['business_date'], isNull);
    });

    test('fromMap deserializes business_date', () {
      final map = <String, dynamic>{
        'week_id': '2026-W13',
        'day_label': 'Mon',
        'daypart': 'lunch',
        'status': 'closed',
        'business_date': '2026-03-23',
        'covers': 100,
        'forecast_covers': 110,
        'ppa': 41.50,
        'cplh': 4.58,
        'splh': 180.0,
        'foh_hours': 22,
        'boh_hours': 23,
        'theoretical_labor_pct': 20.48,
        'primary_lever': 'ON_MODEL',
      };

      final record = ShiftRecord.fromMap(map);
      expect(record.businessDate, '2026-03-23');
    });

    test('fromMap handles null business_date gracefully', () {
      final map = <String, dynamic>{
        'week_id': '2026-W13',
        'day_label': 'Mon',
        'daypart': 'lunch',
        'status': 'closed',
        'business_date': null,
        'covers': 100,
        'forecast_covers': 110,
        'ppa': 41.50,
        'cplh': 4.58,
        'splh': 180.0,
        'foh_hours': 22,
        'boh_hours': 23,
        'theoretical_labor_pct': 20.48,
        'primary_lever': 'ON_MODEL',
      };

      final record = ShiftRecord.fromMap(map);
      expect(record.businessDate, isNull);
    });

    test('withLockedTargetDefaults preserves businessDate', () {
      final record = ShiftRecord(
        weekId: '2026-W13',
        dayLabel: 'Mon',
        daypart: 'lunch',
        status: 'closed',
        businessDate: '2026-03-23',
        covers: 100,
        forecastCovers: 110,
        ppa: 41.50,
        cplh: 4.58,
        splh: 180.0,
        fohHours: 22,
        bohHours: 23,
        primaryLever: 'ON_MODEL',
      );

      final filled = record.withLockedTargetDefaults(
        defaultTargetCPLH: 4.58,
        defaultTargetSPLH: 180.0,
        defaultTargetPPA: 41.50,
        defaultFohWage: 16.50,
        defaultBohWage: 21.35,
        defaultOpzFloorCPLH: 3.50,
        defaultOpzCeilingCPLH: 5.80,
        defaultTheoreticalFohLaborPct: 8.63,
        defaultTheoreticalBohLaborPct: 11.86,
      );

      expect(filled.businessDate, '2026-03-23');
    });
  });

  // ── B. MockIntegrationReplaySeed ShiftRecords have businessDate ─────────

  group('B — mock replay ShiftRecords carry businessDate', () {
    test('all historical closed shifts have non-null ISO businessDate', () {
      final shifts = MockIntegrationReplaySeed.output.historicalClosedShifts;
      expect(shifts, isNotEmpty);

      for (final s in shifts) {
        expect(s.businessDate, isNotNull,
            reason: '${s.weekId}/${s.dayLabel}/${s.daypart} should have businessDate');
        expect(s.businessDate, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
            reason: '${s.weekId}/${s.dayLabel}/${s.daypart} businessDate should be ISO format');
      }
    });

    test('all current week shifts have non-null ISO businessDate', () {
      final shifts = MockIntegrationReplaySeed.output.currentWeekShifts;
      expect(shifts, isNotEmpty);

      for (final s in shifts) {
        expect(s.businessDate, isNotNull,
            reason: '${s.weekId}/${s.dayLabel}/${s.daypart} should have businessDate');
        expect(s.businessDate, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
            reason: '${s.weekId}/${s.dayLabel}/${s.daypart} businessDate should be ISO format');
      }
    });

    test('businessDate is consistent with weekId and dayLabel', () {
      // Spot-check: W13 Mon should be 2026-03-23
      final monLunch = MockIntegrationReplaySeed.output.currentWeekShifts
          .firstWhere((s) => s.dayLabel == 'Mon' && s.daypart == 'lunch');
      expect(monLunch.businessDate, '2026-03-23');

      // W13 Fri should be 2026-03-27
      final friDinner = MockIntegrationReplaySeed.output.currentWeekShifts
          .firstWhere((s) => s.dayLabel == 'Fri' && s.daypart == 'dinner');
      expect(friDinner.businessDate, '2026-03-27');

      // W13 Sun should be 2026-03-29
      final sunDinner = MockIntegrationReplaySeed.output.currentWeekShifts
          .firstWhere((s) => s.dayLabel == 'Sun' && s.daypart == 'dinner');
      expect(sunDinner.businessDate, '2026-03-29');
    });
  });

  // ── C. SQLite seed carries business_date ────────────────────────────────

  group('C — SQLite seed shift_records carry business_date', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('all seeded shift_records have non-null business_date', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('shift_records');
      expect(rows, isNotEmpty);

      for (final row in rows) {
        final bd = row['business_date'] as String?;
        expect(bd, isNotNull,
            reason: '${row['week_id']}/${row['day_label']}/${row['daypart']} should have business_date');
        expect(bd, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
            reason: '${row['week_id']}/${row['day_label']}/${row['daypart']} business_date should be ISO');
      }
    });

    test('business_date column exists in schema', () async {
      final db = await SqliteDatabase.instance.database;
      final cols = await db.rawQuery('PRAGMA table_info(shift_records)');
      final colNames = cols.map((c) => c['name'] as String).toSet();
      expect(colNames.contains('business_date'), isTrue);
    });
  });

  // ── D. DAO date-range query ─────────────────────────────────────────────

  group('D — date-range query behavior', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('getClosedShiftsInDateRange is inclusive on both ends', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = ShiftRecordDao(db);

      // W13 Mon = 2026-03-23, query exactly one day
      final results = await dao.getClosedShiftsInDateRange(
        'demo_restaurant_001', '2026-03-23', '2026-03-23',
      );

      // Should get all closed shifts for Monday (lunch + dinner)
      expect(results, isNotEmpty);
      for (final r in results) {
        expect(r.businessDate, '2026-03-23');
        expect(r.status, 'closed');
      }
    });

    test('getClosedShiftsInDateRange returns only closed shifts', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = ShiftRecordDao(db);

      // Wide range covering projected shifts too
      final results = await dao.getClosedShiftsInDateRange(
        'demo_restaurant_001', '2026-03-23', '2026-03-29',
      );

      for (final r in results) {
        expect(r.status, 'closed',
            reason: 'date-range query must return only closed shifts');
      }
    });

    test('getClosedShiftsInDateRange is restaurant-scoped', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = ShiftRecordDao(db);

      // Non-existent restaurant should return empty
      final results = await dao.getClosedShiftsInDateRange(
        'nonexistent_restaurant', '2026-01-01', '2026-12-31',
      );

      expect(results, isEmpty);
    });

    test('getClosedShiftsInDateRange excludes out-of-range rows', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = ShiftRecordDao(db);

      // Query a range that has no shifts (far future)
      final results = await dao.getClosedShiftsInDateRange(
        'demo_restaurant_001', '2027-01-01', '2027-12-31',
      );

      expect(results, isEmpty);
    });

    test('getClosedShiftsInDateRange ordered by business_date DESC', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = ShiftRecordDao(db);

      // Multi-day range
      final results = await dao.getClosedShiftsInDateRange(
        'demo_restaurant_001', '2026-01-26', '2026-03-27',
      );

      expect(results.length, greaterThan(1));

      // Verify descending date order
      for (int i = 1; i < results.length; i++) {
        final prevDate = results[i - 1].businessDate!;
        final currDate = results[i].businessDate!;
        expect(prevDate.compareTo(currDate), greaterThanOrEqualTo(0),
            reason: 'results should be ordered by business_date DESC');
      }
    });

    test('full 60-day range returns expected historical shifts', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = ShiftRecordDao(db);

      // Demo-data Slice B raised history 8 → 12 weeks; this window
      // (2026-01-01 .. 2026-03-27) still covers well over 8 weeks ×
      // 14 shifts of closed history plus the current week's closed days.
      final results = await dao.getClosedShiftsInDateRange(
        'demo_restaurant_001', '2026-01-01', '2026-03-27',
      );

      // At minimum we should get all historical weeks' closed shifts
      expect(results.length, greaterThanOrEqualTo(112));
      // All should be closed
      expect(results.every((r) => r.isClosed), isTrue);
    });
  });

  // ── E. ShiftService close path persists businessDate ────────────────────

  group('E — ShiftRecord carries businessDate through close path', () {
    test('ShiftRecord round-trips businessDate through toMap/fromMap', () {
      final record = ShiftRecord(
        weekId: '2026-W13',
        dayLabel: 'Fri',
        daypart: 'dinner',
        status: 'closed',
        businessDate: '2026-03-27',
        covers: 88,
        forecastCovers: 95,
        ppa: 43.00,
        cplh: 4.40,
        splh: 185.0,
        fohHours: 20,
        bohHours: 21,
        primaryLever: 'ON_MODEL',
        sourceSystem: 'test',
      );

      final map = record.toMap();
      final restored = ShiftRecord.fromMap(map);

      expect(restored.businessDate, '2026-03-27');
      expect(restored.weekId, '2026-W13');
      expect(restored.dayLabel, 'Fri');
      expect(restored.daypart, 'dinner');
    });
  });

  // ── F. V12 backfill malformed-row hardening ─────────────────────────────

  group('F — V12 backfill leaves malformed rows null', () {
    test('valid weekId + dayLabel backfills correctly', () async {
      final db = await SqliteDatabase.instance.database;

      // Insert a row with valid week/day but null business_date
      await db.insert('shift_records', {
        'restaurant_id': 'demo_restaurant_001',
        'week_id': '2026-W13',
        'day_label': 'Fri',
        'daypart': 'dinner',
        'status': 'closed',
        'business_date': null,
        'covers': 80,
        'forecast_covers': 90,
        'ppa': 41.50,
        'cplh': 4.58,
        'splh': 180.0,
        'blended_wage': 18.0,
        'foh_hours': 17,
        'boh_hours': 18,
        'foh_labor_pct': 8.0,
        'boh_labor_pct': 12.0,
        'total_labor_pct': 20.0,
        'theoretical_labor_pct': 20.48,
        'variance_pts': -0.48,
        'primary_lever': 'ON_MODEL',
      });

      await SqliteDatabase.instance.migrateToV12ForTest(db);

      final rows = await db.rawQuery(
        "SELECT business_date FROM shift_records "
        "WHERE week_id = '2026-W13' AND day_label = 'Fri' AND daypart = 'dinner' "
        "AND business_date IS NOT NULL",
      );
      // At least one row should have the backfilled date
      final backfilled = rows.where((r) => r['business_date'] == '2026-03-27');
      expect(backfilled, isNotEmpty,
          reason: 'valid 2026-W13 + Fri should backfill to 2026-03-27');
    });

    test('malformed weekId row remains business_date null', () async {
      final db = await SqliteDatabase.instance.database;

      // Insert a row with a malformed weekId
      await db.insert('shift_records', {
        'restaurant_id': 'demo_restaurant_001',
        'week_id': 'garbage_week',
        'day_label': 'Mon',
        'daypart': 'lunch',
        'status': 'closed',
        'business_date': null,
        'covers': 50,
        'forecast_covers': 55,
        'ppa': 40.0,
        'cplh': 4.0,
        'splh': 170.0,
        'blended_wage': 17.0,
        'foh_hours': 12,
        'boh_hours': 13,
        'foh_labor_pct': 8.0,
        'boh_labor_pct': 12.0,
        'total_labor_pct': 20.0,
        'theoretical_labor_pct': 20.48,
        'variance_pts': -0.48,
        'primary_lever': 'ON_MODEL',
      });

      await SqliteDatabase.instance.migrateToV12ForTest(db);

      final rows = await db.rawQuery(
        "SELECT business_date FROM shift_records WHERE week_id = 'garbage_week'",
      );
      expect(rows.length, 1);
      expect(rows.first['business_date'], isNull,
          reason: 'malformed weekId should remain business_date null');
    });

    test('unknown dayLabel row remains business_date null', () async {
      final db = await SqliteDatabase.instance.database;

      // Insert a row with an unknown dayLabel
      await db.insert('shift_records', {
        'restaurant_id': 'demo_restaurant_001',
        'week_id': '2026-W13',
        'day_label': 'Xyz',
        'daypart': 'lunch',
        'status': 'closed',
        'business_date': null,
        'covers': 50,
        'forecast_covers': 55,
        'ppa': 40.0,
        'cplh': 4.0,
        'splh': 170.0,
        'blended_wage': 17.0,
        'foh_hours': 12,
        'boh_hours': 13,
        'foh_labor_pct': 8.0,
        'boh_labor_pct': 12.0,
        'total_labor_pct': 20.0,
        'theoretical_labor_pct': 20.48,
        'variance_pts': -0.48,
        'primary_lever': 'ON_MODEL',
      });

      await SqliteDatabase.instance.migrateToV12ForTest(db);

      final rows = await db.rawQuery(
        "SELECT business_date FROM shift_records WHERE day_label = 'Xyz'",
      );
      expect(rows.length, 1);
      expect(rows.first['business_date'], isNull,
          reason: 'unknown dayLabel should remain business_date null');
    });

    test('date-range query excludes null business_date rows', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = ShiftRecordDao(db);

      // Insert a malformed row that will stay null
      await db.insert('shift_records', {
        'restaurant_id': 'demo_restaurant_001',
        'week_id': 'not-a-week',
        'day_label': 'Mon',
        'daypart': 'lunch',
        'status': 'closed',
        'business_date': null,
        'covers': 50,
        'forecast_covers': 55,
        'ppa': 40.0,
        'cplh': 4.0,
        'splh': 170.0,
        'blended_wage': 17.0,
        'foh_hours': 12,
        'boh_hours': 13,
        'foh_labor_pct': 8.0,
        'boh_labor_pct': 12.0,
        'total_labor_pct': 20.0,
        'theoretical_labor_pct': 20.48,
        'variance_pts': -0.48,
        'primary_lever': 'ON_MODEL',
      });

      // Wide range that would include everything
      final results = await dao.getClosedShiftsInDateRange(
        'demo_restaurant_001', '1900-01-01', '2099-12-31',
      );

      // None of the returned rows should have null businessDate
      for (final r in results) {
        expect(r.businessDate, isNotNull,
            reason: 'date-range query must exclude null business_date rows');
      }
      // Confirm the null row is NOT in the results
      expect(results.where((r) => r.weekId == 'not-a-week'), isEmpty,
          reason: 'malformed row with null business_date must be excluded');
    });

    test('no row ever gets 1970-01-01 sentinel value', () async {
      final db = await SqliteDatabase.instance.database;

      // Insert rows with various malformed week/day combos
      for (final combo in [
        {'week_id': 'bad', 'day_label': 'Mon'},
        {'week_id': '2026-W13', 'day_label': 'Holiday'},
        {'week_id': '', 'day_label': ''},
        {'week_id': 'W13', 'day_label': 'Fri'},
      ]) {
        await db.insert('shift_records', {
          'restaurant_id': 'demo_restaurant_001',
          'week_id': combo['week_id'],
          'day_label': combo['day_label'],
          'daypart': 'lunch',
          'status': 'closed',
          'business_date': null,
          'covers': 50,
          'forecast_covers': 55,
          'ppa': 40.0,
          'cplh': 4.0,
          'splh': 170.0,
          'blended_wage': 17.0,
          'foh_hours': 12,
          'boh_hours': 13,
          'foh_labor_pct': 8.0,
          'boh_labor_pct': 12.0,
          'total_labor_pct': 20.0,
          'theoretical_labor_pct': 20.48,
          'variance_pts': -0.48,
          'primary_lever': 'ON_MODEL',
        });
      }

      await SqliteDatabase.instance.migrateToV12ForTest(db);

      final sentinelRows = await db.rawQuery(
        "SELECT * FROM shift_records WHERE business_date = '1970-01-01'",
      );
      expect(sentinelRows, isEmpty,
          reason: 'no row should ever get the 1970-01-01 sentinel value');
    });

    test('non-strict single-digit week ids remain business_date null', () async {
      final db = await SqliteDatabase.instance.database;

      for (final weekId in ['2026-W1', '2026-W5', '2026-W9']) {
        await db.insert('shift_records', {
          'restaurant_id': 'demo_restaurant_001',
          'week_id': weekId,
          'day_label': 'Mon',
          'daypart': 'lunch',
          'status': 'closed',
          'business_date': null,
          'covers': 50,
          'forecast_covers': 55,
          'ppa': 40.0,
          'cplh': 4.0,
          'splh': 170.0,
          'blended_wage': 17.0,
          'foh_hours': 12,
          'boh_hours': 13,
          'foh_labor_pct': 8.0,
          'boh_labor_pct': 12.0,
          'total_labor_pct': 20.0,
          'theoretical_labor_pct': 20.48,
          'variance_pts': -0.48,
          'primary_lever': 'ON_MODEL',
        });
      }

      await SqliteDatabase.instance.migrateToV12ForTest(db);

      for (final weekId in ['2026-W1', '2026-W5', '2026-W9']) {
        final rows = await db.rawQuery(
          'SELECT business_date FROM shift_records WHERE week_id = ?',
          [weekId],
        );
        expect(rows.length, 1);
        expect(rows.first['business_date'], isNull,
            reason: '$weekId is non-strict — should remain business_date null');
      }
    });

    test('no seeded shift_record has 1970-01-01 as business_date', () async {
      await SqliteDatabase.instance.reseedDemo();
      final db = await SqliteDatabase.instance.database;

      final sentinelRows = await db.rawQuery(
        "SELECT * FROM shift_records WHERE business_date = '1970-01-01'",
      );
      expect(sentinelRows, isEmpty,
          reason: 'no seeded shift_record should have 1970-01-01');
    });
  });

  // ── G. getLatestClosedBusinessDate DAO query ───────────────────────────────

  group('G — getLatestClosedBusinessDate', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('returns latest non-null business_date among closed shifts', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = ShiftRecordDao(db);

      final latest =
          await dao.getLatestClosedBusinessDate('demo_restaurant_001');
      expect(latest, isNotNull);
      // Should be a valid ISO date string
      expect(latest, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('returns null when no closed shifts exist for restaurant', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = ShiftRecordDao(db);

      final latest =
          await dao.getLatestClosedBusinessDate('nonexistent_restaurant');
      expect(latest, isNull);
    });

    test('ignores projected shifts and null business_date rows', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = ShiftRecordDao(db);

      // Insert a projected shift with a later date
      await db.insert('shift_records', {
        'restaurant_id': 'demo_restaurant_001',
        'week_id': '2026-W20',
        'day_label': 'Mon',
        'daypart': 'lunch',
        'status': 'projected',
        'business_date': '2026-05-11',
        'covers': 100,
        'forecast_covers': 100,
        'ppa': 40.0,
        'cplh': 4.0,
        'splh': 170.0,
        'blended_wage': 17.0,
        'foh_hours': 25,
        'boh_hours': 10,
        'foh_labor_pct': 8.0,
        'boh_labor_pct': 12.0,
        'total_labor_pct': 20.0,
        'theoretical_labor_pct': 20.48,
        'variance_pts': -0.48,
        'primary_lever': 'ON_MODEL',
      });

      final latest =
          await dao.getLatestClosedBusinessDate('demo_restaurant_001');
      // Should not return '2026-05-11' because that's a projected shift
      expect(latest, isNot('2026-05-11'));
    });
  });
}
