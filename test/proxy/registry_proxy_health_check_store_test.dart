// HARD-A — production wiring of [RegistryProxyHealthCheckStore].
//
// Coverage focus:
//   * `buildProxyProductionBindings` returns a real
//     [RegistryProxyHealthCheckStore] (no scaffold-failing fallback).
//   * The health route returns 200 with the contracted envelope when
//     dependencies are green and the producer registry is wired.
//   * The route returns 503 with `status: unavailable` when a required
//     dependency probe fails.
//   * Reserved metrics whose producers have not landed yet (B43 / B44 /
//     B45 / B47) project to `status: unknown` without making the
//     response degraded.
//   * `strictProxyHealthDependencyProbe` exercises real cypher MATCH
//     and pgvector distance, not just extension presence.
//   * Bindings tolerate missing FIREBASE_PROJECT_ID in non-prod mode
//     via `requireFirebase: false`, so dev/staging boots stay live.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('buildProxyProductionBindings — health check store', () {
    test('binds RegistryProxyHealthCheckStore (not the scaffold)', () {
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

      final bindings = buildProxyProductionBindings(
        config,
        postgresPoolFactory: (_) => _NoOpPostgresPool(),
      );

      expect(bindings.healthCheckStore, isA<RegistryProxyHealthCheckStore>());
      expect(
        bindings.healthCheckStore,
        isNot(isA<ScaffoldFailingProxyHealthCheckStore>()),
      );
    });

    test('binds AdvisorProxyUsageCounterStore (not the scaffold)', () {
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

      final bindings = buildProxyProductionBindings(
        config,
        postgresPoolFactory: (_) => _NoOpPostgresPool(),
      );

      expect(
        bindings.usageCounterStore,
        isNot(isA<ScaffoldFailingUsageCounterStore>()),
      );
    });

    test('requireFirebase=false tolerates missing FIREBASE_PROJECT_ID in '
        'dev/staging so the proxy still binds', () {
      final config = ProxyConfig.fromEnvironment(const <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.postgresUrl: 'postgres://app-role.example/forgeflow',
        ProxySecretNames.postgresAdminUrl:
            'postgres://admin-role.example/forgeflow',
        ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
        ProxySecretNames.servicePrincipalJwtSecret:
            'placeholder-service-principal-jwt-secret',
        // Note: FIREBASE_PROJECT_ID intentionally omitted.
      });
      expect(config.firebaseProjectId, isNull);

      // Default `requireFirebase: true` still throws — preserves the
      // existing prod posture.
      expect(
        () => buildProxyProductionBindings(
          config,
          postgresPoolFactory: (_) => _NoOpPostgresPool(),
        ),
        throwsA(isA<ProxyConfigError>()),
      );

      // Dev/staging override: bindings construct without raising and
      // the Firebase admin client falls back to the scaffold-failing
      // implementation.
      final bindings = buildProxyProductionBindings(
        config,
        postgresPoolFactory: (_) => _NoOpPostgresPool(),
        requireFirebase: false,
      );
      expect(
        bindings.firebaseAdminAuthClient,
        isA<ScaffoldFailingFirebaseAdminAuthClient>(),
      );
    });
  });

  group('strictProxyHealthDependencyProbe — behavioral checks', () {
    test('green when all three SQL calls return without throwing', () async {
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async {
        if (sql.contains('select 1 as ok')) {
          return <Map<String, Object?>>[
            <String, Object?>{'ok': 1},
          ];
        }
        if (sql.contains("cypher('forgeflow'")) {
          // Empty graph returns zero rows — must still be green.
          return const <Map<String, Object?>>[];
        }
        if (sql.contains("'[1,0,0]'::vector <-> '[0,1,0]'::vector")) {
          return <Map<String, Object?>>[
            <String, Object?>{'distance': 1.4142135623730951},
          ];
        }
        throw StateError('unexpected SQL: $sql');
      }

      final probe = await strictProxyHealthDependencyProbe(
        runnerFn,
        DateTime.utc(2026, 5, 2, 12),
      );
      expect(probe.postgresOk, isTrue);
      expect(probe.ageOk, isTrue);
      expect(probe.pgvectorOk, isTrue);
    });

    test(
      'cypher MATCH SQL is sent (not a pg_extension presence check)',
      () async {
        final calls = <String>[];
        Future<List<Map<String, Object?>>> runnerFn(
          String sql, {
          Map<String, Object?> parameters = const <String, Object?>{},
        }) async {
          calls.add(sql);
          return const <Map<String, Object?>>[];
        }

        await strictProxyHealthDependencyProbe(
          runnerFn,
          DateTime.utc(2026, 5, 2, 12),
        );
        // AGE call must invoke cypher with a MATCH; not just check
        // pg_extension.
        final cypherCall = calls.firstWhere(
          (sql) => sql.contains('cypher(') && sql.contains('MATCH (n)'),
          orElse: () => '',
        );
        expect(cypherCall, isNot(equals('')));
        // Must be fully qualified so we don't depend on search_path.
        expect(cypherCall, contains('ag_catalog.cypher'));
        expect(cypherCall, contains('ag_catalog.agtype'));
        // Must be a SINGLE statement — the proxy runs SQL through
        // `package:postgres` `Sql.named(...)` (prepared/extended-query
        // path), which rejects multi-command strings. A semicolon in
        // the body would make a healthy production AGE report `red`.
        expect(
          cypherCall.trimRight().split(';').where((s) => s.trim().isNotEmpty),
          hasLength(1),
          reason:
              'AGE probe must be a single statement; a SET + SELECT '
              'pair would be rejected by the prepared-query runner',
        );
        expect(
          calls.any((sql) => sql.contains("pg_extension where extname")),
          isFalse,
          reason: 'strict probe must not fall back to extension-presence-only',
        );
        // pgvector call must use the distance operator, not just the
        // vector literal cast.
        expect(
          calls.any((sql) => sql.contains("'[1,0,0]'::vector <->")),
          isTrue,
        );
      },
    );

    test('AGE thrown error projects ageOk → false', () async {
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async {
        if (sql.contains('cypher(')) {
          throw StateError('AGE not loaded');
        }
        return <Map<String, Object?>>[
          <String, Object?>{'ok': 1},
        ];
      }

      final probe = await strictProxyHealthDependencyProbe(
        runnerFn,
        DateTime.utc(2026, 5, 2, 12),
      );
      expect(probe.postgresOk, isTrue);
      expect(probe.ageOk, isFalse);
      expect(probe.pgvectorOk, isTrue);
    });

    test('pgvector distance error projects pgvectorOk → false', () async {
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async {
        if (sql.contains('<->')) {
          throw StateError('vector operator missing');
        }
        return const <Map<String, Object?>>[];
      }

      final probe = await strictProxyHealthDependencyProbe(
        runnerFn,
        DateTime.utc(2026, 5, 2, 12),
      );
      expect(probe.pgvectorOk, isFalse);
    });
  });

  group('RegistryProxyHealthCheckStore — envelope behavior', () {
    test('green dependencies + empty producer set → 200 / status ok', () async {
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async => const <Map<String, Object?>>[];

      final store = RegistryProxyHealthCheckStore(
        runnerFn: runnerFn,
        dependencyProbe: (fn, now) async => const ProxyHealthDependencyProbe(
          postgresOk: true,
          ageOk: true,
          pgvectorOk: true,
        ),
        producers: const <String, ProxyHealthRegistryProducer>{},
        now: () => DateTime.utc(2026, 5, 2, 12),
      );

      final result = await store.check();
      final json = result.toJson(checkedAt: DateTime.utc(2026, 5, 2, 12));
      expect(result.ok, isTrue);
      expect(json['status'], equals('ok'));
      expect(json['contract'], equals('proxy_health.v1'));
      expect(json['schema_version'], equals(1));

      final dependencies = json['dependencies']! as Map<String, Object?>;
      expect(
        (dependencies['postgres']! as Map<String, Object?>)['status'],
        equals('green'),
      );
      expect(
        (dependencies['age']! as Map<String, Object?>)['status'],
        equals('green'),
      );
      expect(
        (dependencies['pgvector']! as Map<String, Object?>)['status'],
        equals('green'),
      );

      // Reserved-but-unwired metrics still render as `status: unknown`.
      final metrics = json['metrics']! as Map<String, Object?>;
      for (final key in <String>[
        'audit_chain_lag_seconds',
        'graph_node_count',
        'rollup_freshness_per_grain',
        'vector_index_size_per_corpus',
      ]) {
        final m = metrics[key]! as Map<String, Object?>;
        expect(
          m['status'],
          equals('unknown'),
          reason:
              'reserved metric "$key" should stay status:unknown until '
              'its producer lands',
        );
      }
    });

    test('failed Postgres dependency → 503 / status unavailable', () async {
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async => const <Map<String, Object?>>[];

      final store = RegistryProxyHealthCheckStore(
        runnerFn: runnerFn,
        dependencyProbe: (fn, now) async => const ProxyHealthDependencyProbe(
          postgresOk: false,
          ageOk: true,
          pgvectorOk: true,
        ),
        producers: const <String, ProxyHealthRegistryProducer>{},
        now: () => DateTime.utc(2026, 5, 2, 12),
      );

      final result = await store.check();
      expect(result.ok, isFalse);
      final json = result.toJson(checkedAt: DateTime.utc(2026, 5, 2, 12));
      expect(json['status'], equals('unavailable'));
      expect(json['severity'], equals('red'));
      final dependencies = json['dependencies']! as Map<String, Object?>;
      expect(
        (dependencies['postgres']! as Map<String, Object?>)['status'],
        equals('red'),
      );
    });

    test(
      'reserved keys never appear in metric values when producer absent',
      () async {
        Future<List<Map<String, Object?>>> runnerFn(
          String sql, {
          Map<String, Object?> parameters = const <String, Object?>{},
        }) async => const <Map<String, Object?>>[];

        final store = RegistryProxyHealthCheckStore(
          runnerFn: runnerFn,
          dependencyProbe: (fn, now) async => const ProxyHealthDependencyProbe(
            postgresOk: true,
            ageOk: true,
            pgvectorOk: true,
          ),
          producers: const <String, ProxyHealthRegistryProducer>{},
          now: () => DateTime.utc(2026, 5, 2, 12),
        );

        final result = await store.check();
        final json = result.toJson(checkedAt: DateTime.utc(2026, 5, 2, 12));
        final raw = jsonEncode(json);
        // Tenant identifiers must never appear anywhere in /health.
        expect(raw.contains('operator_id'), isFalse);
        expect(raw.contains('location_id'), isFalse);
      },
    );
  });

  group('main.dart entrypoint contract surface', () {
    // The acceptance criteria pin a specific surface in main.dart: no
    // references to the scaffold-failing health/usage stores, the
    // bootstrap-installed bindings flow into routeRequest, and the
    // diagnostics line emits `gemini_slot_enabled`. Asserting on the
    // file source keeps the wiring honest without binding a real port.
    test('does not reference ScaffoldFailingProxyHealthCheckStore', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();
      expect(
        source.contains('ScaffoldFailingProxyHealthCheckStore'),
        isFalse,
        reason: 'main.dart still wires the scaffold health store',
      );
    });

    test('does not reference ScaffoldFailingUsageCounterStore', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();
      expect(
        source.contains('ScaffoldFailingUsageCounterStore'),
        isFalse,
        reason: 'main.dart still wires the scaffold usage counter store',
      );
    });

    test('routes the production bindings into the runtime', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();
      expect(source, contains('store: productionBindings.usageCounterStore'));
      expect(source, contains('productionBindings.healthCheckStore'));
    });

    test('production health producer concurrency matches the health pool', () {
      final source = File(
        'tool/advisor_proxy/proxy_bootstrap.dart',
      ).readAsStringSync();
      expect(
        source,
        contains(
          'const healthProducerConcurrency = '
          'kPostgresDefaultMaxConnectionsPerPool',
        ),
      );
      expect(
        source,
        contains('producerConcurrency: healthProducerConcurrency'),
      );
      expect(
        source,
        contains('producerBudget: const Duration(milliseconds: 300)'),
      );
      expect(
        source,
        contains('outerProducerBudget: const Duration(milliseconds: 450)'),
      );
      expect(
        source,
        contains('producerRouteBudget: const Duration(seconds: 3)'),
      );
    });

    test('emits gemini_slot_enabled diagnostics line', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();
      expect(
        source,
        contains(
          "'gemini_slot_enabled: \${productionBindings.geminiSlotEnabled}'",
        ),
      );
    });
  });
}

/// Pool that throws on every transaction. The bootstrap construction
/// asserts must not open any transactions; if construction tries to
/// touch the pool, this throws and the test fails loudly.
class _NoOpPostgresPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() async {
    throw StateError('unexpected database access during binding construction');
  }
}
