// Phase 9 live-closeout - proxy bootstrap wiring tests.
//
// These tests prove the production auth-session ledger binding is
// assembled without opening a live database connection. The fake
// Postgres pool records SQL only; no network or provider calls occur.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/locations_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operator_admins_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operators_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/repository_auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/repository_password_change_gateway.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart'
    as integration;
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
        ProxySecretNames.pgcryptoEnvelopeKey:
            'placeholder-pgcrypto-envelope-key',
        ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
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
      // Phase 9 hardening pack (commit 17ce0391, 2026-05-07) added a
      // B1.A6 concurrent-session-cap check that runs UNCONDITIONALLY
      // before insertLogin. The check opens a `withSystem` (BYPASSRLS)
      // admin transaction to count active sessions across the global
      // auth_sessions table. So every recordLogin now opens TWO
      // transactions on the underlying pool:
      //   tx[0] = countActiveSessions  (withSystem / BYPASSRLS)
      //   tx[1] = insertLogin          (withTenant)
      // Both commit; the count returns 0 against the recording pool
      // (no rows pre-seeded) so the eviction branch never fires.
      expect(pool.beginTransactionCount, equals(2));
      final countTx = pool.transactions[0];
      final insertTx = pool.transactions[1];
      expect(countTx.committed, isTrue);
      expect(countTx.rolledBack, isFalse);
      expect(insertTx.committed, isTrue);
      expect(insertTx.rolledBack, isFalse);
      // First tx is the BYPASSRLS admin count, audited with the
      // 'system:auth.session_cap_check' reason.
      expect(
        countTx.executedSql,
        containsAll(<String>[
          "select set_config('app.bypass_rls_audit', @value, true)",
          'set local role forge_admin',
        ]),
      );
      final countQuery = countTx.queryCalls.single;
      expect(countQuery.sql, contains('select count(*)::int as cnt'));
      expect(countQuery.sql, contains('from auth_sessions'));
      // Second tx is the operator-scoped tenant insert.
      expect(
        insertTx.executedSql,
        containsAll(<String>[
          "select set_config('app.operator_id', @value, true)",
          "select set_config('app.location_id', @value, true)",
          "select set_config('app.user_id', @value, true)",
          "select set_config('app.bypass_rls_audit', 'tenant', true)",
        ]),
      );
      final insertCall = insertTx.queryCalls.single;
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
        ProxySecretNames.pgcryptoEnvelopeKey:
            'placeholder-pgcrypto-envelope-key',
        ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
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
        bindings.dataAccuracyAdminGateway,
        isA<RepositoryDataAccuracyAdminProxyGateway>(),
      );
      // Phase 11A.7 — feature flags admin gateway is bound to the
      // admin pool (cross-operator reads/writes). Construction must
      // not open a database connection.
      expect(
        bindings.featureFlagsAdminGateway,
        isA<RepositoryFeatureFlagsAdminProxyGateway>(),
      );
      expect(
        bindings.firstConnectionBackfillEnqueueGateway,
        isA<RepositoryFirstConnectionBackfillEnqueueGateway>(),
      );
      expect(
        bindings.integrationCategoryResolver(
          'toast',
          const <String, Object?>{},
        ),
        equals(integration.IntegrationCategory.pos),
      );
      // Phase 8 framework — connector binder seams. Both must be
      // populated so the binder lane can wire vendor adapters without
      // re-instantiating the wrapper or reaching back into the secret
      // registry. Field types pinned by `expect`s below.
      expect(
        bindings.tenantTransactionWrapper,
        isA<TenantTransactionWrapper>(),
      );
      expect(bindings.pgcryptoEnvelopeKey, isNotEmpty);
      expect(
        bindings.pgcryptoEnvelopeKey,
        equals('placeholder-pgcrypto-envelope-key'),
      );
      expect(
        capturedConnectionStrings,
        equals(<String>[
          'postgres://app-role.example/forgeflow',
          'postgres://admin-role.example/forgeflow',
          // Deep health uses its own admin-role pool so producer
          // fan-out cannot starve admin console gateway reads.
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
        ProxySecretNames.pgcryptoEnvelopeKey:
            'placeholder-pgcrypto-envelope-key',
        ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
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

  group('RepositoryOperatorLocationAdminProxyGateway audit targets', () {
    test('patchOperator audits the operator target metadata', () async {
      final auditRepository = _RecordingSystemAuditRepository();
      final operatorsRepository = _FakeOperatorsRepository(
        updatedOperator: _operatorRow(),
      );
      final gateway = _operatorLocationGateway(
        operatorsRepository: operatorsRepository,
        auditRepository: auditRepository,
      );

      final patched = await gateway.patchOperator(
        actorUserId: 'admin-user',
        operatorId: 'op-1',
        businessName: 'Renamed Operator',
        adminReason: 'Support-requested rename',
      );

      expect(patched, isNotNull);
      expect(auditRepository.events, hasLength(1));
      final audit = auditRepository.events.single;
      expect(
        audit.eventType,
        equals('admin.operator_location.operator_patched'),
      );
      expect(audit.targetKind, equals('operator'));
      expect(audit.targetId, equals('op-1'));
    });

    test('addLocation audits the location target metadata', () async {
      final auditRepository = _RecordingSystemAuditRepository();
      final locationsRepository = _FakeLocationsRepository(
        insertedLocation: _locationRow(),
      );
      final gateway = _operatorLocationGateway(
        locationsRepository: locationsRepository,
        auditRepository: auditRepository,
      );

      final created = await gateway.addLocation(
        actorUserId: 'admin-user',
        operatorId: 'op-1',
        parentOrgUnitId: 'org-1',
        name: 'North',
        address: '1 Main',
        timezone: 'America/Toronto',
        businessDayRolloverHour: 4,
        adminReason: 'Adding a reopened location',
      );

      expect(created['location_id'], equals('loc-1'));
      expect(auditRepository.events, hasLength(1));
      final audit = auditRepository.events.single;
      expect(audit.eventType, equals('admin.operator_location.location_added'));
      expect(audit.targetKind, equals('location'));
      expect(audit.targetId, equals('loc-1'));
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
      expect(source, contains("'pricing_tier_admin': 'postgres'"));
    });

    test('passes data accuracy admin binding into routeRequest', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();

      expect(
        source,
        matches(
          RegExp(
            r'dataAccuracyAdminGateway:\s*productionBindings\.dataAccuracyAdminGateway',
          ),
        ),
      );
      expect(source, contains("'data_accuracy_admin': 'postgres'"));
    });

    test('passes corpus admin binding into routeRequest', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();

      expect(
        source,
        matches(
          RegExp(
            r'corpusAdminGateway:\s*productionBindings\.corpusAdminGateway',
          ),
        ),
      );
      expect(source, contains("'corpus_admin': 'postgres'"));
    });

    test('passes feature flags admin binding into routeRequest', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();

      expect(
        source,
        matches(
          RegExp(
            r'featureFlagsAdminGateway:\s*productionBindings\.featureFlagsAdminGateway',
          ),
        ),
      );
      expect(source, contains("'feature_flags_admin': 'postgres'"));
    });
  });
}

