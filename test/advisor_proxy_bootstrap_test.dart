// Phase 9 live-closeout - proxy bootstrap wiring tests.
//
// These tests prove the production auth-session ledger binding is
// assembled without opening a live database connection. The fake
// Postgres pool records SQL only; no network or provider calls occur.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:forge_and_flow/infrastructure/cloud_run/cloud_run_admin_client.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_provider.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/corpus_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/graph_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/locations_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operator_admins_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operators_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/org_units_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/provider_credentials_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/usage_caps_repository.dart';
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

    // Slice B1.b regression — the operator-location admin gateway is
    // only reachable through the `super_admin`-gated proxy routes
    // (`kFfOperatorLocationAdminRoles` in `advisor_proxy.dart`). Per
    // the CLAUDE.md actor taxonomy (`user` = real human end-user,
    // `forge_admin` = F&F support / super_admin acting
    // cross-operator), every audit row this gateway writes must
    // carry `actor_kind = 'forge_admin'` so the hash-chained
    // `audit_logs` fan-out records honest attribution. Pinning the
    // literal here guards against an accidental flip back to
    // `'user'`, which would mislabel the row in both
    // `auth_events_audit` and (post-cutover) `audit_logs`.
    test(
      'patchOperator records actor_kind=forge_admin (B1.b regression)',
      () async {
        final auditRepository = _RecordingSystemAuditRepository();
        final operatorsRepository = _FakeOperatorsRepository(
          updatedOperator: _operatorRow(),
        );
        final gateway = _operatorLocationGateway(
          operatorsRepository: operatorsRepository,
          auditRepository: auditRepository,
        );

        await gateway.patchOperator(
          actorUserId: 'admin-user',
          operatorId: 'op-1',
          businessName: 'Renamed Operator',
          adminReason: 'Support-requested rename',
        );

        expect(auditRepository.events, hasLength(1));
        expect(auditRepository.events.single.actorKind, equals('forge_admin'));
      },
    );

    test(
      'addLocation records actor_kind=forge_admin (B1.b regression)',
      () async {
        final auditRepository = _RecordingSystemAuditRepository();
        final locationsRepository = _FakeLocationsRepository(
          insertedLocation: _locationRow(),
        );
        final gateway = _operatorLocationGateway(
          locationsRepository: locationsRepository,
          auditRepository: auditRepository,
        );

        await gateway.addLocation(
          actorUserId: 'admin-user',
          operatorId: 'op-1',
          parentOrgUnitId: 'org-1',
          name: 'North',
          address: '1 Main',
          timezone: 'America/Toronto',
          businessDayRolloverHour: 4,
          adminReason: 'Adding a reopened location',
        );

        expect(auditRepository.events, hasLength(1));
        expect(auditRepository.events.single.actorKind, equals('forge_admin'));
      },
    );
  });

  // Slice B1.c — peer-bug sweep for B1.b (PR #500). Four sibling
  // admin gateways in `tool/advisor_proxy/proxy_bootstrap.dart`
  // historically wrote `actorKind: 'user'` to the audit log even
  // though the surrounding `// Admin … path: actor is a verified F&F
  // admin JWT.` comment confirmed the caller path is gated by the
  // `super_admin`-only role sets in `advisor_proxy.dart` (e.g.
  // `kFfPricingAdminWriteRoles`, `kFfCorpusAdminWriteRoles`,
  // `kFfIntegrationAdminWriteRoles`). Per the CLAUDE.md actor
  // taxonomy (`user` = real human end-user, `forge_admin` = F&F
  // support / super_admin acting cross-operator) every audit row
  // these gateways write must carry `actor_kind = 'forge_admin'` so
  // both `auth_events_audit` and (post-cutover) the hash-chained
  // `audit_logs` table record honest attribution. The deep audit
  // (`docs/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md`
  // finding #1) flagged the four sites:
  //   - `RepositoryPricingTierAdminProxyGateway._audit`
  //   - `RepositoryCorpusAdminProxyGateway._audit`
  //   - `RepositoryGraphCandidatesProxyGateway._audit`
  //   - `RepositoryIntegrationAdminProxyGateway._audit`
  // Pinning each one against a recording-fake audit repository
  // guards against an accidental flip back to `'user'` that would
  // mislabel the admin actor in the global audit chain.
  group('B1.c — admin gateway actorKind peer-bug sweep', () {
    test(
      'RepositoryPricingTierAdminProxyGateway records '
      'actor_kind=forge_admin on listOperatorsWithCaps',
      () async {
        final auditRepository = _RecordingSystemAuditRepository();
        final gateway = RepositoryPricingTierAdminProxyGateway(
          operatorsRepository: _StubOperatorsRepository(),
          locationsRepository: _StubLocationsRepository(),
          usageCapsRepository: _StubUsageCapsRepository(),
          orgUnitsRepository: _StubOrgUnitsRepository(),
          auditRepository: auditRepository,
        );

        await gateway.listOperatorsWithCaps(
          actorUserId: 'admin-user',
          adminReason: 'List operators for pricing console',
        );

        expect(auditRepository.events, hasLength(1));
        expect(
          auditRepository.events.single.eventType,
          equals('admin.pricing.list'),
        );
        expect(
          auditRepository.events.single.actorKind,
          equals('forge_admin'),
        );
      },
    );

    test(
      'RepositoryCorpusAdminProxyGateway records '
      'actor_kind=forge_admin on listVersions',
      () async {
        final auditRepository = _RecordingSystemAuditRepository();
        final gateway = RepositoryCorpusAdminProxyGateway(
          corpusRepository: _StubCorpusRepository(),
          auditRepository: auditRepository,
        );

        await gateway.listVersions(
          actorUserId: 'admin-user',
          adminReason: 'List corpus versions for admin console',
        );

        expect(auditRepository.events, hasLength(1));
        expect(
          auditRepository.events.single.eventType,
          equals('admin.corpus.list'),
        );
        expect(
          auditRepository.events.single.actorKind,
          equals('forge_admin'),
        );
      },
    );

    test(
      'RepositoryGraphCandidatesProxyGateway records '
      'actor_kind=forge_admin on listGraphCandidates',
      () async {
        // The graph candidates gateway loads two artifacts off disk:
        //   1. The graphify candidate bundle (manifest JSON +
        //      node/edge JSONL) under `<repoRoot>/<candidatesDir>/`.
        //   2. The corpus manifest YAML at
        //      `<repoRoot>/docs/Knowledge_graph_docs/corpus_manifest.yaml`.
        // To exercise the audit path without standing up real
        // Graphify output, we materialize empty-but-valid versions
        // of both into a temporary repo root. Empty inputs route to
        // zero candidates and `_audit('admin.corpus.graph_candidates.list')`
        // still fires.
        final tempRoot = await Directory.systemTemp.createTemp(
          'b1c_graph_audit_',
        );
        try {
          final candidatesDir = Directory(
            p.join(tempRoot.path, _kGraphifyCandidatesOutputDir),
          );
          await candidatesDir.create(recursive: true);
          await File(
            p.join(candidatesDir.path, _kGraphifyCandidateManifestFile),
          ).writeAsString('{}');
          await File(
            p.join(candidatesDir.path, _kGraphifyNodeCandidatesFile),
          ).writeAsString('');
          await File(
            p.join(candidatesDir.path, _kGraphifyEdgeCandidatesFile),
          ).writeAsString('');
          final corpusManifestFile = File(
            p.join(tempRoot.path, _kCorpusManifestPath),
          );
          await corpusManifestFile.parent.create(recursive: true);
          await corpusManifestFile.writeAsString(
            "corpus_root: '.'\ndocuments: []\n",
          );

          final auditRepository = _RecordingSystemAuditRepository();
          final gateway = RepositoryGraphCandidatesProxyGateway(
            graphRepository: GraphRepository(_dummyTenantWrapper()),
            auditRepository: auditRepository,
            repoRoot: tempRoot,
          );

          await gateway.listGraphCandidates(
            actorUserId: 'admin-user',
            adminReason: 'List graph candidates for admin console',
          );

          expect(auditRepository.events, hasLength(1));
          expect(
            auditRepository.events.single.eventType,
            equals('admin.corpus.graph_candidates.list'),
          );
          expect(
            auditRepository.events.single.actorKind,
            equals('forge_admin'),
          );
        } finally {
          await tempRoot.delete(recursive: true);
        }
      },
    );

    test(
      'RepositoryIntegrationAdminProxyGateway records '
      'actor_kind=forge_admin on listBundle',
      () async {
        final auditRepository = _RecordingSystemAuditRepository();
        final gateway = RepositoryIntegrationAdminProxyGateway(
          providerCredentialsRepository: _StubProviderCredentialsRepository(),
          kmsProvider: _UnusedKmsProvider(),
          auditRepository: auditRepository,
          cloudRunAdminClient: _UnusedCloudRunAdminClient(),
          // adminWrapper intentionally null — `_readVendorApiReachability`
          // short-circuits to an empty map when the wrapper is absent,
          // which keeps the test off the Postgres path while still
          // driving the gateway through `_audit`.
        );

        await gateway.listBundle(
          actorUserId: 'admin-user',
          adminReason: 'List integrations bundle for admin console',
        );

        expect(auditRepository.events, hasLength(1));
        expect(
          auditRepository.events.single.eventType,
          equals('admin.integrations.list'),
        );
        expect(
          auditRepository.events.single.actorKind,
          equals('forge_admin'),
        );
      },
    );
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
    required this.actorKind,
    required this.targetKind,
    required this.targetId,
  });

  final String eventType;
  final String actorKind;
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
        actorKind: actorKind,
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

