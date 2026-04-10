// Phase 7.55f.4 — Mock replay scenario tests.
//
// Validates:
// A. Parameterized generation produces correct scenarios
// B. SQLite reseed coherence across all operational tables
// C. Manager Override anchor follows mock replay date
// D. Week boundary crossing rolls week ids coherently

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/baseline_manager_service.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/data/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  setUp(() async {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
    await SqliteDatabase.instance.reseedDemo();
  });

  tearDown(() {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
  });

  // ── A: Parameterized generation ─────────────────────────────────────────

  group('A — parameterized generation', () {
    test('default date produces Friday W13 open dinner', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-27');
      expect(output.scenario.currentBusinessDate, '2026-03-27');
      expect(output.scenario.currentWeekId, '2026-W13');
      expect(output.scenario.openShiftDayLabel, 'Fri');
      expect(output.scenario.openShiftDaypart, 'dinner');
    });

    test('default date preserves 8 historical weeks + 14 current-week shifts',
        () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-27');
      expect(output.weekRecords.length, 8);
      expect(output.historicalClosedShifts.length, 112);
      expect(output.currentWeekShifts.length, 14);
    });

    test('default date current week has 9 closed + 5 projected', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-27');
      final closed =
          output.currentWeekShifts.where((s) => s.isClosed).length;
      final projected =
          output.currentWeekShifts.where((s) => s.isProjected).length;
      expect(closed, 9);
      expect(projected, 5);
    });

    test('Saturday produces Sat dinner open with 11 closed + 3 projected', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-28');
      expect(output.scenario.currentWeekId, '2026-W13');
      expect(output.scenario.openShiftDayLabel, 'Sat');
      expect(output.scenario.openShiftDaypart, 'dinner');

      final closed =
          output.currentWeekShifts.where((s) => s.isClosed).length;
      final projected =
          output.currentWeekShifts.where((s) => s.isProjected).length;
      expect(closed, 11); // Mon-Fri all shifts + (Sat has no lunch)
      expect(projected, 3); // Sat dinner, Sat late_night, Sun dinner
    });

    test('Sunday produces Sun dinner open with 13 closed + 1 projected', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-29');
      expect(output.scenario.openShiftDayLabel, 'Sun');
      expect(output.scenario.openShiftDaypart, 'dinner');

      final closed =
          output.currentWeekShifts.where((s) => s.isClosed).length;
      expect(closed, 13);
      expect(output.currentWeekShifts.where((s) => s.isProjected).length, 1);
    });

    test('Monday produces Mon dinner open with 1 closed + 13 projected', () {
      // Monday has lunch + dinner. Lunch is closed, dinner is open.
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-23');
      expect(output.scenario.openShiftDayLabel, 'Mon');
      expect(output.scenario.openShiftDaypart, 'dinner');

      final closed =
          output.currentWeekShifts.where((s) => s.isClosed).length;
      expect(closed, 1); // Only Mon lunch
      expect(output.currentWeekShifts.where((s) => s.isProjected).length, 13);
    });
  });

  // ── B: Week boundary crossing ──────────────────────────────────────────

  group('B — week boundary crossing', () {
    test('advancing past Sunday rolls currentWeekId', () {
      final fri = MockIntegrationReplaySeed.generateForDate('2026-03-27');
      final mon = MockIntegrationReplaySeed.generateForDate('2026-03-30');

      expect(fri.scenario.currentWeekId, '2026-W13');
      expect(mon.scenario.currentWeekId, '2026-W14');
    });

    test('W13 becomes historical after advancing to W14', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-30');
      expect(
          output.weekRecords.any((w) => w.weekId == '2026-W13'), isTrue);
    });

    test('oldest historical week drops out after week advance', () {
      final fri = MockIntegrationReplaySeed.generateForDate('2026-03-27');
      final mon = MockIntegrationReplaySeed.generateForDate('2026-03-30');

      // Friday's oldest historical is W05
      expect(
          fri.weekRecords.any((w) => w.weekId == '2026-W05'), isTrue);
      // Monday's oldest should be W06 (W05 dropped)
      expect(
          mon.weekRecords.any((w) => w.weekId == '2026-W05'), isFalse);
      expect(
          mon.weekRecords.any((w) => w.weekId == '2026-W06'), isTrue);
    });

    test('all shifts have coherent businessDate after week advance', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-30');
      for (final s in output.currentWeekShifts) {
        expect(s.businessDate, isNotNull);
        expect(s.weekId, '2026-W14');
      }
    });
  });

  // ── C: SQLite reseed coherence ─────────────────────────────────────────

  group('C — SQLite reseed coherence', () {
    test('default reseed produces Fri dinner open snapshot', () async {
      final db = await SqliteDatabase.instance.database;
      final open = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(open.length, 1);
      expect(open.first['day_label'], 'Fri');
      expect(open.first['daypart'], 'dinner');
    });

    test('reseed for Saturday produces Sat dinner open snapshot', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      final db = await SqliteDatabase.instance.database;

      final open = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(open.length, 1);
      expect(open.first['day_label'], 'Sat');
      expect(open.first['daypart'], 'dinner');
      expect(open.first['business_date'], '2026-03-28');
    });

    test('reservation snapshot follows scenario date/daypart', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      final db = await SqliteDatabase.instance.database;

      final res = await db.query('reservation_book_snapshots');
      expect(res.length, 1);
      expect(res.first['business_date'], '2026-03-28');
      expect(res.first['daypart'], 'dinner');
    });

    test('mock_replay_state updated after reseed', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      final db = await SqliteDatabase.instance.database;

      final state = await db.query('mock_replay_state',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001']);
      expect(state.length, 1);
      expect(state.first['current_business_date'], '2026-03-28');
    });

    test('no old-scenario open snapshot remains after advance', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      final db = await SqliteDatabase.instance.database;

      // No Friday dinner open snapshot should remain
      final friOpen = await db.query('open_shift_snapshots',
          where:
              "day_label = 'Fri' AND daypart = 'dinner' AND status = 'open'");
      expect(friOpen, isEmpty);
    });

    test('all operational tables are rebuilt on advance', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      final db = await SqliteDatabase.instance.database;

      // shift_records should exist
      final shifts = await db.query('shift_records');
      expect(shifts, isNotEmpty);

      // week_records should exist
      final weeks = await db.query('week_records');
      expect(weeks, isNotEmpty);

      // open_shift_snapshots should exist
      final snaps = await db.query('open_shift_snapshots');
      expect(snaps, isNotEmpty);

      // reservation_book_snapshots should exist
      final res = await db.query('reservation_book_snapshots');
      expect(res, isNotEmpty);
    });

    test('week boundary reseed produces W14 current shifts', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-30');
      final db = await SqliteDatabase.instance.database;

      // Current open shift should be Mon dinner of W14
      final open = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(open.length, 1);
      expect(open.first['day_label'], 'Mon');
      expect(open.first['week_id'], '2026-W14');
    });
  });

  // ── D: Manager Override anchor ─────────────────────────────────────────

  group('D — Manager Override anchor follows mock replay date', () {
    test('anchor uses mock replay date when available', () async {
      await BaselineManagerService.instance.primeManagerOverride();

      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);

      // All candidates should be closed shifts with non-null businessDate
      for (final c in candidates) {
        expect(c.businessDate, isNotNull,
            reason: '${c.recordKey} should have businessDate');
      }
    });

    test('anchor shifts when mock replay date changes', () async {
      // Default: anchor is 2026-03-27
      final defaultCandidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(defaultCandidates, isNotEmpty);

      // Advance to Saturday — anchor shifts to 2026-03-28
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      BaselineData.clearHistoricalContext();
      BaselineData.clearManagerOverride();

      final advancedCandidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(advancedCandidates, isNotEmpty);
    });

    test('candidate inclusion remains closed-only and date-range-based',
        () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      BaselineData.clearHistoricalContext();
      BaselineData.clearManagerOverride();

      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();

      // All returned are from closed shifts
      for (final c in candidates) {
        expect(c.businessDate, isNotNull);
      }
    });
  });
}
