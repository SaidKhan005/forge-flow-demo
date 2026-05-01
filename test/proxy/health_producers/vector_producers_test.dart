import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/health_producers/health_producer.dart';
import '../../../tool/advisor_proxy/health_producers/vector_producers.dart';

import '_test_helpers.dart';

void main() {
  group('vector_producers — Decision 31 thresholds', () {
    test(
      'vector_active_count_per_corpus: yellow at 5M, red at 8M (max corpus)',
      () async {
        final yellow = await vectorActiveCountPerCorpusProducer(
          contextWith(runnerWith(
            'vector_index_health',
            <Map<String, Object?>>[
              {'corpus_id': 'a', 'cnt': 5500000},
              {'corpus_id': 'b', 'cnt': 100},
            ],
          )),
        );
        expect(yellow.status, equals('yellow'));
        expect(yellow.value, equals(5500000));
        expect(yellow.metadata['corpus_count'], equals(2));
        final red = await vectorActiveCountPerCorpusProducer(
          contextWith(runnerWith(
            'vector_index_health',
            <Map<String, Object?>>[
              {'corpus_id': 'a', 'cnt': 9000000},
            ],
          )),
        );
        expect(red.status, equals('red'));
      },
    );

    test('vector_query_latency_ms thresholds 200/400', () async {
      final yellow = await vectorQueryLatencyMsProducer(
        contextWith(runnerWith(
          'vector_benchmark_runs',
          <Map<String, Object?>>[{'p50_ms': 250}],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await vectorQueryLatencyMsProducer(
        contextWith(runnerWith(
          'vector_benchmark_runs',
          <Map<String, Object?>>[{'p50_ms': 500}],
        )),
      );
      expect(red.status, equals('red'));
    });

    test('vector_recall: red below 0.70, yellow below 0.85, else green', () async {
      final red = await vectorRecallProducer(
        contextWith(runnerWith(
          'vector_benchmark_runs',
          <Map<String, Object?>>[{'recall_at_10': 0.5}],
        )),
      );
      expect(red.status, equals('red'));
      final yellow = await vectorRecallProducer(
        contextWith(runnerWith(
          'vector_benchmark_runs',
          <Map<String, Object?>>[{'recall_at_10': 0.80}],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final green = await vectorRecallProducer(
        contextWith(runnerWith(
          'vector_benchmark_runs',
          <Map<String, Object?>>[{'recall_at_10': 0.95}],
        )),
      );
      expect(green.status, equals('green'));
    });

    test('vector_query_p99_latency_ms thresholds 600/1200', () async {
      final yellow = await vectorQueryP99LatencyMsProducer(
        contextWith(runnerWith(
          'vector_benchmark_runs',
          <Map<String, Object?>>[{'p99_ms': 700}],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await vectorQueryP99LatencyMsProducer(
        contextWith(runnerWith(
          'vector_benchmark_runs',
          <Map<String, Object?>>[{'p99_ms': 2000}],
        )),
      );
      expect(red.status, equals('red'));
    });

    test('vector_query_timeout_rate thresholds 0.01/0.05', () async {
      final yellow = await vectorQueryTimeoutRateProducer(
        contextWith(runnerWith(
          'vector_query_metrics',
          <Map<String, Object?>>[
            {'t': 2, 'a': 100},
          ],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await vectorQueryTimeoutRateProducer(
        contextWith(runnerWith(
          'vector_query_metrics',
          <Map<String, Object?>>[
            {'t': 10, 'a': 100},
          ],
        )),
      );
      expect(red.status, equals('red'));
    });

    test('vector_growth_projection_90d_count red ≥ 10M', () async {
      final red = await vectorGrowthProjection90dCountProducer(
        contextWith(runnerWith(
          'vector_growth_projection',
          <Map<String, Object?>>[{'projected': 11000000}],
        )),
      );
      expect(red.status, equals('red'));
      final green = await vectorGrowthProjection90dCountProducer(
        contextWith(runnerWith(
          'vector_growth_projection',
          <Map<String, Object?>>[{'projected': 100}],
        )),
      );
      expect(green.status, equals('green'));
    });

    test('vector_index_size_per_corpus emits a corpus-keyed map', () async {
      final metric = await vectorIndexSizePerCorpusProducer(
        contextWith(runnerWith(
          'vector_index_health',
          <Map<String, Object?>>[
            {'corpus_id': 'a', 'cnt': 100},
            {'corpus_id': 'b', 'cnt': 5500000},
          ],
        )),
      );
      expect(metric.status, equals('yellow'));
      expect(metric.value, isA<Map<String, dynamic>>());
      final byCorpus = metric.value as Map<String, dynamic>;
      expect(byCorpus['a'], equals(100));
      expect(byCorpus['b'], equals(5500000));
    });
  });

  group('vector_producers — error projections', () {
    test('producer_timeout projection on slow runner', () async {
      final slow = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'vector_benchmark_runs': <Map<String, Object?>>[
            {'p50_ms': 50},
          ],
        },
        simulatedLatency: const Duration(milliseconds: 300),
      );
      final metric = await vectorQueryLatencyMsProducer(
        contextWith(slow, budget: const Duration(milliseconds: 50)),
      );
      expectUnknownProjection(metric, warning: 'producer_timeout');
    });

    test('producer_error projection when runner throws', () async {
      final boom = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'vector_index_health': StateError('boom'),
        },
      );
      final metric = await vectorIndexSizePerCorpusProducer(contextWith(boom));
      expectUnknownProjection(metric, warning: 'producer_error');
    });
  });
}
