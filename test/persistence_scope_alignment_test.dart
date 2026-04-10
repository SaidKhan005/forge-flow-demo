// Phase 7.5a â€” Persistence scope alignment tests.
//
// Validates:
// A. Schema contains new scope/import tables
// B. Default demo restaurant exists with correct values
// C. Seeded shift/week records carry restaurant scope
// D. Baseline selection round-trips through restaurant-scoped repository
// E. Import tracking persists fixture replay metadata
// F. Close-shift domain pipeline propagates non-default restaurant id
// G. v7 migration preserves existing data and backfills restaurant scope
// H. Real pre-v7 upgrade path preserves old rows and keys
// I. DatabaseHelper compatibility delegation works
// J. Fixture replay raw-import businessDate is a real date

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/data/database_helper.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/domain/services/shift_fact_builder.dart';
import 'package:forge_and_flow/domain/services/target_snapshot_builder.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_week_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_baseline_selection_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_import_tracking_repository.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  // â”€â”€ A: Schema contains new scope/import tables â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('A â€” schema tables exist', () {
    test('restaurant_locations table exists and is queryable', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('restaurant_locations');
      expect(rows, isNotEmpty);
    });

    test('connector_configs table exists and is queryable', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('connector_configs');
      // May be empty but must not throw
      expect(rows, isList);
    });

    test('import_runs table exists and is queryable', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('import_runs');
      expect(rows, isList);
    });

    test('raw_import_records table exists and is queryable', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('raw_import_records');
      expect(rows, isList);
    });

    test('sync_watermarks table exists and is queryable', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('sync_watermarks');
      expect(rows, isList);
    });
  });

  // â”€â”€ B: Default demo restaurant exists â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” demo restaurant scope', () {
    test('getOrCreateActiveRestaurant returns demo_restaurant_001', () async {
      final repo = SqliteRestaurantScopeRepository.instance;
      final restaurant = await repo.getOrCreateActiveRestaurant();
      expect(restaurant.restaurantId, 'demo_restaurant_001');
      expect(restaurant.displayName, 'Barrio Legado');
      expect(restaurant.businessTimezone, 'America/St_Johns');
    });

    test('getActiveRestaurantId returns demo_restaurant_001', () async {
      final repo = SqliteRestaurantScopeRepository.instance;
      final id = await repo.getActiveRestaurantId();
      expect(id, 'demo_restaurant_001');
    });
  });

  // â”€â”€ C: Seeded records are restaurant-scoped â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('C â€” seeded records carry restaurant scope', () {
    test('shift records have restaurantId == demo_restaurant_001', () async {
      final repo = SqliteShiftRecordRepository.instance;
      final shifts =
          await repo.getShiftsForWeek('demo_restaurant_001', '2026-W13');
      expect(shifts, isNotEmpty);
      for (final s in shifts) {
        expect(s.restaurantId, 'demo_restaurant_001');
      }
    });

    test('week records have restaurantId == demo_restaurant_001', () async {
      final repo = SqliteWeekRecordRepository.instance;
      final weeks = await repo.getWeekHistory('demo_restaurant_001');
      expect(weeks, isNotEmpty);
      for (final w in weeks) {
        expect(w.restaurantId, 'demo_restaurant_001');
      }
    });

    test('scoped query returns nothing for unknown restaurant', () async {
      final repo = SqliteShiftRecordRepository.instance;
      final shifts =
          await repo.getShiftsForWeek('unknown_restaurant', '2026-W13');
      expect(shifts, isEmpty);
    });
  });

  // â”€â”€ D: Baseline selection is restaurant-scoped â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('D â€” baseline selection round-trip', () {
    test('round-trips selected keys through demo_restaurant_001', () async {
      final repo = SqliteBaselineSelectionRepository.instance;
      const restaurantId = 'demo_restaurant_001';

      final testKeys = {'2026-W12|Mon|lunch', '2026-W12|Tue|dinner'};
      await repo.replaceSelectedRecordKeys(restaurantId, testKeys);

      final stored = await repo.getSelectedRecordKeys(restaurantId);
      expect(stored, equals(testKeys));
    });

    test('different restaurant sees different keys', () async {
      final repo = SqliteBaselineSelectionRepository.instance;
      const demoId = 'demo_restaurant_001';

      await repo.replaceSelectedRecordKeys(
          demoId, {'2026-W12|Mon|lunch'});

      final otherKeys = await repo.getSelectedRecordKeys('other_restaurant');
      expect(otherKeys, isEmpty);
    });
  });

  // â”€â”€ E: Import tracking persists fixture replay metadata â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('E â€” import tracking', () {
    test('at least one import_runs record exists for demo restaurant',
        () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query(
        'import_runs',
        where: 'restaurant_id = ?',
        whereArgs: ['demo_restaurant_001'],
      );
      expect(rows, isNotEmpty);
      expect(rows.first['mode'], 'mock_pos_labor_replay');
      expect(rows.first['status'], 'completed');
    });

    test('at least one raw_import_records row exists for that import run',
        () async {
      final db = await SqliteDatabase.instance.database;
      final runs = await db.query(
        'import_runs',
        where: 'restaurant_id = ?',
        whereArgs: ['demo_restaurant_001'],
      );
      expect(runs, isNotEmpty);
      final runId = runs.first['import_run_id'] as String;

      final records = await db.query(
        'raw_import_records',
        where: 'import_run_id = ?',
        whereArgs: [runId],
      );
      expect(records, isNotEmpty);
      expect(records.first['source_type'], 'mock_pos_labor_replay');
      expect(records.first['status'], 'applied');
    });

    test('import tracking repository can read watermarks', () async {
      final repo = SqliteImportTrackingRepository.instance;
      final watermark =
          await repo.getWatermark('demo_restaurant_001', 'fixture', 'last_run');
      // No watermark seeded yet, but query works
      expect(watermark, isNull);
    });
  });

  // â”€â”€ F: Close-shift pipeline propagates non-default restaurant id â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('F â€” scope propagation through builders', () {
    test('TargetSnapshotBuilder carries explicit restaurantId', () {
      final snapshot = TargetSnapshotBuilder.fromCurrentBaseline(
        restaurantId: 'restaurant_test_123',
      );
      expect(snapshot.restaurantId, 'restaurant_test_123');
    });

    test('ShiftFactBuilder preserves ClosedShiftInput.restaurantId', () {
      final input = ClosedShiftInput(
        restaurantId: 'restaurant_test_123',
        businessDate: DateTime(2026, 3, 27),
        weekId: '2026-W13',
        dayLabel: 'Fri',
        daypart: 'dinner',
        covers: 200,
        forecastCovers: 210,
        actualSales: 8400,
        actualFohHours: 50,
        actualBohHours: 50,
      );
      final snapshot = TargetSnapshotBuilder.fromCurrentBaseline(
        restaurantId: input.restaurantId,
      );
      final fact = ShiftFactBuilder.fromClosedShiftInput(input, snapshot);
      expect(fact.restaurantId, 'restaurant_test_123');
      expect(fact.targetSnapshot.restaurantId, 'restaurant_test_123');
    });

    test('default restaurantId still works when omitted', () {
      final snapshot = TargetSnapshotBuilder.fromCurrentBaseline();
      expect(snapshot.restaurantId, 'demo_restaurant_001');
    });
  });

  // â”€â”€ G: v7 migration preserves data and backfills scope â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('G â€” v7 additive migration', () {
    test('shift_records have restaurant_id column after reseed', () async {
      final db = await SqliteDatabase.instance.database;
      final columns = await db.rawQuery('PRAGMA table_info(shift_records)');
      final colNames = columns.map((c) => c['name'] as String).toList();
      expect(colNames, contains('restaurant_id'));
    });

    test('week_records have restaurant_id column after reseed', () async {
      final db = await SqliteDatabase.instance.database;
      final columns = await db.rawQuery('PRAGMA table_info(week_records)');
      final colNames = columns.map((c) => c['name'] as String).toList();
      expect(colNames, contains('restaurant_id'));
    });

    test('baseline_selected_records has restaurant_id column', () async {
      final db = await SqliteDatabase.instance.database;
      final columns =
          await db.rawQuery('PRAGMA table_info(baseline_selected_records)');
      final colNames = columns.map((c) => c['name'] as String).toList();
      expect(colNames, contains('restaurant_id'));
    });

    test('demo restaurant exists after reseed', () async {
      final repo = SqliteRestaurantScopeRepository.instance;
      final restaurant = await repo.getOrCreateActiveRestaurant();
      expect(restaurant.restaurantId, 'demo_restaurant_001');
      expect(restaurant.displayName, 'Barrio Legado');
      expect(restaurant.businessTimezone, 'America/St_Johns');
    });

    test('all seeded shift rows are backfilled with demo restaurant id',
        () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('shift_records');
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row['restaurant_id'], 'demo_restaurant_001');
      }
    });

    test('all seeded week rows are backfilled with demo restaurant id',
        () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('week_records');
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row['restaurant_id'], 'demo_restaurant_001');
      }
    });
  });

  // â”€â”€ H: Real pre-v7 upgrade path preserves old rows and keys â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('H â€” real pre-v7 upgrade path', () {
    late Database oldDb;
    late String testDbPath;

    setUp(() async {
      // Create a fresh in-memory-like temp db with old v6 schema
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      testDbPath =
          p.join(Directory.systemTemp.path, 'forge_upgrade_test_${DateTime.now().millisecondsSinceEpoch}.db');

      oldDb = await openDatabase(testDbPath, version: 1, onCreate: (db, v) async {
        // Old v6-style week_records: no restaurant_id, UNIQUE on week_id only
        await db.execute('''
          CREATE TABLE week_records (
            id                    INTEGER PRIMARY KEY AUTOINCREMENT,
            week_id               TEXT NOT NULL UNIQUE,
            week_label            TEXT NOT NULL,
            total_covers          INTEGER NOT NULL,
            forecast_covers       INTEGER NOT NULL,
            total_foh_hours       INTEGER NOT NULL,
            total_boh_hours       INTEGER NOT NULL,
            avg_ppa               REAL NOT NULL,
            avg_cplh              REAL NOT NULL,
            theoretical_labor_pct REAL NOT NULL,
            actual_labor_pct      REAL NOT NULL,
            dollar_gap            REAL NOT NULL,
            primary_lever_id      TEXT NOT NULL,
            shifts_completed      INTEGER NOT NULL DEFAULT 14,
            blended_foh_wage      REAL NOT NULL DEFAULT 16.50,
            blended_boh_wage      REAL NOT NULL DEFAULT 21.35
          )
        ''');

        // Old v6-style baseline_selected_records: no restaurant_id
        await db.execute('''
          CREATE TABLE baseline_selected_records (
            record_key TEXT PRIMARY KEY NOT NULL
          )
        ''');
      });

      // Seed old data
      await oldDb.insert('week_records', {
        'week_id': '2026-W10',
        'week_label': 'Mar 3',
        'total_covers': 2800,
        'forecast_covers': 2900,
        'total_foh_hours': 640,
        'total_boh_hours': 660,
        'avg_ppa': 42.5,
        'avg_cplh': 4.38,
        'theoretical_labor_pct': 20.6,
        'actual_labor_pct': 22.1,
        'dollar_gap': 1780.0,
        'primary_lever_id': 'covers_down',
        'shifts_completed': 14,
        'blended_foh_wage': 16.50,
        'blended_boh_wage': 21.35,
      });

      await oldDb.insert('baseline_selected_records', {
        'record_key': '2026-W10|Mon|lunch',
      });
      await oldDb.insert('baseline_selected_records', {
        'record_key': '2026-W10|Tue|dinner',
      });
    });

    tearDown(() async {
      await oldDb.close();
      try {
        File(testDbPath).deleteSync();
      } catch (_) {}
    });

    test('old week row survives migration with restaurant_id backfilled',
        () async {
      // Run the v7 migration on the old-schema db
      await SqliteDatabase.instance.migrateToV7ForTest(oldDb);

      final rows = await oldDb.query('week_records');
      expect(rows.length, 1);
      expect(rows.first['week_id'], '2026-W10');
      expect(rows.first['week_label'], 'Mar 3');
      expect(rows.first['total_covers'], 2800);
      expect(rows.first['restaurant_id'], 'demo_restaurant_001');
    });

    test('upgraded week_records has restaurant-scoped uniqueness', () async {
      await SqliteDatabase.instance.migrateToV7ForTest(oldDb);

      // The table should have UNIQUE(restaurant_id, week_id).
      // Verify by checking the table SQL in sqlite_master.
      final masterRows = await oldDb.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='week_records'",
      );
      final tableSql = masterRows.first['sql'] as String;
      expect(tableSql, contains('restaurant_id'));
      expect(tableSql, contains('UNIQUE'));
    });

    test('old baseline keys survive migration under demo_restaurant_001',
        () async {
      await SqliteDatabase.instance.migrateToV7ForTest(oldDb);

      final rows = await oldDb.query('baseline_selected_records',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001']);
      final keys = rows.map((r) => r['record_key'] as String).toSet();
      expect(keys, contains('2026-W10|Mon|lunch'));
      expect(keys, contains('2026-W10|Tue|dinner'));
      expect(keys.length, 2);
    });

    test('demo restaurant exists after migration', () async {
      await SqliteDatabase.instance.migrateToV7ForTest(oldDb);

      final rows = await oldDb.query('restaurant_locations',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001']);
      expect(rows.length, 1);
      expect(rows.first['display_name'], 'Barrio Legado');
      expect(rows.first['business_timezone'], 'America/St_Johns');
    });
  });

  // â”€â”€ I: DatabaseHelper compatibility delegation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('I â€” DatabaseHelper compatibility delegation', () {
    test('baseline selected keys round-trip through DatabaseHelper', () async {
      final keys = {'2026-W12|Mon|lunch', '2026-W12|Tue|dinner'};
      await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys(keys);
      final stored =
          await DatabaseHelper.instance.getBaselineSelectedRecordKeys();
      expect(stored, equals(keys));
    });

    test('week history loads through DatabaseHelper', () async {
      final weeks = await DatabaseHelper.instance.getWeekHistory();
      expect(weeks, isNotEmpty);
      for (final w in weeks) {
        expect(w.restaurantId, 'demo_restaurant_001');
      }
    });

    test('shifts-for-week loads through DatabaseHelper', () async {
      final shifts =
          await DatabaseHelper.instance.getShiftsForWeek('2026-W13');
      expect(shifts, isNotEmpty);
      for (final s in shifts) {
        expect(s.restaurantId, 'demo_restaurant_001');
      }
    });
  });

  // â”€â”€ J: Fixture replay raw-import businessDate is a real date â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('J â€” fixture replay businessDate correctness', () {
    test('raw_import_records business_date is not a week id pattern',
        () async {
      final db = await SqliteDatabase.instance.database;
      final records = await db.query('raw_import_records', limit: 10);
      expect(records, isNotEmpty);

      final weekIdPattern = RegExp(r'^\d{4}-W\d{2}$');
      final datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

      for (final r in records) {
        final bd = r['business_date'] as String;
        expect(bd, isNot(matches(weekIdPattern)),
            reason: 'business_date should not be a week id: $bd');
        expect(bd, matches(datePattern),
            reason: 'business_date should be YYYY-MM-DD: $bd');
      }
    });
  });

  // â”€â”€ K: Real pre-v8 upgrade path â€” target-state migration â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('K â€” real pre-v8 upgrade path', () {
    late Database oldDb;
    late String testDbPath;

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      testDbPath = p.join(Directory.systemTemp.path,
          'forge_v8_upgrade_test_${DateTime.now().millisecondsSinceEpoch}.db');

      // Create a v7-style database: has restaurant_id but no locked-target columns
      oldDb = await openDatabase(testDbPath, version: 1,
          onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE restaurant_locations (
            restaurant_id TEXT PRIMARY KEY NOT NULL,
            display_name TEXT NOT NULL,
            business_timezone TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL)
        ''');
        await db.execute('''
          CREATE TABLE shift_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            restaurant_id TEXT NOT NULL DEFAULT 'demo_restaurant_001',
            week_id TEXT NOT NULL,
            day_label TEXT NOT NULL,
            daypart TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'closed',
            covers INTEGER NOT NULL,
            forecast_covers INTEGER NOT NULL,
            ppa REAL NOT NULL,
            cplh REAL NOT NULL,
            splh REAL NOT NULL,
            blended_wage REAL NOT NULL,
            foh_hours INTEGER NOT NULL,
            boh_hours INTEGER NOT NULL,
            foh_labor_pct REAL NOT NULL,
            boh_labor_pct REAL NOT NULL,
            total_labor_pct REAL NOT NULL,
            theoretical_labor_pct REAL NOT NULL DEFAULT 20.6,
            variance_pts REAL NOT NULL,
            primary_lever TEXT NOT NULL,
            scheduled_foh_hours INTEGER,
            scheduled_boh_hours INTEGER,
            foh_labor_dollar REAL,
            boh_labor_dollar REAL,
            source_system TEXT,
            source_shift_id TEXT)
        ''');
        await db.execute('''
          CREATE TABLE week_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            restaurant_id TEXT NOT NULL DEFAULT 'demo_restaurant_001',
            week_id TEXT NOT NULL,
            week_label TEXT NOT NULL,
            total_covers INTEGER NOT NULL,
            forecast_covers INTEGER NOT NULL,
            total_foh_hours INTEGER NOT NULL,
            total_boh_hours INTEGER NOT NULL,
            avg_ppa REAL NOT NULL,
            avg_cplh REAL NOT NULL,
            theoretical_labor_pct REAL NOT NULL,
            actual_labor_pct REAL NOT NULL,
            dollar_gap REAL NOT NULL,
            primary_lever_id TEXT NOT NULL,
            shifts_completed INTEGER NOT NULL DEFAULT 14,
            blended_foh_wage REAL NOT NULL DEFAULT 16.50,
            blended_boh_wage REAL NOT NULL DEFAULT 21.35,
            UNIQUE(restaurant_id, week_id))
        ''');
        await db.execute('''
          CREATE TABLE baseline_selected_records (
            restaurant_id TEXT NOT NULL DEFAULT 'demo_restaurant_001',
            record_key TEXT NOT NULL,
            PRIMARY KEY (restaurant_id, record_key))
        ''');

        // Seed demo restaurant
        final now = DateTime.now().toIso8601String();
        await db.insert('restaurant_locations', {
          'restaurant_id': 'demo_restaurant_001',
          'display_name': 'Barrio Legado',
          'business_timezone': 'America/St_Johns',
          'created_at': now,
          'updated_at': now,
        });

        // Seed one old closed shift (no locked-target columns)
        await db.insert('shift_records', {
          'restaurant_id': 'demo_restaurant_001',
          'week_id': '2026-W10',
          'day_label': 'Mon',
          'daypart': 'lunch',
          'status': 'closed',
          'covers': 154,
          'forecast_covers': 180,
          'ppa': 41.79,
          'cplh': 4.28,
          'splh': 180.5,
          'blended_wage': 18.5,
          'foh_hours': 36,
          'boh_hours': 37,
          'foh_labor_pct': 9.2,
          'boh_labor_pct': 12.3,
          'total_labor_pct': 21.5,
          'theoretical_labor_pct': 20.48,
          'variance_pts': 1.02,
          'primary_lever': 'COVERS_DOWN',
        });
      });
    });

    tearDown(() async {
      await oldDb.close();
      try {
        File(testDbPath).deleteSync();
      } catch (_) {}
    });

    test('old shift row survives v8 migration with locked targets backfilled',
        () async {
      await SqliteDatabase.instance.migrateToV8ForTest(oldDb);

      final rows = await oldDb.query('shift_records');
      expect(rows.length, 1);
      expect(rows.first['week_id'], '2026-W10');
      expect(rows.first['covers'], 154);
      // Numeric locked targets backfilled
      expect(rows.first['target_cplh'], isNotNull);
      expect(rows.first['target_splh'], isNotNull);
      expect(rows.first['target_ppa'], isNotNull);
      expect(rows.first['target_foh_wage'], isNotNull);
      expect(rows.first['target_boh_wage'], isNotNull);
    });

    test('old shift row has target-profile provenance after v8 migration',
        () async {
      await SqliteDatabase.instance.migrateToV8ForTest(oldDb);

      final rows = await oldDb.query('shift_records');
      expect(rows.first['target_profile_id'], isNotNull);
      expect(rows.first['target_profile_id'], isNotEmpty);
      expect(rows.first['target_profile_version_id'], isNotNull);
      expect(rows.first['target_profile_version_id'],
          'compat_demo_restaurant_001_v8_backfill');
    });

    test('compat version row exists after v8 migration', () async {
      await SqliteDatabase.instance.migrateToV8ForTest(oldDb);

      final versions = await oldDb.query('target_profile_versions',
          where: 'target_profile_version_id = ?',
          whereArgs: ['compat_demo_restaurant_001_v8_backfill']);
      expect(versions, isNotEmpty);
      expect(versions.first['restaurant_id'], 'demo_restaurant_001');
      expect((versions.first['target_cplh'] as num).toDouble(),
          greaterThan(0));
    });

    test('active target profile exists after v8 migration', () async {
      await SqliteDatabase.instance.migrateToV8ForTest(oldDb);

      final profiles = await oldDb.query('active_target_profiles',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001']);
      expect(profiles, isNotEmpty);
    });

    test('migrated shift row rehydrates as ShiftRecord with locked fields',
        () async {
      await SqliteDatabase.instance.migrateToV8ForTest(oldDb);

      final rows = await oldDb.query('shift_records');
      expect(rows, isNotEmpty);
      final record = ShiftRecord.fromMap(rows.first);

      expect(record.targetProfileId, isNotNull);
      expect(record.targetProfileId, isNotEmpty);
      expect(record.targetProfileVersionId, isNotNull);
      expect(record.targetProfileVersionId, isNotEmpty);
      expect(record.targetCPLH, isNotNull);
      expect(record.targetCPLH, greaterThan(0));
      expect(record.targetSPLH, isNotNull);
      expect(record.targetPPA, isNotNull);
      expect(record.targetFohWage, isNotNull);
      expect(record.targetBohWage, isNotNull);
      // Original operational data preserved
      expect(record.weekId, '2026-W10');
      expect(record.covers, 154);
      expect(record.isClosed, isTrue);
    });
  });

  // â”€â”€ L: Partial-migration provenance repair â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('L â€” partial-migration provenance repair', () {
    late Database partialDb;
    late String partialDbPath;

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      partialDbPath = p.join(Directory.systemTemp.path,
          'forge_partial_test_${DateTime.now().millisecondsSinceEpoch}.db');

      // Create a v8-ish database with locked-target columns but no provenance
      partialDb = await openDatabase(partialDbPath, version: 1,
          onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE restaurant_locations (
            restaurant_id TEXT PRIMARY KEY NOT NULL,
            display_name TEXT NOT NULL,
            business_timezone TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL)
        ''');
        await db.execute('''
          CREATE TABLE active_target_profiles (
            restaurant_id TEXT PRIMARY KEY NOT NULL,
            target_profile_id TEXT NOT NULL,
            source_type TEXT NOT NULL,
            target_cplh REAL NOT NULL, target_splh REAL NOT NULL,
            target_ppa REAL NOT NULL, foh_wage REAL NOT NULL,
            boh_wage REAL NOT NULL, opz_floor_cplh REAL NOT NULL,
            opz_ceiling_cplh REAL NOT NULL,
            theoretical_foh_labor_pct REAL NOT NULL,
            theoretical_boh_labor_pct REAL NOT NULL,
            theoretical_labor_pct REAL NOT NULL,
            built_at TEXT NOT NULL)
        ''');
        await db.execute('''
          CREATE TABLE target_profile_versions (
            target_profile_version_id TEXT PRIMARY KEY NOT NULL,
            target_profile_id TEXT NOT NULL, restaurant_id TEXT NOT NULL,
            source_type TEXT NOT NULL, target_cplh REAL NOT NULL,
            target_splh REAL NOT NULL, target_ppa REAL NOT NULL,
            foh_wage REAL NOT NULL, boh_wage REAL NOT NULL,
            opz_floor_cplh REAL NOT NULL, opz_ceiling_cplh REAL NOT NULL,
            theoretical_foh_labor_pct REAL NOT NULL,
            theoretical_boh_labor_pct REAL NOT NULL,
            theoretical_labor_pct REAL NOT NULL,
            created_at TEXT NOT NULL)
        ''');
        await db.execute('''
          CREATE TABLE shift_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            restaurant_id TEXT NOT NULL DEFAULT 'demo_restaurant_001',
            week_id TEXT NOT NULL, day_label TEXT NOT NULL,
            daypart TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'closed',
            covers INTEGER NOT NULL, forecast_covers INTEGER NOT NULL,
            ppa REAL NOT NULL, cplh REAL NOT NULL, splh REAL NOT NULL,
            blended_wage REAL NOT NULL,
            foh_hours INTEGER NOT NULL, boh_hours INTEGER NOT NULL,
            foh_labor_pct REAL NOT NULL, boh_labor_pct REAL NOT NULL,
            total_labor_pct REAL NOT NULL,
            theoretical_labor_pct REAL NOT NULL DEFAULT 20.6,
            variance_pts REAL NOT NULL, primary_lever TEXT NOT NULL,
            scheduled_foh_hours INTEGER, scheduled_boh_hours INTEGER,
            foh_labor_dollar REAL, boh_labor_dollar REAL,
            source_system TEXT, source_shift_id TEXT,
            target_profile_id TEXT,
            target_profile_version_id TEXT,
            target_source_type TEXT,
            target_cplh REAL, target_splh REAL, target_ppa REAL,
            target_foh_wage REAL, target_boh_wage REAL,
            opz_floor_cplh REAL, opz_ceiling_cplh REAL,
            theoretical_foh_labor_pct REAL, theoretical_boh_labor_pct REAL)
        ''');

        // v7-compat tables needed by v8 migration path
        await db.execute('''
          CREATE TABLE week_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            restaurant_id TEXT NOT NULL DEFAULT 'demo_restaurant_001',
            week_id TEXT NOT NULL, week_label TEXT NOT NULL,
            total_covers INTEGER NOT NULL, forecast_covers INTEGER NOT NULL,
            total_foh_hours INTEGER NOT NULL, total_boh_hours INTEGER NOT NULL,
            avg_ppa REAL NOT NULL, avg_cplh REAL NOT NULL,
            theoretical_labor_pct REAL NOT NULL, actual_labor_pct REAL NOT NULL,
            dollar_gap REAL NOT NULL, primary_lever_id TEXT NOT NULL,
            shifts_completed INTEGER NOT NULL DEFAULT 14,
            blended_foh_wage REAL NOT NULL DEFAULT 16.50,
            blended_boh_wage REAL NOT NULL DEFAULT 21.35,
            UNIQUE(restaurant_id, week_id))
        ''');
        await db.execute('''
          CREATE TABLE baseline_selected_records (
            restaurant_id TEXT NOT NULL DEFAULT 'demo_restaurant_001',
            record_key TEXT NOT NULL,
            PRIMARY KEY (restaurant_id, record_key))
        ''');

        final now = DateTime.now().toIso8601String();
        await db.insert('restaurant_locations', {
          'restaurant_id': 'demo_restaurant_001',
          'display_name': 'Barrio Legado',
          'business_timezone': 'America/St_Johns',
          'created_at': now, 'updated_at': now,
        });

        // Insert a partially migrated shift: numeric targets present, provenance null
        await db.insert('shift_records', {
          'restaurant_id': 'demo_restaurant_001',
          'week_id': '2026-W10', 'day_label': 'Mon', 'daypart': 'lunch',
          'status': 'closed', 'covers': 154, 'forecast_covers': 180,
          'ppa': 41.79, 'cplh': 4.28, 'splh': 180.5, 'blended_wage': 18.5,
          'foh_hours': 36, 'boh_hours': 37,
          'foh_labor_pct': 9.2, 'boh_labor_pct': 12.3,
          'total_labor_pct': 21.5, 'theoretical_labor_pct': 20.48,
          'variance_pts': 1.02, 'primary_lever': 'COVERS_DOWN',
          // Numeric targets present but provenance null
          'target_cplh': 4.58, 'target_splh': 180.0, 'target_ppa': 42.0,
          'target_foh_wage': 16.50, 'target_boh_wage': 21.35,
          'target_source_type': 'system_baseline',
          'opz_floor_cplh': 3.5, 'opz_ceiling_cplh': 5.8,
          'theoretical_foh_labor_pct': 8.7, 'theoretical_boh_labor_pct': 11.9,
          'target_profile_id': null,
          'target_profile_version_id': null,
        });
      });
    });

    tearDown(() async {
      await partialDb.close();
      try {
        File(partialDbPath).deleteSync();
      } catch (_) {}
    });

    test('partially migrated row gets provenance repaired', () async {
      // Run the backfill (same path used in reseed and migration)
      await SqliteDatabase.instance.migrateToV8ForTest(partialDb);

      final rows = await partialDb.query('shift_records');
      expect(rows.length, 1);

      // Numeric values preserved (not overwritten)
      expect((rows.first['target_cplh'] as num).toDouble(), closeTo(4.58, 0.001));
      expect((rows.first['target_ppa'] as num).toDouble(), closeTo(42.0, 0.001));

      // Provenance now populated
      expect(rows.first['target_profile_id'], isNotNull);
      expect(rows.first['target_profile_id'], isNotEmpty);
      expect(rows.first['target_profile_version_id'],
          'compat_demo_restaurant_001_v8_backfill');
    });

    test('compat version row exists after partial-migration repair', () async {
      await SqliteDatabase.instance.migrateToV8ForTest(partialDb);

      final versions = await partialDb.query('target_profile_versions',
          where: 'target_profile_version_id = ?',
          whereArgs: ['compat_demo_restaurant_001_v8_backfill']);
      expect(versions, isNotEmpty);
    });

    test('repaired row rehydrates with full locked-field access', () async {
      await SqliteDatabase.instance.migrateToV8ForTest(partialDb);

      final rows = await partialDb.query('shift_records');
      final record = ShiftRecord.fromMap(rows.first);

      expect(record.targetProfileId, isNotNull);
      expect(record.targetProfileVersionId, isNotNull);
      expect(record.targetCPLH, closeTo(4.58, 0.001));
      expect(record.covers, 154);
    });
  });
}
