// Phase 2D — Mobile-sync pressure harness.
//
// Sprint: `pressure.preview.v1` Phase 2.
// Plan: `docs/_execution/2026-05-08_pressure_preview_v1_plan.md`.
// Inputs from earlier phases (per `test/integration/pressure/README.md`):
//
//   * 2A (adapter)  — vendor JSON -> parsed `VendorEvent`.
//   * 2B (sink)     — parsed model -> Postgres operator-scoped sink rows.
//   * 2C (spine)    — Postgres sink -> canonical fact aggregation.
//
// This harness exercises the proxy -> mobile SQLite sync path that
// 2C feeds into. The seam under test is `SyncProxyClient` ->
// `PostgresShiftRecordToMobileSync` -> SQLite repos.
//
// Hard-Promise alignment (CLAUDE.md):
//   * HP #2 (demo persists post-launch): `demo_mode_state` rows flip
//     via the realtime spine, not via `kDemoMode`. The synced rows
//     remain queryable per category regardless of build flag.
//   * HP #4 (per-operator isolation): switching the active scope tears
//     down + re-bootstraps SQLite without leaking the prior tenant's
//     rows. The harness records `operator_data_leak_after_switch`
//     when a prior scope's row is reachable post-flip.
//
// Outputs:
//   * `test/integration/pressure/p2d_mobile_sync_findings.jsonl` —
//     one JSON event per finding (newline-delimited).
//   * `test/integration/pressure/p2d_mobile_sync_findings_summary.txt`
//     — human-readable summary, one line per finding category with
//     count.
//
// All proxy I/O is in-memory; no live HTTP. The only real
// infrastructure touched is the per-pid SQLite database wired by
// `test/flutter_test_config.dart`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_wage_role_row_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/sync/mobile_operational_sync_runtime.dart';
import 'package:forge_and_flow/services/sync/postgres_shift_record_to_mobile_sync.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';

// ─── Findings sink ────────────────────────────────────────────────────────

const String _findingsRoot = 'test/integration/pressure';
const String _findingsPath = '$_findingsRoot/p2d_mobile_sync_findings.jsonl';
const String _summaryPath =
    '$_findingsRoot/p2d_mobile_sync_findings_summary.txt';

final List<Map<String, Object?>> _findings = <Map<String, Object?>>[];

void _record(
  String category, {
  required String fixture,
  required String severity,
  required String message,
  Map<String, Object?> details = const <String, Object?>{},
}) {
  _findings.add(<String, Object?>{
    'category': category,
    'severity': severity,
    'fixture': fixture,
    'message': message,
    'details': details,
    'recorded_at': DateTime.now().toUtc().toIso8601String(),
  });
}

Future<void> _flushFindings() async {
  final dir = Directory(_findingsRoot);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final sink = File(_findingsPath);
  final buffer = StringBuffer();
  for (final entry in _findings) {
    buffer.writeln(jsonEncode(entry));
  }
  await sink.writeAsString(buffer.toString());

  final counts = <String, int>{};
  for (final entry in _findings) {
    final category = entry['category']?.toString() ?? 'unknown';
    counts[category] = (counts[category] ?? 0) + 1;
  }
  final summary = StringBuffer()
    ..writeln('Phase 2D mobile-sync pressure harness — findings summary')
    ..writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}')
    ..writeln('Total findings: ${_findings.length}')
    ..writeln('')
    ..writeln('Counts by category:');
  final sortedKeys = counts.keys.toList()..sort();
  for (final key in sortedKeys) {
    summary.writeln('  $key: ${counts[key]}');
  }
  await File(_summaryPath).writeAsString(summary.toString());
}

// ─── Stable test scopes ───────────────────────────────────────────────────

const String _opA = '00000000-0000-4000-8000-0000000a0001';
const String _opB = '00000000-0000-4000-8000-0000000a0002';
const String _locA = '00000000-0000-4000-8000-00000000b001';
const String _locB = '00000000-0000-4000-8000-00000000b002';

// Pressure harness uses dedicated restaurant_ids per scope so writes
// never bleed across the parametric vendor sweep loops below. The
// MobileOperationalSyncHost normally promotes session.locationId into
// the restaurantId; here we drive the sync layer directly so both
// (op, loc) and the corresponding restaurant_id rotate together.
const String _ridA = 'p2d_rid_op_a_loc_a';
const String _ridB = 'p2d_rid_op_b_loc_b';

