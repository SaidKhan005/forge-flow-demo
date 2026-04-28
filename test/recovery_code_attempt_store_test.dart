// Phase 9 live-closeout B13 - Postgres recovery-code attempt store tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/recovery_code_attempt_store.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

void main() {
  group('PostgresRecoveryCodeAttemptStore', () {
    test(
      'recentAttempts prunes old rows and returns ascending timestamps',
      () async {
        final now = DateTime.utc(2026, 4, 28, 12);
        final pool = _AttemptStorePool(<DateTime>[
          now.subtract(const Duration(minutes: 30)),
          now.subtract(const Duration(minutes: 5)),
        ]);
        final store = PostgresRecoveryCodeAttemptStore(
          TenantTransactionWrapper(pool),
        );

        final attempts = await store.recentAttempts(
          userId: _userId,
          now: now,
          window: const Duration(hours: 24),
        );

        expect(attempts, hasLength(2));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql,
          contains("select set_config('app.bypass_rls_audit', @value, true)"),
        );
        expect(tx.executedSql, contains('set local role forge_admin'));
        expect(
          tx.executedSql.any(
            (sql) => sql.contains('delete from recovery_code_attempts'),
          ),
          isTrue,
        );
        expect(tx.queryCalls.single.sql, contains('order by attempted_at asc'));
      },
    );

    test('recordAttempt inserts one user-scoped timestamp', () async {
      final at = DateTime.utc(2026, 4, 28, 12, 1);
      final pool = _AttemptStorePool(const <DateTime>[]);
      final store = PostgresRecoveryCodeAttemptStore(
        TenantTransactionWrapper(pool),
      );

      await store.recordAttempt(userId: _userId, at: at);

      final tx = pool.transactions.single;
      final insert = tx.executeCalls.last;
      expect(insert.sql, contains('insert into recovery_code_attempts'));
      expect(insert.parameters['user_id'], equals(_userId));
      expect(insert.parameters['attempted_at'], equals(at));
      expect(tx.committed, isTrue);
    });
  });
}

const _userId = '11111111-1111-4111-8111-111111111111';

class _AttemptStorePool implements PostgresPool {
  _AttemptStorePool(this.returnedAttempts);

  final List<DateTime> returnedAttempts;
  final transactions = <_AttemptStoreTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _AttemptStoreTransaction(returnedAttempts);
    transactions.add(tx);
    return tx;
  }
}

class _SqlCall {
  const _SqlCall(this.sql, this.parameters);

  final String sql;
  final PostgresParameters parameters;
}

class _AttemptStoreTransaction implements PostgresTransaction {
  _AttemptStoreTransaction(this.returnedAttempts);

  final List<DateTime> returnedAttempts;
  final executedSql = <String>[];
  final executeCalls = <_SqlCall>[];
  final queryCalls = <_SqlCall>[];
  var committed = false;
  var rolledBack = false;

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executedSql.add(sql);
    executeCalls.add(_SqlCall(sql, parameters));
    return 1;
  }

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_SqlCall(sql, parameters));
    return <PostgresRow>[
      for (final attemptedAt in returnedAttempts)
        <String, Object?>{'attempted_at': attemptedAt},
    ];
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {
    rolledBack = true;
  }
}
