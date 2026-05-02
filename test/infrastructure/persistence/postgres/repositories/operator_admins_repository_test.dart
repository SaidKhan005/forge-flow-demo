import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operator_admins_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';

void main() {
  group('OperatorAdminsRepository.countByOperator', () {
    test('loads all admin grant counts in one runAsSystem transaction '
        'instead of one query per operator', () async {
      final pool = _OperatorAdminsPool(
        countRows: const <PostgresRow>[
          <String, Object?>{'operator_id': _opA, 'admin_grant_count': 2},
          <String, Object?>{'operator_id': _opB, 'admin_grant_count': '3'},
        ],
      );
      final repo = OperatorAdminsRepository(TenantTransactionWrapper(pool));

      final counts = await repo.countByOperator(
        adminReason: 'admin.operators.list:admin_grant_counts',
      );

      expect(counts, equals(<String, int>{_opA: 2, _opB: 3}));
      expect(pool.transactions, hasLength(1));
      final tx = pool.transactions.single;
      final selectSql = tx.executedSql.firstWhere(
        (sql) => sql.contains('from operator_admins'),
      );
      expect(selectSql, contains('count(*)::int as admin_grant_count'));
      expect(selectSql, contains('group by operator_id'));
      expect(
        tx.executedSql.where(
          (sql) => sql.contains('set local role forge_admin'),
        ),
        hasLength(1),
      );
      expect(
        tx.parameters.firstWhere(
          (params) =>
              params['value'] ==
              'system:admin.operators.list:admin_grant_counts',
        ),
        isNotNull,
      );
    });
  });
}

class _OperatorAdminsPool implements PostgresPool {
  _OperatorAdminsPool({this.countRows = const <PostgresRow>[]});

  final List<PostgresRow> countRows;
  final List<_OperatorAdminsTransaction> transactions =
      <_OperatorAdminsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _OperatorAdminsTransaction(countRows: countRows);
    transactions.add(tx);
    return tx;
  }
}

class _OperatorAdminsTransaction extends PostgresTransaction {
  _OperatorAdminsTransaction({required this.countRows});

  final List<PostgresRow> countRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from operator_admins') &&
        sql.contains('group by operator_id')) {
      return countRows;
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
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
