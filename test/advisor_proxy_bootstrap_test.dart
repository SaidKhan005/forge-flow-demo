// Phase 9 live-closeout - proxy bootstrap wiring tests.
//
// These tests prove the production auth-session ledger binding is
// assembled without opening a live database connection. The fake
// Postgres pool records SQL only; no network or provider calls occur.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/repository_auth_session_ledger_writer.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import '../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('buildAuthSessionLedgerWriter', () {
    test('uses POSTGRES_URL, not POSTGRES_ADMIN_URL, and opens no '
        'connection until the first ledger write', () async {
      final config = ProxyConfig.fromEnvironment(const <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.postgresUrl: 'postgres://app-role.example/forgeflow',
        ProxySecretNames.postgresAdminUrl:
            'postgres://admin-role.example/forgeflow',
      });
      final pool = _RecordingPostgresPool(
        returningSessionId: '11111111-1111-4111-8111-111111111111',
      );
      final capturedConnectionStrings = <String>[];

      final writer = buildAuthSessionLedgerWriter(
        config,
        postgresPoolFactory: (connectionString) {
          capturedConnectionStrings.add(connectionString);
          return pool;
        },
      );

      expect(writer, isA<RepositoryAuthSessionLedgerWriter>());
      expect(
        capturedConnectionStrings,
        equals(<String>['postgres://app-role.example/forgeflow']),
      );
      expect(pool.beginTransactionCount, equals(0));

      final sessionId = await writer.recordLogin(
        const AuthSessionLedgerLogin(
          userId: '22222222-2222-4222-8222-222222222222',
          operatorId: '33333333-3333-4333-8333-333333333333',
          locationId: '44444444-4444-4444-8444-444444444444',
          tokenHash: 'sha256-id-token-hash',
          context: AuthSessionLedgerContext(
            ip: '127.0.0.1',
            userAgent: 'forge-flow-test',
            geoCountry: 'CA',
          ),
        ),
      );

      expect(sessionId, equals('11111111-1111-4111-8111-111111111111'));
      expect(pool.beginTransactionCount, equals(1));
      expect(pool.transactions.single.committed, isTrue);
      expect(pool.transactions.single.rolledBack, isFalse);
      expect(
        pool.transactions.single.executedSql,
        containsAll(<String>[
          "select set_config('app.operator_id', @value, true)",
          "select set_config('app.location_id', @value, true)",
          "select set_config('app.user_id', @value, true)",
          "select set_config('app.bypass_rls_audit', 'tenant', true)",
        ]),
      );
      final insertCall = pool.transactions.single.queryCalls.single;
      expect(insertCall.sql, contains('insert into auth_sessions'));
      expect(
        insertCall.parameters['token_hash'],
        equals('sha256-id-token-hash'),
      );
      expect(insertCall.parameters['ip'], equals('127.0.0.1'));
      expect(insertCall.parameters['geo_country'], equals('CA'));
    });
  });
}

class _RecordingPostgresPool implements PostgresPool {
  _RecordingPostgresPool({required this.returningSessionId});

  final String returningSessionId;
  final transactions = <_RecordingPostgresTransaction>[];
  var beginTransactionCount = 0;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    beginTransactionCount++;
    final tx = _RecordingPostgresTransaction(returningSessionId);
    transactions.add(tx);
    return tx;
  }
}

class _SqlCall {
  const _SqlCall(this.sql, this.parameters);

  final String sql;
  final PostgresParameters parameters;
}

class _RecordingPostgresTransaction implements PostgresTransaction {
  _RecordingPostgresTransaction(this.returningSessionId);

  final String returningSessionId;
  final executedSql = <String>[];
  final queryCalls = <_SqlCall>[];
  var committed = false;
  var rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_SqlCall(sql, parameters));
    if (sql.contains('insert into auth_sessions')) {
      return <PostgresRow>[
        <String, Object?>{'session_id': returningSessionId},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executedSql.add(sql);
    return 1;
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
