// CODE_OPS_DEBT Theme B#1 — UserPiiErasureRepository unit tests.
//
// Coverage focus:
//
//   * snapshotPiiAndInsertPending — captures PII from `public.users`
//     and inserts the pending row in ONE tenant transaction; appends
//     a `users.pii_erasure_requested` audit row in the same tx.
//   * markReversed — pending-only WHERE guard (cannot reverse a
//     terminal row), wipes `pii_snapshot` to `'{}'::jsonb`, appends
//     `users.pii_erasure_reversed` audit row only when an actual row
//     was updated.
//   * applyRowAndWipeSnapshot — composite write (NULL-out users PII +
//     stamp request row) inside one tx; emits a service-actor audit
//     row attributed to `sp:pii-erasure-worker`.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/user_pii_erasure_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';
const String _adminA = '44444444-4444-4444-4444-444444444444';
const String _erasureA = '55555555-5555-5555-5555-555555555555';

PostgresRow _userRow({
  String? displayName = 'Aria Operator',
  String? email = 'aria@example.test',
  String? firstName = 'Aria',
  String? lastName = 'Operator',
  String? avatarUrl,
}) {
  return <String, Object?>{
    'display_name': displayName,
    'email': email,
    'first_name': firstName,
    'last_name': lastName,
    'avatar_url': avatarUrl,
  };
}

PostgresRow _erasureRequestRow({
  String erasureId = _erasureA,
  String operatorId = _opA,
  String userId = _userA,
  String requestedByUserId = _adminA,
  DateTime? requestedAt,
  String businessDate = '2026-05-08',
  DateTime? gracePeriodEndsAt,
  DateTime? appliedAt,
  DateTime? reversedAt,
  String? reversedByUserId,
  String? reversalReason,
  Map<String, Object?>? piiSnapshot,
}) {
  return <String, Object?>{
    'erasure_id': erasureId,
    'operator_id': operatorId,
    'user_id': userId,
    'requested_by_user_id': requestedByUserId,
    'requested_at': requestedAt ?? DateTime.utc(2026, 5, 8, 12),
    'business_date': businessDate,
    'grace_period_ends_at':
        gracePeriodEndsAt ?? DateTime.utc(2026, 5, 9, 12),
    'applied_at': appliedAt,
    'reversed_at': reversedAt,
    'reversed_by_user_id': reversedByUserId,
    'reversal_reason': reversalReason,
    'pii_snapshot':
        jsonEncode(piiSnapshot ?? const <String, Object?>{
          'display_name': 'Aria Operator',
          'email': 'aria@example.test',
          'first_name': 'Aria',
          'last_name': 'Operator',
          'avatar_url': null,
        }),
  };
}

