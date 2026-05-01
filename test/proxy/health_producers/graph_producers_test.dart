import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/health_producers/graph_producers.dart';
import '../../../tool/advisor_proxy/health_producers/health_producer.dart';

import '_test_helpers.dart';

void main() {
  group('graph_producers — Decision 30 thresholds', () {
    test('graph_edge_count: yellow 3M, red 4M', () async {
      final yellow = await graphEdgeCountProducer(
        contextWith(runnerWith(
          'graph_health_metrics',
          <Map<String, Object?>>[{'cnt': 3500000}],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await graphEdgeCountProducer(
        contextWith(runnerWith(
          'graph_health_metrics',
          <Map<String, Object?>>[{'cnt': 4500000}],
        )),
      );
      expect(red.status, equals('red'));
      final green = await graphEdgeCountProducer(
        contextWith(runnerWith(
          'graph_health_metrics',
          <Map<String, Object?>>[{'cnt': 100}],
        )),
      );
      expect(green.status, equals('green'));
    });

    test('graph_node_count green when populated', () async {
      final metric = await graphNodeCountProducer(
        contextWith(runnerWith(
          'graph_health_metrics',
          <Map<String, Object?>>[{'cnt': 12345}],
        )),
      );
      expect(metric.status, equals('green'));
      expect(metric.value, equals(12345));
      expect(metric.metadata['tier'], equals(2));
    });

    test(
      'graph_traversal_latency_ms p95 thresholds 250/500 (Lock 3 gate)',
      () async {
        final green = await graphTraversalLatencyMsProducer(
          contextWith(runnerWith(
            'graph_benchmark_runs',
            <Map<String, Object?>>[{'p95_ms': 100}],
          )),
        );
        expect(green.status, equals('green'));
        expect(green.metadata['percentile'], equals('p95'));
        final yellow = await graphTraversalLatencyMsProducer(
          contextWith(runnerWith(
            'graph_benchmark_runs',
            <Map<String, Object?>>[{'p95_ms': 300}],
          )),
        );
        expect(yellow.status, equals('yellow'));
        final red = await graphTraversalLatencyMsProducer(
          contextWith(runnerWith(
            'graph_benchmark_runs',
            <Map<String, Object?>>[{'p95_ms': 700}],
          )),
        );
        expect(red.status, equals('red'));
      },
    );

    test('graph_traversal_p99_latency_ms thresholds 750/1500', () async {
      final yellow = await graphTraversalP99LatencyMsProducer(
        contextWith(runnerWith(
          'graph_benchmark_runs',
          <Map<String, Object?>>[{'p99_ms': 800}],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await graphTraversalP99LatencyMsProducer(
        contextWith(runnerWith(
          'graph_benchmark_runs',
          <Map<String, Object?>>[{'p99_ms': 2000}],
        )),
      );
      expect(red.status, equals('red'));
    });

    test('graph_traversal_timeout_rate thresholds 0.01/0.05', () async {
      final yellow = await graphTraversalTimeoutRateProducer(
        contextWith(runnerWith(
          'graph_traversal_metrics',
          <Map<String, Object?>>[
            {'t': 2, 'a': 100},
          ],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await graphTraversalTimeoutRateProducer(
        contextWith(runnerWith(
          'graph_traversal_metrics',
          <Map<String, Object?>>[
            {'t': 10, 'a': 100},
          ],
        )),
      );
      expect(red.status, equals('red'));
      final emptyGreen = await graphTraversalTimeoutRateProducer(
        contextWith(runnerWith(
          'graph_traversal_metrics',
          <Map<String, Object?>>[
            {'t': 0, 'a': 0},
          ],
        )),
      );
      expect(emptyGreen.status, equals('green'));
    });

    test('graph_high_degree_node_count thresholds 100/1000', () async {
      final yellow = await graphHighDegreeNodeCountProducer(
        contextWith(runnerWith(
          'graph_health_metrics',
          <Map<String, Object?>>[{'cnt': 250}],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await graphHighDegreeNodeCountProducer(
        contextWith(runnerWith(
          'graph_health_metrics',
          <Map<String, Object?>>[{'cnt': 5000}],
        )),
      );
      expect(red.status, equals('red'));
    });

    test('graph_growth_projection_90d_edges red ≥ 5M', () async {
      final red = await graphGrowthProjection90dEdgesProducer(
        contextWith(runnerWith(
          'graph_growth_projection',
          <Map<String, Object?>>[{'projected': 6000000}],
        )),
      );
      expect(red.status, equals('red'));
      final green = await graphGrowthProjection90dEdgesProducer(
        contextWith(runnerWith(
          'graph_growth_projection',
          <Map<String, Object?>>[{'projected': 100}],
        )),
      );
      expect(green.status, equals('green'));
    });

    test(
      'graph_projection_age_seconds thresholds: 24h yellow / 7d red',
      () async {
        final yellow = await graphProjectionAgeSecondsProducer(
          contextWith(runnerWith(
            'graph_projection_runs',
            <Map<String, Object?>>[{'age': 86500}],
          )),
        );
        expect(yellow.status, equals('yellow'));
        final red = await graphProjectionAgeSecondsProducer(
          contextWith(runnerWith(
            'graph_projection_runs',
            <Map<String, Object?>>[{'age': 700000}],
          )),
        );
        expect(red.status, equals('red'));
      },
    );
  });

  group('graph_producers — error projections', () {
    test('producer_timeout projection on slow benchmark runner', () async {
      final slow = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'graph_benchmark_runs': <Map<String, Object?>>[
            {'p95_ms': 50},
          ],
        },
        simulatedLatency: const Duration(milliseconds: 300),
      );
      final metric = await graphTraversalLatencyMsProducer(
        contextWith(slow, budget: const Duration(milliseconds: 50)),
      );
      expectUnknownProjection(metric, warning: 'producer_timeout');
    });

    test('producer_error projection when runner throws', () async {
      final boom = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'graph_health_metrics': StateError('boom'),
        },
      );
      final metric = await graphEdgeCountProducer(contextWith(boom));
      expectUnknownProjection(metric, warning: 'producer_error');
    });
  });
}