// Vendor corpora the parametric sweep iterates over. Mirrors the
// fixture set in `test/fixtures/vendor_payloads/`. Each corpus is
// represented by the vendor id; the harness scripts a single scoped
// row per corpus so the sweep stays bounded and deterministic.
const List<String> _posVendors = <String>[
  'aloha_ncr_voyix',
  'clover',
  'lightspeed_lsk',
  'oracle_micros_simphony',
  'revel',
  'square',
  'toast',
];

const List<String> _laborVendors = <String>[
  'adp',
  'agendrix',
  'humanity',
  'push_operations',
  'quickbooks_time',
  'seven_shifts',
];

const List<String> _reservationVendors = <String>[
  'libro',
  'opentable',
  'sevenrooms',
  'tock',
];

void main() {
  late ImportTrackingDao watermarkDao;
  late SqliteShiftRecordRepository shiftRepo;
  late SqliteOpenShiftSnapshotRepository openSnapshotRepo;
  late SqliteWageRoleRowRepository wageRepo;

  setUpAll(() async {
    final db = await SqliteDatabase.instance.database;
    watermarkDao = ImportTrackingDao(db);
    shiftRepo = SqliteShiftRecordRepository.instance;
    openSnapshotRepo = SqliteOpenShiftSnapshotRepository.instance;
    wageRepo = SqliteWageRoleRowRepository.instance;
  });

  // Findings flush happens after every test group has run.
  tearDownAll(() async {
    await _flushFindings();
  });

  // Cleans every restaurant_id used by the harness so each test
  // starts from an empty state regardless of execution order.
  Future<void> wipeAllScopes() async {
    final db = await SqliteDatabase.instance.database;
    for (final rid in <String>[_ridA, _ridB]) {
      await db.delete(
        'shift_records',
        where: 'restaurant_id = ?',
        whereArgs: <Object?>[rid],
      );
      await db.delete(
        'open_shift_snapshots',
        where: 'restaurant_id = ?',
        whereArgs: <Object?>[rid],
      );
      await db.delete(
        'reservation_book_snapshots',
        where: 'restaurant_id = ?',
        whereArgs: <Object?>[rid],
      );
      await wageRepo.deleteAll(rid);
      await db.delete(
        'sync_watermarks',
        where: 'restaurant_id = ?',
        whereArgs: <Object?>[rid],
      );
      await db.delete(
        'restaurant_timing_configs',
        where: 'restaurant_id = ?',
        whereArgs: <Object?>[rid],
      );
    }
  }

  setUp(() async {
    await wipeAllScopes();
  });

  tearDown(() async {
    await wipeAllScopes();
  });

  // ── Task 1 / 5: Operator-scoped subset delivered + widget render ────────

  group('Task 1: operator-scoped subset delivered to mobile SQLite', () {
    test(
      'shift records: scoped subset materialises in shift_records',
      (() async {
        for (final vendorId in _posVendors) {
          await wipeAllScopes();
          final fixture = 'pos/$vendorId/shift_records';
          final client = _StubSyncProxyClient()
            ..scriptShiftPages(<_ShiftPage>[
              _ShiftPage(
                records: <ShiftRecord>[
                  _shift(
                    _ridA,
                    weekId: '2026-W19',
                    day: 'Mon',
                    daypart: 'lunch',
                    source: vendorId,
                    covers: 80,
                  ),
                  _shift(
                    _ridA,
                    weekId: '2026-W19',
                    day: 'Mon',
                    daypart: 'dinner',
                    source: vendorId,
                    covers: 140,
                  ),
                ],
                nextCursor: null,
              ),
            ]);

          final sync = PostgresShiftRecordToMobileSync(
            client: client,
            shiftRepository: shiftRepo,
            watermarkDao: watermarkDao,
          );
          final result = await sync.sync(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: _ridA,
          );

          if (result.recordsWritten != 2) {
            _record(
              'sync_records_not_written',
              fixture: fixture,
              severity: 'high',
              message:
                  'expected 2 records written, got '
                  '${result.recordsWritten}',
              details: <String, Object?>{
                'vendor': vendorId,
                'pages_pulled': result.pagesPulled,
              },
            );
          }
          final stored = await shiftRepo.getShiftsForWeek(_ridA, '2026-W19');
          if (stored.length != 2) {
            _record(
              'shift_records_count_mismatch',
              fixture: fixture,
              severity: 'high',
              message:
                  'shift_records row count mismatch — expected 2 got '
                  '${stored.length}',
              details: <String, Object?>{'vendor': vendorId},
            );
          }
          // Cross-tenant isolation: there must be no rows for op B's rid.
          final crossStored = await shiftRepo.getShiftsForWeek(
            _ridB,
            '2026-W19',
          );
          if (crossStored.isNotEmpty) {
            _record(
              'operator_data_leak_after_switch',
              fixture: fixture,
              severity: 'critical',
              message:
                  'rows for foreign restaurant_id materialised after '
                  'scoped sync',
              details: <String, Object?>{
                'vendor': vendorId,
                'foreign_rows': crossStored.length,
              },
            );
          }
          expect(stored.length, 2, reason: 'shift_records count for $vendorId');
        }
      }),
    );

    test('labor wage rows: scoped cache replaces prior data', (() async {
      for (final vendorId in _laborVendors) {
        await wipeAllScopes();
        final fixture = 'labor/$vendorId/wage_role_rows';
        final client = _StubSyncProxyClient()
          ..scriptShiftPages(<_ShiftPage>[
            _ShiftPage(records: const <ShiftRecord>[], nextCursor: null),
          ])
          ..scriptWageRoleRows(<WageRoleRow>[
            WageRoleRow(
              restaurantId: 'server-side-id',
              roleName: 'Server',
              laborBucket: 'foh',
              hourlyRate: 16.5,
              weightedHours: 32,
              source: vendorId,
            ),
            WageRoleRow(
              restaurantId: 'server-side-id',
              roleName: 'Line Cook',
              laborBucket: 'boh',
              hourlyRate: 18.0,
              weightedHours: 40,
              source: vendorId,
            ),
          ]);

        final sync = PostgresShiftRecordToMobileSync(
          client: client,
          shiftRepository: shiftRepo,
          watermarkDao: watermarkDao,
          wageRoleRowRepository: wageRepo,
        );
        await sync.sync(
          operatorId: _opA,
          locationId: _locA,
          restaurantId: _ridA,
        );

        final stored = await wageRepo.getRows(_ridA);
        if (stored.length != 2) {
          _record(
            'wage_role_rows_count_mismatch',
            fixture: fixture,
            severity: 'high',
            message:
                'wage_role_rows count mismatch — expected 2 got '
                '${stored.length}',
            details: <String, Object?>{'vendor': vendorId},
          );
        }
        if (stored.any((r) => r.restaurantId != _ridA)) {
          _record(
            'wage_role_rows_scope_leak',
            fixture: fixture,
            severity: 'critical',
            message:
                'wage_role_rows mirrored under wrong restaurant_id '
                '(server-side id leaked through)',
            details: <String, Object?>{'vendor': vendorId},
          );
        }
        expect(stored.length, 2);
      }
    }));

    test('reservation snapshots: scoped subset reaches '
        'reservation_book_snapshots', (() async {
      for (final vendorId in _reservationVendors) {
        await wipeAllScopes();
        final fixture = 'reservation/$vendorId/reservation_book_snapshots';
        final db = await SqliteDatabase.instance.database;
        // The mobile sync layer doesn't carry reservation rows in the
        // primary surface, so the harness writes them directly to model
        // the post-projector materialisation step. Asserts the table
        // accepts the canonical fact shape and that scoped reads only
        // see the active scope's rows.
        await db.insert('reservation_book_snapshots', <String, Object?>{
          'restaurant_id': _ridA,
          'business_date': '2026-05-04',
          'daypart': 'dinner',
          'unseated_covers': 30,
          'unseated_party_count': 6,
          'source_system': vendorId,
          'source_service_id': 'svc_1',
          'last_event_at': '2026-05-04T18:00:00.000Z',
          'updated_at': '2026-05-04T18:01:00.000Z',
        });
        await db.insert('reservation_book_snapshots', <String, Object?>{
          'restaurant_id': _ridB,
          'business_date': '2026-05-04',
          'daypart': 'dinner',
          'unseated_covers': 99,
          'unseated_party_count': 99,
          'source_system': vendorId,
          'source_service_id': 'svc_b',
          'last_event_at': '2026-05-04T18:00:00.000Z',
          'updated_at': '2026-05-04T18:01:00.000Z',
        });

        final scopedRows = await db.query(
          'reservation_book_snapshots',
          where: 'restaurant_id = ?',
          whereArgs: <Object?>[_ridA],
        );
        if (scopedRows.length != 1) {
          _record(
            'reservation_snapshot_count_mismatch',
            fixture: fixture,
            severity: 'high',
            message:
                'reservation_book_snapshots scoped read count '
                'mismatch — expected 1 got ${scopedRows.length}',
            details: <String, Object?>{'vendor': vendorId},
          );
        }
        if (scopedRows.isNotEmpty &&
            scopedRows.single['unseated_covers'] != 30) {
          _record(
            'reservation_payload_corruption',
            fixture: fixture,
            severity: 'high',
            message: 'reservation snapshot payload mismatch',
            details: <String, Object?>{
              'vendor': vendorId,
              'expected': 30,
              'actual': scopedRows.single['unseated_covers'],
            },
          );
        }
        expect(scopedRows.length, 1);
      }
    }));
  });

  // ── Task 2: Sync resumes after operator switch ─────────────────────────

  group('Task 2: scope flip tears down + re-bootstraps SQLite', () {
    test('flipping operator wipes prior tenant rows before re-sync', (() async {
      const fixture = 'scope_flip/op_a_to_op_b';

      // Boot operator A with rows.
      final clientA = _StubSyncProxyClient()
        ..scriptShiftPages(<_ShiftPage>[
          _ShiftPage(
            records: <ShiftRecord>[
              _shift(
                _ridA,
                weekId: '2026-W19',
                day: 'Mon',
                daypart: 'lunch',
                source: 'toast',
              ),
              _shift(
                _ridA,
                weekId: '2026-W19',
                day: 'Tue',
                daypart: 'lunch',
                source: 'toast',
              ),
            ],
            nextCursor: null,
          ),
        ])
        ..scriptWageRoleRows(<WageRoleRow>[
          const WageRoleRow(
            restaurantId: 'svr',
            roleName: 'A-Server',
            laborBucket: 'foh',
            hourlyRate: 16,
            weightedHours: 32,
          ),
        ]);
      final syncA = PostgresShiftRecordToMobileSync(
        client: clientA,
        shiftRepository: shiftRepo,
        watermarkDao: watermarkDao,
        wageRoleRowRepository: wageRepo,
      );
      await syncA.sync(
        operatorId: _opA,
        locationId: _locA,
        restaurantId: _ridA,
      );

      var aRows = await shiftRepo.getShiftsForWeek(_ridA, '2026-W19');
      expect(aRows, hasLength(2));
      var aWage = await wageRepo.getRows(_ridA);
      expect(aWage, hasLength(1));

      // Flip to operator B. Production wires this through
      // `MobileOperationalSyncHost._wipeOtherTenantsThenSync` ->
      // `defaultCrossTenantWipe` -> per-repo `wipeForOtherScopes`.
      // The harness invokes the same hook directly so the seam under
      // test is the wipe + re-sync sequence, not the host wiring.
      try {
        await defaultCrossTenantWipe(_ridB);
      } catch (e) {
        _record(
          'cross_tenant_wipe_failed',
          fixture: fixture,
          severity: 'critical',
          message: 'defaultCrossTenantWipe threw: $e',
        );
        rethrow;
      }

      aRows = await shiftRepo.getShiftsForWeek(_ridA, '2026-W19');
      if (aRows.isNotEmpty) {
        _record(
          'operator_data_leak_after_switch',
          fixture: fixture,
          severity: 'critical',
          message:
              'shift_records for prior operator A still readable after '
              'scope flip',
          details: <String, Object?>{
            'leaked_rows': aRows.length,
            'kept_restaurant_id': _ridB,
          },
        );
      }
      aWage = await wageRepo.getRows(_ridA);
      if (aWage.isNotEmpty) {
        _record(
          'operator_data_leak_after_switch',
          fixture: fixture,
          severity: 'critical',
          message:
              'wage_role_rows for prior operator A still readable '
              'after scope flip',
          details: <String, Object?>{'leaked_rows': aWage.length},
        );
      }

      // Re-bootstrap operator B with fresh data.
      final clientB = _StubSyncProxyClient()
        ..scriptShiftPages(<_ShiftPage>[
          _ShiftPage(
            records: <ShiftRecord>[
              _shift(
                _ridB,
                weekId: '2026-W19',
                day: 'Mon',
                daypart: 'lunch',
                source: 'oracle_micros_simphony',
              ),
            ],
            nextCursor: null,
          ),
        ])
        ..scriptWageRoleRows(<WageRoleRow>[
          const WageRoleRow(
            restaurantId: 'svr-b',
            roleName: 'B-Server',
            laborBucket: 'foh',
            hourlyRate: 17,
            weightedHours: 28,
          ),
        ]);
      final syncB = PostgresShiftRecordToMobileSync(
        client: clientB,
        shiftRepository: shiftRepo,
        watermarkDao: watermarkDao,
        wageRoleRowRepository: wageRepo,
      );
      await syncB.sync(
        operatorId: _opB,
        locationId: _locB,
        restaurantId: _ridB,
      );

      final bRows = await shiftRepo.getShiftsForWeek(_ridB, '2026-W19');
      expect(bRows, hasLength(1));
      final bWage = await wageRepo.getRows(_ridB);
      expect(bWage.single.roleName, 'B-Server');

      // Final assertion: operator A's tables are still empty.
      final residualA = await shiftRepo.getShiftsForWeek(_ridA, '2026-W19');
      if (residualA.isNotEmpty) {
        _record(
          'operator_data_leak_after_switch',
          fixture: fixture,
          severity: 'critical',
          message:
              'op A rows reappeared after op B re-sync (likely a '
              'cursor / cache regression)',
          details: <String, Object?>{'rows': residualA.length},
        );
      }
      expect(residualA, isEmpty);
    }));

    test('per-scope cursor watermarks remain isolated across flips', (() async {
      const fixture = 'scope_flip/cursor_isolation';
      // Op A advances watermark to "cursor-A1".
      final clientA = _StubSyncProxyClient()
        ..scriptShiftPages(<_ShiftPage>[
          _ShiftPage(
            records: <ShiftRecord>[
              _shift(
                _ridA,
                weekId: '2026-W19',
                day: 'Wed',
                daypart: 'lunch',
                source: 'toast',
              ),
            ],
            nextCursor: 'cursor-A1',
          ),
          _ShiftPage(records: const <ShiftRecord>[], nextCursor: null),
        ]);
      final syncA = PostgresShiftRecordToMobileSync(
        client: clientA,
        shiftRepository: shiftRepo,
        watermarkDao: watermarkDao,
      );
      await syncA.sync(
        operatorId: _opA,
        locationId: _locA,
        restaurantId: _ridA,
      );

      // Op B sweeps with no cursor history — should NOT inherit op A's
      // cursor.
      final clientB = _StubSyncProxyClient()
        ..scriptShiftPages(<_ShiftPage>[
          _ShiftPage(records: const <ShiftRecord>[], nextCursor: null),
        ]);
      final syncB = PostgresShiftRecordToMobileSync(
        client: clientB,
        shiftRepository: shiftRepo,
        watermarkDao: watermarkDao,
      );
      await syncB.sync(
        operatorId: _opB,
        locationId: _locB,
        restaurantId: _ridB,
      );
      if (clientB.shiftCursorsObserved.first != null) {
        _record(
          'cross_scope_cursor_leak',
          fixture: fixture,
          severity: 'high',
          message:
              'op B first sweep saw cursor ${clientB.shiftCursorsObserved.first} '
              'but it should be null (no prior watermark for opB scope)',
        );
      }
      expect(clientB.shiftCursorsObserved.first, isNull);
    }));
  });

  // ── Task 5: Synced data queryable per category ─────────────────────────

  group('Task 5: synced data queryable per category', () {
    test('Synced shift, wage, and reservation rows are queryable per '
        'category without nulls in NOT NULL columns', () async {
      const fixture = 'render/sql_queryability_per_category';
      final db = await SqliteDatabase.instance.database;
      await wipeAllScopes();

      // Seed each category via the same surfaces used by the sync layer
      // and verify a representative SELECT returns canonical-shaped
      // payloads (no NULL on NOT NULL columns, matching scope).
      final client = _StubSyncProxyClient()
        ..scriptShiftPages(<_ShiftPage>[
          _ShiftPage(
            records: <ShiftRecord>[
              _shift(
                _ridA,
                weekId: '2026-W19',
                day: 'Sat',
                daypart: 'dinner',
                source: 'toast',
                covers: 220,
              ),
            ],
            nextCursor: null,
          ),
        ])
        ..scriptOpenShiftPages(<_OpenPage>[
          _OpenPage(
            snapshots: <OpenShiftSnapshot>[_openSnapshot(_ridA)],
            nextCursor: null,
          ),
        ])
        ..scriptWageRoleRows(<WageRoleRow>[
          const WageRoleRow(
            restaurantId: 'srv',
            roleName: 'Server',
            laborBucket: 'foh',
            hourlyRate: 16.5,
            weightedHours: 32,
          ),
        ]);
      final sync = PostgresShiftRecordToMobileSync(
        client: client,
        shiftRepository: shiftRepo,
        watermarkDao: watermarkDao,
        openShiftSnapshotRepository: openSnapshotRepo,
        wageRoleRowRepository: wageRepo,
      );
      await sync.sync(operatorId: _opA, locationId: _locA, restaurantId: _ridA);
      await db.insert('reservation_book_snapshots', <String, Object?>{
        'restaurant_id': _ridA,
        'business_date': '2026-05-04',
        'daypart': 'dinner',
        'unseated_covers': 8,
        'unseated_party_count': 2,
        'source_system': 'opentable',
        'updated_at': '2026-05-04T18:00:00.000Z',
      });

      final shiftRows = await db.query(
        'shift_records',
        where: 'restaurant_id = ?',
        whereArgs: <Object?>[_ridA],
      );
      if (shiftRows.isEmpty) {
        _record(
          'sync_writes_did_not_persist',
          fixture: fixture,
          severity: 'high',
          message: 'no shift_records rows visible after sync sweep',
        );
      }
      for (final row in shiftRows) {
        for (final col in <String>[
          'restaurant_id',
          'week_id',
          'day_label',
          'daypart',
          'status',
          'business_date',
        ]) {
          if (row[col] == null) {
            _record(
              'shift_records_null_required_field',
              fixture: fixture,
              severity: 'critical',
              message:
                  'shift_records.$col is NULL post-sync; widgets that '
                  'expect non-null values would crash on render',
              details: <String, Object?>{'column': col},
            );
          }
        }
      }
      final openRows = await db.query(
        'open_shift_snapshots',
        where: 'restaurant_id = ?',
        whereArgs: <Object?>[_ridA],
      );
      if (openRows.isEmpty) {
        _record(
          'open_shift_snapshot_not_persisted',
          fixture: fixture,
          severity: 'high',
          message: 'no open_shift_snapshots rows visible after sync',
        );
      }
      final wageRows = await wageRepo.getRows(_ridA);
      if (wageRows.isEmpty) {
        _record(
          'wage_role_rows_not_persisted',
          fixture: fixture,
          severity: 'high',
          message: 'no wage_role_rows rows visible after sync',
        );
      }
      final resvRows = await db.query(
        'reservation_book_snapshots',
        where: 'restaurant_id = ?',
        whereArgs: <Object?>[_ridA],
      );
      if (resvRows.isEmpty) {
        _record(
          'reservation_snapshot_not_persisted',
          fixture: fixture,
          severity: 'high',
          message: 'no reservation_book_snapshots rows visible',
        );
      }

      expect(shiftRows, isNotEmpty);
      expect(openRows, isNotEmpty);
      expect(wageRows, isNotEmpty);
      expect(resvRows, isNotEmpty);
    });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────────

ShiftRecord _shift(
  String restaurantId, {
  required String weekId,
  required String day,
  required String daypart,
  required String source,
  int covers = 60,
}) {
  return ShiftRecord(
    restaurantId: restaurantId,
    weekId: weekId,
    dayLabel: day,
    daypart: daypart,
    status: 'closed',
    covers: covers,
    forecastCovers: covers,
    ppa: 24.0,
    cplh: 30.0,
    splh: 70.0,
    fohHours: 18,
    bohHours: 16,
    primaryLever: 'ON_MODEL',
    sourceSystem: source,
    businessDate: '2026-05-04',
  );
}

OpenShiftSnapshot _openSnapshot(String restaurantId) {
  return OpenShiftSnapshot(
    restaurantId: restaurantId,
    weekId: '2026-W19',
    dayLabel: 'Sat',
    daypart: 'dinner',
    status: 'open',
    businessDate: '2026-05-04',
    forecastCovers: 220,
    currentCovers: 110,
    scheduledFohHours: 14,
    scheduledBohHours: 11,
    currentPPA: 36.0,
    currentCPLH: 22.0,
    currentSPLH: 95.0,
    blendedWage: 18.5,
    sourceSystem: 'oracle_micros_simphony',
    sourceShiftId: 'live-shift-render',
    lastEventAt: '2026-05-04T19:00:00.000Z',
    updatedAt: '2026-05-04T19:01:00.000Z',
  );
}

// ─── Stub proxy clients ───────────────────────────────────────────────────

class _ShiftPage {
  const _ShiftPage({required this.records, required this.nextCursor});
  final List<ShiftRecord> records;
  final String? nextCursor;
}

class _OpenPage {
  const _OpenPage({required this.snapshots, required this.nextCursor});
  final List<OpenShiftSnapshot> snapshots;
  final String? nextCursor;
}

/// In-memory proxy stub used by the sync-driven harness tests.
///
/// Behaviour mirrors `_FakeSyncProxyClient` from
/// `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart`
/// — every method answers from scripted state and the optional aux
/// fields default to empty / null so unspecified surfaces stay silent.
class _StubSyncProxyClient implements SyncProxyClient {
  final List<_ShiftPage> _shiftPages = <_ShiftPage>[];
  final List<_OpenPage> _openPages = <_OpenPage>[];
  final List<String?> shiftCursorsObserved = <String?>[];
  final List<String?> openCursorsObserved = <String?>[];

  List<DemoModeRecord> _demoStates = const <DemoModeRecord>[];
  DataAccuracySettingsSnapshot? _accuracy;
  final List<DataAccuracyServicePeriodSetting> _accuracyKeyed =
      const <DataAccuracyServicePeriodSetting>[];
  List<WageRoleRow> _wageRoleRows = const <WageRoleRow>[];
  ForgeFlowPollingTierAssignmentSnapshot? _polling;
  FirstBackfillStatusSnapshot? _firstBackfill;
  RestaurantTimingConfig? _timing;

  void scriptShiftPages(List<_ShiftPage> pages) {
    _shiftPages
      ..clear()
      ..addAll(pages);
  }

  void scriptOpenShiftPages(List<_OpenPage> pages) {
    _openPages
      ..clear()
      ..addAll(pages);
  }

  void scriptDemoStates(List<DemoModeRecord> rows) {
    _demoStates = rows;
  }

  void scriptWageRoleRows(List<WageRoleRow> rows) {
    _wageRoleRows = rows;
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
    return ShiftRecordPage(records: page.records, nextCursor: page.nextCursor);
  }

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    openCursorsObserved.add(cursor);
    if (_openPages.isEmpty) {
      return const OpenShiftSnapshotPage(
        snapshots: <OpenShiftSnapshot>[],
        nextCursor: null,
      );
    }
    final page = _openPages.removeAt(0);
    return OpenShiftSnapshotPage(
      snapshots: page.snapshots,
      nextCursor: page.nextCursor,
    );
  }

  @override
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? businessDate,
  }) async => _timing;

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async => _demoStates;

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) async => _accuracy;

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
  fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) async => _accuracyKeyed;

  @override
  Future<List<WageRoleRow>> fetchWageRoleRows({
    required String operatorId,
    required String locationId,
  }) async => _wageRoleRows;

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async => _polling;

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) async => _firstBackfill;
}
