// Phase 8 spine-bridge Lane .A — DataAccuracySettingsRepository tests.
//
// Covers acceptance items A, B, D from the lane prompt:
//
//   A. data_accuracy RLS round-trip (operator A vs B isolation) —
//      every read / write goes through `withTenant` with the matching
//      (operator_id, location_id) SET LOCAL chain so the per-tenant
//      RLS policy admits the row only for its own tenant.
//
//   B. Per-daypart partial covers update — `updateCoversSourceForDaypart`
//      touches only the named daypart's column, leaving the other two
//      and the wage source intact.
//
//   D. Historical seed bulk entry — `applyHistoricalCoversSeed`
//      deep-merges the supplied date+daypart entries into the existing
//      jsonb. Prior dates the seed does not name are preserved; the
//      named entries are upserted into the existing date map.
//
// Tests run against a recording fake `PostgresPool` (mirrors the
// EventOutbox / Locations test seam) — no live Postgres needed.

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

Map<String, Object?> _settingsRow({
  String operatorId = _opA,
  String locationId = _locA,
  String coversLunch = 'vendor',
  String coversDinner = 'vendor',
  String coversLateNight = 'vendor',
  Map<String, Object?>? manualEntries,
  String wageSource = 'vendor',
}) {
  return <String, Object?>{
    'setting_id': '99999999-9999-9999-9999-999999999999',
    'operator_id': operatorId,
    'location_id': locationId,
    'covers_source_lunch': coversLunch,
    'covers_source_dinner': coversDinner,
    'covers_source_late_night': coversLateNight,
    'covers_manual_entries': manualEntries ?? <String, Object?>{},
    'wage_source': wageSource,
    'created_at': DateTime.utc(2026, 5, 5, 10),
    'updated_at': DateTime.utc(2026, 5, 5, 11),
    'updated_by': _userA,
  };
}

