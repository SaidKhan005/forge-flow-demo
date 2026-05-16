// Demo-data Slice C — per-location closed history + cycles regression.
//
// Authority: docs/_audits/per_daypart_v1/full_demo_data_spec.md (Slice C
//            + §2c per-location requirements); CLAUDE.md HP #2 / HP #4.
//
// What this guards: before Slice C the rich demo cohort (≥60d closed
// shifts, week_records, an active TargetCycle + per-period dayparts) was
// seeded for Downtown only. The other three §2c locations were empty
// shells, so the scope drawer / multi-location surfaces rendered
// trivial/empty. This file fails if:
//   (a) any of the 4 demo locations is not demo-complete,
//   (b) the 4 locations are clones (not materially distinct),
//   (c) Design Rule 4 (pool == cover-weighted Σ per-period) regresses,
//   (d) per-(operator,location) isolation leaks (HP #4),
//   (e) two reseeds are not byte-identical (determinism / NO RNG),
//   (f) Slice B's per-shift driver-mix is not preserved per location.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';

void main() {
  final demoIds =
      DemoScope.locations.map((l) => l.restaurantId).toList();
  final newIds = demoIds.skip(1).toList(); // North Loop / Riverside / Harbour

  group('Demo-data Slice C — per-location operational data', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('all 4 demo locations are demo-complete '
        '(≥60d closed shifts + active cycle + per-period dayparts)',
        () async {
      final db = await SqliteDatabase.instance.database;
      for (final rid in demoIds) {
        final closed = await db.query(
          'shift_records',
          columns: ['business_date'],
          where: 'restaurant_id = ? AND status = ?',
          whereArgs: [rid, 'closed'],
        );
        final distinctDates = closed
            .map((r) => r['business_date'] as String?)
            .whereType<String>()
            .toSet();
        expect(distinctDates.length, greaterThanOrEqualTo(60),
            reason: '$rid must have ≥60 days of closed shifts');

        final weeks = await db.query('week_records',
            where: 'restaurant_id = ?', whereArgs: [rid]);
        expect(weeks.length, greaterThanOrEqualTo(9),
            reason: '$rid must have a populated week history');

        final cycle = await SqliteTargetCycleRepository.instance
            .getActiveCycle(rid);
        expect(cycle, isNotNull,
            reason: '$rid must have an active target cycle');
        expect(
          cycle!.dayparts.map((d) => d.servicePeriodId).toSet(),
          {'lunch', 'dinner', 'late_night'},
          reason: '$rid cycle must carry differentiated per-period rows',
        );
      }
    });

    test('Design Rule 4 — each location\'s whole-day scalars are the '
        'cover-weighted Σ of its per-period rows', () async {
      for (final rid in demoIds) {
        final cycle = await SqliteTargetCycleRepository.instance
            .getActiveCycle(rid);
        final pool = TargetCycleDaypartPool.fromDayparts(cycle!.dayparts);
        expect(cycle.targetCPLH, closeTo(pool.targetCPLH, 1e-9),
            reason: '$rid CPLH pool rollup');
        expect(cycle.targetSPLH, closeTo(pool.targetSPLH, 1e-9),
            reason: '$rid SPLH pool rollup');
        expect(cycle.targetPPA, closeTo(pool.targetPPA, 1e-9),
            reason: '$rid PPA pool rollup');
        expect(cycle.opzFloorCPLH, closeTo(pool.opzFloorCPLH, 1e-9));
        expect(cycle.opzCeilingCPLH, closeTo(pool.opzCeilingCPLH, 1e-9));
      }
    });

    test('the 4 locations are materially distinct, not clones '
        '(per-period CPLH/SPLH/PPA + volume pairwise differ)', () async {
      final db = await SqliteDatabase.instance.database;
      final cycles = <String, TargetCycle>{};
      final coverVolume = <String, int>{};
      for (final rid in demoIds) {
        cycles[rid] = (await SqliteTargetCycleRepository.instance
            .getActiveCycle(rid))!;
        final rows = await db.rawQuery(
          'SELECT SUM(total_covers) AS c FROM week_records '
          'WHERE restaurant_id = ?',
          [rid],
        );
        coverVolume[rid] = (rows.first['c'] as num).toInt();
      }

      for (final period in ['lunch', 'dinner', 'late_night']) {
        for (var a = 0; a < demoIds.length; a++) {
          for (var b = a + 1; b < demoIds.length; b++) {
            final da =
                cycles[demoIds[a]]!.daypartFor(period)!;
            final dbp =
                cycles[demoIds[b]]!.daypartFor(period)!;
            final rel = (da.targetCPLH - dbp.targetCPLH).abs() /
                da.targetCPLH;
            expect(rel, greaterThan(0.01),
                reason: '$period CPLH for ${demoIds[a]} vs '
                    '${demoIds[b]} must differ ≥1% (not a clone)');
            expect(da.targetPPA, isNot(equals(dbp.targetPPA)),
                reason: '$period PPA ${demoIds[a]} vs ${demoIds[b]}');
            expect(da.targetSPLH, isNot(equals(dbp.targetSPLH)),
                reason: '$period SPLH ${demoIds[a]} vs ${demoIds[b]}');
          }
        }
      }

      // Volume profile pairwise material difference.
      for (var a = 0; a < demoIds.length; a++) {
        for (var b = a + 1; b < demoIds.length; b++) {
          final va = coverVolume[demoIds[a]]!;
          final vb = coverVolume[demoIds[b]]!;
          final rel = (va - vb).abs() / va;
          expect(rel, greaterThan(0.05),
              reason: 'cover volume ${demoIds[a]} vs ${demoIds[b]} '
                  'must differ ≥5%');
        }
      }
    });

    test('per-(operator,location) isolation — no cross-location rows '
        '(HP #4)', () async {
      final db = await SqliteDatabase.instance.database;
      for (final table in ['shift_records', 'week_records']) {
        final rows = await db.rawQuery(
            'SELECT DISTINCT restaurant_id AS r FROM $table');
        final ids = rows.map((m) => m['r'] as String).toSet();
        expect(ids, equals(demoIds.toSet()),
            reason: '$table must contain exactly the 4 demo '
                'locations and never cross-write');
      }
      // Each new location owns its own cycle id (no shared/cloned id).
      final cycleIds = <String>{};
      for (final rid in demoIds) {
        final c = await SqliteTargetCycleRepository.instance
            .getActiveCycle(rid);
        expect(c!.restaurantId, rid);
        cycleIds.add(c.cycleId);
      }
      expect(cycleIds.length, demoIds.length,
          reason: 'every location has its own cycle row');
    });

    test('Slice B driver-mix preserved per location — each new '
        'location\'s closed primary_lever multiset == Downtown\'s',
        () async {
      final db = await SqliteDatabase.instance.database;

      Future<Map<String, int>> leverMix(String rid) async {
        final rows = await db.query(
          'shift_records',
          columns: ['primary_lever'],
          where: 'restaurant_id = ? AND status = ?',
          whereArgs: [rid, 'closed'],
        );
        final m = <String, int>{};
        for (final r in rows) {
          final k = r['primary_lever'] as String;
          m[k] = (m[k] ?? 0) + 1;
        }
        return m;
      }

      final downtown = await leverMix(DemoScope.restaurantId);
      // Slice B engineers ≥6 lever families across the cohort; the
      // per-location scaling keeps every tilt below the determineLever
      // thresholds, so the mix must be preserved verbatim.
      expect(downtown.keys.length, greaterThanOrEqualTo(6),
          reason: 'Downtown Slice B cohort spans ≥6 lever ids');
      for (final rid in newIds) {
        expect(await leverMix(rid), equals(downtown),
            reason: '$rid must preserve Slice B\'s exact driver-mix');
      }
    });

    test('determinism — two reseeds are byte-identical for all 4 '
        'locations (NO RNG)', () async {
      Future<String> fingerprint() async {
        final db = await SqliteDatabase.instance.database;
        final buf = StringBuffer();
        for (final rid in demoIds) {
          final shifts = await db.query(
            'shift_records',
            where: 'restaurant_id = ?',
            whereArgs: [rid],
            orderBy: 'week_id, day_label, daypart, status',
          );
          for (final s in shifts) {
            buf.write('${s['week_id']}|${s['day_label']}|'
                '${s['daypart']}|${s['status']}|${s['covers']}|'
                '${s['cplh']}|${s['splh']}|${s['ppa']}|'
                '${s['primary_lever']}|${s['target_cplh']};');
          }
          final cycle = await SqliteTargetCycleRepository.instance
              .getActiveCycle(rid);
          for (final d in cycle!.dayparts) {
            buf.write('C:${d.servicePeriodId}:${d.targetCPLH}:'
                '${d.targetSPLH}:${d.targetPPA};');
          }
        }
        return buf.toString();
      }

      final first = await fingerprint();
      await SqliteDatabase.instance.reseedDemo();
      final second = await fingerprint();
      expect(second, equals(first),
          reason: 'two reseeds must produce identical shift/cycle data');
    });
  });
}
