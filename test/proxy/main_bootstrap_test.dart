// Two test surfaces share this file:
//
// HARD-A — `tool/advisor_proxy/main.dart` startup wiring.
// The actual `Future<void> main()` binds a socket and falls into a
// request loop, so we exercise the testable surface it delegates to:
// [evaluateProxyStartup] (decides whether prod needs to fail closed)
// and a source-grep over `main.dart` (proves the bindings + diagnostics
// flow through the runtime in the right places).
//
// HARD-G — startup KMS fail-closed gate + Postgres connectivity probe.
// Verifies that `ProxyConfig.fromEnvironment` throws
// `ProxyKmsMisconfiguredError` (and emits `startup.kms_misconfigured`)
// whenever `PROXY_ENVIRONMENT=prod` + `KMS_REAL_PROVIDER_ENABLED=true`
// and any of the three GCP env vars is unset (full or partial). All
// other combinations either continue with the stub provider (logging
// `startup.kms_stub_active` at WARN) or surface the unrelated
// partial-config error. Also verifies that
// `probeProxyStartupConnectivity` surfaces a timeout-on-acquire and a
// timeout-mid-transaction as `DependencyTimeoutException` so
// `main.dart` can exit 78.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/main.dart' as proxy_main;
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

ProxyConfig _configFromEnv({
  Map<String, String> overrides = const <String, String>{},
}) {
  final env = <String, String>{
    ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
    ProxySecretNames.voyageApiKey: 'placeholder-voyage',
    ProxySecretNames.postgresUrl: 'postgres://app-role.example/forgeflow',
    ProxySecretNames.postgresAdminUrl:
        'postgres://admin-role.example/forgeflow',
    ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
    ProxySecretNames.servicePrincipalJwtSecret:
        'placeholder-service-principal-jwt-secret',
    ...overrides,
  };
  return ProxyConfig.fromEnvironment(env);
}

Map<String, String> _baseEnv() => <String, String>{
  ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
  ProxySecretNames.voyageApiKey: 'placeholder-voyage',
  ProxySecretNames.postgresUrl: 'postgres://app-role.example/forgeflow',
  ProxySecretNames.postgresAdminUrl: 'postgres://admin-role.example/forgeflow',
  ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
  ProxySecretNames.servicePrincipalJwtSecret:
      'placeholder-service-principal-jwt-secret',
  ProxyConfigNames.firebaseProjectId: 'forge-flow-test',
};

class _StubPostgresPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw StateError('test pool must not open a real transaction');
  }
}

