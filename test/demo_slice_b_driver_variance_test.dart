// Demo-data Slice B — driver variance overhaul regression tests.
//
// Authority: docs/_audits/per_daypart_v1/full_demo_data_spec.md
//            §2a (16-lever distribution), §2b (per-period
//            differentiation), §2d (60+ day variance); CLAUDE.md HP #2.
//
// Guards the TWO operator-visible defects this slice fixes (same root —
// a flat seed):
//   1. Benchmark Daypart Breakdown showed identical lunch/dinner/
//      late_night targets because the seeded closed cohort had
//      near-uniform productivity across periods, so
//      `recommendation.perDaypartStats` came back ≈ equal.
//   2. "All covers covers covers" — every shift's primary driver
//      collapsed to `covers_*` / the empty-candidate `covers_down`
//      fallback because the seed only moved covers + PPA and held
//      wages / CPLH / SPLH / hours at target.
//
// Plus the hard determinism invariant (no RNG — all variation derived
// from week/day/period indices) and the wage-waterfall exercise (§2g).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_wage_role_row_repository.dart';
import 'package:forge_and_flow/models/shift_record.dart';

/// Maps a normalized lever id to its 8-family axis:
/// `covers_down` → `covers`, `foh_wage_up` → `foh_wage`,
/// `boh_hours_over` → `boh_hours`, `cplh_down` → `cplh`, …
String _leverFamily(String leverId) {
  const directions = {'up', 'down', 'over', 'under'};
  final parts = leverId.split('_');
  if (parts.length > 1 && directions.contains(parts.last)) {
    return parts.sublist(0, parts.length - 1).join('_');
  }
  return leverId;
}

