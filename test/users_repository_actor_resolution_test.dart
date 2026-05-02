// Phase 11A.4 — UsersRepository.findActiveUserIdByFirebaseUidSystem.
//
// Pins the strict admin-actor resolution contract. The Phase 9 auth
// contract requires Firebase UID resolution to reject non-active
// statuses (invited / suspended / dormant_*) so an admin claim with a
// still-valid token cannot bypass account suspension to act on shared
// integration credentials.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _firebaseUid = 'firebase-auth-uid-abc123';
const String _resolvedUserId = '11111111-1111-4111-8111-111111111111';

void main() {
  group(
    'UsersRepository.findActiveUserIdByFirebaseUidSystem',
    () {
      test(
        'SELECT pins status = \'active\' so suspended / dormant rows do not resolve',
        () async {
          final pool = _ResolverPool(rows: <PostgresRow>[
            <String, Object?>{'user_id': _resolvedUserId},
          ]);
          final repo = UsersRepository(TenantTransactionWrapper(pool));
          final resolved = await repo.findActiveUserIdByFirebaseUidSystem(
            firebaseUid: _firebaseUid,
            adminReason: 'admin.integrations.POST:tester:resolve_actor',
          );
          expect(resolved, equals(_resolvedUserId));

          final tx = pool.transactions.single;
          final selectStatement = tx.executedSql.firstWhere(
            (sql) => sql.contains('from users'),
          );
          // Strict status filter: the contract is `= 'active'`,
          // not `!= 'deleted'`. Suspended / dormant_30 / dormant_60 /
          // dormant_90 / invited rows must NOT match.
          expect(selectStatement, contains("status = 'active'"));
          expect(
            selectStatement,
            isNot(contains("status != 'deleted'")),
          );
          expect(selectStatement, contains('deleted_at is null'));
          expect(
            selectStatement,
            contains('firebase_uid = @firebase_uid'),
          );
        },
      );

      test(
        'returns null when the SELECT yields no row '
        '(suspended/dormant/invited filtered server-side, deleted, or unknown)',
        () async {
          final pool = _ResolverPool(rows: const <PostgresRow>[]);
          final repo = UsersRepository(TenantTransactionWrapper(pool));
          final resolved = await repo.findActiveUserIdByFirebaseUidSystem(
            firebaseUid: _firebaseUid,
            adminReason: 'admin.integrations.POST:tester:resolve_actor',
          );
          expect(resolved, isNull);
        },
      );

      test(
        'queries arbitrary Firebase UID strings instead of UUID-casting them',
        () async {
          final pool = _ResolverPool(rows: const <PostgresRow>[]);
          final repo = UsersRepository(TenantTransactionWrapper(pool));
          final resolved = await repo.findActiveUserIdByFirebaseUidSystem(
            firebaseUid: 'firebase-not-a-uuid-abc123',
            adminReason: 'admin.integrations.POST:tester:resolve_actor',
          );
          expect(resolved, isNull);
          expect(pool.transactions, hasLength(1));
          final firebaseUidParameters = pool.transactions.single.parameters
              .firstWhere((params) => params.containsKey('firebase_uid'));
          expect(
            firebaseUidParameters['firebase_uid'],
            equals('firebase-not-a-uuid-abc123'),
          );
        },
      );
    },
  );
}

class _ResolverPool implements PostgresPool {
  _ResolverPool({required this.rows});

  final List<PostgresRow> rows;
  final List<_ResolverTransaction> transactions = <_ResolverTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _ResolverTransaction(rows: rows);
    transactions.add(tx);
    return tx;
  }
}

class _ResolverTransaction extends PostgresTransaction {
  _ResolverTransaction({required this.rows});

  final List<PostgresRow> rows;
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
    if (sql.contains('from users')) {
      return rows;
    }
    return <PostgresRow>[];
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
