// Code-health L3 (C5) — AuthInvitesRepository operator-scope predicates.
//
// Coverage focus:
//
//   * `markAccepted` and `revokeInvite` UPDATE the `auth_invites` row
//     keyed by `invite_id`. The WHERE includes `operator_id = $N` so a
//     caller passing an `inviteId` from operator A while believing it
//     lives in operator B writes 0 rows instead of touching an invite
//     in a different tenant. RLS already filters reads through
//     `withTenant`, but the predicate keeps this defense-in-depth even
//     if RLS were ever loosened or bypassed.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_invites_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _userInOpA = '33333333-3333-3333-3333-333333333333';
const String _inviteInOpA = '44444444-4444-4444-4444-444444444444';

void main() {
  group('AuthInvitesRepository UPDATE methods bind operator_id (C5)', () {
    test(
      'markAccepted WHERE includes operator_id; mismatched operator '
      'returns 0 affected rows',
      () async {
        final pool = _UpdatesPool(rowsAffected: 0);
        final repo = AuthInvitesRepository(TenantTransactionWrapper(pool));

        final affected = await repo.markAccepted(
          operatorId: _opB,
          locationId: _validLocId,
          inviteId: _inviteInOpA,
          acceptingUserId: _userInOpA,
        );
        expect(
          affected,
          equals(0),
          reason: 'WHERE operator_id mismatch must short-circuit the UPDATE',
        );
        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.last;
        expect(updateSql, contains('update auth_invites'));
        expect(updateSql, contains('set accepted_at = now()'));
        expect(updateSql, contains('where invite_id = @invite_id::uuid'));
        expect(updateSql, contains('and operator_id = @operator_id::uuid'));
        final params = tx.parameters.last;
        expect(params['invite_id'], equals(_inviteInOpA));
        expect(params['operator_id'], equals(_opB));
      },
    );

    test(
      'markAccepted matched operator returns 1 affected row',
      () async {
        final pool = _UpdatesPool(rowsAffected: 1);
        final repo = AuthInvitesRepository(TenantTransactionWrapper(pool));

        final affected = await repo.markAccepted(
          operatorId: _opA,
          locationId: _validLocId,
          inviteId: _inviteInOpA,
          acceptingUserId: _userInOpA,
        );
        expect(affected, equals(1));
      },
    );

    test(
      'revokeInvite WHERE includes operator_id; mismatched operator '
      'returns 0 affected rows',
      () async {
        final pool = _UpdatesPool(rowsAffected: 0);
        final repo = AuthInvitesRepository(TenantTransactionWrapper(pool));

        final affected = await repo.revokeInvite(
          operatorId: _opB,
          locationId: _validLocId,
          inviteId: _inviteInOpA,
          actorUserId: _userInOpA,
        );
        expect(affected, equals(0));
        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.last;
        expect(updateSql, contains('update auth_invites'));
        expect(updateSql, contains('set revoked_at = now()'));
        expect(updateSql, contains('where invite_id = @invite_id::uuid'));
        expect(updateSql, contains('and operator_id = @operator_id::uuid'));
        final params = tx.parameters.last;
        expect(params['invite_id'], equals(_inviteInOpA));
        expect(params['operator_id'], equals(_opB));
      },
    );

    test(
      'revokeInvite matched operator returns 1 affected row',
      () async {
        final pool = _UpdatesPool(rowsAffected: 1);
        final repo = AuthInvitesRepository(TenantTransactionWrapper(pool));

        final affected = await repo.revokeInvite(
          operatorId: _opA,
          locationId: _validLocId,
          inviteId: _inviteInOpA,
          actorUserId: _userInOpA,
        );
        expect(affected, equals(1));
      },
    );
  });
}

/// Recording fake `PostgresPool` for the UPDATE-method seam.
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