void main() {
  group('Slice B — §2a 16-lever driver distribution (the "all covers" fix)',
      () {
    test(
        'closed cohort spans ≥6 lever families AND covers_down share ≤ 50%',
        () {
      final closed =
          MockIntegrationReplaySeed.output.historicalClosedShifts;
      expect(closed, isNotEmpty);

      final families = <String>{};
      var coversDown = 0;
      for (final s in closed) {
        final id = s.normalizedLeverId;
        families.add(_leverFamily(id));
        if (id == 'covers_down') coversDown++;
      }

      expect(
        families.length,
        greaterThanOrEqualTo(6),
        reason: 'driver mix must span ≥6 of the 16-lever families '
            '(was effectively 1: covers). Got: $families',
      );

      final coversDownShare = coversDown / closed.length;
      expect(
        coversDownShare,
        lessThanOrEqualTo(0.50),
        reason: 'covers_down must no longer be the >50% degenerate mass '
            '(share=$coversDownShare)',
      );

      // The fix also engineers the recurring per-(day,period) cells the
      // Learn analyzer needs (§2e): Fri dinner is always ppa_down, Tue
      // lunch always ppa_up. Assert the recurrence so a Slice D
      // regression here is caught early.
      final friDinner = closed
          .where((s) => s.dayLabel == 'Fri' && s.daypart == 'dinner');
      expect(friDinner, isNotEmpty);
      expect(
        friDinner.every((s) => s.normalizedLeverId == 'ppa_down'),
        isTrue,
        reason: 'Fri dinner must be a recurring ppa_down leak (§2e)',
      );
      final tueLunch = closed
          .where((s) => s.dayLabel == 'Tue' && s.daypart == 'lunch');
      expect(tueLunch, isNotEmpty);
      expect(
        tueLunch.every((s) => s.normalizedLeverId == 'ppa_up'),
        isTrue,
        reason: 'Tue lunch must be a recurring ppa_up benchmark (§2e)',
      );
    });

    test('§2d — ≥10 historical weeks of non-flat week-to-week variance',
        () {
      final out = MockIntegrationReplaySeed.output;
      expect(
        out.weekRecords.length,
        greaterThanOrEqualTo(10),
        reason: '§2d requires ≥10–12 historical weeks for non-flat '
            'Variance/History',
      );

      // Week-to-week dollar gaps must genuinely vary (not a flat line).
      final gaps = out.weekRecords.map((w) => w.dollarGap).toSet();
      expect(
        gaps.length,
        greaterThan(out.weekRecords.length ~/ 2),
        reason: 'weekly dollar gaps must be non-flat across history',
      );
    });
  });

  group('Slice B — §2b end-to-end per-period target unlock', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test(
        'demo active cycle per-period CPLH/SPLH/PPA are materially '
        'different across lunch/dinner/late_night (Benchmark Daypart '
        'Breakdown will no longer show identical rows)', () async {
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(DemoScope.restaurantId);
      expect(cycle, isNotNull);

      final lunch = cycle!.daypartFor('lunch')!;
      final dinner = cycle.daypartFor('dinner')!;
      final lateNight = cycle.daypartFor('late_night')!;

      // CPLH: pairwise margin large enough to render distinctly in
      // Benchmark (the prompt's acceptance example: ≥ 0.2 CPLH).
      expect((lunch.targetCPLH - dinner.targetCPLH).abs(),
          greaterThanOrEqualTo(0.20),
          reason: 'lunch vs dinner CPLH must differ visibly');
      expect((dinner.targetCPLH - lateNight.targetCPLH).abs(),
          greaterThanOrEqualTo(0.20),
          reason: 'dinner vs late_night CPLH must differ visibly');
      expect((lunch.targetCPLH - lateNight.targetCPLH).abs(),
          greaterThanOrEqualTo(0.20),
          reason: 'lunch vs late_night CPLH must differ visibly');

      // SPLH: per-period base 165 / 200 / 150 → wide separation.
      expect((lunch.targetSPLH - dinner.targetSPLH).abs(),
          greaterThanOrEqualTo(5.0));
      expect((dinner.targetSPLH - lateNight.targetSPLH).abs(),
          greaterThanOrEqualTo(5.0));
      expect((lunch.targetSPLH - lateNight.targetSPLH).abs(),
          greaterThanOrEqualTo(5.0));

      // PPA: per-period base 40.5 / 43 / 38.5.
      expect((lunch.targetPPA - dinner.targetPPA).abs(),
          greaterThanOrEqualTo(0.50));
      expect((dinner.targetPPA - lateNight.targetPPA).abs(),
          greaterThanOrEqualTo(0.50));
      expect((lunch.targetPPA - lateNight.targetPPA).abs(),
          greaterThanOrEqualTo(0.50));
    });

    test(
        'parent whole-day scalars remain the cover-weighted rollup of '
        'the per-period rows (Design Rule 4 — no pool regression)',
        () async {
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(DemoScope.restaurantId);
      final pool =
          TargetCycleDaypartPool.fromDayparts(cycle!.dayparts);
      expect(cycle.targetCPLH, closeTo(pool.targetCPLH, 1e-9));
      expect(cycle.targetSPLH, closeTo(pool.targetSPLH, 1e-9));
      expect(cycle.targetPPA, closeTo(pool.targetPPA, 1e-9));
      expect(cycle.opzFloorCPLH, closeTo(pool.opzFloorCPLH, 1e-9));
      expect(cycle.opzCeilingCPLH, closeTo(pool.opzCeilingCPLH, 1e-9));
    });

    test(
        '§2g/G7 — cycle blended wage comes from seeded wage_role_rows '
        '(production waterfall), not the MeridianConfig fallback',
        () async {
      // Force the clean cold-start path deterministically: clear any
      // wage rows (operator authority safe — the seed only populates
      // when empty, HP #11) then reseed so the demo cohort is the
      // wage source under test.
      await SqliteWageRoleRowRepository.instance
          .deleteAll(DemoScope.restaurantId);
      await SqliteDatabase.instance.reseedDemo();

      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('wage_role_rows',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId]);
      expect(rows, isNotEmpty,
          reason: 'demo wage_role_rows must be seeded so the wage '
              'waterfall is exercised');
      expect(rows.any((r) => r['labor_bucket'] == 'foh'), isTrue);
      expect(rows.any((r) => r['labor_bucket'] == 'boh'), isTrue);

      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(DemoScope.restaurantId);
      // Weighted blends are tuned to the MeridianConfig wages so the
      // cycle scalars are unchanged while the waterfall path is now
      // real role-row evidence.
      expect(cycle!.fohWage, closeTo(16.50, 1e-6));
      expect(cycle.bohWage, closeTo(21.35, 1e-6));
    });
  });

  group('Slice B — determinism (hard invariant: no RNG)', () {
    test('two generator runs produce a byte-identical closed cohort', () {
      final a = MockIntegrationReplaySeed.generateForDate(
          MockIntegrationReplaySeed.defaultBusinessDate);
      final b = MockIntegrationReplaySeed.generateForDate(
          MockIntegrationReplaySeed.defaultBusinessDate);

      expect(a.historicalClosedShifts.length,
          b.historicalClosedShifts.length);
      for (var i = 0; i < a.historicalClosedShifts.length; i++) {
        expect(
          a.historicalClosedShifts[i].toMap().toString(),
          b.historicalClosedShifts[i].toMap().toString(),
          reason: 'closed shift #$i must be identical across runs',
        );
      }
      for (var i = 0; i < a.currentWeekShifts.length; i++) {
        expect(
          a.currentWeekShifts[i].toMap().toString(),
          b.currentWeekShifts[i].toMap().toString(),
        );
      }
    });

    test('two DB reseeds produce identical persisted shift_records', () async {
      await SqliteDatabase.instance.reseedDemo();
      final db = await SqliteDatabase.instance.database;
      // Read the closed cohort ordered deterministically.
      final first = await db.query('shift_records',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId],
          orderBy: 'business_date, daypart');
      final firstKeys = first
          .map((r) => '${r['business_date']}|${r['daypart']}|'
              '${r['covers']}|${r['cplh']}|${r['splh']}|${r['ppa']}|'
              '${r['primary_lever']}|${r['scheduled_foh_hours']}|'
              '${r['scheduled_boh_hours']}|${r['foh_labor_dollar']}|'
              '${r['boh_labor_dollar']}')
          .toList();

      await SqliteDatabase.instance.reseedDemo();
      final second = await db.query('shift_records',
          where: 'restaurant_id = ?',
          whereArgs: [DemoScope.restaurantId],
          orderBy: 'business_date, daypart');
      final secondKeys = second
          .map((r) => '${r['business_date']}|${r['daypart']}|'
              '${r['covers']}|${r['cplh']}|${r['splh']}|${r['ppa']}|'
              '${r['primary_lever']}|${r['scheduled_foh_hours']}|'
              '${r['scheduled_boh_hours']}|${r['foh_labor_dollar']}|'
              '${r['boh_labor_dollar']}')
          .toList();

      expect(secondKeys, equals(firstKeys),
          reason: 'reseed must be byte-identical — no RNG');
      // Sanity: also assert ShiftRecord round-trips cleanly.
      expect(
        ShiftRecord.fromMap(second.first).daypart,
        second.first['daypart'],
      );
    });
  });
}
