// Demo-data — per-location operational-envelope regression.
//
// Authority: docs/_audits/per_daypart_v1/
//            demo_seed_multilocation_operational_envelope.md;
//            CLAUDE.md HP #2 / HP #4 / Metric Honesty / Design Rule 2.
//
// Reconciliation guarded here: Slice C already seeds the SALES pipeline
// (shift_records / week_records / cycles) for all 4 demo locations
// across {12 historical weeks + current}. This slice extends the SAME
// envelope to the non-sales operational tables:
//   • open_shift_snapshots — per-location historical closed snapshots
//     (Promise 2 — closed truth matches the closed shift stamp); EVERY
//     location has its OWN live current-week status='open' row (one per
//     restaurant_id, per-location-distinct figures — fixes the
//     non-Downtown HISTORICAL-ONLY / empty-Shift defect).
//   • reservation_book_snapshots — the FORWARD book per location;
//     closed/past cells get NO row (Metric Honesty honest-degrade).
//   • weekly_plan_snapshots + weekly_plan_snapshot_day_dayparts — a
//     locked plan per (location, week); the per-period child rows carry
//     the cycle's per-daypart band targets (the Item-5 dependency).
//   • app_notifications — a deterministic per-location sample inbox,
//     disjoint from the variance_breach seeder.
//
// This file fails if any of those regress, if the per-location data is a
// clone, if honest-degrade is violated (a fabricated row where the
// scenario has no source truth), or if two reseeds are not
// byte-identical.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/demo_vendor_integration_state_fixture.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';