RepositoryOperatorLocationAdminProxyGateway _operatorLocationGateway({
  OperatorsRepository? operatorsRepository,
  LocationsRepository? locationsRepository,
  AuthEventsAuditRepository? auditRepository,
}) {
  return RepositoryOperatorLocationAdminProxyGateway(
    operatorsRepository: operatorsRepository ?? _FakeOperatorsRepository(),
    locationsRepository: locationsRepository ?? _FakeLocationsRepository(),
    operatorAdminsRepository: _FakeOperatorAdminsRepository(),
    authOperationsGateway: const ScaffoldFailingAuthOperationsGateway(),
    auditRepository: auditRepository ?? _RecordingSystemAuditRepository(),
  );
}

TenantTransactionWrapper _dummyTenantWrapper() {
  return TenantTransactionWrapper(
    _RecordingPostgresPool(
      returningSessionId: '00000000-0000-4000-8000-000000000000',
    ),
  );
}

OperatorAdminRow _operatorRow() {
  final now = DateTime.utc(2026, 5, 12, 12);
  return OperatorAdminRow(
    operatorId: 'op-1',
    businessName: 'Renamed Operator',
    ownerEmail: 'owner@example.test',
    subscriptionTier: 'launch',
    preferredCurrency: 'CAD',
    primaryLocationId: 'loc-1',
    suspendedAt: null,
    createdAt: now,
    updatedAt: now,
  );
}

LocationAdminRow _locationRow() {
  final now = DateTime.utc(2026, 5, 12, 12);
  return LocationAdminRow(
    locationId: 'loc-1',
    operatorId: 'op-1',
    parentOrgUnitId: 'org-1',
    name: 'North',
    address: '1 Main',
    timezone: 'America/Toronto',
    businessDayRolloverHour: 4,
    createdAt: now,
    updatedAt: now,
  );
}

class _FakeOperatorsRepository extends OperatorsRepository {
  _FakeOperatorsRepository({this.updatedOperator})
    : super(_dummyTenantWrapper());

  final OperatorAdminRow? updatedOperator;

  @override
  Future<OperatorAdminRow?> updateOperator({
    required String operatorId,
    String? businessName,
    String? ownerEmail,
    String? subscriptionTier,
    String? preferredCurrency,
    String? primaryLocationId,
    required String adminReason,
  }) async {
    return updatedOperator;
  }
}

class _FakeLocationsRepository extends LocationsRepository {
  _FakeLocationsRepository({this.insertedLocation})
    : super(_dummyTenantWrapper());

  final LocationAdminRow? insertedLocation;

  @override
  Future<LocationAdminRow> insertLocation({
    required String operatorId,
    required String parentOrgUnitId,
    required String name,
    required String address,
    required String timezone,
    required int businessDayRolloverHour,
    required String adminReason,
  }) async {
    final row = insertedLocation;
    if (row == null) throw StateError('insertedLocation not configured');
    return row;
  }
}

class _FakeOperatorAdminsRepository extends OperatorAdminsRepository {
  _FakeOperatorAdminsRepository() : super(_dummyTenantWrapper());
}

class _RecordedSystemAuditEvent {
  const _RecordedSystemAuditEvent({
    required this.eventType,
    required this.targetKind,
    required this.targetId,
  });

  final String eventType;
  final String? targetKind;
  final String? targetId;
}

class _RecordingSystemAuditRepository extends AuthEventsAuditRepository {
  _RecordingSystemAuditRepository() : super(_dummyTenantWrapper());

  final List<_RecordedSystemAuditEvent> events = <_RecordedSystemAuditEvent>[];

  @override
  Future<String> insertSystemEvent({
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) async {
    events.add(
      _RecordedSystemAuditEvent(
        eventType: eventType,
        targetKind: targetKind,
        targetId: targetId,
      ),
    );
    return 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  }
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
