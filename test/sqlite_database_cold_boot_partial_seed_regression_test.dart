// Cold-boot demo seed PARTIAL-SEED regression test.
//
// Authority: this slice's prompt (FU-coldboot-partial-seed); CLAUDE.md
// HP #2 (writer-side switch — same tables, no demo_* table, no
// kDemoMode reader branch), HP #4 (per-location scoping); the W8
// cold-boot today-anchor and W6 per-location operational envelope it
// builds on.
//
// Defect this guards (operator-reproduced on emulator-5554, real
// current date): a clean cold boot ran the heavy demo seed INSIDE
// sqflite's implicit `onCreate` transaction. The seed invokes DAOs
// (`TargetCycleDao.upsertCycle`, weekly-plan / open-shift / reservation
// DAOs) that each open their own `Database.transaction()`. A
// transaction opened while one is already in force on the same
// connection does not compose on Android native sqflite the way it does
// on `sqflite_common_ffi`: the parent-table writes made directly on the
// `onCreate` handle were rolled back while independently-committed
// nested-DAO writes and the final in-memory envelope step survived — a
// silently half-seeded DB (shift_records / target_cycles /
// weekly_plan_snapshots / open_shift_snapshots / wage_role_rows empty;
// target_cycle_dayparts + weekly_plan_snapshot_day_dayparts ORPHANED)
// with no crash. The reseed/advance path
// (`reseedMockReplayForBusinessDate`) was unaffected because it runs
// the SAME seeders post-open (no implicit onCreate transaction).
//
// The fix keeps `onCreate` schema-only and runs the demo seed
// POST-open, single-flight, exactly as the device-proven reseed path
// does. These tests lock that contract.
//
// HONEST REPRODUCTION NOTE (CI is dark; disclosed in the PR body):
// `sqflite_common_ffi` — the only SQLite the `flutter test` harness has
// — composes nested transactions differently from Android native
// sqflite and also coalesces concurrent same-path opens, so the
// *behavioral* half-seed cannot be reproduced in-process here (the
// merged W6/W8 suites are green on master for the same reason). What IS
// deterministic in this harness, and is asserted below, is the
// STRUCTURAL fix that removes the Android failure mechanism by
// construction: (1) `onCreate` is schema-only — a freshly created DB
// has zero demo rows; (2) a clean cold boot still fully seeds every
// parent table for all 4 locations with zero orphaned child rows, for
// the real current date and the operator's 2026-05-16; (3) concurrent
// first-callers share one open + one seed (single-flight).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/dev/demo_vendor_integration_state_fixture.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Fix A (operator decision 2026-05-16): a "none connected" demo
  // location (today Harbour) is honest-EMPTY — no operational parent
  // rows. The partial-seed regression (parent tables non-empty) applies
  // to the CONNECTED locations; Harbour's honest-empty state is asserted
  // separately below.
  final demoIds = DemoScope.locations
      .map((l) => l.restaurantId)
      .where((id) => !DemoVendorIntegrationStateFixture.isNoneConnected(id))
      .toList();
  final noneConnectedIds = DemoScope.locations
      .map((l) => l.restaurantId)
      .where((id) => DemoVendorIntegrationStateFixture.isNoneConnected(id))
      .toList();

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('coldboot_partial_');
    SqliteDatabase.debugColdBootSeedRunCount = 0;
  });

  tearDown(() async {
    SqliteDatabase.debugColdBootTodayOverride = null;
    SqliteDatabase.debugColdBootSeedRunCount = 0;
    await SqliteDatabase.instance.close();
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
  });

  Future<int> count(Database db, String sql) async =>
      (await db.rawQuery(sql)).first.values.first as int;

  // True cold boot: fresh file path → openDatabase runs _createFreshSchema
  // then the post-open seed, all before `database` resolves.
  Future<void> coldBoot(String today) async {
    SqliteDatabase.debugColdBootTodayOverride = today;
    await SqliteDatabase.instance
        .useDatabasePath(p.join(tmpDir.path, 'cold_$today.db'));
    await SqliteDatabase.instance.database;
  }

  String realTodayUtc() {
    final now = DateTime.now().toUtc();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> assertFullySeededNoOrphans(String today) async {
    final db = await SqliteDatabase.instance.database;

    // Every parent table the cold-boot path owns is non-empty for every
    // demo location (the partial-seed defect left these at 0).
    for (final rid in demoIds) {
      for (final table in const [
        'shift_records',
        'target_cycles',
        'weekly_plan_snapshots',
        'open_shift_snapshots',
      ]) {
        final n = await count(
          db,
          "SELECT COUNT(*) FROM $table WHERE restaurant_id = '$rid'",
        );
        expect(n, greaterThan(0),
            reason: 'cold boot ($today): $table empty for $rid — the '
                'partial-seed regression');
      }
    }

    // Fix A: the "none connected" location is honest-EMPTY — every
    // operational parent table has ZERO rows for it (no phantom data),
    // while its scope row (restaurant_locations) IS still seeded.
    for (final rid in noneConnectedIds) {
      for (final table in const [
        'shift_records',
        'week_records',
        'target_cycles',
        'weekly_plan_snapshots',
        'open_shift_snapshots',
      ]) {
        final n = await count(
          db,
          "SELECT COUNT(*) FROM $table WHERE restaurant_id = '$rid'",
        );
        expect(n, 0,
            reason: 'cold boot ($today): $rid ($table) must be '
                'honest-EMPTY (none connected → no fabricated data)');
      }
      final loc = await count(
        db,
        "SELECT COUNT(*) FROM restaurant_locations "
        "WHERE restaurant_id = '$rid'",
      );
      expect(loc, greaterThan(0),
          reason: 'cold boot ($today): $rid still in the scope drawer');
    }

    // Wage authority: Downtown business default + the Riverside HP #11
    // override OWN rows; North Loop + Harbour intentionally INHERIT
    // (W6 design — no own rows). Assert the owners are populated and the
    // table is globally non-empty (it was 0 in the defect).
    expect(await count(db, 'SELECT COUNT(*) FROM wage_role_rows'),
        greaterThan(0),
        reason: 'cold boot ($today): wage_role_rows globally empty');
    for (final rid in const [
      DemoScope.downtownRestaurantId,
      DemoScope.riversideRestaurantId,
    ]) {
      expect(
        await count(db,
            "SELECT COUNT(*) FROM wage_role_rows WHERE restaurant_id = '$rid'"),
        greaterThan(0),
        reason: 'cold boot ($today): wage_role_rows empty for $rid',
      );
    }

    // Zero orphaned children — every per-period child row has a parent
    // (the defect left 12 target_cycle_dayparts + 735
    // weekly_plan_snapshot_day_dayparts orphaned).
    expect(
      await count(
          db,
          'SELECT COUNT(*) FROM target_cycle_dayparts c '
          'LEFT JOIN target_cycles pTbl ON c.cycle_id = pTbl.cycle_id '
          'WHERE pTbl.cycle_id IS NULL'),
      0,
      reason: 'cold boot ($today): orphaned target_cycle_dayparts',
    );
    expect(
      await count(
          db,
          'SELECT COUNT(*) FROM weekly_plan_snapshot_day_dayparts c '
          'LEFT JOIN weekly_plan_snapshots pTbl '
          '  ON c.snapshot_id = pTbl.snapshot_id '
          'WHERE pTbl.snapshot_id IS NULL'),
      0,
      reason: 'cold boot ($today): orphaned '
          'weekly_plan_snapshot_day_dayparts',
    );

    // mock_replay_state pinned to the cold-boot anchor (W8 preserved).
    final st = await db.query('mock_replay_state',
        where: 'restaurant_id = ?',
        whereArgs: [DemoScope.restaurantId]);
    expect(st.single['current_business_date'], today);
  }

  test('cold boot on the REAL current date fully seeds every parent '
      'table for every CONNECTED location (none-connected honest-empty) '
      'with zero orphans', () async {
    final today = realTodayUtc();
    await coldBoot(today);
    await assertFullySeededNoOrphans(today);
    expect(SqliteDatabase.debugColdBootSeedRunCount, 1,
        reason: 'seed runs exactly once on a clean cold boot');
  });

  test('cold boot on the operator-reproduced 2026-05-16 fully seeds '
      'every parent table for every CONNECTED location '
      '(none-connected honest-empty) with zero orphans',
      () async {
    await coldBoot('2026-05-16');
    await assertFullySeededNoOrphans('2026-05-16');
  });

  test('onCreate is schema-only — a freshly created DB has ZERO demo '
      'rows (the seed must NOT run inside sqflite\'s onCreate '
      'transaction)', () async {
    // Open a raw DB and run only the schema-create step. If the seed
    // were still wired into onCreate this DB would be populated; the
    // fix guarantees it is empty and the seed is deferred post-open.
    final raw = await databaseFactory.openDatabase(
      p.join(tmpDir.path, 'schema_only.db'),
    );
    await SqliteDatabase.instance.debugCreateFreshSchemaOnly(raw);

    for (final table in const [
      'shift_records',
      'target_cycles',
      'target_cycle_dayparts',
      'weekly_plan_snapshots',
      'weekly_plan_snapshot_day_dayparts',
      'open_shift_snapshots',
      'wage_role_rows',
      'restaurant_locations',
      'week_records',
    ]) {
      expect(await count(raw, 'SELECT COUNT(*) FROM $table'), 0,
          reason: 'onCreate must be schema-only; $table was seeded '
              'inside the onCreate transaction');
    }
    expect(SqliteDatabase.debugColdBootSeedRunCount, 0,
        reason: 'schema create must not run the demo seed');
    await raw.close();
  });

  test('single-flight: concurrent first-callers during a clean cold '
      'boot share one open + one seed', () async {
    SqliteDatabase.debugColdBootTodayOverride = '2026-05-16';
    await SqliteDatabase.instance
        .useDatabasePath(p.join(tmpDir.path, 'cc.db'));

    // The demo flavor boots several subsystems that each await
    // `database` at roughly the same time. They must coalesce.
    final handles = await Future.wait([
      for (var i = 0; i < 8; i++) SqliteDatabase.instance.database,
    ]);
    expect(handles.every((h) => identical(h, handles.first)), isTrue,
        reason: 'all concurrent first-callers get one Database');
    expect(SqliteDatabase.debugColdBootSeedRunCount, 1,
        reason: 'exactly one seed run despite concurrent first-callers '
            '(the unguarded re-entrant getter could seed/open twice)');

    final db = handles.first;
    expect(
      await count(db, 'SELECT COUNT(*) FROM shift_records'),
      greaterThan(0),
    );
  });
}