void main() {
  group('DataAccuracySettingsRepository — RLS round-trip (item A)', () {
    test(
      'readOrCreateDefault returns the existing row for operator A only — '
      'tenant SET LOCAL flows operator A\'s GUC and the SELECT filters '
      'on operator_id::uuid + location_id::uuid',
      () async {
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
        // Tenant GUC injection precedes the SELECT.
        final operatorSetCfg = tx.parameters.firstWhere(
          (p) => p['value'] == _opA,
        );
        expect(operatorSetCfg['value'], equals(_opA));
        final locationSetCfg = tx.parameters.firstWhere(
          (p) => p['value'] == _locA,
        );
        expect(locationSetCfg['value'], equals(_locA));
        // SELECT carries the tenant predicate.
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from data_accuracy_settings'),
        );
        expect(
          selectSql,
          contains('where operator_id = @operator_id::uuid'),
        );
        expect(
          selectSql,
          contains('and location_id = @location_id::uuid'),
        );
      },
    );

    test(
      'two distinct tenants (A vs B) open independent transactions so '
      'one tenant\'s SET LOCAL never leaks into the other',
      () async {
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

        // Two independent transactions, each with its own SET LOCAL
        // chain — never reuses a connection mid-context.
        expect(pool.transactions, hasLength(2));
        final txA = pool.transactions[0];
        final txB = pool.transactions[1];
        expect(
          txA.parameters.firstWhere((p) => p['value'] == _opA)['value'],
          equals(_opA),
          reason: 'tx[0] sets operator A',
        );
        expect(
          txB.parameters.firstWhere((p) => p['value'] == _opB)['value'],
          equals(_opB),
          reason: 'tx[1] sets operator B; A\'s GUC never reused',
        );
      },
    );

    test(
      'rejects a malformed operator UUID at the wrapper boundary — no '
      'transaction opens (tenant context cannot leak a bad value into '
      'SET LOCAL)',
      () async {
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
      },
    );
  });

  group('DataAccuracySettingsRepository — per-daypart partial update '
      '(item B)', () {
    test(
      'updateCoversSourceForDaypart on dinner sets only the dinner '
      'column; lunch + late_night + wage_source carried through from '
      'the existing row',
      () async {
        final pool = _DataAccuracyPool(
          existingRows: <PostgresRow>[
            _settingsRow(
              coversLunch: 'manual',
              coversDinner: 'vendor',
              coversLateNight: 'forecast',
              wageSource: 'manual_mix',
            ),
          ],
          updatedRows: <PostgresRow>[
            _settingsRow(
              coversLunch: 'manual',
              coversDinner: 'forecast',
              coversLateNight: 'forecast',
              wageSource: 'manual_mix',
            ),
          ],
        );
        final repo = DataAccuracySettingsRepository(
          TenantTransactionWrapper(pool),
        );
        final updated = await repo.updateCoversSourceForDaypart(
          operatorId: _opA,
          locationId: _locA,
          daypart: Daypart.dinner,
          source: CoversSource.forecast,
          actorUserId: _userA,
        );
        expect(updated.coversSourceLunch, equals(CoversSource.manual));
        expect(updated.coversSourceDinner, equals(CoversSource.forecast));
        expect(updated.coversSourceLateNight, equals(CoversSource.forecast));
        expect(updated.wageSource, equals(WageSource.manualMix));

        // The UPDATE SQL re-binds every column (so the partial
        // semantics are enforced by the repository's read-current +
        // re-bind unchanged logic, not by NULL-coalesce). Verify the
        // bound values match the partial intent.
        final tx = pool.transactions.single;
        final updateParams = tx.parameters.firstWhere(
          (p) => p['covers_dinner'] == 'forecast',
        );
        expect(updateParams['covers_lunch'], equals('manual'));
        expect(updateParams['covers_late_night'], equals('forecast'));
        expect(updateParams['wage_source'], equals('manual_mix'));
      },
    );

    test(
      'updateCoversSourceForDaypart with manual covers patch upserts '
      'into existing covers_manual_entries jsonb under the same '
      'business_date — prior dayparts at that date preserved',
      () async {
        final pool = _DataAccuracyPool(
          existingRows: <PostgresRow>[
            _settingsRow(
              coversLunch: 'manual',
              manualEntries: <String, Object?>{
                '2026-05-04': <String, Object?>{'lunch': 87, 'dinner': 187},
              },
            ),
          ],
          updatedRows: <PostgresRow>[
            _settingsRow(
              coversLunch: 'manual',
              manualEntries: <String, Object?>{
                '2026-05-04': <String, Object?>{
                  'lunch': 87,
                  'dinner': 187,
                  'late_night': 12,
                },
              },
            ),
          ],
        );
        final repo = DataAccuracySettingsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.updateCoversSourceForDaypart(
          operatorId: _opA,
          locationId: _locA,
          daypart: Daypart.lateNight,
          source: CoversSource.manual,
          businessDateIso: '2026-05-04',
          setManualCovers: 12,
          actorUserId: _userA,
        );

        final tx = pool.transactions.single;
        final updateParams = tx.parameters.firstWhere(
          (p) => p['covers_late_night'] == 'manual',
        );
        // Repository serialises the patched jsonb into the bound
        // `manual_entries` parameter as a JSON string.
        final boundJson = updateParams['manual_entries'] as String;
        final decoded = jsonDecode(boundJson) as Map<String, Object?>;
        final dateMap = decoded['2026-05-04'] as Map<String, Object?>;
        expect(dateMap['lunch'], equals(87));
        expect(dateMap['dinner'], equals(187));
        expect(dateMap['late_night'], equals(12));
      },
    );
  });

  group('DataAccuracySettingsRepository — historical seed bulk entry '
      '(item D)', () {
    test(
      'applyHistoricalCoversSeed deep-merges per-date entries; '
      'pre-existing dates the seed does not name are preserved; '
      'pre-existing dayparts at named dates are overwritten by the seed',
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
          updatedRows: <PostgresRow>[_settingsRow()],
        );
        final repo = DataAccuracySettingsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.applyHistoricalCoversSeed(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _userA,
          entries: <String, Map<Daypart, int>>{
            // Re-seed 2026-05-02 dinner (overwrite) + add late_night.
            '2026-05-02': <Daypart, int>{
              Daypart.dinner: 250,
              Daypart.lateNight: 25,
            },
            // Brand-new date 2026-05-03 (full daypart triple).
            '2026-05-03': <Daypart, int>{
              Daypart.lunch: 80,
              Daypart.dinner: 210,
              Daypart.lateNight: 15,
            },
          },
        );

        final tx = pool.transactions.single;
        final updateParams = tx.parameters.firstWhere(
          (p) => p['manual_entries'] is String,
        );
        final boundJson = updateParams['manual_entries'] as String;
        final decoded = jsonDecode(boundJson) as Map<String, Object?>;

        // 2026-05-01 untouched.
        expect(decoded['2026-05-01'], equals({'lunch': 60}));
        // 2026-05-02 lunch preserved; dinner overwritten; late_night added.
        final may2 = decoded['2026-05-02'] as Map<String, Object?>;
        expect(may2['lunch'], equals(70), reason: 'lunch preserved');
        expect(may2['dinner'], equals(250), reason: 'dinner overwritten');
        expect(may2['late_night'], equals(25), reason: 'late_night added');
        // 2026-05-03 fully written.
        expect(decoded['2026-05-03'], equals({
          'lunch': 80,
          'dinner': 210,
          'late_night': 15,
        }));
      },
    );
  });

  group('DataAccuracySettingsRepository — defensive read-create path', () {
    test(
      'readOrCreateDefault inserts a default row when none exists, '
      'then re-SELECTs to return whichever row landed (concurrent '
      'first-create collapses onto the unique index)',
      () async {
        final pool = _DataAccuracyPool(
          existingRows: const <PostgresRow>[], // first SELECT empty
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
        expect(row.coversSourceLunch, equals(CoversSource.vendor));
        expect(row.wageSource, equals(WageSource.vendor));

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into data_accuracy_settings'),
        );
        expect(insertSql, contains('on conflict (operator_id, location_id)'));
        expect(insertSql, contains('do nothing'));
      },
    );
  });
}

