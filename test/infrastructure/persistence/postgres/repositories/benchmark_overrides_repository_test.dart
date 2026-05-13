import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/benchmark_overrides_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';

void main() {
  const operatorId = '22222222-2222-4222-8222-222222222222';
  const locationId = '33333333-3333-4333-8333-333333333333';
  const orgUnitId = '44444444-4444-4444-8444-444444444444';
  const actorUserId = '11111111-1111-4111-8111-111111111111';

  group('BenchmarkOverridesRepository', () {
    test('setOverride closes current row then inserts in one tenant tx',
        () async {
      final pool = _RecordingPostgresPool();
      final repository = BenchmarkOverridesRepository(
        TenantTransactionWrapper(pool),
      );

      final row = await repository.setOverride(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        scopeType: BenchmarkOverrideScopeType.orgUnit,
        orgUnitId: orgUnitId,
        targetLocationId: null,
        metricKey: 'target_cplh',
        overrideValue: 12.25,
        createdBy: actorUserId,
        effectiveFrom: DateTime.utc(2026, 5, 13, 15),
      );

      expect(row.metricKey, 'target_cplh');
      expect(row.value, 12.25);
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
      final closeIndex = tx.operations.indexWhere(
        (operation) =>
            operation.sql.contains('update public.benchmark_overrides') &&
            operation.sql.contains('coalesce(org_unit_id'),
      );
      final insertIndex = tx.operations.indexWhere(
        (operation) =>
            operation.sql.contains('insert into public.benchmark_overrides'),
      );
      expect(closeIndex, greaterThanOrEqualTo(0));
      expect(insertIndex, greaterThan(closeIndex));
    });

    test('resolveForLocation reads lowest configured hierarchy scope',
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
    });

    test('clearOverride soft-closes current row without deleting', () async {
      final pool = _RecordingPostgresPool();
      final repository = BenchmarkOverridesRepository(
        TenantTransactionWrapper(pool),
      );

      final closed = await repository.clearOverride(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        overrideId: '55555555-5555-4555-8555-555555555555',
      );

      expect(closed, isNotNull);
      final sql = pool.transactions.single.operations.map((op) => op.sql).join('\n');
      expect(sql, contains('update public.benchmark_overrides'));
      expect(sql, contains('set effective_until = now()'));
      expect(sql, contains('returning'));
      expect(sql, isNot(contains('delete from public.benchmark_overrides')));
    });

    test('invalid scope payload fails before opening a transaction', () async {
      final pool = _RecordingPostgresPool();
      final repository = BenchmarkOverridesRepository(
        TenantTransactionWrapper(pool),
      );

      expect(
        () => repository.setOverride(
          operatorId: operatorId,
          locationId: locationId,
          actorUserId: actorUserId,
          scopeType: BenchmarkOverrideScopeType.location,
          orgUnitId: orgUnitId,
          targetLocationId: locationId,
          metricKey: 'target_cplh',
          overrideValue: 10,
          createdBy: actorUserId,
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
    if (sql.contains('insert into public.benchmark_overrides') ||
        (sql.contains('update public.benchmark_overrides') &&
            sql.contains('returning')) ||
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
      'override_id':
          parameters['override_id'] ?? '55555555-5555-4555-8555-555555555555',
      'operator_id': parameters['operator_id'] ?? '22222222-2222-4222-8222-222222222222',
      'scope_type': parameters['scope_type'] ?? 'org_unit',
      'org_unit_id': parameters['org_unit_id'] ?? '44444444-4444-4444-8444-444444444444',
      'location_id': parameters['location_id'],
      'metric_key': parameters['metric_key'] ?? 'target_cplh',
      'override_value': parameters['override_value'] ?? 12.25,
      'effective_from': parameters['effective_from'] ?? now,
      'effective_until': parameters['effective_until'],
      'created_by': parameters['created_by'] ?? '11111111-1111-4111-8111-111111111111',
      'created_at': now,
      'updated_at': now,
      'source_label': 'Org unit',
    };
  }
}
