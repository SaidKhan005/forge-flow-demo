// Phase 8 Wave B `8.spine-bridge.3` server -> mobile sync tests + banned-
// items grep. Validates A-J per the spine-bridge.3 prompt:
//
//   A. Single-page pull: 2 rows -> 2 replaceShiftForSlot calls + 2
//      AppRuntimeInvalidationBus signals.
//   B. Cursor advance: second pull uses the last persisted cursor.
//   C. Replace-for-slot: same slot twice with newer payload -> later
//      wins (idempotent on (restaurant_id, week_id, day_label, daypart)).
//   D. AppRuntimeInvalidationBus fires per write.
//   E. Demo-mode flip propagation to mobile (server flips -> mobile
//      sees on next sync sweep).
//   F. data_accuracy_settings sync to mobile.
//   G. forge_flow_polling_tier_assignment sync to mobile.
//   H. Multi-page; final cursor empty.
//   I. Empty page no-op; no invalidation.
//   J. Banned-items grep across both new source files.
//
// No live HTTP — `_FakeSyncProxyClient` answers every fetch from
// scripted in-memory state.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/sync/postgres_shift_record_to_mobile_sync.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';
import 'package:forge_and_flow/state/app_runtime_invalidation_bus.dart';

const String _opId = '00000000-0000-4000-8000-000000000a01';
const String _locId = '00000000-0000-4000-8000-0000000000b1';