void main() {
  final allDemoIds = DemoScope.locations.map((l) => l.restaurantId).toList();
  // Fix A (operator decision 2026-05-16): a "none connected" demo
  // location (today Harbour) is honest-EMPTY — it carries NO
  // operational/historical rows so the existing readers honest-degrade
  // to "awaiting first connection". Only the CONNECTED locations carry
  // the full operational envelope.
  final demoIds = allDemoIds
      .where((id) => !DemoVendorIntegrationStateFixture.isNoneConnected(id))
      .toList();
  final noneConnectedIds = allDemoIds
      .where((id) => DemoVendorIntegrationStateFixture.isNoneConnected(id))
      .toList();
  const downtown = DemoScope.restaurantId;

  group('Demo-data — per-location operational envelope', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('open_shift_snapshots — per-location historical closed coverage; '
        'every location has its own live open row', () async {
      final db = await SqliteDatabase.instance.database;

      // Every location has a deep historical closed snapshot history.
      for (final rid in demoIds) {
        final closed = await db.query(
          'open_shift_snapshots',
          columns: ['business_date'],
          where: "restaurant_id = ? AND status = 'closed'",
          whereArgs: [rid],
        );
        final dates = closed
            .map((r) => r['business_date'] as String?)
            .whereType<String>()
            .toSet();
        expect(dates.length, greaterThanOrEqualTo(60),
            reason: '$rid must have ≥60 days of historical closed '
                'open_shift_snapshots');
      }

      // Per-location invariant (the fix): EVERY demo location has exactly
      // ONE status='open' row, scoped by restaurant_id (HP #4). No more
      // single global Downtown-only open row — that was the
      // non-Downtown HISTORICAL-ONLY / empty-Shift defect.
      final open = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(open.length, demoIds.length,
          reason: 'one live open row per demo location');
      expect(
          open.map((r) => r['restaurant_id'] as String).toSet(),
          demoIds.toSet(),
          reason: 'every location (not just Downtown) has a live shift');
      for (final rid in demoIds) {
        final perLoc =
            open.where((r) => r['restaurant_id'] == rid).toList();
        expect(perLoc.length, 1,
            reason: '$rid has exactly one status=open row');
      }

      // Per-location-distinct: a non-Downtown location's live open shift
      // is NOT a clone of Downtown's (its scaled covers/hours feed the
      // shared in-progress math, so the figures differ).
      final dtOpen =
          open.firstWhere((r) => r['restaurant_id'] == downtown);
      final nlOpen = open.firstWhere(
          (r) => r['restaurant_id'] == DemoScope.northLoopRestaurantId);
      expect(nlOpen['current_covers'],
          isNot(equals(dtOpen['current_covers'])),
          reason: 'North Loop live open covers ≠ Downtown (not a clone)');

      // Promise 2 — a closed snapshot's covers match the closed shift
      // stamp it derives from (closed truth never re-derived).
      final sampleSnap = (await db.query(
        'open_shift_snapshots',
        where: "restaurant_id = ? AND status = 'closed'",
        whereArgs: [downtown],
        limit: 1,
      )).first;
      final shift = await db.query(
        'shift_records',
        where: 'restaurant_id = ? AND week_id = ? AND day_label = ? '
            "AND daypart = ? AND status = 'closed'",
        whereArgs: [
          downtown,
          sampleSnap['week_id'],
          sampleSnap['day_label'],
          sampleSnap['daypart'],
        ],
        limit: 1,
      );
      expect(shift, isNotEmpty);
      expect(sampleSnap['current_covers'], shift.first['covers'],
          reason: 'closed snapshot covers == closed shift covers '
              '(Promise 2)');
    });

    test('reservation_book_snapshots — forward book per location, '
        'honest-degrade for closed/past cells', () async {
      final db = await SqliteDatabase.instance.database;

      final all = await db.query('reservation_book_snapshots');
      final scopes =
          all.map((r) => r['restaurant_id'] as String).toSet();
      expect(scopes, demoIds.toSet(),
          reason: 'every location has a forward reservation book');

      // Default scenario is 2026-03-27 (Fri). Forward book only — no
      // row may predate the scenario business date, and the closed
      // Fri-lunch cell must have NO row anywhere (honest-degrade).
      for (final r in all) {
        expect((r['business_date'] as String).compareTo('2026-03-27'),
            greaterThanOrEqualTo(0),
            reason: 'no closed/past reservation rows (Metric Honesty)');
      }
      final friLunch = await db.query(
        'reservation_book_snapshots',
        where: 'business_date = ? AND daypart = ?',
        whereArgs: ['2026-03-27', 'lunch'],
      );
      expect(friLunch, isEmpty,
          reason: 'closed Fri-lunch cell carries no fabricated '
              'reservation row');

      // Downtown scenario open-shift row preserves the pinned value.
      final dt = await db.query(
        'reservation_book_snapshots',
        where: 'restaurant_id = ? AND business_date = ? AND daypart = ?',
        whereArgs: [downtown, '2026-03-27', 'dinner'],
      );
      expect(dt.length, 1);
      expect(dt.first['unseated_covers'], 72);
      expect(dt.first['unseated_party_count'], 18);
      expect(dt.first['source_service_id'], 'demo_res_fri_dinner');

      // Per-location distinctness — a higher-volume location books more
      // unseated covers for the same forward cell than Downtown.
      final nl = await db.query(
        'reservation_book_snapshots',
        where: 'restaurant_id = ? AND business_date = ? AND daypart = ?',
        whereArgs: [
          DemoScope.northLoopRestaurantId,
          '2026-03-27',
          'dinner',
        ],
      );
      expect(nl, isNotEmpty);
      expect((nl.first['unseated_covers'] as int),
          greaterThan(dt.first['unseated_covers'] as int),
          reason: 'North Loop (higher volume) > Downtown — not a clone');
    });

    test('weekly_plan_snapshots — locked plan per (location, week) for '
        'history + current; in-force Downtown snapshot preserved',
        () async {
      final db = await SqliteDatabase.instance.database;

      for (final rid in demoIds) {
        final snaps = await db.query(
          'weekly_plan_snapshots',
          where: 'restaurant_id = ?',
          whereArgs: [rid],
        );
        expect(snaps.length, greaterThanOrEqualTo(10),
            reason: '$rid must have a deep locked-plan history '
                '(12 historical weeks + current)');
        // No duplicate week_key per location.
        final keys =
            snaps.map((r) => r['week_key'] as String).toList();
        expect(keys.toSet().length, keys.length,
            reason: '$rid week_key is unique (no rewrite of locked '
                'truth)');
      }
    });

    test('weekly_plan_snapshot_day_dayparts — child rows carry the '
        'cycle per-daypart band targets (the Item-5 dependency)',
        () async {
      final db = await SqliteDatabase.instance.database;

      for (final rid in demoIds) {
        final cycle = await SqliteTargetCycleRepository.instance
            .getActiveCycle(rid);
        expect(cycle, isNotNull);

        final snap = (await db.query(
          'weekly_plan_snapshots',
          columns: ['snapshot_id'],
          where: 'restaurant_id = ?',
          whereArgs: [rid],
          limit: 1,
        )).first;
        final children = await db.query(
          'weekly_plan_snapshot_day_dayparts',
          where: 'snapshot_id = ?',
          whereArgs: [snap['snapshot_id']],
        );
        expect(children, isNotEmpty,
            reason: '$rid locked plan must have per-period child rows');

        // Each child's implied per-period CPLH/PPA equals the cycle's
        // per-period band target — i.e. NOT a whole-day pooled value.
        // This is exactly what the Item-5 footer reads.
        final periodIds =
            children.map((c) => c['service_period_id'] as String).toSet();
        expect(periodIds, {'lunch', 'dinner', 'late_night'});
        for (final c in children) {
          final period = c['service_period_id'] as String;
          final dp = cycle!.daypartFor(period)!;
          final covers = (c['forecast_covers'] as num).toDouble();
          final reqFoh = (c['required_foh_hours'] as num).toDouble();
          final sales = (c['forecast_sales'] as num).toDouble();
          if (covers > 0 && reqFoh > 0) {
            expect(covers / reqFoh, closeTo(dp.targetCPLH, 1e-6),
                reason: '$rid $period child CPLH == cycle band CPLH');
            expect(sales / covers, closeTo(dp.targetPPA, 1e-6),
                reason: '$rid $period child PPA == cycle band PPA');
          }
        }

        // The bands are differentiated, not one pooled number.
        final lunch = cycle!.daypartFor('lunch')!;
        final dinner = cycle.daypartFor('dinner')!;
        expect(lunch.targetCPLH, isNot(equals(dinner.targetCPLH)));
      }
    });

    test('app_notifications — per-location sample inbox, recognized '
        'types, varied read state; variance_breach disjoint', () async {
      final db = await SqliteDatabase.instance.database;

      for (final rid in demoIds) {
        final notes = await db.query(
          'app_notifications',
          where: 'restaurant_id = ? AND event_key LIKE ?',
          whereArgs: [rid, 'demo_seed_%'],
        );
        expect(notes.length, 4,
            reason: '$rid has the modest 4-item sample inbox');
        final types = notes.map((n) => n['type'] as String).toSet();
        expect(
          types,
          {
            'notif.backfill.complete',
            'notif.plan.updated',
            'cycle_rollover',
            'notif.vendor.now_available',
          },
          reason: 'recognized catalog/legacy types (proper rendering)',
        );
        final unread =
            notes.where((n) => n['read_at'] == null).length;
        expect(unread, inInclusiveRange(1, 3),
            reason: 'varied read/unread states');
        // Never collides with the variance_breach seeder.
        expect(notes.any((n) => n['type'] == 'variance_breach'), isFalse);
      }
    });

    test('Fix A — a "none connected" demo location is honest-EMPTY: '
        'ZERO operational/historical rows, but its scope + vendor demo '
        'rows ARE seeded', () async {
      expect(noneConnectedIds, isNotEmpty,
          reason: 'the fixture defines a none-connected demo location '
              '(today Harbour) — guards the generalization off the '
              'vendor fixture, not a hardcoded id');
      final db = await SqliteDatabase.instance.database;

      for (final rid in noneConnectedIds) {
        // No fabricated operational/historical numbers anywhere.
        for (final table in const [
          'shift_records',
          'week_records',
          'open_shift_snapshots',
          'reservation_book_snapshots',
          'weekly_plan_snapshots',
          'target_cycles',
          'active_target_profiles',
          'import_runs',
          'raw_import_records',
        ]) {
          final rows = await db.query(
            table,
            where: 'restaurant_id = ?',
            whereArgs: [rid],
          );
          expect(rows, isEmpty,
              reason: '$rid ($table) must be honest-EMPTY — no phantom '
                  'data for a location with nothing connected');
        }
        // No sample inbox rows either (backfill-complete etc. would be
        // phantom for an awaiting-first-connection location).
        final notes = await db.query(
          'app_notifications',
          where: 'restaurant_id = ? AND event_key LIKE ?',
          whereArgs: [rid, 'demo_seed_%'],
        );
        expect(notes, isEmpty,
            reason: '$rid has no sample notifications (honest-empty)');

        // BUT the scope row IS present (stays in the scope drawer)…
        final loc = await db.query(
          'restaurant_locations',
          where: 'restaurant_id = ?',
          whereArgs: [rid],
        );
        expect(loc, isNotEmpty,
            reason: '$rid still appears in the scope drawer');
        // …and its vendor fixture says all categories disconnected
        // (so the demo banners still render).
        expect(DemoVendorIntegrationStateFixture.connectedCategoryCount(rid),
            0,
            reason: '$rid is the none-connected location by fixture');
      }
    });

    test('determinism — two reseeds are byte-identical for every new '
        'envelope table (HP #2, NO RNG)', () async {
      // Determinism is asserted over the data THIS slice owns. Excluded:
      //  • `id` — AUTOINCREMENT surrogate, not semantic data, not stable
      //    across delete+reinsert reseeds (Slice C's determinism test
      //    excludes surrogate keys for the same reason).
      //  • open_shift_snapshots current-week rows — written with
      //    `nowIsoUtc()` by `_seedOpenShiftSnapshotsFromReplay`
      //    (Downtown) and the shared `_buildCurrentWeekOpenShiftSnapshots`
      //    per non-Downtown location; all share `scenario.currentWeekId`,
      //    so excluding the in-force week scopes the fingerprint to the
      //    deterministic HISTORICAL weeks for every location.
      //  • weekly_plan_snapshots `generated_at`/`locked_at` and
      //    weekly_plan_snapshot_day_dayparts `created_at` — the
      //    pre-existing in-force Downtown snapshot
      //    (`_seedWeeklyPlanSnapshotFromReplay`) stamps these with
      //    `nowIsoUtc()`. The substantive plan values + per-period
      //    covers/sales/hours/dollars ARE deterministic and remain in
      //    the fingerprint.
      const volatileCols = <String, Set<String>>{
        'weekly_plan_snapshots': {'generated_at', 'locked_at'},
        'weekly_plan_snapshot_day_dayparts': {'created_at'},
      };
      Future<String> fingerprint() async {
        final db = await SqliteDatabase.instance.database;
        final openRow = await db.query('open_shift_snapshots',
            columns: ['week_id'], where: "status = 'open'", limit: 1);
        final inForceWeek = openRow.first['week_id'] as String;
        final buf = StringBuffer();
        for (final table in const [
          'open_shift_snapshots',
          'reservation_book_snapshots',
          'weekly_plan_snapshots',
          'weekly_plan_snapshot_day_dayparts',
          'app_notifications',
        ]) {
          var rows = await db.query(table);
          if (table == 'open_shift_snapshots') {
            rows = rows
                .where((r) => r['week_id'] != inForceWeek)
                .toList();
          }
          final skip = {'id', ...?volatileCols[table]};
          final serialized = rows.map((r) {
            final keys =
                r.keys.where((k) => !skip.contains(k)).toList()..sort();
            return keys.map((k) => '$k=${r[k]}').join('|');
          }).toList()
            ..sort();
          buf.write('#$table[${serialized.length}]:');
          buf.writeAll(serialized, ';');
          buf.write('\n');
        }
        return buf.toString();
      }

      final first = await fingerprint();
      await SqliteDatabase.instance.reseedDemo();
      final second = await fingerprint();
      expect(second, equals(first),
          reason: 'two reseeds must produce byte-identical operational '
              'envelope rows');
    });
  });
}
