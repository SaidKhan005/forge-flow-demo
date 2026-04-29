// Phase 9 live-closeout B13 / B39 - Postgres recovery-code attempt store tests.
//
// Verifies the store routes through the user-scoped helper so the
// per-user RLS policy (`recovery_code_attempts_per_user`, reads
// `public.app_current_actor_user()`) admits the row. The store must
// NOT engage `forge_admin` BYPASSRLS — RLS itself is the gate.

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
        // User-scoped execution: app.user_id is set transaction-locally
        // with parameter binding, audit marker is 'user', and there is
        // NO `set local role forge_admin`.
        expect(
          tx.executedSql,
          contains("select set_config('app.user_id', @value, true)"),
        );
        expect(
          tx.executedSql,
          contains("select set_config('app.bypass_rls_audit', 'user', true)"),
        );
        expect(
          tx.executedSql.any((sql) => sql.contains('forge_admin')),
          isFalse,
          reason: 'recovery-code attempt store must not engage BYPASSRLS',
        );
        // app.user_id is bound via parameter, not concatenated.
        final userIdSet = tx.executeCalls.firstWhere(
          (call) => call.sql.contains("'app.user_id'"),
        );
        expect(userIdSet.parameters['value'], equals(_userId));

        expect(
          tx.executedSql.any(
            (sql) => sql.contains('delete from recovery_code_attempts'),
          ),
          isTrue,
        );
        expect(tx.queryCalls.single.sql, contains('order by attempted_at asc'));
        expect(tx.committed, isTrue);
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
      // Same user-scoped guarantees as the read path.
      expect(
        tx.executedSql,
        contains("select set_config('app.user_id', @value, true)"),
      );
      expect(
        tx.executedSql.any((sql) => sql.contains('forge_admin')),
        isFalse,
      );
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