void main() {
  // ── Shared SQLite DB (per-pid via flutter_test_config) ─────────────
  // Each test uses its own restaurant_id so writes never bleed across
  // tests (replaceShiftForSlot is keyed on
  // (restaurant_id, week_id, day_label, daypart) and sync_watermarks
  // PK leads with restaurant_id).
  late ImportTrackingDao watermarkDao;
  late AppRuntimeInvalidationBus bus;

  setUpAll(() async {
    final db = await SqliteDatabase.instance.database;
    watermarkDao = ImportTrackingDao(db);
    bus = AppRuntimeInvalidationBus.instance;
  });

  // ── A. Single-page pull: 2 rows -> 2 writes + 2 fires ──────────────

  test('A. single-page pull: 2 records -> 2 writes + 2 invalidations',
      () async {
    const rid = 'rest_A';
    final client = _FakeSyncProxyClient()
      ..scriptShiftPages([
        _Page(
          records: [
            _shift(rid, weekId: '2026-W13', day: 'Mon', daypart: 'lunch'),
            _shift(rid, weekId: '2026-W13', day: 'Mon', daypart: 'dinner'),
          ],
          nextCursor: null,
        ),
      ]);

    final invalidations = _BusListener(bus);
    addTearDown(invalidations.detach);
    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );

    final result = await sync.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );
    invalidations.detach();

    expect(result.recordsWritten, 2);
    expect(result.pagesPulled, 1);
    expect(invalidations.count, 2,
        reason: 'one bus fire per write');

    final stored = await SqliteShiftRecordRepository.instance
        .getShiftsForWeek(rid, '2026-W13');
    expect(stored.map((r) => r.daypart).toSet(), {'lunch', 'dinner'});
  });

  // ── B. Cursor advance: second pull uses last persisted cursor ──────

  test('B. cursor advance: second sync pull uses last persisted cursor',
      () async {
    const rid = 'rest_B';
    final client = _FakeSyncProxyClient()
      ..scriptShiftPages([
        _Page(
          records: [
            _shift(rid, weekId: '2026-W13', day: 'Tue', daypart: 'lunch'),
          ],
          nextCursor: 'cursor-after-page-1',
        ),
        _Page(records: const [], nextCursor: null),
      ]);

    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );

    // First sweep: writes 1 row, advances watermark to "cursor-after-page-1",
    // then second fetch with that cursor returns empty + nextCursor=null.
    final firstResult = await sync.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );
    expect(firstResult.recordsWritten, 1);
    expect(firstResult.pagesPulled, 2);
    expect(client.shiftCursorsObserved,
        [null, 'cursor-after-page-1']);

    // Second sweep: should read the persisted cursor and call with it.
    client.scriptShiftPages([
      _Page(records: const [], nextCursor: null),
    ]);
    client.shiftCursorsObserved.clear();

    await sync.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );

    expect(client.shiftCursorsObserved, ['cursor-after-page-1'],
        reason: 'second sweep MUST resume from the persisted watermark');
  });

  // ── C. Replace-for-slot: same slot twice -> later wins ─────────────

  test('C. replace-for-slot: same slot twice with newer payload -> '
      'later wins', () async {
    const rid = 'rest_C';

    final clientA = _FakeSyncProxyClient()
      ..scriptShiftPages([
        _Page(
          records: [
            _shift(rid,
                weekId: '2026-W14',
                day: 'Wed',
                daypart: 'dinner',
                covers: 100),
          ],
          nextCursor: null,
        ),
      ]);
    final syncA = PostgresShiftRecordToMobileSync(
      client: clientA,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );
    await syncA.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );

    var stored = await SqliteShiftRecordRepository.instance
        .getShiftsForWeek(rid, '2026-W14');
    expect(stored.single.covers, 100);

    final clientB = _FakeSyncProxyClient()
      ..scriptShiftPages([
        _Page(
          records: [
            _shift(rid,
                weekId: '2026-W14',
                day: 'Wed',
                daypart: 'dinner',
                covers: 222),
          ],
          nextCursor: null,
        ),
      ]);
    final syncB = PostgresShiftRecordToMobileSync(
      client: clientB,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );
    await syncB.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );

    stored = await SqliteShiftRecordRepository.instance
        .getShiftsForWeek(rid, '2026-W14');
    expect(stored, hasLength(1),
        reason: 'replace-for-slot: still exactly one row at this slot');
    expect(stored.single.covers, 222,
        reason: 'later payload (covers=222) overrides the earlier one (100)');
  });

  // ── D. AppRuntimeInvalidationBus fires per write ───────────────────

  test('D. AppRuntimeInvalidationBus fires exactly once per write',
      () async {
    const rid = 'rest_D';
    final client = _FakeSyncProxyClient()
      ..scriptShiftPages([
        _Page(
          records: [
            _shift(rid, weekId: '2026-W15', day: 'Mon', daypart: 'lunch'),
            _shift(rid, weekId: '2026-W15', day: 'Mon', daypart: 'dinner'),
            _shift(rid, weekId: '2026-W15', day: 'Tue', daypart: 'lunch'),
          ],
          nextCursor: null,
        ),
      ]);

    final invalidations = _BusListener(bus);
    addTearDown(invalidations.detach);
    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );
    final result = await sync.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );
    invalidations.detach();

    expect(result.recordsWritten, 3);
    expect(invalidations.count, 3,
        reason: 'bus fires exactly once per ShiftRecord write');
  });

  // ── E. Demo-mode flip propagation to mobile ────────────────────────

  test('E. demo-mode flip propagation: server flip -> mobile sees on '
      'next sync sweep', () async {
    const rid = 'rest_E';
    final client = _FakeSyncProxyClient()
      ..scriptShiftPages([_Page(records: const [], nextCursor: null)])
      ..scriptDemoModeStates([
        // Server flipped to live (is_demo = false) for the POS category.
        DemoModeRecord(
          operatorId: _opId,
          locationId: _locId,
          category: IntegrationCategory.pos,
          isDemo: false,
          flippedToLiveAt: DateTime.utc(2026, 5, 4, 17, 30),
          flippedByConnectionId: 'conn-toast-001',
        ),
        DemoModeRecord(
          operatorId: _opId,
          locationId: _locId,
          category: IntegrationCategory.labor,
          isDemo: true,
        ),
      ]);

    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );
    final result = await sync.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );

    expect(result.demoModeStates, hasLength(2));
    final pos = result.demoModeStates
        .firstWhere((r) => r.category == IntegrationCategory.pos);
    expect(pos.isDemo, isFalse,
        reason: 'mobile sees the flipped row on the next sweep');
    expect(pos.flippedByConnectionId, 'conn-toast-001');
    expect(sync.latestDemoModeStates, hasLength(2),
        reason: 'getter exposes the same snapshot');
  });

  // ── F. data_accuracy_settings sync to mobile ───────────────────────

  test('F. data_accuracy_settings sync: server snapshot -> mobile getter',
      () async {
    const rid = 'rest_F';
    final client = _FakeSyncProxyClient()
      ..scriptShiftPages([_Page(records: const [], nextCursor: null)])
      ..scriptDataAccuracySettings(
        DataAccuracySettingsSnapshot(
          operatorId: _opId,
          locationId: _locId,
          coversSourceLunch: 'manual',
          coversSourceDinner: 'vendor',
          coversSourceLateNight: 'forecast',
          coversManualEntries: const {
            '2026-05-04': {'lunch': 87, 'dinner': 187, 'late_night': 12},
          },
          wageSource: 'manual_mix',
          updatedAt: DateTime.utc(2026, 5, 4, 12, 0),
        ),
      );

    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );
    final result = await sync.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );

    final settings = result.dataAccuracySettings;
    expect(settings, isNotNull);
    expect(settings!.coversSourceLunch, 'manual');
    expect(settings.coversSourceDinner, 'vendor');
    expect(settings.coversSourceLateNight, 'forecast');
    expect(settings.coversManualEntries['2026-05-04']!['dinner'], 187);
    expect(settings.wageSource, 'manual_mix');
    expect(sync.latestDataAccuracySettings?.wageSource, 'manual_mix');
  });

  // ── G. forge_flow_polling_tier_assignment sync to mobile ───────────

  test('G. forge_flow_polling_tier_assignment sync: server snapshot -> '
      'mobile getter', () async {
    const rid = 'rest_G';
    final client = _FakeSyncProxyClient()
      ..scriptShiftPages([_Page(records: const [], nextCursor: null)])
      ..scriptPollingTierAssignment(
        ForgeFlowPollingTierAssignmentSnapshot(
          operatorId: _opId,
          locationId: _locId,
          tierKey: 'premium',
          pollingCadencePerVendorSeconds: const {
            'oracle_micros_simphony': 300,
            'quickbooks_time': 60,
          },
          monthlyPriceCents: 4900,
          effectiveAt: DateTime.utc(2026, 5, 1),
        ),
      );

    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );
    final result = await sync.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );

    final tier = result.pollingTierAssignment;
    expect(tier, isNotNull);
    expect(tier!.tierKey, 'premium');
    expect(tier.pollingCadencePerVendorSeconds['oracle_micros_simphony'],
        300);
    expect(tier.monthlyPriceCents, 4900);
    expect(sync.latestPollingTierAssignment?.tierKey, 'premium');
  });

  // ── H. Multi-page; final cursor empty ──────────────────────────────

  test('H. multi-page: pulls all pages until nextCursor is null',
      () async {
    const rid = 'rest_H';
    final client = _FakeSyncProxyClient()
      ..scriptShiftPages([
        _Page(
          records: [
            _shift(rid, weekId: '2026-W16', day: 'Mon', daypart: 'lunch'),
            _shift(rid, weekId: '2026-W16', day: 'Mon', daypart: 'dinner'),
          ],
          nextCursor: 'page-2',
        ),
        _Page(
          records: [
            _shift(rid, weekId: '2026-W16', day: 'Tue', daypart: 'lunch'),
          ],
          nextCursor: 'page-3',
        ),
        _Page(records: const [], nextCursor: null),
      ]);

    final invalidations = _BusListener(bus);
    addTearDown(invalidations.detach);
    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );
    final result = await sync.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );
    invalidations.detach();

    expect(result.pagesPulled, 3);
    expect(result.recordsWritten, 3);
    expect(invalidations.count, 3);
    expect(client.shiftCursorsObserved, [null, 'page-2', 'page-3']);
    expect(result.finalCursor, 'page-3');

    final stored = await SqliteShiftRecordRepository.instance
        .getShiftsForWeek(rid, '2026-W16');
    expect(stored, hasLength(3));
  });

  // ── I. Empty page no-op; no invalidation ───────────────────────────

  test('I. empty initial page is a no-op: zero writes, zero invalidations',
      () async {
    const rid = 'rest_I';
    final client = _FakeSyncProxyClient()
      ..scriptShiftPages([_Page(records: const [], nextCursor: null)]);

    final invalidations = _BusListener(bus);
    addTearDown(invalidations.detach);
    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );
    final result = await sync.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );
    invalidations.detach();

    expect(result.recordsWritten, 0);
    expect(result.pagesPulled, 1);
    expect(invalidations.count, 0,
        reason: 'no records -> no invalidation signals');

    // Watermark must NOT advance when no nextCursor came back.
    final wm = await watermarkDao.getWatermark(
      rid,
      'pg_shift_record_sync:$_opId:$_locId',
      'cursor',
    );
    expect(wm, isNull,
        reason: 'no advance on empty initial page (nextCursor=null)');
  });

  // ── J. Banned-items grep across both new source files ──────────────

  group('J. Banned-item ledger absent from every new source file '
      'this lane shipped', () {
    const banned = <String>[
      _t1, _t2, _t3, _t4, _t5,
      _t6, _t7, _t8, _t9, _t10,
    ];
    const newFiles = <String>[
      'lib/services/sync/sync_proxy_client.dart',
      'lib/services/sync/postgres_shift_record_to_mobile_sync.dart',
    ];

    for (final path in newFiles) {
      test('$path raw grep: zero banned-token matches', () {
        final source = File(path).readAsStringSync();
        for (final token in banned) {
          expect(source.contains(token), isFalse,
              reason: 'banned token "$token" present in $path');
        }
      });
    }
  });
}

