import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';

import '../../../tool/advisor_proxy/health_producers/health_producer.dart';
import '../../../tool/advisor_proxy/health_producers/retrieval_producers.dart';

import '_test_helpers.dart';

void main() {
  group('retrieval_producers — circuit breakers', () {
    test('circuit_breaker_anthropic_state: closed → green', () async {
      final metric = await circuitBreakerAnthropicStateProducer(
        contextWith(runnerWith(
          'circuit_breaker_state',
          <Map<String, Object?>>[
            {'state': 'closed', 'opened_at': null},
          ],
        )),
      );
      expect(metric.status, equals('green'));
      expect(metric.value, equals('closed'));
      expect(metric.metadata['tier'], equals(1));
    });

    test('circuit_breaker_anthropic_state: half_open → yellow', () async {
      final metric = await circuitBreakerAnthropicStateProducer(
        contextWith(runnerWith(
          'circuit_breaker_state',
          <Map<String, Object?>>[
            {'state': 'half_open', 'opened_at': null},
          ],
        )),
      );
      expect(metric.status, equals('yellow'));
      expect(metric.value, equals('half_open'));
    });

    test('circuit_breaker_voyage_state: open → red', () async {
      final metric = await circuitBreakerVoyageStateProducer(
        contextWith(runnerWith(
          'circuit_breaker_state',
          <Map<String, Object?>>[
            {'state': 'open', 'opened_at': '2026-05-01T11:50:00Z'},
          ],
        )),
      );
      expect(metric.status, equals('red'));
      expect(metric.value, equals('open'));
    });

    test('in-memory accessor (Block 2 v1) short-circuits the DB query '
        'and reports open → red without touching circuit_breaker_state', () async {
      final runner = FakeProxyHealthQueryRunner();
      final context = ProxyHealthProducerContext(
        runner: runner,
        now: DateTime.utc(2026, 5, 1, 12),
        inMemoryBreakerStates: () => const <String, CircuitState>{
          'anthropic': CircuitState.open,
        },
      );

      final metric = await circuitBreakerAnthropicStateProducer(context);

      expect(metric.status, equals('red'));
      expect(metric.value, equals('open'));
      expect(metric.source, equals('in_memory_breaker'));
      // No DB query was issued — the runner has no patterns registered
      // and would have thrown if consulted.
      expect(runner.calls, isEmpty);
    });

    test('in-memory accessor without a registered breaker reports '
        'closed → green with no_breaker_registered note', () async {
      final runner = FakeProxyHealthQueryRunner();
      final context = ProxyHealthProducerContext(
        runner: runner,
        now: DateTime.utc(2026, 5, 1, 12),
        inMemoryBreakerStates: () => const <String, CircuitState>{},
      );

      final metric = await circuitBreakerAnthropicStateProducer(context);

      expect(metric.status, equals('green'));
      expect(metric.value, equals('closed'));
      expect(metric.metadata['note'], equals('no_breaker_registered'));
      expect(runner.calls, isEmpty);
    });

    test('circuit_breaker_open_count_total counts open + half_open', () async {
      final metric = await circuitBreakerOpenCountTotalProducer(
        contextWith(runnerWith(
          'circuit_breaker_state',
          <Map<String, Object?>>[{'cnt': 2}],
        )),
      );
      expect(metric.status, equals('green'));
      expect(metric.value, equals(2));
      expect(metric.metadata['tier'], equals(3));
    });
  });

  group('retrieval_producers — provider rates and proxy traffic', () {
    test('provider_5xx_rate_anthropic thresholds 0.05/0.25', () async {
      final yellow = await provider5xxRateAnthropicProducer(
        contextWith(runnerWith(
          'provider_request_metrics',
          <Map<String, Object?>>[
            {'e': 6, 'a': 100},
          ],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await provider5xxRateAnthropicProducer(
        contextWith(runnerWith(
          'provider_request_metrics',
          <Map<String, Object?>>[
            {'e': 30, 'a': 100},
          ],
        )),
      );
      expect(red.status, equals('red'));
      final greenZero = await provider5xxRateAnthropicProducer(
        contextWith(runnerWith(
          'provider_request_metrics',
          <Map<String, Object?>>[
            {'e': 0, 'a': 0},
          ],
        )),
      );
      expect(greenZero.status, equals('green'));
    });

    test('proxy_request_p99_latency_ms thresholds 2000/5000', () async {
      final yellow = await proxyRequestP99LatencyMsProducer(
        contextWith(runnerWith(
          'proxy_request_metrics',
          <Map<String, Object?>>[{'p99': 2500}],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await proxyRequestP99LatencyMsProducer(
        contextWith(runnerWith(
          'proxy_request_metrics',
          <Map<String, Object?>>[{'p99': 6000}],
        )),
      );
      expect(red.status, equals('red'));
    });

    test('proxy_request_5xx_rate thresholds 0.01/0.05', () async {
      final yellow = await proxyRequest5xxRateProducer(
        contextWith(runnerWith(
          'proxy_request_metrics',
          <Map<String, Object?>>[
            {'e': 2, 'a': 100},
          ],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await proxyRequest5xxRateProducer(
        contextWith(runnerWith(
          'proxy_request_metrics',
          <Map<String, Object?>>[
            {'e': 10, 'a': 100},
          ],
        )),
      );
      expect(red.status, equals('red'));
    });

    test(
      'fallback_chain_usage_count_anthropic returns informational green',
      () async {
        final metric = await fallbackChainUsageCountAnthropicProducer(
          contextWith(runnerWith(
            'usage_logs',
            <Map<String, Object?>>[{'cnt': 5}],
          )),
        );
        expect(metric.status, equals('green'));
        expect(metric.value, equals(5));
        expect(metric.metadata['provider'], equals('anthropic'));
      },
    );
  });

  group('retrieval_producers — error projections', () {
    test('producer_timeout projection on slow runner', () async {
      final slow = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'circuit_breaker_state': <Map<String, Object?>>[
            {'state': 'closed'},
          ],
        },
        simulatedLatency: const Duration(milliseconds: 300),
      );
      final metric = await circuitBreakerAnthropicStateProducer(
        contextWith(slow, budget: const Duration(milliseconds: 50)),
      );
      expectUnknownProjection(metric, warning: 'producer_timeout');
    });

    test('producer_error projection when runner throws', () async {
      final boom = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'provider_request_metrics': StateError('boom'),
        },
      );
      final metric =
          await provider429RateVoyageProducer(contextWith(boom));
      expectUnknownProjection(metric, warning: 'producer_error');
    });
  });
}
