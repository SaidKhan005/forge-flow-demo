import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/benchmark_overrides_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const operatorId = '22222222-2222-4222-8222-222222222222';
const locationId = '33333333-3333-4333-8333-333333333333';
const actorUserId = '11111111-1111-4111-8111-111111111111';

void main() {
  group('BenchmarkOverridesRepository', () {
    test(
      'listCurrent is read-only compatibility over historical rows',
      () async {
        final pool = _RecordingPostgresPool();
        final repository = BenchmarkOverridesRepository(
          TenantTransactionWrapper(pool),
        );

        final rows = await repository.listCurrent(
          operatorId: operatorId,
          locationId: locationId,
          actorUserId: actorUserId,
        );

        expect(rows, hasLength(1));
        expect(rows.single.metricKey, 'target_cplh');
        final tx = pool.transactions.single;
        expect(tx.committed, isTrue);
        expect(tx.rolledBack, isFalse);
        expect(
          tx.operations.map((operation) => operation.sql),
          containsAll(<String>[
            "select set_config('app.operator_id', @value, true)",
            "select set_config('app.location_id', @value, true)",
            "select set_config('app.user_id', @value, true)",
            "select set_config('app.bypass_rls_audit', 'tenant', true)",
          ]),
        );
        expect(
          tx.operations.any(
            (op) =>
                op.sql.contains('insert into public.benchmark_overrides') ||
                op.sql.contains('update public.benchmark_overrides'),
          ),
          isFalse,
        );
      },
    );

    test(
      'resolveForLocation reads lowest configured hierarchy scope',
      () async {
        final pool = _RecordingPostgresPool();
        final repository = BenchmarkOverridesRepository(
          TenantTransactionWrapper(pool),
        );

        await repository.resolveForLocation(
          operatorId: operatorId,
          locationId: locationId,
          actorUserId: actorUserId,
          metricKey: 'target_splh',
          fallbackValue: 20,
        );

        final selectSql = pool.transactions.single.operations.last.sql;
        expect(selectSql, contains('loc.org_unit_path <@ ou.path'));
        expect(selectSql, contains('order by precedence asc, depth desc'));
        expect(selectSql, contains('nlevel(ou.path) as depth'));
        expect(selectSql, contains("bo.scope_type = 'location'"));
        expect(selectSql, contains("bo.scope_type = 'operator_wide'"));
      },
    );

    test('invalid metric fails before opening a transaction', () async {
      final pool = _RecordingPostgresPool();
      final repository = BenchmarkOverridesRepository(
        TenantTransactionWrapper(pool),
      );

      expect(
        () => repository.resolveForLocation(
          operatorId: operatorId,
          locationId: locationId,
          actorUserId: actorUserId,
          metricKey: 'whole_day_cplh',
          fallbackValue: 20,
        ),
        throwsA(isA<BenchmarkOverridesInputError>()),
      );
      expect(pool.transactions, isEmpty);
    });
  });
}

class _RecordingPostgresPool implements PostgresPool {
  final List<_RecordingPostgresTransaction> transactions =
      <_RecordingPostgresTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingPostgresTransaction();
    transactions.add(tx);
    return tx;
  }
}

class _SqlOperation {
  const _SqlOperation(this.kind, this.sql, this.parameters);

  final String kind;
  final String sql;
  final PostgresParameters parameters;
}

class _RecordingPostgresTransaction implements PostgresTransaction {
  final List<_SqlOperation> operations = <_SqlOperation>[];
  var committed = false;
  var rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    operations.add(_SqlOperation('query', sql, parameters));
    if (sql.contains('from public.benchmark_overrides bo') ||
        sql.contains('from ranked bo')) {
      return <PostgresRow>[_row(parameters)];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    operations.add(_SqlOperation('execute', sql, parameters));
    return 1;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {
    rolledBack = true;
  }

  PostgresRow _row(PostgresParameters parameters) {
    final now = DateTime.utc(2026, 5, 13, 17);
    return <String, Object?>{
      'override_id': '55555555-5555-4555-8555-555555555555',
      'operator_id': operatorId,
      'scope_type': 'org_unit',
      'org_unit_id': '44444444-4444-4444-8444-444444444444',
      'location_id': null,
      'metric_key': parameters['metric_key'] ?? 'target_cplh',
      'override_value': 12.25,
      'effective_from': now,
      'effective_until': null,
      'created_by': actorUserId,
      'created_at': now,
      'updated_at': now,
      'source_label': 'Org unit',
    };
  }
}