// ─── Test fakes & helpers ──────────────────────────────────────────

class _Page {
  const _Page({required this.records, required this.nextCursor});
  final List<ShiftRecord> records;
  final String? nextCursor;
}

class _FakeSyncProxyClient implements SyncProxyClient {
  final List<_Page> _shiftPages = <_Page>[];
  final List<String?> shiftCursorsObserved = <String?>[];
  List<DemoModeRecord> _demoModeStates = const <DemoModeRecord>[];
  DataAccuracySettingsSnapshot? _dataAccuracySettings;
  ForgeFlowPollingTierAssignmentSnapshot? _pollingTierAssignment;

  void scriptShiftPages(List<_Page> pages) {
    _shiftPages
      ..clear()
      ..addAll(pages);
  }

  void scriptDemoModeStates(List<DemoModeRecord> states) {
    _demoModeStates = states;
  }

  void scriptDataAccuracySettings(DataAccuracySettingsSnapshot? snap) {
    _dataAccuracySettings = snap;
  }

  void scriptPollingTierAssignment(
      ForgeFlowPollingTierAssignmentSnapshot? snap) {
    _pollingTierAssignment = snap;
  }

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    shiftCursorsObserved.add(cursor);
    if (_shiftPages.isEmpty) {
      return const ShiftRecordPage(records: <ShiftRecord>[], nextCursor: null);
    }
    final page = _shiftPages.removeAt(0);
    return ShiftRecordPage(
      records: page.records,
      nextCursor: page.nextCursor,
    );
  }

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async =>
      _demoModeStates;

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) async =>
      _dataAccuracySettings;

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
      fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async =>
      _pollingTierAssignment;
}

