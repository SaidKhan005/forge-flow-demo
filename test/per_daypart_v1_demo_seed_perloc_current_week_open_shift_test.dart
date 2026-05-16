// Per-location current-week open/projected shift regression test.
//
// Authority: this slice's prompt (P0 — every demo location needs its own
// current-week open/projected shift, today-anchored); CLAUDE.md HP #2
// (writer-side switch, no kDemoMode reader branch, no demo_* table),
// HP #4 (per-(operator,location) scoping), Metric Honesty / Design
// Rule 2 (no fabricated phantom).
//
// Operator-reproduced defect this guards: after the sibling scope-wiring
// fix, switching to a non-Downtown location and refreshing showed
// HISTORICAL ONLY / empty Shift. Root cause:
// `ShiftDashboardNotifier._load()` resolves the live business date via
// `OpenShiftSnapshotDao.getCurrentBusinessDate` — `WHERE status='open'`.
// The pre-fix per-location operational envelope emitted the non-Downtown
// scenario open daypart as `projected` (only Downtown got a
// `status='open'` row — the W6 "one global open row stays Downtown's"
// design), so a correctly-scoped read of any non-Downtown location
// returned null → the dashboard rendered the empty "No open or projected
// shift" state.
//
// The fix extends the per-location envelope so EVERY demo location gets
// its OWN current-week open/projected/closed `open_shift_snapshots` rows
// for the today-anchored current week, built by the SAME shared
// `_buildCurrentWeekOpenShiftSnapshots` Downtown uses, parameterized by
// each location's already-scaled per-location shift set (so the figures
// are per-location-distinct, NOT a Downtown clone, NOT a phantom).
//
// Pre-change behaviour (disclosed, not asserted here because the fix is
// already in place on this branch): on master, querying
// `open_shift_snapshots WHERE status='open'` returned exactly ONE row,
// always Downtown's, and `getCurrentBusinessDate(<non-Downtown>)`
// returned null — the empty-Shift defect. This test asserts the
// post-fix invariant: one live open row PER location, today-anchored,
// per-location-distinct, idempotent, zero orphans.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/open_shift_snapshot_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final demoIds =
      DemoScope.locations.map((l) => l.restaurantId).toList();
  const downtown = DemoScope.restaurantId;

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('perloc_open_');
  });

  tearDown(() async {
    SqliteDatabase.debugColdBootTodayOverride = null;
    await SqliteDatabase.instance.close();
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
  });

  // Triggers a true cold boot: a fresh DB file path means
  // `openDatabase` runs `_onCreate` (version 0 -> schemaVersion), which
  // runs the today-anchored demo seed end-to-end.
  Future<void> coldBoot(String injectedToday) async {
    SqliteDatabase.debugColdBootTodayOverride = injectedToday;
    await SqliteDatabase.instance.useDatabasePath(
      p.join(tmpDir.path, 'cold_$injectedToday.db'),
    );
    await SqliteDatabase.instance.database; // first access -> _onCreate
  }

  /// Asserts the post-fix invariant for a cold-booted DB anchored at
  /// [injectedToday]: every demo location has exactly one today-week
  /// `status='open'` row + ≥1 today-week `projected` row, all rows are
  /// scoped to a known demo id (zero orphans), and the non-Downtown
  /// figures are NOT a clone of Downtown's.
  Future<void> assertEveryLocationHasLiveCurrentWeekShift(
      String injectedToday) async {
    final oracle =
        MockIntegrationReplaySeed.generateForDate(injectedToday);
    final currentWeekId = oracle.scenario.currentWeekId;
    final currentBusinessDate = oracle.scenario.currentBusinessDate;

    final db = await SqliteDatabase.instance.database;
    // The exact DAO the dashboard reads through
    // (`SqliteOpenShiftSnapshotRepository.getCurrentBusinessDate`
    // delegates verbatim to `OpenShiftSnapshotDao.getCurrentBusinessDate`
    // — `WHERE status='open' LIMIT 1`). Built fresh from the live `db`
    // so the repository singleton's cross-cold-boot DAO cache (a
    // test-harness artifact, not a production path) cannot mask the
    // assertion with a stale closed handle.
    final dao = OpenShiftSnapshotDao(db);

    // Zero orphans: every open_shift_snapshots row is scoped to one of
    // the 4 known demo locations (no stray/leaked scope).
    final allScopes = (await db.query('open_shift_snapshots',
            columns: ['restaurant_id'], distinct: true))
        .map((r) => r['restaurant_id'] as String)
        .toSet();
    expect(allScopes, demoIds.toSet(),
        reason: 'open_shift_snapshots scoped only to the 4 demo '
            'locations — zero orphans');

    final perLocOpenCovers = <String, int>{};
    for (final rid in demoIds) {
      // Exactly one live open row, today-anchored.
      final open = await db.query(
        'open_shift_snapshots',
        where: "restaurant_id = ? AND status = 'open'",
        whereArgs: [rid],
      );
      expect(open.length, 1,
          reason: '$rid must have exactly one status=open row');
      expect(open.first['week_id'], currentWeekId,
          reason: "$rid open row is in TODAY's week (not historical)");
      expect(open.first['business_date'], currentBusinessDate,
          reason: '$rid open row is anchored to today');
      perLocOpenCovers[rid] = open.first['current_covers'] as int;

      // The Shift dashboard's exact resolution path (`status='open'`)
      // now returns a live business date for THIS location → no more
      // HISTORICAL ONLY / empty Shift on scope switch.
      final resolvedBd = await dao.getCurrentBusinessDate(rid);
      expect(resolvedBd, currentBusinessDate,
          reason: '$rid: getCurrentBusinessDate (the dashboard read '
              'path) resolves the live week, not null');

      // ≥1 projected row in the same (today) week so the whole-day view
      // has forward coverage.
      final projected = await db.query(
        'open_shift_snapshots',
        where: "restaurant_id = ? AND week_id = ? AND status = 'projected'",
        whereArgs: [rid, currentWeekId],
      );
      expect(projected, isNotEmpty,
          reason: '$rid has current-week projected coverage');

      // No orphan snapshot: the live open cell maps to a backing
      // shift_records row for the SAME location/week/day/daypart.
      final backing = await db.query(
        'shift_records',
        where: 'restaurant_id = ? AND week_id = ? AND day_label = ? '
            'AND daypart = ?',
        whereArgs: [
          rid,
          open.first['week_id'],
          open.first['day_label'],
          open.first['daypart'],
        ],
        limit: 1,
      );
      expect(backing, isNotEmpty,
          reason: '$rid open snapshot has a backing shift_record '
              '(no fabricated phantom)');
    }

    // Per-location-distinct: each non-Downtown location's live open
    // covers differ from Downtown's — derived from that location's own
    // scaled shift set + variance profile, not cloned.
    for (final rid in demoIds.where((r) => r != downtown)) {
      expect(perLocOpenCovers[rid], isNot(equals(perLocOpenCovers[downtown])),
          reason: '$rid live open covers ≠ Downtown (per-location '
              'variance profile, not a clone)');
    }
  }

  test(
      'cold boot (fixed today) — every demo location has its own '
      "today-anchored live open shift; zero orphans; not a clone",
      () async {
    // Deterministic "today", deliberately far from the 2026-03-27
    // default scenario so the today-anchor + per-location coverage is
    // unambiguous regardless of the real wall clock.
    const injectedToday = '2026-09-04';
    expect(injectedToday,
        isNot(MockIntegrationReplaySeed.defaultBusinessDate));

    await coldBoot(injectedToday);
    await assertEveryLocationHasLiveCurrentWeekShift(injectedToday);
  });

  test(
      'cold boot (real current date) — non-Downtown locations are NOT '
      'HISTORICAL ONLY on a real device clock', () async {
    // The operator reproduced the defect on a real device whose clock is
    // "now". Drive the seed with the real current UTC date so the test
    // fails if the today-anchor + per-location open seed regress against
    // an unpinned wall clock.
    final realToday =
        DateTime.now().toUtc().toIso8601String().substring(0, 10);

    await coldBoot(realToday);
    await assertEveryLocationHasLiveCurrentWeekShift(realToday);
  });

  test(
      'idempotent across cold boot + reseed/advance — counts stable, '
      'no duplicate rows, no PK collision', () async {
    const injectedToday = '2026-09-04';
    await coldBoot(injectedToday);

    Future<Map<String, int>> openCountsByLocation() async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query(
        'open_shift_snapshots',
        columns: ['restaurant_id'],
        where: "status = 'open'",
      );
      final counts = <String, int>{};
      for (final r in rows) {
        final rid = r['restaurant_id'] as String;
        counts[rid] = (counts[rid] ?? 0) + 1;
      }
      return counts;
    }

    final before = await openCountsByLocation();
    expect(before, {for (final rid in demoIds) rid: 1},
        reason: 'one live open row per location after cold boot');

    // Reseed/advance to the SAME today (the W6 clear-then-rebuild +
    // (restaurant_id, week_key) guard path). Must not duplicate rows or
    // collide on the (restaurant_id, week_id, day_label, daypart) UNIQUE.
    await SqliteDatabase.instance
        .reseedMockReplayForBusinessDate(injectedToday);

    final after = await openCountsByLocation();
    expect(after, before,
        reason: 'reseed/advance leaves exactly one live open row per '
            'location — idempotent, no duplicates, no PK collision');

    // Total open rows across the whole table is exactly 4 (one per
    // demo location) — no stray/duplicate open rows survive a reseed.
    final db = await SqliteDatabase.instance.database;
    final allOpen = await db.query('open_shift_snapshots',
        where: "status = 'open'");
    expect(allOpen.length, demoIds.length);
  });
}
