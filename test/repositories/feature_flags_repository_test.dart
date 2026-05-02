// Phase 11A.7 — FeatureFlagsRepository unit tests.
//
// Drives `FeatureFlagsRepository` against a fake `PostgresPool` so
// the SQL shape + parameter mapping are pinned without a live
// database. Coverage:
//
//   * `listFlags` issues a single SELECT with the canonical column
//     list and ordering (destructive-first, then alphabetical), and
//     runs through the `withSystem` audit-marker + role elevation
//     stages.
//   * `findById` parameterises `flag_id` and returns null when the
//     query yields no rows.
//   * `toggleFlag` UPDATEs `enabled` + `updated_by` keyed on
//     `flag_id` and projects the post-update row.
//
// Mirrors the `_CorpusPool` shape from
// `test/repositories/corpus_repository_test.dart`.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/feature_flags_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

void main() {
  PostgresRow seedRow({
    String flagId = '00000000-0000-4000-8000-0000000000f1',
    String flagName = 'advisor_enabled',
    String? operatorId,
    String? locationId,
    bool enabled = true,
    String kind = 'standard',
    String? description,
    String? updatedBy,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return <String, Object?>{
      'flag_id': flagId,
      'flag_name': flagName,
      'operator_id': operatorId,
      'location_id': locationId,
      'enabled': enabled,
      'kind': kind,
      'description': description,
      'updated_by': updatedBy,
      'created_at': createdAt ?? DateTime.utc(2026, 5, 1, 10, 0),
      'updated_at': updatedAt ?? DateTime.utc(2026, 5, 1, 10, 0),
    };
  }

  group('FeatureFlagsRepository.listFlags', () {
    test(
      'issues SELECT with destructive-first ordering and runs '
      'through withSystem (audit marker + role elevation)',
      () async {
        final pool = _FlagsPool(rows: <PostgresRow>[
          seedRow(
            flagId: 'f1',
            flagName: 'audit_logs_cutover_enabled',
            kind: 'destructive',
          ),
          seedRow(
            flagId: 'f2',
            flagName: 'advisor_enabled',
            kind: 'standard',
          ),
        ]);
        final repo = FeatureFlagsRepository(TenantTransactionWrapper(pool));
        final flags = await repo.listFlags(adminReason: 'admin.test.list');
        expect(flags, hasLength(2));
        expect(flags.first.flagName, equals('audit_logs_cutover_enabled'));
        expect(flags.first.kind, equals('destructive'));
        expect(flags.last.flagName, equals('advisor_enabled'));

        final tx = pool.transactions.single;
        // Audit marker + role elevation come before the SELECT.
        expect(tx.executed.first.sql, contains('app.bypass_rls_audit'));
        expect(tx.executed[1].sql, contains('set local role forge_admin'));
        // SELECT shape pins the canonical columns + ordering.
        final selectSql = tx.executed[2].sql;
        expect(selectSql, contains('from public.feature_flags'));
        expect(selectSql, contains('flag_id::text as flag_id'));
        expect(selectSql, contains('kind'));
        expect(selectSql, contains('updated_by'));
        expect(
          selectSql,
          contains("case when kind = 'destructive' then 0 else 1 end"),
          reason:
              'destructive rows must surface first so kill switches '
              'land at the top of the admin grid',
        );
      },
    );
  });

  group('FeatureFlagsRepository.findById', () {
    test(
      'returns the projected row when the SELECT yields one',
      () async {
        final pool = _FlagsPool(rows: <PostgresRow>[
          seedRow(flagId: 'f-1', flagName: 'advisor_enabled'),
        ]);
        final repo = FeatureFlagsRepository(TenantTransactionWrapper(pool));
        final row = await repo.findById(
          flagId: 'f-1',
          adminReason: 'admin.test.find',
        );
        expect(row, isNotNull);
        expect(row!.flagId, equals('f-1'));
        expect(row.flagName, equals('advisor_enabled'));
        final tx = pool.transactions.single;
        final selectSql = tx.executed[2].sql;
        expect(selectSql, contains('where flag_id = @flag_id::uuid'));
        expect(tx.executed[2].parameters['flag_id'], equals('f-1'));
      },
    );

    test('returns null when the row is missing', () async {
      final pool = _FlagsPool(rows: const <PostgresRow>[]);
      final repo = FeatureFlagsRepository(TenantTransactionWrapper(pool));
      final row = await repo.findById(
        flagId: 'f-missing',
        adminReason: 'admin.test.find',
      );
      expect(row, isNull);
    });
  });

  group('FeatureFlagsRepository.toggleFlag', () {
    test(
      'UPDATEs enabled + updated_by keyed on flag_id and projects '
      'the post-update row',
      () async {
        final pool = _FlagsPool(rowsByContains: <String, List<PostgresRow>>{
          'update public.feature_flags': <PostgresRow>[
            seedRow(
              flagId: 'f-1',
              flagName: 'advisor_enabled',
              enabled: false,
              updatedBy: 'super-admin-uuid',
              updatedAt: DateTime.utc(2026, 5, 2, 12, 0),
            ),
          ],
        });
        final repo = FeatureFlagsRepository(TenantTransactionWrapper(pool));
        final updated = await repo.toggleFlag(
          flagId: 'f-1',
          enabled: false,
          actorUserId: 'super-admin-uuid',
          adminReason: 'admin.test.toggle',
        );
        expect(updated, isNotNull);
        expect(updated!.enabled, isFalse);
        expect(updated.updatedBy, equals('super-admin-uuid'));

        final tx = pool.transactions.single;
        final updateStmt = tx.executed
            .firstWhere((s) => s.sql.contains('update public.feature_flags'));
        expect(updateStmt.sql, contains('set enabled = @enabled'));
        expect(updateStmt.sql, contains('updated_by = @actor'));
        expect(updateStmt.sql, contains('where flag_id = @flag_id::uuid'));
        expect(updateStmt.sql, contains('returning'));
        expect(updateStmt.parameters['enabled'], equals(false));
        expect(updateStmt.parameters['actor'], equals('super-admin-uuid'));
        expect(updateStmt.parameters['flag_id'], equals('f-1'));
      },
    );

    test('returns null when no row matches flag_id', () async {
      final pool = _FlagsPool(rowsByContains: <String, List<PostgresRow>>{
        'update public.feature_flags': const <PostgresRow>[],
      });
      final repo = FeatureFlagsRepository(TenantTransactionWrapper(pool));
      final updated = await repo.toggleFlag(
        flagId: 'f-missing',
        enabled: true,
        actorUserId: 'super-admin-uuid',
        adminReason: 'admin.test.toggle',
      );
      expect(updated, isNull);
    });
  });
}

class _FlagsPool implements PostgresPool {
  _FlagsPool({
    this.rows = const <PostgresRow>[],
    this.rowsByContains = const <String, List<PostgresRow>>{},
  });

  final List<PostgresRow> rows;
  final Map<String, List<PostgresRow>> rowsByContains;
  final List<_FlagsTransaction> transactions = <_FlagsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FlagsTransaction(rows: rows, rowsByContains: rowsByContains);
    transactions.add(tx);
    return tx;
  }
}

class _RecordedSql {
  _RecordedSql({required this.sql, required this.parameters});
  final String sql;
  final PostgresParameters parameters;
}

class _FlagsTransaction extends PostgresTransaction {
  _FlagsTransaction({required this.rows, required this.rowsByContains});

  final List<PostgresRow> rows;
  final Map<String, List<PostgresRow>> rowsByContains;
  final List<_RecordedSql> executed = <_RecordedSql>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executed.add(_RecordedSql(sql: sql, parameters: parameters));
    for (final entry in rowsByContains.entries) {
      if (sql.contains(entry.key)) return entry.value;
    }
    return rows;
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executed.add(_RecordedSql(sql: sql, parameters: parameters));
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
