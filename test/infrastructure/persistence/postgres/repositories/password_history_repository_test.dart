// Code-health L3 (C5) — PasswordHistoryRepository operator-scope predicates.
//
// Coverage focus:
//
//   * `clearForUser` runs through `withSystem` (BYPASSRLS) for the GDPR
//     erasure runbook so it can DELETE rows it does not own.
//     `password_history` is a per-user table with no `operator_id`
//     column, so the WHERE adds an EXISTS subquery against `users`
//     keyed on `(user_id, operator_id)`. A caller passing a `userId`
//     from operator A while believing it lives in operator B deletes 0
//     rows instead of leaking across tenants.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _userInOpA = '33333333-3333-3333-3333-333333333333';

void main() {
  group('PasswordHistoryRepository DELETE methods bind operator_id (C5)', () {
    test(
      'clearForUser WHERE includes operator_id via EXISTS on users; '
      'mismatched operator returns 0 affected rows',
      () async {
        final pool = _UpdatesPool(rowsAffected: 0);
        final repo = PasswordHistoryRepository(TenantTransactionWrapper(pool));

        final affected = await repo.clearForUser(
          userId: _userInOpA,
          operatorId: _opB,
          adminReason: 'gdpr.erasure_executed',
        );
        expect(
          affected,
          equals(0),
          reason:
              'WHERE EXISTS users (user_id, operator_id) mismatch must '
              'short-circuit the DELETE',
        );
        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.last;
        expect(updateSql, contains('delete from password_history'));
        expect(updateSql, contains('where user_id = @user_id::uuid'));
        expect(updateSql, contains('exists ('));
        expect(updateSql, contains('select 1 from users u'));
        expect(updateSql, contains('u.user_id = @user_id::uuid'));
        expect(updateSql, contains('u.operator_id = @operator_id::uuid'));
        final params = tx.parameters.last;
        expect(params['user_id'], equals(_userInOpA));
        expect(params['operator_id'], equals(_opB));
      },
    );

    test('clearForUser matched operator returns 1 affected row', () async {
      final pool = _UpdatesPool(rowsAffected: 1);
      final repo = PasswordHistoryRepository(TenantTransactionWrapper(pool));

      final affected = await repo.clearForUser(
        userId: _userInOpA,
        operatorId: _opA,
        adminReason: 'gdpr.erasure_executed',
      );
      expect(affected, equals(1));
    });
  });
}

/// Recording fake `PostgresPool` for the DELETE-method seam.
///
/// Returns [rowsAffected] from every `execute` call so tests can simulate
/// both the leaked-tenant case (0 rows, the WHERE drops the row) and the
/// happy match (1 row).
class _UpdatesPool implements PostgresPool {
  _UpdatesPool({required this.rowsAffected});

  final int rowsAffected;
  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(executeReturn: rowsAffected);
    transactions.add(tx);
    return tx;
  }
}

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({this.executeReturn = 0});

  final int executeReturn;

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
    return executeReturn;
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
