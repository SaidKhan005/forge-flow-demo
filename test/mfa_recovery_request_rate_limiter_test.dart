import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_recovery_request_attempts_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_rate_limiter.dart';

void main() {
  group('InMemoryMfaRecoveryRequestRateLimiter', () {
    test('blocks repeated requests for the same normalized email', () async {
      var now = DateTime.utc(2026, 4, 30, 12);
      final limiter = InMemoryMfaRecoveryRequestRateLimiter(
        now: () => now,
        emailCooldown: const Duration(minutes: 15),
      );

      final first = await limiter.checkAndRecord(
        normalizedEmail: 'USER@example.test',
        clientIp: '203.0.113.10',
      );
      final second = await limiter.checkAndRecord(
        normalizedEmail: ' user@example.test ',
        clientIp: '203.0.113.11',
      );

      expect(first.isAllowed, isTrue);
      expect(second.isAllowed, isFalse);
      expect(second.retryAfter, equals(DateTime.utc(2026, 4, 30, 12, 15)));

      now = DateTime.utc(2026, 4, 30, 12, 16);
      final third = await limiter.checkAndRecord(
        normalizedEmail: 'user@example.test',
        clientIp: '203.0.113.11',
      );
      expect(third.isAllowed, isTrue);
    });

    test('blocks noisy IPs within the rolling window', () async {
      final limiter = InMemoryMfaRecoveryRequestRateLimiter(
        now: () => DateTime.utc(2026, 4, 30, 12),
        maxRequestsPerIpWindow: 2,
      );

      expect(
        (await limiter.checkAndRecord(
          normalizedEmail: 'a@example.test',
          clientIp: '203.0.113.10',
        )).isAllowed,
        isTrue,
      );
      expect(
        (await limiter.checkAndRecord(
          normalizedEmail: 'b@example.test',
          clientIp: '203.0.113.10',
        )).isAllowed,
        isTrue,
      );
      final third = await limiter.checkAndRecord(
        normalizedEmail: 'c@example.test',
        clientIp: '203.0.113.10',
      );
      expect(third.isAllowed, isFalse);
    });
  });

  group('PostgresMfaRecoveryRequestRateLimiter', () {
    test('allows through system scope and stores hashed identifiers', () async {
      final pool = _LimiterPool(emailRows: const [], ipRows: const []);
      final limiter = PostgresMfaRecoveryRequestRateLimiter(
        TenantTransactionWrapper(pool),
        now: () => DateTime.utc(2026, 4, 30, 12),
      );

      final decision = await limiter.checkAndRecord(
        normalizedEmail: 'User@Example.test',
        clientIp: '203.0.113.10',
      );

      expect(decision.isAllowed, isTrue);
      final tx = pool.transactions.single;
      expect(
        tx.executedSql,
        contains("select set_config('app.bypass_rls_audit', @value, true)"),
      );
      expect(tx.executedSql, contains('set local role forge_admin'));
      final insert = tx.executeCalls.firstWhere(
        (call) =>
            call.sql.contains('insert into mfa_recovery_request_attempts'),
      );
      expect(insert.parameters['email_hash'], isNot('user@example.test'));
      expect(insert.parameters['ip_hash'], isNot('203.0.113.10'));
      expect(tx.committed, isTrue);
    });

    test('blocks repeated email without inserting another attempt', () async {
      final pool = _LimiterPool(
        emailRows: <PostgresRow>[
          <String, Object?>{'attempted_at': DateTime.utc(2026, 4, 30, 12)},
        ],
        ipRows: const [],
      );
      final limiter = PostgresMfaRecoveryRequestRateLimiter(
        TenantTransactionWrapper(pool),
        now: () => DateTime.utc(2026, 4, 30, 12, 5),
      );

      final decision = await limiter.checkAndRecord(
        normalizedEmail: 'user@example.test',
        clientIp: '203.0.113.10',
      );

      expect(decision.isAllowed, isFalse);
      expect(decision.retryAfter, DateTime.utc(2026, 4, 30, 12, 15));
      final tx = pool.transactions.single;
      expect(
        tx.executeCalls.any(
          (call) =>
              call.sql.contains('insert into mfa_recovery_request_attempts'),
        ),
        isFalse,
      );
    });
  });
}

class _LimiterPool implements PostgresPool {
  _LimiterPool({required this.emailRows, required this.ipRows});

  final List<PostgresRow> emailRows;
  final List<PostgresRow> ipRows;
  final transactions = <_LimiterTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _LimiterTransaction(emailRows: emailRows, ipRows: ipRows);
    transactions.add(tx);
    return tx;
  }
}

class _SqlCall {
  const _SqlCall(this.sql, this.parameters);

  final String sql;
  final PostgresParameters parameters;
}

class _LimiterTransaction implements PostgresTransaction {
  _LimiterTransaction({required this.emailRows, required this.ipRows});

  final List<PostgresRow> emailRows;
  final List<PostgresRow> ipRows;
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
    if (sql.contains('email_hash')) return emailRows;
    return ipRows;
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