// ---------------------------------------------------------------------------
// B1.c — peer-bug sweep helpers.
//
// The four targeted gateways live in
// `tool/advisor_proxy/proxy_bootstrap.dart` and pull in real
// repositories. The tests below need to drive each gateway's lightest
// audit-emitting method without touching Postgres, KMS, or Cloud Run.
// The stubs here override the one or two repository methods each
// gateway actually calls in that path (`listOperators`,
// `listAllLocations`, `listAllCaps`, `listAllRootsAsAdmin`,
// `listVersions`, `listActive`) and return empty results so the audit
// row is the only observable side-effect.
// ---------------------------------------------------------------------------

/// Filenames mirrored from
/// `tool/advisor_corpus/advisor_corpus.dart`. Hard-coded here so the
/// proxy-bootstrap test does not have to depend on the advisor_corpus
/// tool package; if those constants ever drift the graph-candidates
/// test will fail loudly with a missing-file error.
const String _kGraphifyCandidatesOutputDir = 'graphify-out/candidates';
const String _kGraphifyNodeCandidatesFile = 'graphify_node_candidates.jsonl';
const String _kGraphifyEdgeCandidatesFile = 'graphify_edge_candidates.jsonl';
const String _kGraphifyCandidateManifestFile =
    'graphify_candidate_manifest.json';