void main() {
  group('evaluateProxyStartup — PROXY_ENVIRONMENT=prod fail-closed', () {
    test('PROXY_ENVIRONMENT=prod with FIREBASE_PROJECT_ID unset returns '
        'EX_CONFIG (78) and the contracted stderr line', () {
      final config = _configFromEnv();
      // Sanity: config still parses, FIREBASE_PROJECT_ID is just absent.
      expect(config.firebaseProjectId, isNull);

      final failure = evaluateProxyStartup(
        config: config,
        environment: <String, String>{'PROXY_ENVIRONMENT': 'prod'},
      );

      expect(failure, isNotNull);
      expect(failure!.exitCode, equals(78));
      expect(
        failure.message,
        equals('startup_failure: firebase_project_id_required_in_prod'),
      );
    });

    test('PROXY_ENVIRONMENT=prod with FIREBASE_PROJECT_ID set returns null '
        '(proxy continues to bind)', () {
      final config = _configFromEnv(
        overrides: <String, String>{
          ProxyConfigNames.firebaseProjectId: 'forge-flow-prod',
        },
      );
      expect(config.firebaseProjectId, equals('forge-flow-prod'));

      final failure = evaluateProxyStartup(
        config: config,
        environment: <String, String>{'PROXY_ENVIRONMENT': 'prod'},
      );

      expect(failure, isNull);
    });

    test('PROXY_ENVIRONMENT=staging with FIREBASE_PROJECT_ID unset preserves '
        'the scaffold-fallback (no fail-closed)', () {
      final config = _configFromEnv();
      final failure = evaluateProxyStartup(
        config: config,
        environment: <String, String>{'PROXY_ENVIRONMENT': 'staging'},
      );
      expect(failure, isNull);
    });

    test('PROXY_ENVIRONMENT=dev with FIREBASE_PROJECT_ID unset preserves '
        'the scaffold-fallback (no fail-closed)', () {
      final config = _configFromEnv();
      final failure = evaluateProxyStartup(
        config: config,
        environment: <String, String>{'PROXY_ENVIRONMENT': 'dev'},
      );
      expect(failure, isNull);
    });

    test('PROXY_ENVIRONMENT unset with FIREBASE_PROJECT_ID unset preserves '
        'the scaffold-fallback (no fail-closed)', () {
      final config = _configFromEnv();
      final failure = evaluateProxyStartup(
        config: config,
        environment: const <String, String>{},
      );
      expect(failure, isNull);
    });

    test(
      'PROXY_ENVIRONMENT match is case-insensitive and trims whitespace',
      () {
        final config = _configFromEnv();
        final failure = evaluateProxyStartup(
          config: config,
          environment: <String, String>{'PROXY_ENVIRONMENT': '  PROD  '},
        );
        expect(failure, isNotNull);
        expect(failure!.exitCode, equals(78));
      },
    );
  });

  group('main.dart entrypoint surface (source assertions)', () {
    String readMainSource() =>
        File('tool/advisor_proxy/main.dart').readAsStringSync();

    test('wires productionBindings.usageCounterStore into ProxyUsageGuard', () {
      expect(
        readMainSource(),
        contains('store: productionBindings.usageCounterStore'),
      );
    });

    test('wires productionBindings.healthCheckStore into the runtime', () {
      final source = readMainSource();
      expect(source, contains('productionBindings.healthCheckStore'));
      // And the runtime call passes it into routeRequest.
      expect(source, contains('healthCheckStore: healthCheckStore'));
    });

    test('dispatches request handling without blocking the listener loop', () {
      final source = readMainSource();
      expect(source, contains('import \'dart:async\';'));
      expect(source, contains('unawaited('));
      expect(source, contains('long-lived WebSockets must not queue probes'));
    });

    test('loads migration catalog before production binding construction', () {
      final source = readMainSource();
      expect(source, contains('final migrationFilenames ='));
      expect(source, contains('loadProxyMigrationFilenames()'));
      expect(source, contains("'phase': 'migration_catalog'"));
      expect(
        source,
        contains('expectedMigrationFilenames: migrationFilenames'),
      );
    });

    test('records migration catalog before binding request routes', () {
      final source = readMainSource();
      expect(source, contains('recordProxyStartupMigrations'));
      expect(source, contains("'startup.migrations_recorded'"));
      expect(source, contains("'phase': 'migration_registry'"));
      expect(source, contains("'migration_catalog_count'"));
    });

    test('no longer references the scaffold-failing usage / health stores', () {
      final source = readMainSource();
      expect(source.contains('ScaffoldFailingUsageCounterStore'), isFalse);
      expect(source.contains('ScaffoldFailingProxyHealthCheckStore'), isFalse);
    });

    test('emits gemini_slot_enabled diagnostics line', () {
      final source = readMainSource();
      expect(
        source,
        contains(
          "'gemini_slot_enabled: \${productionBindings.geminiSlotEnabled}'",
        ),
      );
    });

    test('top-of-file comment references real Anthropic primary + optional '
        'real Gemini secondary', () {
      final source = readMainSource();
      // The top-of-file block has been retargeted to describe the
      // post-Lock-7 reality: real Anthropic primary + optional real
      // Gemini secondary, not the rejecting scaffold provider.
      // Substrings are kept short so comment line wrapping cannot
      // accidentally break them up.
      expect(source, contains('real Anthropic'));
      expect(source, contains('real Gemini'));
      expect(source, contains('GEMINI_API_KEY'));
      expect(
        source.contains('ScaffoldRejectingProxyLlmProvider'),
        isFalse,
        reason:
            'main.dart top-of-file comment should no longer reference '
            'the removed ScaffoldRejectingProxyLlmProvider',
      );
    });
  });

  group('proxy_bootstrap migration registry wiring', () {
    String readBootstrapSource() =>
        File('tool/advisor_proxy/proxy_bootstrap.dart').readAsStringSync();

    test('threads expected migration filenames into the health producers', () {
      final source = readBootstrapSource();
      expect(
        source,
        contains('List<String> expectedMigrationFilenames = const <String>[]'),
      );
      expect(
        source,
        contains('expectedMigrationFilenames: expectedMigrationFilenames'),
      );
      expect(source, contains('buildProxyHealthRegistryProducers('));
    });

    test('records startup migrations through the admin system wrapper', () {
      final source = readBootstrapSource();
      expect(source, contains('Future<int> recordProxyStartupMigrations'));
      expect(source, contains('TenantTransactionWrapper(bindings.adminPool)'));
      expect(source, contains("reason: 'proxy_migration_registry'"));
      expect(source, contains('ProxyMigrationApplyRegistryWriter'));
      expect(source, contains('.recordAppliedMigrations(migrationFilenames)'));
    });
  });

  group('loadProxyMigrationFilenames', () {
    test('returns sorted SQL basenames and ignores non-SQL files', () {
      final directory = Directory.systemTemp.createTempSync(
        'proxy_migrations_catalog_test_',
      );
      try {
        File(
          '${directory.path}${Platform.pathSeparator}002_second.sql',
        ).writeAsStringSync('-- second');
        File(
          '${directory.path}${Platform.pathSeparator}001_first.sql',
        ).writeAsStringSync('-- first');
        File(
          '${directory.path}${Platform.pathSeparator}README.md',
        ).writeAsStringSync('# ignored');

        expect(
          proxy_main.loadProxyMigrationFilenames(directory: directory),
          equals(<String>['001_first.sql', '002_second.sql']),
        );
      } finally {
        directory.deleteSync(recursive: true);
      }
    });

    test('returns an empty catalog when the directory is absent', () {
      final directory = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'proxy_migrations_catalog_missing',
      );
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }

      expect(
        proxy_main.loadProxyMigrationFilenames(directory: directory),
        isEmpty,
      );
    });
  });

  group('startup KMS fail-closed (HARD-G observability)', () {
    test('prod + KMS_REAL_PROVIDER_ENABLED=true + all GCP vars unset '
        'throws ProxyKmsMisconfiguredError listing the missing names', () {
      final env = _baseEnv()
        ..[ProxyConfigNames.proxyEnvironment] = 'prod'
        ..[ProxyConfigNames.kmsRealProviderEnabled] = 'true';
      Object? thrown;
      try {
        ProxyConfig.fromEnvironment(env);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyKmsMisconfiguredError>());
      final error = thrown! as ProxyKmsMisconfiguredError;
      expect(
        error.missingSecretNames,
        containsAll(<String>[
          ProxyConfigNames.gcpProjectId,
          ProxyConfigNames.cloudRunRegion,
          ProxyConfigNames.cloudRunServiceName,
        ]),
      );
      expect(error.message, contains(ProxyConfigNames.gcpProjectId));
    });

    test('prod + KMS_REAL_PROVIDER_ENABLED=true + partial GCP vars '
        '(one of three set) maps to the KMS misconfig event, not the '
        'generic partial-config error', () {
      final env = _baseEnv()
        ..[ProxyConfigNames.proxyEnvironment] = 'prod'
        ..[ProxyConfigNames.kmsRealProviderEnabled] = 'true'
        ..[ProxyConfigNames.gcpProjectId] = 'forge-flow-prod';
      Object? thrown;
      try {
        ProxyConfig.fromEnvironment(env);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyKmsMisconfiguredError>());
      final error = thrown! as ProxyKmsMisconfiguredError;
      expect(
        error.missingSecretNames,
        containsAll(<String>[
          ProxyConfigNames.cloudRunRegion,
          ProxyConfigNames.cloudRunServiceName,
        ]),
      );
      expect(
        error.missingSecretNames,
        isNot(contains(ProxyConfigNames.gcpProjectId)),
      );
    });

    test('non-prod + KMS_REAL_PROVIDER_ENABLED=true + partial GCP vars '
        'still surfaces the legacy partial-config error', () {
      // Outside prod the partial-set check is the legacy guardrail —
      // the KMS rollout flag does not arm fail-closed in non-prod.
      final env = _baseEnv()
        ..[ProxyConfigNames.proxyEnvironment] = 'staging'
        ..[ProxyConfigNames.kmsRealProviderEnabled] = 'true'
        ..[ProxyConfigNames.gcpProjectId] = 'forge-flow-staging';
      Object? thrown;
      try {
        ProxyConfig.fromEnvironment(env);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyConfigError>());
      expect(thrown, isNot(isA<ProxyKmsMisconfiguredError>()));
    });

    test('staging + missing GCP vars proceeds with stub (no throw)', () {
      final env = _baseEnv()
        ..[ProxyConfigNames.proxyEnvironment] = 'staging'
        ..[ProxyConfigNames.kmsRealProviderEnabled] = 'false';
      final config = ProxyConfig.fromEnvironment(env);
      final bindings = buildProxyProductionBindings(
        config,
        postgresPoolFactory: (connectionString) => _StubPostgresPool(),
      );
      expect(bindings, isNotNull);
    });

    test('prod + KMS_REAL_PROVIDER_ENABLED=false + missing GCP vars '
        'proceeds with stub (rollout not yet armed)', () {
      final env = _baseEnv()
        ..[ProxyConfigNames.proxyEnvironment] = 'prod'
        ..[ProxyConfigNames.kmsRealProviderEnabled] = 'false';
      final config = ProxyConfig.fromEnvironment(env);
      final bindings = buildProxyProductionBindings(
        config,
        postgresPoolFactory: (connectionString) => _StubPostgresPool(),
      );
      expect(bindings, isNotNull);
    });

    test('PROXY_ENVIRONMENT lowercases for the prod check', () {
      final env = _baseEnv()
        ..[ProxyConfigNames.proxyEnvironment] = 'PROD'
        ..[ProxyConfigNames.kmsRealProviderEnabled] = 'true';
      Object? thrown;
      try {
        ProxyConfig.fromEnvironment(env);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyKmsMisconfiguredError>());
    });
  });

  group('probeProxyStartupConnectivity (HARD-G observability)', () {
    test('rethrows DependencyTimeoutException when beginTransaction '
        'times out (covers both acquire and BEGIN paths)', () async {
      final bindings = _bindingsWithTenantPool(
        _TimingOutPool(throwOn: _TimingOutPoolPhase.beginTransaction),
      );
      Object? thrown;
      try {
        await probeProxyStartupConnectivity(bindings);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<DependencyTimeoutException>());
      final timeout = thrown! as DependencyTimeoutException;
      expect(timeout.surface, equals('postgres'));
      expect(timeout.operation, equals('acquire_connection'));
    });

    test('rethrows DependencyTimeoutException when a mid-transaction '
        'query times out, after attempting rollback', () async {
      final pool = _TimingOutPool(throwOn: _TimingOutPoolPhase.query);
      final bindings = _bindingsWithTenantPool(pool);
      Object? thrown;
      try {
        await probeProxyStartupConnectivity(bindings);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<DependencyTimeoutException>());
      expect(pool.lastTransaction?.rollbackCount, equals(1));
    });

    test('happy path commits each pool exactly once', () async {
      final tenantPool = _RecordingPool();
      final adminPool = _RecordingPool();
      final bindings = _bindingsWithPools(tenant: tenantPool, admin: adminPool);
      await probeProxyStartupConnectivity(bindings);
      expect(tenantPool.transactions.length, equals(1));
      expect(tenantPool.transactions.single.committed, isTrue);
      expect(adminPool.transactions.length, equals(1));
      expect(adminPool.transactions.single.committed, isTrue);
    });
  });
}

