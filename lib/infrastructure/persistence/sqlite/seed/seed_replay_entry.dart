// Part of sqlite_database.dart. Top-level _seedDemoDataFromReplay + vendor mode-state hook + helpers.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

Future<void> _seedDemoDataFromReplay(
  Database db,
  MockReplayOutput replay,
) async {
  final now = DateTime.now().toIso8601String();
  final importRunId =
      'mock_replay_seed_${now.replaceAll(RegExp(r'[^0-9]'), '')}';

  // Per-Daypart V1 (Slice 1, Decision 4) — pre-production reseed wipes
  // demo-scope closed shifts before regenerating so newly added
  // timing-provenance / per-period target stamp columns are populated
  // uniformly across every row. There is no "transition period" /
  // "dual shapes" / "retroactive re-grading" concern because the demo
  // restaurant has no real operator data to preserve. Production
  // behavior is "closed truth retains its stamp from close time"
  // (Promise 2) — that rule applies only to non-demo scopes.
  await db.delete(
    'shift_records',
    where: 'restaurant_id = ?',
    whereArgs: [DemoScope.restaurantId],
  );

  final batch = db.batch();

  for (final s in replay.currentWeekShifts) {
    final map = s.toMap()..remove('id');
    map['restaurant_id'] = DemoScope.restaurantId;
    batch.insert('shift_records', map);
  }
  for (final s in replay.historicalClosedShifts) {
    final map = s.toMap()..remove('id');
    map['restaurant_id'] = DemoScope.restaurantId;
    batch.insert('shift_records', map);
  }
  for (final w in replay.weekRecords) {
    final map = w.toMap()..remove('id');
    map['restaurant_id'] = DemoScope.restaurantId;
    batch.insert(
      'week_records',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
  await batch.commit(noResult: true);

  // Record a mock_pos_labor_replay import run
  final importRun = ImportRun(
    importRunId: importRunId,
    restaurantId: DemoScope.restaurantId,
    mode: 'mock_pos_labor_replay',
    startedAt: now,
    completedAt: now,
    status: 'completed',
  );
  await db.insert('import_runs', importRun.toMap());

  // Insert raw import records for seeded shifts
  final allShifts = [
    ...replay.currentWeekShifts,
    ...replay.historicalClosedShifts,
  ];
  final rawBatch = db.batch();
  for (int i = 0; i < allShifts.length; i++) {
    final s = allShifts[i];
    final payloadJson = jsonEncode(s.toMap()..remove('id'));
    final hash = _deterministicHash(payloadJson);
    final record = RawImportRecord(
      rawImportId: '${importRunId}_shift_$i',
      importRunId: importRunId,
      restaurantId: DemoScope.restaurantId,
      sourceType: 'mock_pos_labor_replay',
      sourceEntityType: 'shift_record',
      sourceEntityId: '${s.weekId}_${s.dayLabel}_${s.daypart}',
      payloadHash: hash,
      businessDate: _businessDateFromWeekDay(s.weekId, s.dayLabel)!,
      receivedAt: now,
      status: 'applied',
      payloadJson: payloadJson,
    );
    rawBatch.insert('raw_import_records', record.toMap());
  }
  await rawBatch.commit(noResult: true);

  // Demo-data Slice C — after Downtown's cohort lands, seed the SAME
  // shape (scoped per `restaurant_id`, HP #4) for the 3 non-Downtown
  // §2c locations so the scope drawer is a real switcher and every
  // location's dashboard is fully operational. Called from BOTH the
  // cold-boot seed path and the reseed/advance path (this function is
  // the single per-location seed-orchestration seam).
  await _seedAdditionalLocationsFromReplay(db, replay, now, importRunId);

  // Demo-data Slice E pt2 (Gap G6) — arm the mobile-fold
  // `demo_mode_state` source so Settings → Integrations + the
  // `DemoModeBanner` render the per-(operator, location, category)
  // vendor demo state, consistent with pt1's (#800) fixture. Single
  // call site for this hook; both demo-seed paths (`_onCreate` cold
  // boot AND reseed/advance) flow through `_seedDemoDataFromReplay`,
  // mirroring the `_seedAdditionalLocationsFromReplay` seam above.
  await _seedDemoVendorIntegrationModeStateSource();
}

/// Demo-data Slice E pt2 — mobile-fold `demo_mode_state` seed hook.
///
/// HP #2 (CLAUDE.md → Demo Mode): the mobile fold + banner read ONLY
/// `DemoModeStateNotifier`, which is fed by an injected
/// `SyncProxyClient.fetchDemoModeStates`. The demo flavor bootstraps
/// with no proxy, so there is no SQLite `demo_mode_state` table to
/// write and inventing a `demo_*` table is forbidden. Per the pt2
/// prompt (Required #3) the "hook" instead WIRES pt1's fixture into the
/// mobile notifier's demo source — the notifier-side analogue of
/// `MockReplayDataSourceProvider`. This is a WRITER-side source swap,
/// not a `kDemoMode` reader branch: every reader resolves the records
/// through the SAME code path in demo and prod.
///
/// `_seedDemoDataFromReplay` runs in BOTH the demo flavor and ordinary
/// (production) `_onCreate` because the demo restaurant rows coexist in
/// the same tables (HP #2). The demo source must therefore arm ONLY in
/// the demo flavor; the gate below is the `kDemoMode` /
/// `FORGE_FLOW_DEMO_MODE` WRITER-side switch (HP #2 explicitly endorses
/// `kDemoMode` as a writer-side switch — used here in the seeder, not a
/// reader). In production the gate is false → the source is never armed
/// → `DemoVendorIntegrationDemoModeSource.maybeClient()` stays null →
/// the notifier resolves exactly the bootstrap proxy it always has, so
/// the production read path is byte-unchanged.
///
/// Determinism + HP #4: `armForDemoSeed` materializes and asserts the
/// canonical pt1 records for the 4 `DemoScope.locations` ×
/// {pos, labor, reservation} for the demo operator — pure, no RNG, no
/// `DateTime.now()`, no DB write, no cross-location/operator leakage.
/// Two reseeds are byte-identical.
Future<void> _seedDemoVendorIntegrationModeStateSource() async {
  if (!_kDemoModeWriterSwitch) return;
  DemoVendorIntegrationDemoModeSource.armForDemoSeed(
    demoLocationIds: <String>[
      for (final location in DemoScope.locations) location.restaurantId,
    ],
  );
}

/// `kDemoMode` / `FORGE_FLOW_DEMO_MODE` WRITER-side switch — the SAME
/// pair `main_forgeflow.dart`'s `_demoAuthEnabled` and the demo
/// `SettingsScreen` carve-outs use. Compile-time const; unset in
/// production builds so `_seedDemoVendorIntegrationModeStateSource` is
/// a no-op there and the demo source never arms.
const bool _kDemoModeWriterSwitch =
    bool.fromEnvironment('kDemoMode') ||
    bool.fromEnvironment('FORGE_FLOW_DEMO_MODE');

String _deterministicHash(String payload) {
  int hash = 0x811c9dc5;
  for (int i = 0; i < payload.length; i++) {
    hash ^= payload.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

Future<void> _ensureDemoRestaurant(Database db) async {
  // Unconditional + idempotent. A Downtown-only `existing.isEmpty` guard
  // would skip backfilling North Loop / Riverside / Harbour on any demo
  // DB that predates the multi-location build (Downtown already exists →
  // guard true → 3 locations never seeded). `_seedDemoRestaurant` uses
  // ConflictAlgorithm.ignore so re-running is a no-op for present rows
  // and backfills only the missing ones.
  await _seedDemoRestaurant(db);
}
