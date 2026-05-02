// HARD-B - AuthLoginAttemptsRepository tests.
//
// Covers the surface from
// `docs/contracts/hardening_auth_protection_contract.md` "Lockout
// Schema" + "Lockout Behavior":
//
//   1. Tenant-bound writes ride `withTenant` and bind operator/
//      location into the row.
//   2. Anonymous writes ride `withSystem` (forge_admin BYPASSRLS) so
//      the pre-tenant lockout lookup can record before Firebase
//      resolves the tenant.
//   3. Window-counter SQL leads with `user_email_hash` per the
//      anonymous-lookup index, includes `attempted_date >= ...` for
//      partition pruning, and counts both failure + locked rows.
//   4. SHA-256 normalization is consistent (case + whitespace).
//   5. Outcome validation rejects unknown values.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_login_attempts_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';
const String _validAttemptId = '44444444-4444-4444-4444-444444444444';

void main() {
  group('AuthLoginAttemptsRepository.hashEmail / hashIp', () {
    test('email hash is normalized: trim + lowercase', () {
      final a = AuthLoginAttemptsRepository.hashEmail('  Foo@Bar.COM  ');
      final b = AuthLoginAttemptsRepository.hashEmail('foo@bar.com');
      expect(a, equals(b));
      expect(a.length, equals(32),
          reason: 'SHA-256 must produce 32 raw bytes');
    });

    test('ip hash trims whitespace before hashing', () {
      final a = AuthLoginAttemptsRepository.hashIp(' 203.0.113.7 ');
      final b = AuthLoginAttemptsRepository.hashIp('203.0.113.7');
      expect(a, equals(b));
      expect(a.length, equals(32));
    });

    test('different inputs produce different hashes', () {
      expect(
        AuthLoginAttemptsRepository.hashEmail('alice@example.com'),
        isNot(equals(
          AuthLoginAttemptsRepository.hashEmail('bob@example.com'),
        )),
      );
      expect(
        AuthLoginAttemptsRepository.hashIp('203.0.113.7'),
        isNot(equals(
          AuthLoginAttemptsRepository.hashIp('203.0.113.8'),
        )),
      );
    });
  });

  group('writeForTenant (tenant-scoped insert)', () {
    test('runs withTenant + binds operator/location/user + outcome', () async {
      final pool = _AttemptsPool(returningAttemptId: _validAttemptId);
      final repo = AuthLoginAttemptsRepository(TenantTransactionWrapper(pool));

      final id = await repo.writeForTenant(
        operatorId: _validOpId,
        locationId: _validLocId,
        actorUserId: _validUserId,
        userEmailHash: AuthLoginAttemptsRepository.hashEmail('alice@e.test'),
        ipHash: AuthLoginAttemptsRepository.hashIp('203.0.113.7'),
        outcome: AuthLoginAttemptOutcome.success,
        userAgentClass: 'desktop',
      );

      expect(id, equals(_validAttemptId));

      final tx = pool.transactions.single;
      // SET LOCAL app.operator_id ran first - tenant path engaged.
      expect(tx.executedSql.first, contains("'app.operator_id'"));
      expect(tx.executedSql.last,
          contains('insert into public.auth_login_attempts'));
      // The insert binds the operator_id + the outcome literal.
      final params = tx.parameters.last;
      expect(params['operator_id'], equals(_validOpId));
      expect(params['outcome'], equals('success'));
      expect(params['user_agent_class'], equals('desktop'));
    });

    test('rejects unknown outcome values', () {
      final pool = _AttemptsPool();
      final repo = AuthLoginAttemptsRepository(TenantTransactionWrapper(pool));

      expect(
        () => repo.writeForTenant(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
          userEmailHash: AuthLoginAttemptsRepository.hashEmail('a@b.test'),
          ipHash: AuthLoginAttemptsRepository.hashIp('1.1.1.1'),
          outcome: 'something_else',
        ),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty,
          reason:
              'outcome validation must throw before opening a transaction');
    });
  });

  group('writeAnonymous (system-scoped insert)', () {
    test('runs withSystem with the supplied audit reason', () async {
      final pool = _AttemptsPool(returningAttemptId: _validAttemptId);
      final repo = AuthLoginAttemptsRepository(TenantTransactionWrapper(pool));

      final id = await repo.writeAnonymous(
        userEmailHash: AuthLoginAttemptsRepository.hashEmail('alice@e.test'),
        ipHash: AuthLoginAttemptsRepository.hashIp('203.0.113.7'),
        outcome: AuthLoginAttemptOutcome.failure,
        adminReason: 'auth.lockout_record_failure',
      );

      expect(id, equals(_validAttemptId));
      final tx = pool.transactions.single;
      // First call binds the system audit marker via set_config (the
      // tenant_transaction wrapper passes the reason through @value
      // parameter binding rather than string interpolation); second
      // SETs the forge_admin role; the insert ran with operator_id
      // NULL (the SQL passes the literal `null` for operator_id).
      expect(tx.executedSql[0],
          equals("select set_config('app.bypass_rls_audit', @value, true)"));
      expect(tx.parameters[0]['value'],
          equals('system:auth.lockout_record_failure'));
      expect(tx.executedSql[1], equals('set local role forge_admin'));
      expect(tx.executedSql.last,
          contains('insert into public.auth_login_attempts'));
      expect(tx.executedSql.last,
          contains('values (null'),
          reason:
              'anonymous insert must explicitly pass null for operator_id; '
              'the per-tenant RLS policy refuses to admit operator_id IS NULL '
              'rows so the BYPASSRLS path is the only allowed write target');
    });
  });

  group('countFailuresIn (rolling-window query)', () {
    test('runs withSystem + reads with email_hash leading + partition prune',
        () async {
      final pool = _AttemptsPool(
        countResult: <PostgresRow>[
          <String, Object?>{
            'failure_count': 3,
            'has_locked': false,
          },
        ],
      );
      final repo = AuthLoginAttemptsRepository(TenantTransactionWrapper(pool));

      final result = await repo.countFailuresIn(
        userEmailHash: AuthLoginAttemptsRepository.hashEmail('alice@e.test'),
        ipHash: AuthLoginAttemptsRepository.hashIp('203.0.113.7'),
        window: const Duration(minutes: 15),
        adminReason: 'auth.lockout_evaluate',
      );

      expect(result.failureCount, equals(3));
      expect(result.locked, isFalse);

      final sql = pool.transactions.single.executedSql.last;
      // Anonymous index is (user_email_hash, attempted_at desc) - the
      // SQL leads with user_email_hash so the planner picks it.
      expect(sql, contains('where user_email_hash = @user_email_hash::bytea'));
      expect(sql, contains('and ip_hash = @ip_hash::bytea'));
      expect(sql, contains("and outcome in ('failure','locked')"));
      // Partition pruning needs an attempted_date predicate alongside
      // attempted_at >= window_start.
      expect(sql, contains('attempted_at >= @window_start'));
      expect(sql, contains('attempted_date >='));
    });

    test('reports locked = true when has_locked column is true', () async {
      final pool = _AttemptsPool(
        countResult: <PostgresRow>[
          <String, Object?>{
            'failure_count': 5,
            'has_locked': true,
          },
        ],
      );
      final repo = AuthLoginAttemptsRepository(TenantTransactionWrapper(pool));

      final result = await repo.countFailuresIn(
        userEmailHash: AuthLoginAttemptsRepository.hashEmail('alice@e.test'),
        ipHash: AuthLoginAttemptsRepository.hashIp('203.0.113.7'),
        window: const Duration(minutes: 15),
        adminReason: 'auth.lockout_evaluate',
      );

      expect(result.failureCount, equals(5));
      expect(result.locked, isTrue);
    });

    test('returns zero when the window is empty', () async {
      final pool = _AttemptsPool(
        countResult: <PostgresRow>[
          <String, Object?>{
            'failure_count': 0,
            'has_locked': null,
          },
        ],
      );
      final repo = AuthLoginAttemptsRepository(TenantTransactionWrapper(pool));

      final result = await repo.countFailuresIn(
        userEmailHash: AuthLoginAttemptsRepository.hashEmail('fresh@e.test'),
        ipHash: AuthLoginAttemptsRepository.hashIp('203.0.113.42'),
        window: const Duration(minutes: 15),
        adminReason: 'auth.lockout_evaluate',
      );

      expect(result.failureCount, equals(0));
      expect(result.locked, isFalse);
    });

    test(
      'SQL filters failures to the latest success in the window so a '
      'success row resets the count',
      () async {
        final pool = _AttemptsPool(
          countResult: <PostgresRow>[
            <String, Object?>{
              'failure_count': 0,
              'has_locked': false,
            },
          ],
        );
        final repo =
            AuthLoginAttemptsRepository(TenantTransactionWrapper(pool));
        await repo.countFailuresIn(
          userEmailHash:
              AuthLoginAttemptsRepository.hashEmail('alice@e.test'),
          ipHash: AuthLoginAttemptsRepository.hashIp('203.0.113.7'),
          window: const Duration(minutes: 15),
          adminReason: 'auth.lockout_evaluate',
        );
        final sql = pool.transactions.single.executedSql.last;
        // Per the contract reset semantics: the count predicate must
        // exclude failures that occurred BEFORE the latest success
        // inside the window. The COALESCE fallback with a tiny
        // timestamp before window_start handles "no success yet".
        expect(
          sql,
          contains('attempted_at > coalesce('),
          reason:
              'count predicate must gate on attempted_at > latest success '
              'so a successful login within the window resets the count',
        );
        expect(
          sql,
          contains("outcome = 'success'"),
          reason:
              'subquery must look up the latest success in the same '
              '(email_hash, ip_hash) window',
        );
        expect(
          sql,
          contains("interval '1 microsecond'"),
          reason:
              'no-success fallback must be strictly before window_start so '
              'every failure in the window participates when no reset has '
              'happened',
        );
      },
    );
  });

  group('hash determinism vs Dart sha256', () {
    test('hashEmail matches dart:crypto sha256 of normalized bytes', () {
      final hashed = AuthLoginAttemptsRepository.hashEmail('Alice@Example.test');
      final expected =
          sha256.convert(utf8.encode('alice@example.test')).bytes;
      expect(hashed, equals(expected));
    });

    test('hashIp matches dart:crypto sha256 of trimmed bytes', () {
      final hashed = AuthLoginAttemptsRepository.hashIp(' 1.2.3.4');
      final expected = sha256.convert(utf8.encode('1.2.3.4')).bytes;
      expect(hashed, equals(expected));
    });
  });
}

class _AttemptsPool implements PostgresPool {
  _AttemptsPool({
    this.returningAttemptId,
    this.countResult = const <PostgresRow>[],
  });

  final String? returningAttemptId;
  final List<PostgresRow> countResult;
  final List<_AttemptsTransaction> transactions = <_AttemptsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _AttemptsTransaction(
      returningAttemptId: returningAttemptId,
      countResult: countResult,
    );
    transactions.add(tx);
    return tx;
  }
}

class _AttemptsTransaction extends PostgresTransaction {
  _AttemptsTransaction({
    required this.returningAttemptId,
    required this.countResult,
  });

  final String? returningAttemptId;
  final List<PostgresRow> countResult;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;
  int commitCount = 0;
  int rollbackCount = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into public.auth_login_attempts') &&
        sql.contains('returning attempt_id')) {
      final id = returningAttemptId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'attempt_id': id},
      ];
    }
    if (sql.contains('count(*)') &&
        sql.contains('from public.auth_login_attempts')) {
      return countResult;
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
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    rollbackCount += 1;
  }
}
