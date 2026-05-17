// Phase 8 spine-bridge Lane .A — DataAccuracySettingsRepository tests.
//
// Per-Daypart V1 Slice R5 (Gap 27/36): per-period covers source is
// keyed by service_period_key in the
// `data_accuracy_service_period_settings` table; the legacy
// `covers_source_lunch` / `_dinner` / `_late_night` columns on
// `data_accuracy_settings` are deprecated and no longer written by
// this repository. These tests cover:
//
//   A. data_accuracy RLS round-trip (operator A vs B isolation) —
//      every read / write goes through `withTenant` with the matching
//      (operator_id, location_id) SET LOCAL chain.
//
//   B. Per-period covers update — `updateCoversSourceForServicePeriod`
//      writes the keyed table (upsert) and patches the manual-entries
//      jsonb on data_accuracy_settings.
//
//   D. Historical seed bulk entry — `applyHistoricalCoversSeed`
//      deep-merges the supplied date+service-period entries into the
//      existing jsonb.
//
// Tests run against a recording fake `PostgresPool` — no live Postgres.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/data_accuracy/data_accuracy_settings_repository.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _locB = '55555555-5555-5555-5555-555555555555';
const String _userA = '33333333-3333-3333-3333-333333333333';

// Mirrors what `_readRow`'s keyed subquery projects: a
// `covers_source_per_service_period` jsonb instead of the legacy
// columns.
Map<String, Object?> _settingsRow({
  String operatorId = _opA,
  String locationId = _locA,
  Map<String, Object?>? perPeriod,
  Map<String, Object?>? manualEntries,
  String wageSource = 'vendor',
  String walkInHandlingMode = 'reservations_only',
  Map<String, Object?>? walkInManualEntries,
}) {
  return <String, Object?>{
    'setting_id': '99999999-9999-9999-9999-999999999999',
    'operator_id': operatorId,
    'location_id': locationId,
    'covers_source_per_service_period':
        perPeriod ?? <String, Object?>{},
    'covers_manual_entries': manualEntries ?? <String, Object?>{},
    'wage_source': wageSource,
    'walk_in_handling_mode': walkInHandlingMode,
    'walk_in_manual_entries': walkInManualEntries ?? <String, Object?>{},
    'created_at': DateTime.utc(2026, 5, 5, 10),
    'updated_at': DateTime.utc(2026, 5, 5, 11),
    'updated_by': _userA,
  };
}

