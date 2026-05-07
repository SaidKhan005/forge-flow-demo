// Code-health L3 (C5) — UsersRepository operator-scope predicates.
//
// Coverage focus:
//
//   * `withSystem` (BYPASSRLS) UPDATE methods — `updateStatus`,
//     `softDelete`, `redactPii`, `bumpRolesVersion` — must bind
//     `operator_id` in the WHERE so a caller passing a `userId` from
//     operator A while believing it lives in operator B writes 0 rows
//     instead of leaking across tenants.
//
//   * System-tier scan methods — `firebaseUidForUserSystem`,
//     `findActiveUserIdByFirebaseUidSystem`,
//     `findMfaRecoveryTargetByEmail` — accept an optional
//     `requireOperatorId`. When supplied, the WHERE adds
//     `operator_id = $N`; when null (pre-auth login resolution path),
//     behavior is unchanged.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _userInOpA = '33333333-3333-3333-3333-333333333333';
const String _firebaseUid = 'firebase-uid-abc123';

void main() {
  group('UsersRepository UPDATE methods bind operator_id (C5)', () {
    test(
      'updateStatus WHERE includes operator_id; mismatched operator '
      'returns 0 affected rows',
      () async {
        final pool = _UpdatesPool(rowsAffected: 0);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final affected = await repo.updateStatus(
          userId: _userInOpA,
          operatorId: _opB,
          newStatus: 'suspended',
          adminReason: 'admin.users.suspend',
        );
        expect(
          affected,
          equals(0),
          reason: 'WHERE operator_id mismatch must short-circuit the UPDATE',
        );
        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.last;
        expect(updateSql, contains('update users'));
        expect(updateSql, contains('and operator_id = @operator_id::uuid'));
        final params = tx.parameters.last;
        expect(params['user_id'], equals(_userInOpA));
        expect(params['operator_id'], equals(_opB));
        expect(params['status'], equals('suspended'));
      },
    );

    test(
      'updateStatus matched operator returns 1 affected row',
      () async {
        final pool = _UpdatesPool(rowsAffected: 1);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final affected = await repo.updateStatus(
          userId: _userInOpA,
          operatorId: _opA,
          newStatus: 'suspended',
          adminReason: 'admin.users.suspend',
        );
        expect(affected, equals(1));
      },
    );

    test(
      'softDelete WHERE includes operator_id; mismatched operator '
      'returns 0 affected rows',
      () async {
        final pool = _UpdatesPool(rowsAffected: 0);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final affected = await repo.softDelete(
          userId: _userInOpA,
          operatorId: _opB,
          adminReason: 'admin.users.soft_delete',
        );
        expect(affected, equals(0));
        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.last;
        expect(updateSql, contains('update users'));
        expect(updateSql, contains('and operator_id = @operator_id::uuid'));
        expect(updateSql, contains('and deleted_at is null'));
        final params = tx.parameters.last;
        expect(params['user_id'], equals(_userInOpA));
        expect(params['operator_id'], equals(_opB));
      },
    );

    test('softDelete matched operator returns 1 affected row', () async {
      final pool = _UpdatesPool(rowsAffected: 1);
      final repo = UsersRepository(TenantTransactionWrapper(pool));

      final affected = await repo.softDelete(
        userId: _userInOpA,
        operatorId: _opA,
        adminReason: 'admin.users.soft_delete',
      );
      expect(affected, equals(1));
    });

    test(
      'bumpRolesVersion WHERE includes operator_id; mismatched operator '
      'returns 0 affected rows',
      () async {
        final pool = _UpdatesPool(rowsAffected: 0);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final affected = await repo.bumpRolesVersion(
          userId: _userInOpA,
          operatorId: _opB,
          adminReason: 'admin.users.roles_changed',
        );
        expect(affected, equals(0));
        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.last;
        expect(updateSql, contains('roles_version = roles_version + 1'));
        expect(updateSql, contains('and operator_id = @operator_id::uuid'));
        final params = tx.parameters.last;
        expect(params['user_id'], equals(_userInOpA));
        expect(params['operator_id'], equals(_opB));
      },
    );

    test(
      'bumpRolesVersion matched operator returns 1 affected row',
      () async {
        final pool = _UpdatesPool(rowsAffected: 1);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final affected = await repo.bumpRolesVersion(
          userId: _userInOpA,
          operatorId: _opA,
          adminReason: 'admin.users.roles_changed',
        );
        expect(affected, equals(1));
      },
    );

    test(
      'redactPii WHERE includes operator_id; mismatched operator '
      'returns 0 affected rows',
      () async {
        final pool = _UpdatesPool(rowsAffected: 0);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final affected = await repo.redactPii(
          userId: _userInOpA,
          operatorId: _opB,
          adminReason: 'gdpr.erasure_executed',
        );
        expect(affected, equals(0));
        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.last;
        expect(updateSql, contains('update users'));
        expect(updateSql, contains('and operator_id = @operator_id::uuid'));
        expect(
          updateSql,
          contains("set email = 'redacted-' || user_id::text || '@deleted.local'"),
        );
        final params = tx.parameters.last;
        expect(params['user_id'], equals(_userInOpA));
        expect(params['operator_id'], equals(_opB));
      },
    );

    test('redactPii matched operator returns 1 affected row', () async {
      final pool = _UpdatesPool(rowsAffected: 1);
      final repo = UsersRepository(TenantTransactionWrapper(pool));

      final affected = await repo.redactPii(
        userId: _userInOpA,
        operatorId: _opA,
        adminReason: 'gdpr.erasure_executed',
      );
      expect(affected, equals(1));
    });
  });

  group('UsersRepository system-tier scans accept requireOperatorId (C5)', () {
    test(
      'firebaseUidForUserSystem omits operator_id WHERE when '
      'requireOperatorId is null (pre-auth login resolution path '
      'unchanged)',
      () async {
        final pool = _UidScanPool(rows: <PostgresRow>[
          <String, Object?>{'firebase_uid': _firebaseUid},
        ]);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final uid = await repo.firebaseUidForUserSystem(
          userId: _userInOpA,
          adminReason: 'system.test_default_unchanged',
        );
        expect(uid, equals(_firebaseUid));
        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('from users'),
        );
        expect(selectSql, isNot(contains('operator_id')));
        final selectParamsIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('from users'),
        );
        final params = tx.parameters[selectParamsIndex];
        expect(params.containsKey('operator_id'), isFalse);
      },
    );

    test(
      'firebaseUidForUserSystem with mismatched requireOperatorId '
      'yields no rows (system-pool read cannot leak across tenants)',
      () async {
        final pool = _UidScanPool(rows: const <PostgresRow>[]);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        await expectLater(
          repo.firebaseUidForUserSystem(
            userId: _userInOpA,
            requireOperatorId: _opB,
            adminReason: 'system.test_mismatch',
          ),
          throwsStateError,
        );
        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('from users'),
        );
        expect(selectSql, contains('and operator_id = @operator_id::uuid'));
        final selectParamsIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('from users'),
        );
        final params = tx.parameters[selectParamsIndex];
        expect(params['operator_id'], equals(_opB));
      },
    );

    test(
      'firebaseUidForUserSystem with matched requireOperatorId '
      'returns the row',
      () async {
        final pool = _UidScanPool(rows: <PostgresRow>[
          <String, Object?>{'firebase_uid': _firebaseUid},
        ]);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final uid = await repo.firebaseUidForUserSystem(
          userId: _userInOpA,
          requireOperatorId: _opA,
          adminReason: 'system.test_match',
        );
        expect(uid, equals(_firebaseUid));
        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('from users'),
        );
        expect(selectSql, contains('and operator_id = @operator_id::uuid'));
      },
    );

    test(
      'findActiveUserIdByFirebaseUidSystem omits operator_id WHERE '
      'when requireOperatorId is null (login resolution unchanged)',
      () async {
        final pool = _UidScanPool(rows: <PostgresRow>[
          <String, Object?>{'user_id': _userInOpA},
        ]);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final resolved = await repo.findActiveUserIdByFirebaseUidSystem(
          firebaseUid: _firebaseUid,
          adminReason: 'system.test_default_unchanged',
        );
        expect(resolved, equals(_userInOpA));
        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('from users'),
        );
        expect(selectSql, isNot(contains('operator_id')));
      },
    );

    test(
      'findActiveUserIdByFirebaseUidSystem with mismatched '
      'requireOperatorId returns null',
      () async {
        final pool = _UidScanPool(rows: const <PostgresRow>[]);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final resolved = await repo.findActiveUserIdByFirebaseUidSystem(
          firebaseUid: _firebaseUid,
          requireOperatorId: _opB,
          adminReason: 'system.test_mismatch',
        );
        expect(resolved, isNull);
        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('from users'),
        );
        expect(selectSql, contains('and operator_id = @operator_id::uuid'));
        final selectParamsIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('from users'),
        );
        final params = tx.parameters[selectParamsIndex];
        expect(params['operator_id'], equals(_opB));
      },
    );

    test(
      'findActiveUserIdByFirebaseUidSystem with matched '
      'requireOperatorId returns the user_id',
      () async {
        final pool = _UidScanPool(rows: <PostgresRow>[
          <String, Object?>{'user_id': _userInOpA},
        ]);
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final resolved = await repo.findActiveUserIdByFirebaseUidSystem(
          firebaseUid: _firebaseUid,
          requireOperatorId: _opA,
          adminReason: 'system.test_match',
        );
        expect(resolved, equals(_userInOpA));
      },
    );

    test(
      'findMfaRecoveryTargetByEmail omits operator scope WHERE when '
      'requireOperatorId is null (pre-auth recovery resolution '
      'unchanged)',
      () async {
        final pool = _MfaRecoveryPool(
          targetRows: <PostgresRow>[
            <String, Object?>{
              'user_id': _userInOpA,
              'operator_id': _opA,
              'location_id': null,
              'email': 'someone@example.test',
            },
          ],
          adminRows: const <PostgresRow>[],
        );
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final target = await repo.findMfaRecoveryTargetByEmail(
          email: 'someone@example.test',
          adminReason: 'mfa_recovery_request_lookup',
        );
        expect(target, isNotNull);
        expect(target!.operatorId, equals(_opA));
        final tx = pool.transactions.single;
        final userSelectSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('lower(u.email) = lower(@email)'),
        );
        expect(
          userSelectSql,
          isNot(contains('u.operator_id = @scoped_operator_id')),
        );
      },
    );

    test(
      'findMfaRecoveryTargetByEmail with mismatched requireOperatorId '
      'returns null (cross-tenant email scan blocked)',
      () async {
        final pool = _MfaRecoveryPool(
          targetRows: const <PostgresRow>[],
          adminRows: const <PostgresRow>[],
        );
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final target = await repo.findMfaRecoveryTargetByEmail(
          email: 'someone@example.test',
          requireOperatorId: _opB,
          adminReason: 'mfa_recovery_request_lookup',
        );
        expect(target, isNull);
        final tx = pool.transactions.single;
        final userSelectSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('lower(u.email) = lower(@email)'),
        );
        expect(
          userSelectSql,
          contains('and u.operator_id = @scoped_operator_id::uuid'),
        );
        final selectParamsIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('lower(u.email) = lower(@email)'),
        );
        final params = tx.parameters[selectParamsIndex];
        expect(params['scoped_operator_id'], equals(_opB));
      },
    );

    test(
      'findMfaRecoveryTargetByEmail with matched requireOperatorId '
      'returns the target row',
      () async {
        final pool = _MfaRecoveryPool(
          targetRows: <PostgresRow>[
            <String, Object?>{
              'user_id': _userInOpA,
              'operator_id': _opA,
              'location_id': null,
              'email': 'someone@example.test',
            },
          ],
          adminRows: const <PostgresRow>[],
        );
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final target = await repo.findMfaRecoveryTargetByEmail(
          email: 'someone@example.test',
          requireOperatorId: _opA,
          adminReason: 'mfa_recovery_request_lookup',
        );
        expect(target, isNotNull);
        expect(target!.operatorId, equals(_opA));
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

/// Recording fake for the system-tier scan SELECT seams (firebase_uid /
/// active user resolution).
class _UidScanPool implements PostgresPool {
  _UidScanPool({required this.rows});

  final List<PostgresRow> rows;
  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(queryRows: rows);
    transactions.add(tx);
    return tx;
  }
}

/// Recording fake for `findMfaRecoveryTargetByEmail` (two queries: the
/// user lookup, then the operator_admins lookup keyed off the resolved
/// operator).
class _MfaRecoveryPool implements PostgresPool {
  _MfaRecoveryPool({required this.targetRows, required this.adminRows});

  final List<PostgresRow> targetRows;
  final List<PostgresRow> adminRows;
  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      queryRouter: (sql) {
        if (sql.contains('lower(u.email) = lower(@email)')) return targetRows;
        if (sql.contains('from operator_admins oa')) return adminRows;
        return const <PostgresRow>[];
      },
    );
    transactions.add(tx);
    return tx;
  }
}

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({
    this.executeReturn = 0,
    this.queryRows = const <PostgresRow>[],
    this.queryRouter,
  });

  final int executeReturn;
  final List<PostgresRow> queryRows;
  final List<PostgresRow> Function(String sql)? queryRouter;

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
    final router = queryRouter;
    if (router != null) return router(sql);
    if (sql.contains('from users')) return queryRows;
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
