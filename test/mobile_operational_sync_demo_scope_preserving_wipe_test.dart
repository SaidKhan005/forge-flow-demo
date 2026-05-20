// Demo location switch must NOT cross-tenant-wipe the operator's other
// demo locations.
//
// Authority: this slice's prompt (P0 — demo location switch nukes the
// other 3 locations' operational data); CLAUDE.md Demo Mode + HP #2
// (writer-side / bootstrap source-swap, NO `kDemoMode` reader fork, NO
// `demo_*` table), HP #4 (per-(operator,location) isolation).
//
// Operator-reproduced defect this guards: in the proper demo build,
// switching the active location (Downtown -> Riverside) published a
// business-scope change; `MobileOperationalSyncHost` ran
// `defaultCrossTenantWipe(session.locationId)`, which `DELETE`d every
// row whose `restaurant_id != keep`. Because the 4 `DemoScope`
// locations are ONE demo operator's tenancy and the demo build has no
// operational proxy sync to re-materialize a wiped location, the 3
// non-active demo locations' cold-boot operational envelope
// (#824/#827) was permanently destroyed -> Shift rendered
// `HISTORICAL ONLY`. Device evidence: cold boot
// `open_shift_snapshots` = 684 (4 locations); after the switch = 171
// (only Riverside).
//
// Fix under test: `demoScopePreservingCrossTenantWipe` — the
// bootstrap-injected (demo-branch-only) sibling of
// `defaultCrossTenantWipe`. It preserves the demo operator's full
// `DemoScope.locations` set while still purging a genuinely-foreign
// `restaurant_id`. Production keeps `defaultCrossTenantWipe`
// byte-unchanged.
//
// This test cold-boots ONCE (seeds all 4 demo locations across the
// operational tables), seeds one foreign-tenant row, then exercises
// BOTH wipe strategies sequentially on the same DB:
//   1. demo-preserving wipe (keep = Riverside): assert ALL 4 demo
//      locations survive across the 8 affected repos / 9 tables AND
//      the foreign row is deleted.
//   2. production default wipe (keep = Riverside) on the data the
//      demo wipe preserved: assert it STILL deletes the 3 non-keep
//      demo locations (only Riverside remains) — proving the
//      production control is untouched and the difference is purely
//      the injected strategy.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/dev/demo_vendor_integration_state_fixture.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/sync/mobile_operational_sync_runtime.dart';

