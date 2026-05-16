// QA fix — demo open-shift derives from the restaurant-local clock (was
// hardcoded Dinner/7:45 PM) + weekends now serve Lunch.
//
// Authority: this slice's prompt; CLAUDE.md HP #2 (writer-side switch —
// no kDemoMode reader branch, no demo_* table), Metric Honesty / Design
// Rule 2, Time Guardrails. The defect (device-reproduced 2026-05-16,
// Sat ~09:25): the seed hardcoded `openShiftDaypart='dinner'` with a
// fabricated `0.63` / `7:45 PM` / `3h 15m` mid-service snapshot that
// never consulted the clock, so Dinner always showed the location's
// WHOLE-DAY total as "live" even before Dinner opened — and Sat/Sun had
// NO Lunch slot, so a Saturday's only actuals were the one open-Dinner
// row and Whole-Day collapsed to ≡ Dinner.
//
// Change A: the open period is derived from the restaurant-local clock
// at seed time (injectable via `SqliteDatabase.debugColdBootNowOverride`
// so tests pin BOTH date AND time-of-day; demo/device use the real
// clock). Change B: Sat AND Sun serve a Lunch like a real restaurant.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/dev/demo_vendor_integration_state_fixture.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Fix A: the "none connected" location (today Harbour) is honest-empty;
  // open-shift assertions apply only to CONNECTED demo locations.
  final demoIds = DemoScope.locations
      .map((l) => l.restaurantId)
      .where((id) => !DemoVendorIntegrationStateFixture.isNoneConnected(id))
      .toList();

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('openclock_');
  });

  tearDown(() async {
    SqliteDatabase.debugColdBootNowOverride = null;
    SqliteDatabase.debugColdBootTodayOverride = null;
    await SqliteDatabase.instance.close();
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
  });

  // True cold boot: a fresh DB path runs `_onCreate` → the
  // today/now-anchored demo seed end-to-end.
  Future<void> coldBoot(String injectedNow) async {
    SqliteDatabase.debugColdBootNowOverride = injectedNow;
    await SqliteDatabase.instance.useDatabasePath(
      p.join(tmpDir.path, 'cb_${injectedNow.replaceAll(':', '-')}.db'),
    );
    await SqliteDatabase.instance.database; // first access → _onCreate
  }

  // ── A. Open period follows the restaurant-local clock ──────────────────

  group('A — open period is clock-derived (Change A)', () {
    test(
        'Sat 09:25 (before Lunch) → resolver stays honest (null) but '
        'Fix B seeds the UPCOMING period (Lunch) as the open shift; '
        'whole-day ≠ a single period row', () async {
      // 2026-05-16 is a Saturday; 09:25 is before Lunch (11:00).
      await coldBoot('2026-05-16T09:25:00');

      // The pure resolver is UNCHANGED — it still honestly reports no
      // period in progress at 09:25 (Fix B never touched it).
      final res = resolveDemoOpenPeriod(
        localNow: DateTime(2026, 5, 16, 9, 25),
      );
      expect(res.openDaypart, isNull,
          reason: 'resolveDemoOpenPeriod stays honest — 09:25 Sat is '
              'before Lunch, nothing is in progress');

      final db = await SqliteDatabase.instance.database;

      // Fix B (operator decision 2026-05-16): the Shift home must never
      // be blank. With no period live, the seeder presents the UPCOMING
      // period (Lunch — earliest start ahead of 09:25) as the open shift.
      final open = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(open.map((r) => r['restaurant_id']).toSet(), demoIds.toSet(),
          reason: 'one live open row per CONNECTED demo location — the '
              'demo Shift home is never blank');
      for (final r in open) {
        expect(r['day_label'], 'Sat');
        expect(r['daypart'], 'lunch',
            reason: 'the upcoming period (Lunch) is presented as the '
                'demo live shift when nothing is genuinely in progress');
      }

      for (final rid in demoIds) {
        final satRows = await db.query(
          'open_shift_snapshots',
          where: "restaurant_id = ? AND day_label = 'Sat'",
          whereArgs: [rid],
        );
        final byPart = {
          for (final r in satRows)
            r['daypart'] as String: r['status'] as String,
        };
        expect(byPart['lunch'], 'open',
            reason: '$rid Sat Lunch is the Fix B fallback open shift');
        expect(byPart['dinner'], 'projected',
            reason: '$rid Sat Dinner has NOT occurred — projected');
        expect(byPart['late_night'], 'projected',
            reason: '$rid Sat LateNight is forecast-only at 09:25');

        // Whole-day ≠ a single period row: the open Lunch covers are
        // strictly less than the Σ of the Saturday periods (the
        // arithmetic identity that produced the original defect is gone).
        final dinner = satRows.firstWhere((r) => r['daypart'] == 'dinner');
        final dinnerCovers = dinner['forecast_covers'] as int;
        final satTotal = satRows.fold<int>(
            0, (s, r) => s + (r['forecast_covers'] as int));
        expect(dinnerCovers, lessThan(satTotal),
            reason: '$rid whole-day Saturday is the Σ of Lunch + Dinner '
                '+ LateNight, never ≡ a single period alone');
        expect(satRows.length, greaterThanOrEqualTo(3),
            reason: '$rid Saturday now serves ≥3 periods incl. Lunch');
      }
    });

    test(
        'Sat 19:45 → Dinner is the single open shift (clock-derived '
        'progress); Lunch closed, LateNight projected', () async {
      await coldBoot('2026-05-16T19:45:00');

      final res = resolveDemoOpenPeriod(
        localNow: DateTime(2026, 5, 16, 19, 45),
      );
      expect(res.openDaypart, 'dinner');
      expect(res.currentDayClosedPeriods, contains('lunch'),
          reason: 'Lunch (ends 15:00) already closed by 19:45');
      // Dinner 17:00–23:00: 165 of 360 min elapsed.
      expect(res.openProgressFraction, closeTo(165 / 360, 0.001));
      expect(res.openTimeLabel, '7:45 PM');
      expect(res.openServiceElapsedLabel, '2h 45m into service');

      final db = await SqliteDatabase.instance.database;

      // Exactly one open row per location, all Sat dinner.
      final open = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(
          open.map((r) => r['restaurant_id']).toSet(), demoIds.toSet(),
          reason: 'one live open row per demo location');
      for (final r in open) {
        expect(r['day_label'], 'Sat');
        expect(r['daypart'], 'dinner');
        expect(r['business_date'], '2026-05-16');
        expect(r['time_label'], '7:45 PM');
        expect((r['current_covers'] as int),
            lessThan(r['forecast_covers'] as int),
            reason: 'mid-service: current covers are the clock-derived '
                'fraction of forecast, not the whole forecast');
      }

      for (final rid in demoIds) {
        final satRows = await db.query(
          'open_shift_snapshots',
          where: "restaurant_id = ? AND day_label = 'Sat'",
          whereArgs: [rid],
        );
        final byPart = {
          for (final r in satRows)
            r['daypart'] as String: r['status'] as String,
        };
        expect(byPart['lunch'], 'closed',
            reason: '$rid Sat Lunch already ended by 19:45');
        expect(byPart['dinner'], 'open');
        expect(byPart['late_night'], 'projected',
            reason: '$rid Sat LateNight has not opened yet at 19:45');
      }
    });
  });

  // ── B. Weekends serve Lunch (Change B) ─────────────────────────────────

  group('B — weekends serve Lunch (Change B)', () {
    test(
        'Sat AND Sun have a Lunch slot, per-location-distinct covers, '
        'pool-consistent locked plan + per-period targets', () async {
      await coldBoot('2026-05-16T19:45:00');
      final db = await SqliteDatabase.instance.database;

      // shift_records: Sat AND Sun Lunch exist with covers > 0.
      for (final day in ['Sat', 'Sun']) {
        final lunch = await db.query(
          'shift_records',
          where: 'restaurant_id = ? AND day_label = ? AND daypart = ?',
          whereArgs: [DemoScope.restaurantId, day, 'lunch'],
        );
        expect(lunch, isNotEmpty,
            reason: '$day now serves a Lunch (Change B)');
        for (final r in lunch) {
          expect((r['covers'] as int), greaterThan(0),
              reason: '$day Lunch has real covers');
        }
      }

      // Per-location-distinct: Downtown vs another location differ for
      // a Saturday Lunch (the per-location envelope scales covers).
      final other = demoIds.firstWhere((id) => id != DemoScope.restaurantId);
      final dtSatLunch = await db.query('shift_records',
          where:
              "restaurant_id = ? AND day_label = 'Sat' AND daypart = 'lunch' "
              "AND status = 'closed'",
          whereArgs: [DemoScope.restaurantId],
          orderBy: 'business_date DESC',
          limit: 1);
      final otherSatLunch = await db.query('shift_records',
          where:
              "restaurant_id = ? AND day_label = 'Sat' AND daypart = 'lunch' "
              "AND status = 'closed'",
          whereArgs: [other],
          orderBy: 'business_date DESC',
          limit: 1);
      expect(dtSatLunch, isNotEmpty);
      expect(otherSatLunch, isNotEmpty);
      expect(dtSatLunch.first['covers'],
          isNot(otherSatLunch.first['covers']),
          reason: 'weekend Lunch covers are per-location-distinct, not '
              'a clone of Downtown');

      // Per-period target band exists for Lunch (cycle child rows;
      // `target_cycle_dayparts` is keyed by cycle_id).
      final activeCycle = await db.query(
        'target_cycles',
        columns: const ['cycle_id'],
        where: 'restaurant_id = ? AND deactivated_at IS NULL',
        whereArgs: [DemoScope.restaurantId],
        orderBy: 'created_at DESC',
        limit: 1,
      );
      expect(activeCycle, isNotEmpty, reason: 'demo cycle exists');
      final lunchBand = await db.query(
        'target_cycle_dayparts',
        where: 'cycle_id = ? AND service_period_id = ?',
        whereArgs: [activeCycle.first['cycle_id'], 'lunch'],
      );
      expect(lunchBand, isNotEmpty,
          reason: 'the demo cycle carries a per-period Lunch band so the '
              'weekend Lunch is judged against its own target');

      // Locked-plan child rows include a weekend (Sat or Sun) Lunch,
      // and the parent day row == Σ of its per-period child rows
      // (pool consistency).
      final weekendLunchChildren = await db.rawQuery('''
        SELECT business_date, forecast_covers
        FROM weekly_plan_snapshot_day_dayparts
        WHERE service_period_id = 'lunch'
          AND CAST(strftime('%w', business_date) AS INTEGER) IN (0, 6)
      ''');
      expect(weekendLunchChildren, isNotEmpty,
          reason: 'the locked plan now has weekend Lunch child rows '
              '(Promise 3 / Layer 9 coherent for weekend Lunch)');

      // Pool consistency: for one weekend business date, the Σ of its
      // per-period child forecast covers equals the parent day row.
      final wd = weekendLunchChildren.first['business_date'] as String;
      final children = await db.query('weekly_plan_snapshot_day_dayparts',
          where: 'business_date = ?', whereArgs: [wd]);
      final childSum = children.fold<int>(
          0, (s, r) => s + (r['forecast_covers'] as int));
      final parent = await db.query('weekly_plan_snapshots',
          columns: const ['day_rows_json'], limit: 1);
      expect(parent, isNotEmpty);
      expect(childSum, greaterThan(0),
          reason: 'weekend Lunch contributes covers to the locked plan; '
              'parent day = cover-weighted Σ of per-period rows');
    });

    test('two reseeds are byte-identical (determinism)', () async {
      // The clock SELECTION is the only clock-relative input and it is
      // pinned by the injected anchor — no seeded VALUE uses
      // DateTime.now(), so two generates are byte-identical.
      final res = resolveDemoOpenPeriod(
        localNow: DateTime(2026, 5, 16, 19, 45),
      );
      final a = MockIntegrationReplaySeed.generateForDate(
        '2026-05-16',
        open: res,
      );
      final b = MockIntegrationReplaySeed.generateForDate(
        '2026-05-16',
        open: res,
      );

      String sig(MockReplayOutput o) => [
            o.scenario.openShiftDaypart,
            o.scenario.openShiftDayLabel,
            o.scenario.openProgressFraction,
            o.scenario.currentDayClosedPeriods.join(','),
            o.historicalClosedShifts
                .map((s) =>
                    '${s.weekId}|${s.dayLabel}|${s.daypart}|${s.covers}|'
                    '${s.ppa}|${s.cplh}|${s.splh}|${s.status}')
                .join(';'),
            o.currentWeekShifts
                .map((s) =>
                    '${s.dayLabel}|${s.daypart}|${s.covers}|${s.status}')
                .join(';'),
          ].join('§');

      expect(sig(a), sig(b),
          reason: 'deterministic — two reseeds with the same anchor are '
              'byte-identical');
      // Sat + Sun Lunch present in the deterministic output.
      expect(
          a.historicalClosedShifts.any(
              (s) => s.dayLabel == 'Sat' && s.daypart == 'lunch'),
          isTrue);
      expect(
          a.historicalClosedShifts.any(
              (s) => s.dayLabel == 'Sun' && s.daypart == 'lunch'),
          isTrue);
    });
  });
}