class _BusListener {
  _BusListener(this.bus) {
    _listener = _onFire;
    bus.addListener(_listener);
  }
  final AppRuntimeInvalidationBus bus;
  late final void Function() _listener;
  int count = 0;
  void _onFire() {
    count++;
  }

  void detach() => bus.removeListener(_listener);
}

ShiftRecord _shift(
  String restaurantId, {
  required String weekId,
  required String day,
  required String daypart,
  int covers = 50,
}) {
  return ShiftRecord(
    restaurantId: restaurantId,
    weekId: weekId,
    dayLabel: day,
    daypart: daypart,
    status: 'closed',
    covers: covers,
    forecastCovers: covers,
    ppa: 22.0,
    cplh: 30.0,
    splh: 70.0,
    fohHours: 20,
    bohHours: 18,
    primaryLever: 'ON_MODEL',
    sourceSystem: 'oracle_micros_simphony',
    businessDate: '2026-05-04',
  );
}

// Banned tokens declared as fragmented constants so this file itself
// does not contain any of the literal tokens (mirrors the canonical
// pattern in test/services/integration/canonical_sink_contract_test.dart).
const String _t1 = 'K' 'M' 'S';
const String _t2 = 'parse' '_' 'warnings';
const String _t3 = 'parse' '_' 'partial';
const String _t4 = 'kStrict' 'Replay' 'FiveMinute';
const String _t5 = 'pg_' 'advisory' '_lock';
const String _t6 = 'sigterm' 'Drain' 'Handler';
const String _t7 = 'inboundWebhook' 'DLQ' 'Tile';
const String _t8 = 'raw_' 'payload' '_partition';
const String _t9 = 'pg_' 'partman' '_raw';
const String _t10 = 'package' ':' 'postgres';