const String _kCorpusManifestPath =
    'docs/Knowledge_graph_docs/corpus_manifest.yaml';

class _StubOperatorsRepository extends OperatorsRepository {
  _StubOperatorsRepository() : super(_dummyTenantWrapper());

  @override
  Future<List<OperatorAdminRow>> listOperators({
    required String adminReason,
  }) async {
    return const <OperatorAdminRow>[];
  }
}

class _StubLocationsRepository extends LocationsRepository {
  _StubLocationsRepository() : super(_dummyTenantWrapper());

  @override
  Future<List<LocationAdminRow>> listAllLocations({
    required String adminReason,
  }) async {
    return const <LocationAdminRow>[];
  }
}

class _StubUsageCapsRepository extends UsageCapsRepository {
  _StubUsageCapsRepository() : super(_dummyTenantWrapper());

  @override
  Future<List<UsageCapAdminRow>> listAllCaps({
    required String adminReason,
  }) async {
    return const <UsageCapAdminRow>[];
  }
}

class _StubOrgUnitsRepository extends OrgUnitsRepository {
  _StubOrgUnitsRepository() : super(_dummyTenantWrapper());
}

class _StubCorpusRepository extends CorpusRepository {
  _StubCorpusRepository() : super(_dummyTenantWrapper());

  @override
  Future<List<CorpusVersionRow>> listVersions({
    required String adminReason,
  }) async {
    return const <CorpusVersionRow>[];
  }
}

class _StubProviderCredentialsRepository
    extends ProviderCredentialsRepository {
  _StubProviderCredentialsRepository() : super(_dummyTenantWrapper());

  @override
  Future<List<ProviderCredentialRow>> listActive({
    required String adminReason,
  }) async {
    return const <ProviderCredentialRow>[];
  }
}

/// `listBundle` never touches KMS, but the gateway's constructor
/// requires a non-null [KmsProvider]. This stub throws if the bundle
/// path ever inadvertently exercises the rotation flow.
class _UnusedKmsProvider implements KmsProvider {
  @override
  Future<KmsWriteResult> writeSecret({
    required String logicalKeyKind,
    required String plaintext,
  }) async {
    throw StateError(
      'B1.c listBundle test must not exercise KmsProvider.writeSecret',
    );
  }
}

/// `listBundle` never forces a Cloud Run revision, but the gateway's
/// constructor requires a non-null [CloudRunAdminClient]. This stub
/// throws if the bundle path ever inadvertently triggers a restart.
class _UnusedCloudRunAdminClient implements CloudRunAdminClient {
  @override
  Future<String> forceNewRevision({required String reason}) async {
    throw StateError(
      'B1.c listBundle test must not exercise CloudRunAdminClient.forceNewRevision',
    );
  }
}