void main() {
  group('DataAccuracySettingsRepository — RLS round-trip (item A)', () {
    test('readOrCreateDefault returns the existing row for operator A only — '
        'tenant SET LOCAL flows operator A\'s GUC and the SELECT filters '
        'on operator_id::uuid + location_id::uuid', () async {
      final pool = _DataAccuracyPool(
        existingRows: <PostgresRow>[_settingsRow(operatorId: _opA)],
      );
      final repo = DataAccuracySettingsRepository(
        TenantTransactionWrapper(pool),
      );
      final row = await repo.readOrCreateDefault(
        operatorId: _opA,
        locationId: _locA,
        actorUserId: _userA,
      );
      expect(row.operatorId, equals(_opA));
      expect(row.locationId, equals(_locA));

      final tx = pool.transactions.single;
      final operatorSetCfg = tx.parameters.firstWhere(
        (p) => p['value'] == _opA,
      );
      expect(operatorSetCfg['value'], equals(_opA));
      final locationSetCfg = tx.parameters.firstWhere(
        (p) => p['value'] == _locA,
      );
      expect(locationSetCfg['value'], equals(_locA));
      final selectSql = tx.executedSql.firstWhere(
        (s) => s.contains('from data_accuracy_settings das'),
      );
      expect(
        selectSql,
        contains('where das.operator_id = @operator_id::uuid'),
      );
      expect(
        selectSql,
        contains('and das.location_id = @location_id::uuid'),
      );
      // The keyed per-period covers source is projected from the keyed
      // table, NOT the deprecated legacy columns.
      expect(
        selectSql,
        contains('data_accuracy_service_period_settings'),
      );
      expect(selectSql, isNot(contains('covers_source_lunch')));
    });

    test('two distinct tenants (A vs B) open independent transactions so '
        'one tenant\'s SET LOCAL never leaks into the other', () async {
      final pool = _DataAccuracyPool(
        existingRows: <PostgresRow>[
          _settingsRow(operatorId: _opA, locationId: _locA),
        ],
        existingRowsAlt: <PostgresRow>[
          _settingsRow(operatorId: _opB, locationId: _locB),
        ],
      );
      final repo = DataAccuracySettingsRepository(
        TenantTransactionWrapper(pool),
      );

      final rowA = await repo.readOrCreateDefault(
        operatorId: _opA,
        locationId: _locA,
      );
      final rowB = await repo.readOrCreateDefault(
        operatorId: _opB,
        locationId: _locB,
      );
      expect(rowA.operatorId, equals(_opA));
      expect(rowB.operatorId, equals(_opB));
      expect(pool.transactions, hasLength(2));
      final txA = pool.transactions[0];
      final txB = pool.transactions[1];
      expect(
        txA.parameters.firstWhere((p) => p['value'] == _opA)['value'],
        equals(_opA),
      );
      expect(
        txB.parameters.firstWhere((p) => p['value'] == _opB)['value'],
        equals(_opB),
      );
    });

    test('rejects a malformed operator UUID at the wrapper boundary — no '
        'transaction opens', () async {
      final pool = _DataAccuracyPool();
      final repo = DataAccuracySettingsRepository(
        TenantTransactionWrapper(pool),
      );
      Object? thrown;
      try {
        await repo.readOrCreateDefault(
          operatorId: 'not-a-uuid',
          locationId: _locA,
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(pool.transactions, isEmpty);
    });
  });

  group('DataAccuracySettingsRepository — per-period covers update '
      '(item B)', () {
    test('updateCoversSourceForServicePeriod writes the keyed '
        'data_accuracy_service_period_settings table (not the legacy '
        'columns) for the named period only', () async {
      final pool = _DataAccuracyPool(
        existingRows: <PostgresRow>[
          _settingsRow(
            perPeriod: <String, Object?>{
              'lunch': 'manual',
              'late_night': 'forecast',
            },
            wageSource: 'manual_mix',
          ),
        ],
      );
      final repo = DataAccuracySettingsRepository(
        TenantTransactionWrapper(pool),
      );
      await repo.updateCoversSourceForServicePeriod(
        operatorId: _opA,
        locationId: _locA,
        servicePeriodId: 'dinner',
        source: CoversSource.forecast,
        actorUserId: _userA,
      );

      final tx = pool.transactions.single;
      final keyedUpsert = tx.executedSql.firstWhere(
        (s) => s.contains(
          'insert into public.data_accuracy_service_period_settings',
        ),
      );
      expect(
        keyedUpsert,
        contains('on conflict (operator_id, location_id, '
            'service_period_key, effective_at_business_date)'),
      );
      final keyedParams = tx.parameters.firstWhere(
        (p) => p['service_period_key'] == 'dinner',
      );
      expect(keyedParams['covers_source'], equals('forecast'));
      // No legacy-column write anywhere.
      expect(
        tx.executedSql.any((s) => s.contains('covers_source_lunch')),
        isFalse,
      );
    });

    test('updateCoversSourceForServicePeriod with a manual covers patch '
        'upserts into the existing covers_manual_entries jsonb under the '
        'same business_date — prior periods at that date preserved',
        () async {
      final pool = _DataAccuracyPool(
        existingRows: <PostgresRow>[
          _settingsRow(
            perPeriod: <String, Object?>{'lunch': 'manual'},
            manualEntries: <String, Object?>{
              '2026-05-04': <String, Object?>{'lunch': 87, 'dinner': 187},
            },
          ),
        ],
      );
      final repo = DataAccuracySettingsRepository(
        TenantTransactionWrapper(pool),
      );
      await repo.updateCoversSourceForServicePeriod(
        operatorId: _opA,
        locationId: _locA,
        servicePeriodId: 'late_night',
        source: CoversSource.manual,
        businessDateIso: '2026-05-04',
        setManualCovers: 12,
        actorUserId: _userA,
      );

      final tx = pool.transactions.single;
      final updateParams = tx.parameters.firstWhere(
        (p) => p['manual_entries'] is String,
      );
      final boundJson = updateParams['manual_entries'] as String;
      final decoded = jsonDecode(boundJson) as Map<String, Object?>;
      final dateMap = decoded['2026-05-04'] as Map<String, Object?>;
      expect(dateMap['lunch'], equals(87));
      expect(dateMap['dinner'], equals(187));
      expect(dateMap['late_night'], equals(12));
    });
  });

  group('DataAccuracySettingsRepository — historical seed bulk entry '
      '(item D)', () {
    test(
      'applyHistoricalCoversSeed deep-merges per-date entries keyed by '
      'service_period_id; unnamed dates preserved; named periods '
      'overwritten',
      () async {
        final pool = _DataAccuracyPool(
          existingRows: <PostgresRow>[
            _settingsRow(
              manualEntries: <String, Object?>{
                '2026-05-01': <String, Object?>{'lunch': 60},
                '2026-05-02': <String, Object?>{'lunch': 70, 'dinner': 200},
              },
            ),
          ],
        );
        final repo = DataAccuracySettingsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.applyHistoricalCoversSeed(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _userA,
          entries: <String, Map<String, int>>{
            '2026-05-02': <String, int>{'dinner': 250, 'late_night': 25},
            '2026-05-03': <String, int>{
              'breakfast': 40,
              'lunch': 80,
              'dinner': 210,
            },
          },
        );

        final tx = pool.transactions.single;
        final updateParams = tx.parameters.firstWhere(
          (p) => p['manual_entries'] is String,
        );
        final decoded = jsonDecode(updateParams['manual_entries'] as String)
            as Map<String, Object?>;
        expect(decoded['2026-05-01'], equals({'lunch': 60}));
        final may2 = decoded['2026-05-02'] as Map<String, Object?>;
        expect(may2['lunch'], equals(70));
        expect(may2['dinner'], equals(250));
        expect(may2['late_night'], equals(25));
        // Brand-new date with a 4th period (breakfast) — proves N
        // periods, not a hardcoded triplet.
        expect(
          decoded['2026-05-03'],
          equals({'breakfast': 40, 'lunch': 80, 'dinner': 210}),
        );
      },
    );
  });

  group('DataAccuracySettingsRepository — defensive read-create path', () {
    test('readOrCreateDefault inserts a default row when none exists, '
        'then re-SELECTs; an empty keyed map resolves to the vendor '
        'default', () async {
      final pool = _DataAccuracyPool(
        existingRows: const <PostgresRow>[],
        firstCreateRow: _settingsRow(),
      );
      final repo = DataAccuracySettingsRepository(
        TenantTransactionWrapper(pool),
      );
      final row = await repo.readOrCreateDefault(
        operatorId: _opA,
        locationId: _locA,
        actorUserId: _userA,
      );
      expect(row.coversSourceFor('lunch'), equals(CoversSource.vendor));
      expect(row.coversSourceFor('dinner'), equals(CoversSource.vendor));
      expect(row.wageSource, equals(WageSource.vendor));

      final tx = pool.transactions.single;
      final insertSql = tx.executedSql.firstWhere(
        (s) => s.contains('insert into data_accuracy_settings'),
      );
      expect(insertSql, contains('on conflict (operator_id, location_id)'));
      expect(insertSql, contains('do nothing'));
    });
  });

  group('DataAccuracySettingsRepository - walk-in handling', () {
    test('updateWalkInHandling patches one business-date count while '
        'preserving the keyed covers + wage settings', () async {
      final pool = _DataAccuracyPool(
        existingRows: <PostgresRow>[
          _settingsRow(
            perPeriod: <String, Object?>{'dinner': 'forecast'},
            wageSource: 'manual_mix',
            walkInHandlingMode: 'reservations_only',
            walkInManualEntries: <String, Object?>{'2026-05-03': 7},
          ),
        ],
      );
      final repo = DataAccuracySettingsRepository(
        TenantTransactionWrapper(pool),
      );

      final updated = await repo.updateWalkInHandling(
        operatorId: _opA,
        locationId: _locA,
        mode: DataAccuracyWalkInHandlingMode.walkInsAddedToReservations,
        businessDateIso: '2026-05-04',
        setWalkInCount: 12,
        actorUserId: _userA,
      );

      expect(
        updated.walkInHandlingMode,
        equals(DataAccuracyWalkInHandlingMode.walkInsAddedToReservations),
      );
      expect(updated.walkInCountFor('2026-05-04'), equals(12));
      final tx = pool.transactions.single;
      final updateParams = tx.parameters.firstWhere(
        (p) => p['walk_in_handling_mode'] == 'walk_ins_added_to_reservations',
      );
      expect(updateParams['wage_source'], equals('manual_mix'));
      final decoded =
          jsonDecode(updateParams['walk_in_manual_entries'] as String)
              as Map<String, Object?>;
      expect(decoded['2026-05-03'], equals(7));
      expect(decoded['2026-05-04'], equals(12));
    });
  });
}

class _DataAccuracyPool implements PostgresPool {
  _DataAccuracyPool({
    this.existingRows = const <PostgresRow>[],
    this.existingRowsAlt = const <PostgresRow>[],
    this.firstCreateRow,
  });

  final List<PostgresRow> existingRows;
  final List<PostgresRow> existingRowsAlt;
  final PostgresRow? firstCreateRow;

  final List<_DataAccuracyTransaction> transactions =
      <_DataAccuracyTransaction>[];

  int _txIndex = 0;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final isAltTx = _txIndex == 1;
    _txIndex += 1;
    final tx = _DataAccuracyTransaction(
      existingRows: isAltTx && existingRowsAlt.isNotEmpty
          ? existingRowsAlt
          : existingRows,
      firstCreateRow: firstCreateRow,
    );
    transactions.add(tx);
    return tx;
  }
}

class _DataAccuracyTransaction extends PostgresTransaction {
  _DataAccuracyTransaction({
    required this.existingRows,
    required this.firstCreateRow,
  });

  final List<PostgresRow> existingRows;
  final PostgresRow? firstCreateRow;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  int commitCount = 0;
  int rollbackCount = 0;
  bool _finalized = false;
  int _selectsSeen = 0;
  // Mutated working copy of the row so a follow-up SELECT after an
  // UPDATE reflects the just-written values (mirrors the real DB).
  PostgresRow? _mutatedRow;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from data_accuracy_settings das')) {
      _selectsSeen += 1;
      // First SELECT returns the seeded existing row(s); a follow-up
      // SELECT (after readOrCreateDefault INSERT or _writeAndReturn
      // UPDATE) returns the created/mutated current row.
      if (_selectsSeen == 1) return existingRows;
      if (_mutatedRow != null) return <PostgresRow>[_mutatedRow!];
      if (firstCreateRow != null) {
        return <PostgresRow>[firstCreateRow!];
      }
      return existingRows.isNotEmpty
          ? existingRows
          : (firstCreateRow != null
              ? <PostgresRow>[firstCreateRow!]
              : const <PostgresRow>[]);
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    // _writeAndReturn checks the affected-row count; a matched UPDATE
    // returns 1 and mutates the working row so the follow-up re-SELECT
    // reflects the write (wage / walk-in / manual-entries).
    if (sql.contains('update data_accuracy_settings set')) {
      final base = _mutatedRow ??
          (existingRows.isNotEmpty
              ? existingRows.first
              : firstCreateRow ?? <String, Object?>{});
      final next = Map<String, Object?>.from(base);
      if (parameters['wage_source'] is String) {
        next['wage_source'] = parameters['wage_source'];
      }
      if (parameters['walk_in_handling_mode'] is String) {
        next['walk_in_handling_mode'] =
            parameters['walk_in_handling_mode'];
      }
      if (parameters['manual_entries'] is String) {
        next['covers_manual_entries'] = jsonDecode(
          parameters['manual_entries'] as String,
        );
      }
      if (parameters['walk_in_manual_entries'] is String) {
        next['walk_in_manual_entries'] = jsonDecode(
          parameters['walk_in_manual_entries'] as String,
        );
      }
      _mutatedRow = next;
      return 1;
    }
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
    rollbackCount += 1;
  }
}
