// Demo-data — cold-boot wage authority regression.
//
// Authority: docs/_audits/per_daypart_v1/
//            demo_seed_multilocation_operational_envelope.md;
//            CLAUDE.md HP #2 / HP #4 / HP #11.
//
// Gap 4 reconciliation: the reseed/advance path already seeds
// `wage_role_rows` (+ the Riverside location override) before the cycle
// build, but the cold-boot `_onCreate` path did NOT — so Settings ▸
// Wage Authority was empty on the very first launch (before any date
// advance). The per-location wage story itself is intentional HP #11
// inheritance (Downtown business default, Riverside override, North Loop
// + Harbour inherit), so the only genuine fix is wiring the existing
// seeders into cold-boot. This test exercises a true fresh-file
// `_onCreate` (no reseed) and asserts the wage surface is populated with
// the correct per-location inheritance shape.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:path/path.dart' as p;

double _blend(List<Map<String, Object?>> rows, String bucket) {
  final f = rows.where((r) => r['labor_bucket'] == bucket).toList();
  final hrs = f.fold<double>(
      0, (s, r) => s + (r['weighted_hours'] as num).toDouble());
  final dollars = f.fold<double>(
      0,
      (s, r) =>
          s +
          (r['hourly_rate'] as num).toDouble() *
              (r['weighted_hours'] as num).toDouble());
  return dollars / hrs;
}

void main() {
  test('cold-boot _onCreate populates wage_role_rows with the per-location '
      'HP #11 inheritance shape (no reseed)', () async {
    // Point the singleton at a brand-new file so `database` triggers the
    // real `_onCreate` cold-boot path (not reseedDemo).
    final dir = Directory(
        p.join(Directory.current.path, '.dart_tool', 'test_databases'));
    await dir.create(recursive: true);
    final dbPath =
        p.join(dir.path, 'cold_boot_wage_$pid.db');
    for (final sfx in const ['', '-shm', '-wal']) {
      final f = File('$dbPath$sfx');
      if (await f.exists()) await f.delete();
    }

    await SqliteDatabase.instance.useDatabasePath(dbPath);
    final db = await SqliteDatabase.instance.database; // → _onCreate

    try {
      // Downtown — business default cohort, blends to 16.50 / 21.35.
      final dt = await db.query('wage_role_rows',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId]);
      expect(dt, isNotEmpty,
          reason: 'cold-boot must populate Downtown wage authority');
      expect(_blend(dt, 'foh'), closeTo(16.50, 1e-9));
      expect(_blend(dt, 'boh'), closeTo(21.35, 1e-9));

      // Riverside — location override cohort, blends to 17.50 / 22.35.
      final rv = await db.query('wage_role_rows',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.riversideRestaurantId]);
      expect(rv, isNotEmpty,
          reason: 'cold-boot must seed the Riverside wage override');
      expect(_blend(rv, 'foh'), closeTo(17.50, 1e-9));
      expect(_blend(rv, 'boh'), closeTo(22.35, 1e-9));

      // North Loop + Harbour — intentionally NO rows (inherit the
      // business default; HP #11 "inherited from Business" pill).
      for (final rid in const [
        DemoScope.northLoopRestaurantId,
        DemoScope.harbourRestaurantId,
      ]) {
        final rows = await db.query('wage_role_rows',
            where: 'restaurant_id = ?', whereArgs: [rid]);
        expect(rows, isEmpty,
            reason: '$rid intentionally inherits the business default '
                '(do not seed wage rows)');
      }

      // Cold-boot also lands the operational envelope: a locked plan
      // with per-period child rows exists without any reseed/advance.
      final children =
          await db.query('weekly_plan_snapshot_day_dayparts', limit: 1);
      expect(children, isNotEmpty,
          reason: 'cold-boot seeds the per-daypart child rows '
              '(the Item-5 dependency) on first launch');
    } finally {
      await SqliteDatabase.instance.close();
      for (final sfx in const ['', '-shm', '-wal']) {
        final f = File('$dbPath$sfx');
        if (await f.exists()) await f.delete();
      }
    }
  });
}
