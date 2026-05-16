// Cold-boot demo seed today-anchor regression test.
//
// Authority: this slice's prompt; CLAUDE.md HP #2 (writer-side switch,
// no kDemoMode reader branch, no demo_* table); Time Guardrails.
//
// The defect this guards (operator-reproduced on emulator-5554,
// 2026-05-16): the cold-boot seed path in `sqlite_database.dart`
// (`_onCreate`) anchored every seeded table to the fixed
// `MockIntegrationReplaySeed.defaultBusinessDate` (2026-03-27 /
// 2026-W13). The Shift dashboard evaluates "current-week open/projected
// state" against the real wall clock (`shift_dashboard_notifier.dart`
// :82,126 — `DateTime.now().toUtc()`). The seeded "current week" (week
// of 2026-03-27) therefore never contained "now", so a clean cold boot
// silently degraded to "HISTORICAL ONLY".
//
// The fix anchors the cold-boot seed to *today* (UTC ISO) via
// `MockIntegrationReplaySeed.generateForDate(today)`, mirroring the
// date threading already proven in `reseedMockReplayForBusinessDate`.
// `defaultBusinessDate` / `MockIntegrationReplaySeed.output` stay the
// documented default for unit tests and back-compat — only the runtime
// cold-boot DB seed is today-anchored. `debugColdBootTodayOverride` is
// the test-only seam used here to drive a deterministic "today".

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = DemoScope.restaurantId;

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('coldboot_anchor_');
  });

  tearDown(() async {
    SqliteDatabase.debugColdBootTodayOverride = null;
    await SqliteDatabase.instance.close();
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
  });

  // Triggers a true cold boot: a fresh DB file path means
  // `openDatabase` runs `_onCreate` (version 0 -> schemaVersion).
  Future<void> coldBoot(String injectedToday) async {
    SqliteDatabase.debugColdBootTodayOverride = injectedToday;
    await SqliteDatabase.instance.useDatabasePath(
      p.join(tmpDir.path, 'cold_$injectedToday.db'),
    );
    await SqliteDatabase.instance.database; // first access -> _onCreate
  }

  test(
      'cold boot anchors the seeded current week to the injected today '
      '(NOT 2026-W13) with 12 historical weeks preceding it', () async {
    // A date deliberately far from defaultBusinessDate (2026-03-27) so
    // the anchor change is unambiguous, and deterministic regardless of
    // the real wall clock (the override pins "today").
    const injectedToday = '2026-09-04';
    final oracle = MockIntegrationReplaySeed.generateForDate(injectedToday);

    expect(injectedToday,
        isNot(MockIntegrationReplaySeed.defaultBusinessDate));
    expect(oracle.scenario.currentWeekId, isNot('2026-W13'),
        reason: 'sanity: 2026-09-04 is not in the default scenario week');

    await coldBoot(injectedToday);

    final db = await SqliteDatabase.instance.database;

    // 1. mock_replay_state is pinned to the injected today, not the
    //    fixed default.
    final state = await db.query('mock_replay_state',
        where: 'restaurant_id = ?', whereArgs: [restaurantId]);
    expect(state.single['current_business_date'], injectedToday,
        reason: 'cold boot must persist the today-anchored business '
            'date, not MockIntegrationReplaySeed.defaultBusinessDate');

    // 2. A current-week open shift exists -> Shift is NOT HISTORICAL
    //    ONLY on a clean cold boot (the operator-reproduced defect).
    final currentBusinessDate = await SqliteOpenShiftSnapshotRepository
        .instance
        .getCurrentBusinessDate(restaurantId);
    expect(currentBusinessDate, isNotNull,
        reason: 'cold boot must seed a current-week open shift so the '
            'Shift dashboard finds current-week open/projected state');

    // 3. Exactly 12 historical weeks precede the current week, and they
    //    are the today-anchored oracle weeks — NOT the 2026-03-27
    //    default set, and never the leftover 2026-W13.
    final weekRows = await db.query('week_records',
        distinct: true,
        columns: ['week_id'],
        where: 'restaurant_id = ?',
        whereArgs: [restaurantId]);
    final seededWeekIds =
        weekRows.map((r) => r['week_id'] as String).toSet();
    final oracleHistIds =
        oracle.weekRecords.map((w) => w.weekId).toSet();

    expect(seededWeekIds.length, 12,
        reason: '12 historical weeks (Slice B raised 8 -> 12)');
    expect(seededWeekIds, oracleHistIds,
        reason: 'seeded historical weeks == the today-anchored oracle '
            'weeks, not the 2026-03-27 default scenario');
    expect(seededWeekIds.contains('2026-W13'), isFalse,
        reason: 'no leftover default-scenario current week');
  });

  test(
      'back-compat: MockIntegrationReplaySeed.defaultBusinessDate and '
      'the static output are unchanged (tests / 2026-03-27)', () {
    expect(MockIntegrationReplaySeed.defaultBusinessDate, '2026-03-27');
    expect(MockIntegrationReplaySeed.output.scenario.currentBusinessDate,
        '2026-03-27');
    expect(MockIntegrationReplaySeed.output.scenario.currentWeekId,
        '2026-W13');
    // The today-anchor is scoped strictly to the runtime cold-boot DB
    // seed; the static generator default is untouched.
    expect(MockIntegrationReplaySeed.historicalWeekIds.length, 12);
  });
}
