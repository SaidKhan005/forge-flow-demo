// Phase 9 live-closeout - proxy bootstrap wiring tests.
//
// These tests prove the production auth-session ledger binding is
// assembled without opening a live database connection. The fake
// Postgres pool records SQL only; no network or provider calls occur.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/repository_auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/repository_password_change_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_gateway.dart';

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
        ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
        ProxySecretNames.servicePrincipalJwtSecret:
            'placeholder-service-principal-jwt-secret',
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

  group('buildProxyProductionBindings', () {
    test('assembles all live-closeout route bindings without opening '
        'database connections', () {
      final config = ProxyConfig.fromEnvironment(const <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.postgresUrl: 'postgres://app-role.example/forgeflow',
        ProxySecretNames.postgresAdminUrl:
            'postgres://admin-role.example/forgeflow',
        ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
        ProxySecretNames.servicePrincipalJwtSecret:
            'placeholder-service-principal-jwt-secret',
        ProxyConfigNames.firebaseProjectId: 'forge-flow-test',
      });
      final appPool = _RecordingPostgresPool(
        returningSessionId: '11111111-1111-4111-8111-111111111111',
      );
      final adminPool = _RecordingPostgresPool(
        returningSessionId: '22222222-2222-4222-8222-222222222222',
      );
      final poolsByConnectionString = <String, _RecordingPostgresPool>{
        'postgres://app-role.example/forgeflow': appPool,
        'postgres://admin-role.example/forgeflow': adminPool,
      };
      final capturedConnectionStrings = <String>[];

      final bindings = buildProxyProductionBindings(
        config,
        postgresPoolFactory: (connectionString) {
          capturedConnectionStrings.add(connectionString);
          final pool = poolsByConnectionString[connectionString];
          if (pool == null) {
            throw StateError('unexpected connection string');
          }
          return pool;
        },
      );

      expect(bindings.accountingStore, isA<PostgresProxyAccountingStore>());
      expect(
        bindings.authSessionLedgerWriter,
        isA<RepositoryAuthSessionLedgerWriter>(),
      );
      expect(
        bindings.permissionSnapshotResolver,
        isA<RepositoryProxyPermissionSnapshotResolver>(),
      );
      expect(
        bindings.adminPermissionGuard,
        isA<RepositoryProxyAdminPermissionGuard>(),
      );
      expect(
        bindings.authOperationsGateway,
        isA<RepositoryAuthOperationsGateway>(),
      );
      expect(
        bindings.servicePrincipalJwtIssuanceGateway,
        isA<PostgresServicePrincipalJwtIssuanceGateway>(),
      );
      expect(
        bindings.passwordChangeGateway,
        isA<RepositoryPasswordChangeGateway>(),
      );
      expect(
        bindings.mfaOperationsGateway,
        isA<RepositoryMfaOperationsGateway>(),
      );
      expect(
        bindings.mfaRecoveryRequestGateway,
        isA<RepositoryMfaRecoveryRequestGateway>(),
      );
      // Phase 11A.2 — pricing tier admin gateway is bound to the
      // admin pool (cross-operator reads/writes). Construction must
      // not open a database connection.
      expect(
        bindings.pricingTierAdminGateway,
        isA<RepositoryPricingTierAdminProxyGateway>(),
      );
      expect(
        capturedConnectionStrings,
        equals(<String>[
          'postgres://app-role.example/forgeflow',
          'postgres://admin-role.example/forgeflow',
        ]),
      );
      expect(appPool.beginTransactionCount, equals(0));
      expect(adminPool.beginTransactionCount, equals(0));
    });

    test('requires FIREBASE_PROJECT_ID before constructing database pools', () {
      final config = ProxyConfig.fromEnvironment(const <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.postgresUrl: 'postgres://app-role.example/forgeflow',
        ProxySecretNames.postgresAdminUrl:
            'postgres://admin-role.example/forgeflow',
        ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
        ProxySecretNames.servicePrincipalJwtSecret:
            'placeholder-service-principal-jwt-secret',
      });
      var poolFactoryCalls = 0;

      Object? thrown;
      try {
        buildProxyProductionBindings(
          config,
          postgresPoolFactory: (connectionString) {
            poolFactoryCalls++;
            return _RecordingPostgresPool(
              returningSessionId: '33333333-3333-4333-8333-333333333333',
            );
          },
        );
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<ProxyConfigError>());
      final error = thrown! as ProxyConfigError;
      expect(
        error.missingSecretNames,
        contains(ProxyConfigNames.firebaseProjectId),
      );
      expect(poolFactoryCalls, equals(0));
    });
  });

  group('Cloud Run entrypoint wiring', () {
    test('passes pricing tier admin binding into routeRequest', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();

      expect(
        source,
        matches(
          RegExp(
            r'pricingTierAdminGateway:\s*productionBindings\.pricingTierAdminGateway',
          ),
        ),
      );
      expect(source, contains('pricing_tier_admin: postgres'));
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
    if (sql.contains('insert into auth_events_audit')) {
      // Audit insert uses RETURNING; surface any non-null event_id so
      // callers that check `if rows.isEmpty` succeed.
      return const <PostgresRow>[
        <String, Object?>{'event_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'},
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