void main() {
  group('UserPiiErasureRepository.snapshotPiiAndInsertPending', () {
    test(
      'reads PII from public.users + inserts the pending row in one tx; '
      'pii_snapshot::jsonb carries the captured columns',
      () async {
        final pool = _ErasurePool(
          userRow: _userRow(),
          insertedRow: _erasureRequestRow(),
        );
        final repo = UserPiiErasureRepository(
          TenantTransactionWrapper(pool),
        );
        final result = await repo.snapshotPiiAndInsertPending(
          erasureId: _erasureA,
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          requestedByUserId: _adminA,
          requestedAt: DateTime.utc(2026, 5, 8, 12),
          businessDate: '2026-05-08',
          gracePeriodEndsAt: DateTime.utc(2026, 5, 9, 12),
        );
        expect(result, isNotNull);
        expect(result!.erasureId, equals(_erasureA));
        expect(result.isPending, isTrue);

        final tx = pool.transactions.single;
        // 1) tenant SET LOCAL precedes both reads + writes.
        expect(tx.executedSql[0], contains("'app.operator_id'"));
        // 2) PII read happens first — the snapshot capture lives in
        //    the same transaction as the insert.
        expect(
          tx.executedSql.any(
            (s) =>
                s.contains('select display_name') &&
                s.contains('from public.users'),
          ),
          isTrue,
          reason: 'PII snapshot must be captured from public.users',
        );
        // 3) Insert into the ledger.
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains(
              'insert into public.user_pii_erasure_requests'),
        );
        expect(insertSql, contains('pii_snapshot'));
        expect(insertSql, contains('@pii_snapshot::jsonb'));
        // 4) Audit row appended in the same tx.
        expect(
          tx.executedSql.any(
            (s) =>
                s.contains('insert into public.audit_logs') &&
                s.contains('action'),
          ),
          isTrue,
          reason:
              'audit row must be appended in the same tenant tx so '
              'the chain commits atomically with the ledger row',
        );
      },
    );

    test('returns null when the target user row is not found',
        () async {
      final pool = _ErasurePool(
        userRow: null,
        insertedRow: _erasureRequestRow(),
      );
      final repo = UserPiiErasureRepository(
        TenantTransactionWrapper(pool),
      );
      final result = await repo.snapshotPiiAndInsertPending(
        erasureId: _erasureA,
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        requestedByUserId: _adminA,
        requestedAt: DateTime.utc(2026, 5, 8, 12),
        businessDate: '2026-05-08',
        gracePeriodEndsAt: DateTime.utc(2026, 5, 9, 12),
      );
      expect(result, isNull);
    });
  });

  group('UserPiiErasureRepository.markReversed', () {
    test(
      'pending-only guard: WHERE clause requires applied_at IS NULL '
      'AND reversed_at IS NULL AND grace_period_ends_at > now',
      () async {
        final pool = _ErasurePool(updateAffectedRows: 1);
        final repo = UserPiiErasureRepository(
          TenantTransactionWrapper(pool),
        );
        final affected = await repo.markReversed(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          erasureId: _erasureA,
          reversedByUserId: _adminA,
          reversalReason: 'admin changed their mind',
          reversedAt: DateTime.utc(2026, 5, 8, 14),
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update public.user_pii_erasure_requests') &&
              s.contains('reversed_at = '),
        );
        expect(updateSql, contains('and applied_at is null'));
        expect(updateSql, contains('and reversed_at is null'));
        expect(
          updateSql,
          contains(
            'and grace_period_ends_at > @reversed_at::timestamptz',
          ),
        );
        // pii_snapshot wiped to '{}'::jsonb so PII does not linger
        // past the grace window.
        expect(updateSql, contains("pii_snapshot = '{}'::jsonb"));
        // Audit row appended only when the row was actually updated
        // (rowcount > 0).
        expect(
          tx.executedSql.any(
            (s) => s.contains('insert into public.audit_logs'),
          ),
          isTrue,
        );
      },
    );

    test('returns 0 when row is terminal — no audit row appended',
        () async {
      final pool = _ErasurePool(updateAffectedRows: 0);
      final repo = UserPiiErasureRepository(
        TenantTransactionWrapper(pool),
      );
      final affected = await repo.markReversed(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        erasureId: _erasureA,
        reversedByUserId: _adminA,
        reversalReason: null,
        reversedAt: DateTime.utc(2026, 5, 8, 14),
      );
      expect(affected, equals(0));
      final tx = pool.transactions.single;
      // No audit-log insert when the WHERE clause refused.
      expect(
        tx.executedSql.any(
          (s) => s.contains('insert into public.audit_logs'),
        ),
        isFalse,
      );
    });
  });

  group('UserPiiErasureRepository.applyRowAndWipeSnapshot', () {
    test(
      'NULLs the user PII columns + stamps applied_at + wipes snapshot '
      'inside one tenant tx; audit row attributed to '
      'sp:pii-erasure-worker',
      () async {
        final pool = _ErasurePool(updateAffectedRows: 1);
        final repo = UserPiiErasureRepository(
          TenantTransactionWrapper(pool),
        );
        final affected = await repo.applyRowAndWipeSnapshot(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          erasureId: _erasureA,
          appliedAt: DateTime.utc(2026, 5, 9, 12, 1),
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        // 1) NULL the PII columns.
        final userUpdate = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update public.users') &&
              s.contains('display_name = null'),
        );
        expect(userUpdate, contains('email = null'));
        expect(userUpdate, contains('first_name = null'));
        expect(userUpdate, contains('last_name = null'));
        expect(userUpdate, contains('avatar_url = null'));
        // 2) Stamp the request row + wipe snapshot.
        final ledgerUpdate = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update public.user_pii_erasure_requests') &&
              s.contains('applied_at = '),
        );
        expect(ledgerUpdate, contains("pii_snapshot = '{}'::jsonb"));
        // 3) Audit row — actor_kind = service.
        final auditInsert = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.audit_logs'),
        );
        expect(auditInsert, contains('actor_kind'));
      },
    );
  });
}

class _ErasurePool implements PostgresPool {
  _ErasurePool({
    this.userRow,
    this.insertedRow,
    this.updateAffectedRows = 0,
  });

  final PostgresRow? userRow;
  final PostgresRow? insertedRow;
  final List<PostgresRow> dueRows;
  final int updateAffectedRows;
  final List<_ErasureTransaction> transactions = <_ErasureTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _ErasureTransaction(
      userRow: userRow,
      insertedRow: insertedRow,
      dueRows: dueRows,
      updateAffectedRows: updateAffectedRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _ErasureTransaction extends PostgresTransaction {
  _ErasureTransaction({
    required this.userRow,
    required this.insertedRow,
    required this.dueRows,
    required this.updateAffectedRows,
  });

  final PostgresRow? userRow;
  final PostgresRow? insertedRow;
  final List<PostgresRow> dueRows;
  final int updateAffectedRows;

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
    if (sql.contains('select display_name') &&
        sql.contains('from public.users')) {
      if (userRow == null) return const <PostgresRow>[];
      return <PostgresRow>[userRow!];
    }
    if (sql.contains('insert into public.user_pii_erasure_requests')) {
      if (insertedRow == null) return const <PostgresRow>[];
      return <PostgresRow>[insertedRow!];
    }
    if (sql.contains('insert into public.audit_logs')) {
      // The repository's audit-log writer expects a `returning id`
      // shape. We synthesize a single dummy row.
      return const <PostgresRow>[<String, Object?>{'id': 1}];
    }
    if (sql.contains('from public.user_pii_erasure_requests')) {
      return dueRows;
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
    if (sql.contains('update public.user_pii_erasure_requests') ||
        sql.contains('update public.users')) {
      return updateAffectedRows;
    }
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
