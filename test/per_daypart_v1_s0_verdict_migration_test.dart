// Per-Daypart Targets V1 — Slice S0 (foundation).
//
// SQLite migration smoke test for the V37 per-period verdict columns.
//
// Asserts:
//   * `target_cycle_dayparts` has `verdict` + `verdict_reason` columns
//     after the real migration chain runs to schemaVersion 37.
//   * The columns are queryable (PRAGMA table_info + a direct SELECT).
//   * TargetCycleDao round-trips verdict / verdictReason (non-null AND
//     null) through upsertCycle -> getActiveCycle.
//
// Uses the real SqliteDatabase singleton (same harness as
// manual_cover_entry_dao_test.dart) so the column comes from the
// production migration path, not a hand-rolled schema.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/target_cycle_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = 'demo_restaurant_001';

  setUp(() async {
    final db = await SqliteDatabase.instance.database;
    await db.delete('target_cycle_dayparts');
    await db.delete('target_cycles', where: 'restaurant_id = ?',
        whereArgs: [restaurantId]);
  });

  test('migration adds verdict + verdict_reason columns (queryable)',
      () async {
    final db = await SqliteDatabase.instance.database;
    final info = await db.rawQuery(
      "PRAGMA table_info('target_cycle_dayparts')",
    );
    final cols = info.map((r) => r['name'] as String).toSet();
    expect(cols, contains('verdict'));
    expect(cols, contains('verdict_reason'));

    // Direct SELECT proves the columns are addressable.
    final selected = await db.rawQuery(
      'SELECT verdict, verdict_reason FROM target_cycle_dayparts LIMIT 1',
    );
    expect(selected, isEmpty); // table cleared in setUp; SELECT compiled OK.
  });

  TargetCycle cycle(List<TargetCycleDaypart> dayparts) => TargetCycle(
        cycleId: 'cycle_s0_test',
        restaurantId: restaurantId,
        source: TargetCycleSource.recommended,
        effectiveStart: '2026-05-01',
        effectiveEnd: '2026-06-30',
        calibrationWindowStart: '2026-03-01',
        calibrationWindowEnd: '2026-04-30',
        targetCPLH: 4.5,
        targetSPLH: 175.0,
        targetPPA: 40.0,
        fohWage: 18.0,
        bohWage: 19.0,
        opzFloorCPLH: 3.5,
        opzCeilingCPLH: 5.5,
        createdAt: '2026-05-01T00:00:00Z',
        dayparts: dayparts,
      );

  test('DAO round-trips non-null verdict + reason', () async {
    final db = await SqliteDatabase.instance.database;
    final dao = TargetCycleDao(db);

    await dao.upsertCycle(cycle([
      const TargetCycleDaypart(
        servicePeriodId: 'dinner',
        targetCPLH: 5.0,
        targetSPLH: 200.0,
        targetPPA: 45.0,
        opzFloorCPLH: 4.5,
        opzCeilingCPLH: 5.5,
        coverCount: 300,
        verdict: BenchmarkVerdict.teachable,
        verdictReason: 'robust cohort',
      ),
    ]));

    final loaded = await dao.getActiveCycle(restaurantId);
    expect(loaded, isNotNull);
    final dp = loaded!.daypartFor('dinner');
    expect(dp, isNotNull);
    expect(dp!.verdict, BenchmarkVerdict.teachable);
    expect(dp.verdictReason, 'robust cohort');
  });

  test('DAO round-trips null verdict + reason (back-compat default)',
      () async {
    final db = await SqliteDatabase.instance.database;
    final dao = TargetCycleDao(db);

    await dao.upsertCycle(cycle([
      const TargetCycleDaypart(
        servicePeriodId: 'lunch',
        targetCPLH: 4.0,
        targetSPLH: 150.0,
        targetPPA: 35.0,
        opzFloorCPLH: 3.5,
        opzCeilingCPLH: 4.5,
        coverCount: 100,
      ),
    ]));

    final loaded = await dao.getActiveCycle(restaurantId);
    final dp = loaded!.daypartFor('lunch');
    expect(dp, isNotNull);
    expect(dp!.verdict, isNull);
    expect(dp.verdictReason, isNull);
    // Existing per-period payload unaffected.
    expect(dp.targetCPLH, 4.0);
    expect(dp.coverCount, 100);
  });
}