ProxyProductionBindings _bindingsWithTenantPool(PostgresPool tenantPool) {
  return _bindingsWithPools(tenant: tenantPool, admin: _RecordingPool());
}

ProxyProductionBindings _bindingsWithPools({
  required PostgresPool tenant,
  required PostgresPool admin,
}) {
  return _StartupProbeBindingsView(tenantPool: tenant, adminPool: admin);
}

/// Minimal stub of [ProxyProductionBindings] that only surfaces the
/// pool fields the startup probe touches. Dart treats the bindings
/// class as concrete with `required` fields, so the test instead
/// exposes the same shape via a thin container that the probe can
/// read. Concretely the probe reads `bindings.tenantPool` /
/// `bindings.adminPool`; we satisfy that contract here without
/// constructing the rest of the production graph.
class _StartupProbeBindingsView implements ProxyProductionBindings {
  _StartupProbeBindingsView({
    required this.tenantPool,
    required this.adminPool,
  });

  @override
  final PostgresPool tenantPool;

  @override
  final PostgresPool adminPool;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

enum _TimingOutPoolPhase { beginTransaction, query }

class _TimingOutPool implements PostgresPool {
  _TimingOutPool({required this.throwOn});

  final _TimingOutPoolPhase throwOn;
  _TimingOutPoolTransaction? lastTransaction;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    if (throwOn == _TimingOutPoolPhase.beginTransaction) {
      throw const DependencyTimeoutException(
        surface: 'postgres',
        operation: 'acquire_connection',
        elapsedMs: 10000,
      );
    }
    final tx = _TimingOutPoolTransaction(throwOnQuery: true);
    lastTransaction = tx;
    return tx;
  }
}

class _TimingOutPoolTransaction implements PostgresTransaction {
  _TimingOutPoolTransaction({required this.throwOnQuery});

  final bool throwOnQuery;
  int rollbackCount = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) {
    if (throwOnQuery) {
      throw const DependencyTimeoutException(
        surface: 'postgres',
        operation: 'query',
        elapsedMs: 5000,
      );
    }
    return Future<List<PostgresRow>>.value(const <PostgresRow>[]);
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {
    rollbackCount++;
  }
}

class _RecordingPool implements PostgresPool {
  final transactions = <_RecordingPoolTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingPoolTransaction();
    transactions.add(tx);
    return tx;
  }
}

class _RecordingPoolTransaction implements PostgresTransaction {
  bool committed = false;
  bool rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    return 0;
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
