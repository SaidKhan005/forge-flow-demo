// Phase 8.0 / N4 — Demo writer-side regression test.
//
// Authority: CLAUDE.md → Hard Promise #2 ("Demo mode is a writer-side
// switch — same tables, same reads, same UI either way").
// Detail:    docs/contracts/demo_mode_contract.md
//
// What this asserts:
//   1. The seeded demo path writes to the SAME SQLite tables that
//      production reads through (`restaurant_locations`,
//      `shift_records`, `week_records`, `import_runs`,
//      `raw_import_records`).
//   2. There are NO `demo_*` parallel SQLite tables in the schema.
//   3. Every demo row carries `restaurant_id = DemoScope.restaurantId`
//      ('demo_restaurant_001'), so production-side repositories scoped
//      by `restaurant_id` see them as ordinary rows.
//
// If a future change introduces a `demo_*` table, splits demo writes
// to a parallel DAO, or omits `restaurant_id` on a seeded row, this
// test fails. That is the intended trip-wire — replace the change
// with a writer-side seed + scoped read, then re-run.
//
// This file does NOT exercise reader-side branches; the two
// intentional reader-side carve-outs (login button + status badge)
// are covered in `test/app_data_status_test.dart` and the login screen
// widget tests respectively.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_week_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';

import '../_test_helpers/sqlite_demo_helpers.dart';

void main() {
  setUp(setUpSqliteDemo);

  group('Demo writer-side switch — production tables only', () {
    test('schema contains zero `demo_*` parallel tables', () async {
      final db = await SqliteDatabase.instance.database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name LIKE 'demo\\_%' ESCAPE '\\'",
      );
      expect(
        tables,
        isEmpty,
        reason:
            'Demo mode is a WRITER-side switch (HP #2). No `demo_*` SQLite '
            'tables may exist; demo data must round-trip through the same '
            'tables production reads. Found: '
            '${tables.map((r) => r['name']).toList()}',
      );
    });

    test(
        'demo seed writes restaurant_locations row with '
        'restaurant_id = demo_restaurant_001', () async {
      final repo = SqliteRestaurantScopeRepository.instance;
      final restaurant = await repo.getOrCreateActiveRestaurant();
      expect(restaurant.restaurantId, 'demo_restaurant_001');
      // The same repository is what production scope-resolution uses;
      // there is no demo-only branch in `getOrCreateActiveRestaurant`.
    });

    test(
        'demo seed writes shift_records under '
        'restaurant_id = demo_restaurant_001', () async {
      final db = await SqliteDatabase.instance.database;
      final demoShifts = await db.query(
        'shift_records',
        where: 'restaurant_id = ?',
        whereArgs: ['demo_restaurant_001'],
        limit: 1,
      );
      expect(demoShifts, isNotEmpty,
          reason: 'demo seed must populate shift_records');

      // The production repository is the SAME path the UI reads
      // through. If this returns rows, the writer-side switch is
      // honored end-to-end.
      final via = await SqliteShiftRecordRepository.instance
          .getShiftsForWeek('demo_restaurant_001', '2026-W13');
      expect(via, isNotEmpty,
          reason: 'production repository must surface demo rows');
      for (final s in via) {
        expect(s.restaurantId, 'demo_restaurant_001');
      }
    });

    test(
        'demo seed writes week_records under '
        'restaurant_id = demo_restaurant_001', () async {
      final weeks = await SqliteWeekRecordRepository.instance
          .getWeekHistory('demo_restaurant_001');
      expect(weeks, isNotEmpty);
      for (final w in weeks) {
        expect(w.restaurantId, 'demo_restaurant_001');
      }
    });

    test('demo seed writes import_runs row tagged mock_pos_labor_replay',
        () async {
      final db = await SqliteDatabase.instance.database;
      final runs = await db.query(
        'import_runs',
        where: 'restaurant_id = ?',
        whereArgs: ['demo_restaurant_001'],
      );
      expect(runs, isNotEmpty);
      // Mode is the only demo-distinguishing label; the row itself
      // lives in the SAME `import_runs` table Phase 8 vendor sinks
      // write to.
      expect(runs.first['mode'], 'mock_pos_labor_replay');
    });

    test(
        'demo seed writes raw_import_records under the same import_run',
        () async {
      final db = await SqliteDatabase.instance.database;
      final runs = await db.query(
        'import_runs',
        where: 'restaurant_id = ?',
        whereArgs: ['demo_restaurant_001'],
      );
      expect(runs, isNotEmpty);
      final runId = runs.first['import_run_id'] as String;
      final raws = await db.query(
        'raw_import_records',
        where: 'import_run_id = ?',
        whereArgs: [runId],
      );
      expect(raws, isNotEmpty);
      // Production vendor sinks share this exact table; switching
      // sources is a writer change, not a schema change.
    });

    test(
        'no shift_records row is missing a restaurant_id '
        '(would silently bypass scoped reads)', () async {
      final db = await SqliteDatabase.instance.database;
      final orphans = await db.query(
        'shift_records',
        where: 'restaurant_id IS NULL OR restaurant_id = ""',
      );
      expect(orphans, isEmpty,
          reason:
              'Every seeded shift must carry restaurant_id so the same '
              'scoped repository production uses can see it.');
    });
  });
}