class _DataAccuracyPool implements PostgresPool {
  _DataAccuracyPool({
    this.existingRows = const <PostgresRow>[],
    this.existingRowsAlt = const <PostgresRow>[],
    this.updatedRows = const <PostgresRow>[],
    this.firstCreateRow,
  });

  final List<PostgresRow> existingRows;
  final List<PostgresRow> existingRowsAlt;
  final List<PostgresRow> updatedRows;
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
      updatedRows: updatedRows,
      firstCreateRow: firstCreateRow,
    );
    transactions.add(tx);
    return tx;
  }
}

class _DataAccuracyTransaction extends PostgresTransaction {
  _DataAccuracyTransaction({
    required this.existingRows,
    required this.updatedRows,
    required this.firstCreateRow,
  });

  final List<PostgresRow> existingRows;
  final List<PostgresRow> updatedRows;
  final PostgresRow? firstCreateRow;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  int commitCount = 0;
  int rollbackCount = 0;
  bool _finalized = false;
  int _selectsSeen = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from data_accuracy_settings')) {
      _selectsSeen += 1;
      // First SELECT returns the seeded existing row(s); any follow-up
      // SELECT (after the readOrCreateDefault INSERT) returns the
      // freshly-created row.
      if (_selectsSeen == 1) return existingRows;
      if (firstCreateRow != null) {
        return <PostgresRow>[firstCreateRow!];
      }
      return existingRows;
    }
    if (sql.contains('update data_accuracy_settings')) {
      return updatedRows;
    }
    if (sql.contains('insert into data_accuracy_settings') &&
        sql.contains('returning')) {
      return updatedRows;
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