import '_test_helpers/cold_boot_helpers.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // The 8 repos `defaultCrossTenantWipe` / `demoScopePreservingCross
  // TenantWipe` compose, expanded to the 9 underlying `restaurant_id`-
  // scoped tables (target_profile repo touches 2).
  const affectedTables = <String>[
    'shift_records',
    'open_shift_snapshots',
    'restaurant_timing_configs',
    'baseline_selected_records',
    'target_cycles',
    'active_target_profiles',
    'target_profile_versions',
    'weekly_plan_snapshots',
    'wage_role_rows',
  ];

  // Fix A (operator decision 2026-05-16): the "none connected" demo
  // location (today Harbour) is honest-EMPTY — it has NO operational
  // rows. The scope-preserving-wipe invariant therefore applies to the
  // CONNECTED demo locations (the scopes that actually carry data); the
  // none-connected location is vacuously preserved (no rows to wipe) and
  // its `restaurant_locations` row is not in `affectedTables`.
  final demoIds = DemoScope.locations
      .map((l) => l.restaurantId)
      .where((id) => !DemoVendorIntegrationStateFixture.isNoneConnected(id))
      .toSet();
  const keep = DemoScope.riversideRestaurantId;
  const foreignId = 'foreign_tenant_zzz_not_a_demo_scope';

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('demo_preserve_wipe_');
    // Bucket 4d (audit 2026-05-20): reset cold-boot overrides via
    // `addTearDown` so the override can't leak between tests
    // (PR #1091 bug shape). The `set` happens below in `coldBoot()`.
    addTearDown(resetColdBootOverrides);
  });

  tearDown(() async {
    await SqliteDatabase.instance.close();
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
  });

  /// Cold boot: a fresh DB file path runs `_onCreate` -> the
  /// today-anchored demo seed end-to-end (all 4 demo locations).
  Future<void> coldBoot(String injectedToday) async {
    SqliteDatabase.debugColdBootTodayOverride = injectedToday;
    await SqliteDatabase.instance.useDatabasePath(
      p.join(tmpDir.path, 'cold_$injectedToday.db'),
    );
    await SqliteDatabase.instance.database; // first access -> _onCreate
  }

  Future<Set<String>> scopesIn(String table) async {
    final db = await SqliteDatabase.instance.database;
    final rows = await db.query(
      table,
      columns: ['restaurant_id'],
      distinct: true,
    );
    return rows.map((r) => r['restaurant_id'] as String).toSet();
  }

  /// Clones one existing `open_shift_snapshots` row into a foreign
  /// (non-DemoScope) tenant so we can prove the wipe still purges a
  /// genuinely-foreign scope. `id` is INTEGER PRIMARY KEY AUTOINCREMENT
  /// so dropping it lets SQLite assign a fresh key (no PK collision).
  Future<void> insertForeignOpenShiftRow() async {
    final db = await SqliteDatabase.instance.database;
    final sample = await db.query(
      'open_shift_snapshots',
      where: 'restaurant_id = ?',
      whereArgs: [DemoScope.restaurantId],
      limit: 1,
    );
    expect(sample, isNotEmpty,
        reason: 'cold boot must seed at least one Downtown '
            'open_shift_snapshots row to clone');
    final row = Map<String, Object?>.from(sample.first)
      ..remove('id')
      ..['restaurant_id'] = foreignId;
    await db.insert('open_shift_snapshots', row);
  }

  test(
      'demo-preserving wipe keeps every CONNECTED DemoScope location + '
      'purges foreign; production default wipe still nukes non-keep '
      'demo scopes (production byte-unchanged)', () async {
    // Deliberately far from the demo scenario anchor so the cold-boot
    // path is a true today-anchored seed (matches the sibling per-loc
    // regression test's choice).
    const injectedToday = '2026-09-04';
    await coldBoot(injectedToday);

    // Sanity: the defect is only meaningful if cold boot really seeded
    // every demo location's live operational envelope. The per-loc
    // regression test proves open_shift_snapshots carries all 4.
    final openScopesBefore = await scopesIn('open_shift_snapshots');
    expect(openScopesBefore.containsAll(demoIds), isTrue,
        reason: 'cold boot must seed every CONNECTED demo location into '
            'open_shift_snapshots (the device-reproduced 684 -> 171 '
            'defect surface); the none-connected location is honest-empty '
            'by Fix A and not expected here');

    await insertForeignOpenShiftRow();
    expect(
      (await scopesIn('open_shift_snapshots')).contains(foreignId),
      isTrue,
      reason: 'foreign-tenant row seeded',
    );

    // Capture, per table, exactly which demo locations cold boot
    // populated. We assert THAT set survives the demo wipe (a table
    // the seed leaves empty stays vacuously correct).
    final demoScopesBefore = <String, Set<String>>{};
    for (final table in affectedTables) {
      final scopes = await scopesIn(table);
      demoScopesBefore[table] = scopes.intersection(demoIds);
    }

    // ── 1. Demo-preserving wipe (the fix) ────────────────────────────
    await demoScopePreservingCrossTenantWipe(keep);

    for (final table in affectedTables) {
      final after = (await scopesIn(table)).intersection(demoIds);
      expect(
        after,
        equals(demoScopesBefore[table]),
        reason: '$table: every demo location present before the demo '
            'wipe must still be present after it (a demo location '
            'switch must NOT cross-tenant-wipe the operator\'s own '
            'other demo locations)',
      );
    }
    // Every CONNECTED demo location specifically survives in the defect
    // surface.
    expect(
      (await scopesIn('open_shift_snapshots')).intersection(demoIds),
      equals(demoIds),
      reason: 'every connected DemoScope location keeps its open_shift '
          'snapshots after the demo location switch (no HISTORICAL '
          'ONLY regression)',
    );
    // …but a genuinely-foreign tenant is STILL purged (isolation
    // intent preserved for any non-demo scope).
    expect(
      (await scopesIn('open_shift_snapshots')).contains(foreignId),
      isFalse,
      reason: 'foreign (non-DemoScope) tenant row must still be wiped',
    );

    // ── 2. Production default wipe, UNCHANGED, on the preserved data ──
    // Re-seed a foreign row; default wipe deletes restaurant_id != keep.
    await insertForeignOpenShiftRow();
    await defaultCrossTenantWipe(keep);

    for (final table in affectedTables) {
      final after = (await scopesIn(table)).intersection(demoIds);
      final expected = demoScopesBefore[table]!.contains(keep)
          ? <String>{keep}
          : <String>{};
      expect(
        after,
        equals(expected),
        reason: '$table: the production default wipe (byte-unchanged) '
            'still deletes every non-keep scope — only Riverside may '
            'survive. The demo-vs-prod difference is purely the '
            'bootstrap-injected strategy object, not a behavior change '
            'to defaultCrossTenantWipe.',
      );
    }
    expect(
      (await scopesIn('open_shift_snapshots')).contains(foreignId),
      isFalse,
      reason: 'production default wipe also purges the foreign tenant',
    );
  });
}
