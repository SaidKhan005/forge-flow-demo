// Phase 11A.B42 — full /health envelope shape, severity tiering,
// tenant-identifier absence, surface tier grouping, feature-flag rollback.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/health_producers/health_producer.dart';
import '../../tool/advisor_proxy/health_producers/producer_registry.dart';

void main() {
  group('proxy_health envelope — registry catalog inventory', () {
    test('producer catalog covers exactly 61 distinct slots', () {
      // 60 catalog entries on master (including the two retention
      // producers 10a.3 added) plus 1 from Phase 10a.4
      // (event_outbox_bridge_lag_seconds). The number on disk pre-slice
      // had drifted past the original 58 pin during 10a.3; this test
      // tracks the live count.
      expect(proxyHealthRegisteredProducerCount(), equals(61));
    });

    test('every catalog key maps to a reserved metric placeholder', () {
      for (final key in proxyHealthProducerCatalog().keys) {
        expect(
          proxyHealthReservedMetrics.containsKey(key),
          isTrue,
          reason:
              'producer key "$key" is missing from proxyHealthReservedMetrics',
        );
      }
    });

    test('every Tier-1 reserved metric has a producer wired', () {
      final tier1Keys = proxyHealthReservedMetrics.entries
          .where((entry) => entry.value.metadata['tier'] == 1)
          .map((entry) => entry.key)
          .toSet();
      final catalogKeys = proxyHealthProducerCatalog().keys.toSet();
      final missing = tier1Keys.difference(catalogKeys);
      expect(
        missing,
        isEmpty,
        reason: 'Tier-1 producers must be wired: $missing',
      );
    });

    test('reserved surfaces only reference reserved metrics', () {
      for (final entry in proxyHealthReservedSurfaces.entries) {
        for (final metric in entry.value.metrics) {
          expect(
            proxyHealthReservedMetrics.containsKey(metric),
            isTrue,
            reason: 'surface ${entry.key} references unknown metric $metric',
          );
        }
      }
    });
  });

  group('proxy_health envelope — JSON shape', () {
    test('reserved metrics + 11 surfaces present with unknown defaults', () {
      const status = ProxyHealthStatus(
        postgresOk: true,
        ageOk: true,
        pgvectorOk: true,
      );
      final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));

      final metrics = json['metrics']! as Map<String, Object?>;
      // Reserved metrics drift slightly ahead of the producer catalog
      // when families add a producer without backfilling the placeholder
      // (10a.3 retention left two such orphans). The catalog-inventory
      // test in this file already gates the producer→reserved direction;
      // this check just pins the rendered length to the reserved map's
      // current size so JSON shape changes are noticed.
      expect(metrics.length, equals(proxyHealthReservedMetrics.length));
      for (final entry in metrics.entries) {
        final m = entry.value! as Map<String, Object?>;
        expect(
          m['status'],
          isIn(<String>['unknown', 'green', 'yellow', 'red']),
          reason: 'metric ${entry.key} has invalid status',
        );
      }

      final surfaces = json['surfaces']! as Map<String, Object?>;
      expect(surfaces.length, equals(11));

      // Tenant identifiers must not appear anywhere in the rendered
      // JSON. (Search the serialized form so a future producer that
      // accidentally populates `metadata.operator_id` is caught.)
      final raw = jsonEncode(json);
      expect(raw.contains('operator_id'), isFalse);
      expect(raw.contains('location_id'), isFalse);
      expect(raw.contains('tenant_id'), isFalse);
    });

    test('envelope_variant renders full_v1 by default', () {
      const status = ProxyHealthStatus(
        postgresOk: true,
        ageOk: true,
        pgvectorOk: true,
      );
      final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
      expect(json['envelope_variant'], equals('full_v1'));
      expect(json['warnings'], isA<List<dynamic>>());
    });

    test('warnings array is populated from metric metadata.warning', () {
      final status = ProxyHealthStatus(
        postgresOk: true,
        ageOk: true,
        pgvectorOk: true,
        metrics: <String, ProxyHealthMetric>{
          'usage_caps_breach_count': ProxyHealthMetric(
            status: 'unknown',
            value: null,
            unit: 'count',
            description: '...',
            owner: 'B33',
            metadata: <String, Object?>{
              'tier': 2,
              'warning': 'producer_timeout',
              'budget_ms': 250,
            },
          ),
        },
      );
      final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
      final warnings = json['warnings']! as List<dynamic>;
      expect(warnings, hasLength(1));
      final entry = warnings.first as Map<String, Object?>;
      expect(entry['metric'], equals('usage_caps_breach_count'));
      expect(entry['warning'], equals('producer_timeout'));
      expect(entry['budget_ms'], equals(250));
    });
  });

  group('proxy_health envelope — severity tiering', () {
    test('Tier-1 yellow → severity red', () {
      final status = ProxyHealthStatus(
        postgresOk: true,
        ageOk: true,
        pgvectorOk: true,
        metrics: <String, ProxyHealthMetric>{
          'audit_chain_lag_seconds': ProxyHealthMetric(
            status: 'yellow',
            value: 1900,
            unit: 'seconds',
            description: '...',
            owner: 'B37/B43',
            metadata: <String, Object?>{'tier': 1},
          ),
        },
      );
      final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
      expect(json['severity'], equals('red'));
      expect(json['status'], equals('degraded'));
    });

    test('Tier-1 red → severity red', () {
      final status = ProxyHealthStatus(
        postgresOk: true,
        ageOk: true,
        pgvectorOk: true,
        metrics: <String, ProxyHealthMetric>{
          'circuit_breaker_anthropic_state': ProxyHealthMetric(
            status: 'red',
            value: 'open',
            unit: 'state',
            description: '...',
            owner: 'B42',
            metadata: <String, Object?>{'tier': 1},
          ),
        },
      );
      final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
      expect(json['severity'], equals('red'));
    });

    test('Tier-2 yellow → severity yellow (no Tier-1 issues)', () {
      final status = ProxyHealthStatus(
        postgresOk: true,
        ageOk: true,
        pgvectorOk: true,
        metrics: <String, ProxyHealthMetric>{
          'graph_edge_count': ProxyHealthMetric(
            status: 'yellow',
            value: 3500000,
            unit: 'count',
            description: '...',
            owner: 'B44',
            metadata: <String, Object?>{'tier': 2},
          ),
        },
      );
      final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
      expect(json['severity'], equals('yellow'));
      expect(json['status'], equals('degraded'));
    });

    test(
      'Tier-3 red does NOT bump severity (still green) but degrades status',
      () {
        final status = ProxyHealthStatus(
          postgresOk: true,
          ageOk: true,
          pgvectorOk: true,
          metrics: <String, ProxyHealthMetric>{
            'prompt_cache_hit_rate': ProxyHealthMetric(
              status: 'red',
              value: 0.05,
              unit: 'ratio',
              description: '...',
              owner: 'B42',
              metadata: <String, Object?>{'tier': 3},
            ),
          },
        );
        final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
        expect(json['severity'], equals('green'));
        expect(json['status'], equals('degraded'));
      },
    );

    test(
      'dependency failure → severity red, status unavailable, surfaces still '
      'render their metrics list',
      () {
        const status = ProxyHealthStatus(
          postgresOk: true,
          ageOk: false,
          pgvectorOk: true,
        );
        final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
        expect(json['severity'], equals('red'));
        expect(json['status'], equals('unavailable'));
        expect(json['age_cypher_match'], equals('failed'));
      },
    );
  });

  group('proxy_health envelope — surface tier rollup', () {
    test('surface status reflects max severity of contained metrics', () {
      final status = ProxyHealthStatus(
        postgresOk: true,
        ageOk: true,
        pgvectorOk: true,
        metrics: <String, ProxyHealthMetric>{
          'graph_edge_count': ProxyHealthMetric(
            status: 'red',
            value: 5000000,
            unit: 'count',
            description: '...',
            owner: 'B44',
            metadata: <String, Object?>{'tier': 2},
          ),
        },
      );
      final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
      final surfaces = json['surfaces']! as Map<String, Object?>;
      final graphSurface = surfaces['graph']! as Map<String, Object?>;
      expect(graphSurface['status'], equals('red'));
    });
  });

  group('proxy_health envelope — feature flag rollback', () {
    test(
      'health_envelope_full_v1=false renders the legacy 11-metric envelope',
      () {
        const status = ProxyHealthStatus(
          postgresOk: true,
          ageOk: true,
          pgvectorOk: true,
          useFullEnvelope: false,
        );
        final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
        expect(json['envelope_variant'], equals('legacy_b42'));
        final metrics = json['metrics']! as Map<String, Object?>;
        expect(metrics.length, equals(11));
        final surfaces = json['surfaces']! as Map<String, Object?>;
        expect(surfaces.length, equals(6));
      },
    );
  });

  group('proxy_health envelope — registry-driven check', () {
    test('RegistryProxyHealthCheckStore runs producers, projects timeouts to '
        'unknown, and renders the reserved metric slots', () async {
      // Fake runner: every producer query gets an empty/clean response.
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async {
        if (sql.contains('proxy_migration_apply_drift')) {
          return <Map<String, Object?>>[
            {'cnt': 0, 'missing': const <String>[]},
          ];
        }
        if (sql.contains('cron.job_run_details') &&
            sql.contains("status = 'succeeded'")) {
          return <Map<String, Object?>>[
            {'last_end': DateTime.utc(2026, 5, 1, 11, 59).toIso8601String()},
          ];
        }
        if (sql.contains('cron.job_run_details')) {
          return <Map<String, Object?>>[
            {'cnt': 0},
          ];
        }
        if (sql.contains('pg_extension')) {
          return <Map<String, Object?>>[
            {'extname': 'age'},
            {'extname': 'vector'},
            {'extname': 'pg_diskann'},
            {'extname': 'pg_partman'},
            {'extname': 'pg_stat_statements'},
            {'extname': 'pgcrypto'},
          ];
        }
        if (sql.contains('audit_chain_anchors') && sql.contains('lag')) {
          return <Map<String, Object?>>[
            {'lag': 60},
          ];
        }
        if (sql.contains('audit_chain_anchors') && sql.contains('age')) {
          return <Map<String, Object?>>[
            {'age': 100},
          ];
        }
        if (sql.contains('firebase_jwks_cache_status')) {
          return <Map<String, Object?>>[
            {'alive': true, 'age_seconds': 60},
          ];
        }
        if (sql.contains('service_principals_signer_status')) {
          return <Map<String, Object?>>[
            {'signer_loaded': true, 'recent_verify_ok': true},
          ];
        }
        if (sql.contains('circuit_breaker_state') && sql.contains('cnt')) {
          return <Map<String, Object?>>[
            {'cnt': 0},
          ];
        }
        if (sql.contains('circuit_breaker_state')) {
          return <Map<String, Object?>>[
            {'state': 'closed', 'opened_at': null},
          ];
        }
        if (sql.contains('graph_health_metrics') &&
            sql.contains('high_degree_node_count')) {
          return <Map<String, Object?>>[
            {'cnt': 0},
          ];
        }
        if (sql.contains('graph_health_metrics') &&
            sql.contains('active_edge_count')) {
          return <Map<String, Object?>>[
            {'cnt': 100},
          ];
        }
        if (sql.contains('graph_health_metrics')) {
          return <Map<String, Object?>>[
            {'cnt': 100},
          ];
        }
        if (sql.contains('graph_benchmark_runs')) {
          return <Map<String, Object?>>[
            {'p50_ms': 50, 'p95_ms': 100, 'p99_ms': 150},
          ];
        }
        if (sql.contains('graph_traversal_metrics')) {
          return <Map<String, Object?>>[
            {'t': 0, 'a': 100, 'failure_count': 0},
          ];
        }
        if (sql.contains('graph_projection_runs')) {
          return <Map<String, Object?>>[
            {'age': 1000},
          ];
        }
        if (sql.contains('graph_growth_projection')) {
          return <Map<String, Object?>>[
            {'projected': 1000},
          ];
        }
        if (sql.contains('vector_index_health')) {
          return <Map<String, Object?>>[
            {'corpus_id': 'a', 'cnt': 100, 'active_count': 100},
          ];
        }
        if (sql.contains('vector_benchmark_runs')) {
          return <Map<String, Object?>>[
            {'p50_ms': 50, 'p99_ms': 100, 'recall_at_10': 0.95},
          ];
        }
        if (sql.contains('vector_query_metrics')) {
          return <Map<String, Object?>>[
            {'t': 0, 'a': 100},
          ];
        }
        if (sql.contains('vector_growth_projection')) {
          return <Map<String, Object?>>[
            {'projected': 100},
          ];
        }
        if (sql.contains('aggregation_state') && sql.contains('grain')) {
          return <Map<String, Object?>>[
            {'grain': 'daily', 'lag': 100},
          ];
        }
        if (sql.contains('aggregation_state')) {
          return <Map<String, Object?>>[
            {'lag': 100},
          ];
        }
        if (sql.contains('pg_stat_activity')) {
          return <Map<String, Object?>>[
            {'cnt': 0},
          ];
        }
        if (sql.contains('event_outbox_publish_metrics')) {
          return <Map<String, Object?>>[
            {'failed': 0, 'attempted': 100},
          ];
        }
        if (sql.contains('event_outbox') && sql.contains('lag')) {
          return <Map<String, Object?>>[
            {'lag': 5},
          ];
        }
        if (sql.contains('event_outbox')) {
          return <Map<String, Object?>>[
            {'cnt': 0},
          ];
        }
        if (sql.contains('pg_notification_queue_usage')) {
          return <Map<String, Object?>>[
            {'usage': 0.05},
          ];
        }
        if (sql.contains('partman.part_config')) {
          return <Map<String, Object?>>[
            {'cnt': 5},
          ];
        }
        if (sql.contains('usage_logs_default')) {
          return <Map<String, Object?>>[
            {'cnt': 0},
          ];
        }
        if (sql.contains('proxy_requests')) {
          return <Map<String, Object?>>[
            {'ok': 1},
          ];
        }
        if (sql.contains('cloud_run_instance_metrics')) {
          return <Map<String, Object?>>[
            {'instance_count': 3},
          ];
        }
        if (sql.contains('provider_request_metrics')) {
          return <Map<String, Object?>>[
            {'e': 0, 'a': 100},
          ];
        }
        if (sql.contains('proxy_request_metrics')) {
          return <Map<String, Object?>>[
            {'e': 0, 'a': 100, 'p99': 100},
          ];
        }
        if (sql.contains('cache_metrics')) {
          return <Map<String, Object?>>[
            {'h': 60, 'a': 100},
          ];
        }
        if (sql.contains('usage_logs') &&
            (sql.contains('cap_reached') || sql.contains('outcome'))) {
          return <Map<String, Object?>>[
            {'cnt': 0},
          ];
        }
        if (sql.contains('usage_logs') && sql.contains('avg_cost')) {
          return <Map<String, Object?>>[
            {'avg_cost': 0.005, 'baseline': 0.005},
          ];
        }
        if (sql.contains('usage_logs')) {
          return <Map<String, Object?>>[
            {'cnt': 0},
          ];
        }
        if (sql.contains('workflow_runs')) {
          return <Map<String, Object?>>[
            {'cnt': 0},
          ];
        }
        return const <Map<String, Object?>>[];
      }

      final store = RegistryProxyHealthCheckStore(
        runnerFn: runnerFn,
        dependencyProbe: (fn, now) async => const ProxyHealthDependencyProbe(
          postgresOk: true,
          ageOk: true,
          pgvectorOk: true,
        ),
        producers: buildProxyHealthRegistryProducers(
          expectedMigrationFilenames: const <String>['202605020000_x.sql'],
        ),
        now: () => DateTime.utc(2026, 5, 1, 12),
      );

      final result = await store.check();
      final json = result.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
      final metrics = json['metrics']! as Map<String, Object?>;
      expect(metrics.length, equals(proxyHealthReservedMetrics.length));
      // Tier-1 azure_extensions_present should be green when full set
      // is installed.
      final ext = metrics['azure_extensions_present']! as Map<String, Object?>;
      expect(ext['status'], equals('green'));
      // Drift threaded an expected list into the registry; the fake
      // returns drift=0 for it → green.
      final drift =
          metrics['migration_apply_drift_count']! as Map<String, Object?>;
      expect(drift['status'], equals('green'));
    });

    test(
      'registry without expected_migration_filenames flags drift unknown',
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
          producers: buildProxyHealthRegistryProducers(),
          now: () => DateTime.utc(2026, 5, 1, 12),
        );

        final result = await store.check();
        final json = result.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
        final metrics = json['metrics']! as Map<String, Object?>;
        final drift =
            metrics['migration_apply_drift_count']! as Map<String, Object?>;
        expect(drift['status'], equals('unknown'));
      },
    );

    test(
      'feature-flag rollback shrinks the registry to the legacy 11',
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
          producers: buildProxyHealthRegistryProducers(),
          featureFlags: const ProxyHealthFeatureFlags(
            healthEnvelopeFullV1: false,
          ),
          now: () => DateTime.utc(2026, 5, 1, 12),
        );

        final result = await store.check();
        final json = result.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
        expect(json['envelope_variant'], equals('legacy_b42'));
        expect((json['metrics']! as Map<String, Object?>).length, equals(11));
      },
    );

    test('dependency probe failure flips response to 503-shape', () async {
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
        producers: <String, ProxyHealthRegistryProducer>{},
        now: () => DateTime.utc(2026, 5, 1, 12),
      );

      final result = await store.check();
      expect(result.ok, isFalse);
      final json = result.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
      expect(json['status'], equals('unavailable'));
      expect(json['severity'], equals('red'));
    });

    test('red Postgres probe skips producer fan-out', () async {
      var producerCalls = 0;
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
        producers: <String, ProxyHealthRegistryProducer>{
          'audit_chain_lag_seconds': (context) async {
            producerCalls += 1;
            return ProxyHealthMetric(
              status: 'green',
              value: 0,
              unit: 'seconds',
              description: 'test',
              owner: 'test',
              observedAt: context.now,
              thresholds: const <String, Object?>{},
            );
          },
        },
        now: () => DateTime.utc(2026, 5, 1, 12),
      );

      final result = await store.check();
      expect(result.ok, isFalse);
      expect(producerCalls, equals(0));
    });

    test('producer fan-out is bounded by configured concurrency', () async {
      var active = 0;
      var maxActive = 0;
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async => const <Map<String, Object?>>[];

      ProxyHealthRegistryProducer producerFor(String unit) {
        return (context) async {
          active += 1;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          active -= 1;
          return ProxyHealthMetric(
            status: 'green',
            value: 1,
            unit: unit,
            description: 'test',
            owner: 'test',
            observedAt: context.now,
            thresholds: const <String, Object?>{},
          );
        };
      }

      final store = RegistryProxyHealthCheckStore(
        runnerFn: runnerFn,
        dependencyProbe: (fn, now) async => const ProxyHealthDependencyProbe(
          postgresOk: true,
          ageOk: true,
          pgvectorOk: true,
        ),
        producers: <String, ProxyHealthRegistryProducer>{
          'audit_chain_lag_seconds': producerFor('seconds'),
          'audit_chain_anchor_age_seconds': producerFor('seconds'),
          'migration_apply_drift_count': producerFor('count'),
          'firebase_jwks_fetch_alive': producerFor('boolean'),
          'service_principal_jwt_alive': producerFor('boolean'),
        },
        producerConcurrency: 2,
        now: () => DateTime.utc(2026, 5, 1, 12),
      );

      final result = await store.check();
      expect(result.ok, isTrue);
      expect(maxActive, lessThanOrEqualTo(2));
    });

    test(
      'timed-out producer settles before worker schedules another',
      () async {
        var firstSettled = false;
        var secondStartedBeforeFirstSettled = false;

        ProxyHealthMetric metricFor(
          String unit,
          ProxyHealthRegistryContext ctx,
        ) {
          return ProxyHealthMetric(
            status: 'green',
            value: 1,
            unit: unit,
            description: 'test',
            owner: 'test',
            observedAt: ctx.now,
            thresholds: const <String, Object?>{},
          );
        }

        final store = RegistryProxyHealthCheckStore(
          runnerFn:
              (
                String sql, {
                Map<String, Object?> parameters = const <String, Object?>{},
              }) async => const <Map<String, Object?>>[],
          dependencyProbe: (fn, now) async => const ProxyHealthDependencyProbe(
            postgresOk: true,
            ageOk: true,
            pgvectorOk: true,
          ),
          producers: <String, ProxyHealthRegistryProducer>{
            'audit_chain_lag_seconds': (context) async {
              await Future<void>.delayed(const Duration(milliseconds: 30));
              firstSettled = true;
              return metricFor('seconds', context);
            },
            'audit_chain_anchor_age_seconds': (context) async {
              secondStartedBeforeFirstSettled = !firstSettled;
              return metricFor('seconds', context);
            },
          },
          producerConcurrency: 1,
          outerProducerBudget: const Duration(milliseconds: 5),
          now: () => DateTime.utc(2026, 5, 1, 12),
        );

        await store.check();

        expect(firstSettled, isTrue);
        expect(secondStartedBeforeFirstSettled, isFalse);
      },
    );

    test(
      'route budget returns timeout warnings for unfinished producer sweep',
      () async {
        ProxyHealthMetric metricFor(
          String unit,
          ProxyHealthRegistryContext ctx,
        ) {
          return ProxyHealthMetric(
            status: 'green',
            value: 1,
            unit: unit,
            description: 'test',
            owner: 'test',
            observedAt: ctx.now,
            thresholds: const <String, Object?>{},
          );
        }

        final store = RegistryProxyHealthCheckStore(
          runnerFn:
              (
                String sql, {
                Map<String, Object?> parameters = const <String, Object?>{},
              }) async => const <Map<String, Object?>>[],
          dependencyProbe: (fn, now) async => const ProxyHealthDependencyProbe(
            postgresOk: true,
            ageOk: true,
            pgvectorOk: true,
          ),
          producers: <String, ProxyHealthRegistryProducer>{
            'audit_chain_lag_seconds': (context) async {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              return metricFor('seconds', context);
            },
            'audit_chain_anchor_age_seconds': (context) async {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              return metricFor('seconds', context);
            },
          },
          producerConcurrency: 1,
          outerProducerBudget: const Duration(seconds: 1),
          producerRouteBudget: const Duration(milliseconds: 5),
          now: () => DateTime.utc(2026, 5, 1, 12),
        );

        final startedAt = DateTime.now();
        final status = await store.check();
        final elapsed = DateTime.now().difference(startedAt);

        expect(elapsed, lessThan(const Duration(milliseconds: 100)));
        final json = status.toJson(checkedAt: DateTime.utc(2026, 5, 1, 12));
        final warnings = (json['warnings'] as List<Object?>)
            .cast<Map<String, Object?>>();
        expect(
          warnings,
          contains(
            allOf(
              containsPair('metric', 'audit_chain_lag_seconds'),
              containsPair('warning', 'registry_route_budget_exceeded'),
              containsPair('budget_ms', 5),
            ),
          ),
        );
      },
    );
  });

  group('defaultProxyHealthDependencyProbe — liveness vs data presence', () {
    test(
      'AGE/pgvector probes are green even with no graph/embedding rows',
      () async {
        // Both probes assert extension presence + a syntactic round-trip;
        // they must not depend on data rows existing.
        Future<List<Map<String, Object?>>> runnerFn(
          String sql, {
          Map<String, Object?> parameters = const <String, Object?>{},
        }) async {
          if (sql.contains('select 1 as ok') && !sql.contains('pg_extension')) {
            return <Map<String, Object?>>[
              {'ok': 1},
            ];
          }
          if (sql.contains("extname = 'age'")) {
            return <Map<String, Object?>>[
              {'ok': 1},
            ];
          }
          if (sql.contains("extname = 'vector'") && sql.contains('::vector')) {
            return <Map<String, Object?>>[
              {'ok': 1},
            ];
          }
          return const <Map<String, Object?>>[];
        }

        final probe = await defaultProxyHealthDependencyProbe(
          runnerFn,
          DateTime.utc(2026, 5, 1, 12),
        );
        expect(probe.postgresOk, isTrue);
        expect(probe.ageOk, isTrue);
        expect(probe.pgvectorOk, isTrue);
      },
    );

    test('AGE probe red only when extension is missing', () async {
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async {
        if (sql.contains('select 1 as ok') && !sql.contains('pg_extension')) {
          return <Map<String, Object?>>[
            {'ok': 1},
          ];
        }
        if (sql.contains("extname = 'age'")) {
          return const <Map<String, Object?>>[];
        }
        if (sql.contains("extname = 'vector'")) {
          return <Map<String, Object?>>[
            {'ok': 1},
          ];
        }
        return const <Map<String, Object?>>[];
      }

      final probe = await defaultProxyHealthDependencyProbe(
        runnerFn,
        DateTime.utc(2026, 5, 1, 12),
      );
      expect(probe.ageOk, isFalse);
      expect(probe.pgvectorOk, isTrue);
      expect(probe.postgresOk, isTrue);
    });
  });

  group('FakeProxyHealthQueryRunner — sanity', () {
    test('throws when no pattern matches', () async {
      final runner = FakeProxyHealthQueryRunner();
      expect(() => runner.query('select 1'), throwsStateError);
    });
  });
}
