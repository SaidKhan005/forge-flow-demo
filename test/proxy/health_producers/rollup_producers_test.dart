import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/health_producers/health_producer.dart';
import '../../../tool/advisor_proxy/health_producers/rollup_producers.dart';

import '_test_helpers.dart';

void main() {
  group('rollup_producers — happy paths', () {
    test('rollup_freshness_per_grain returns grain-keyed map', () async {
      final metric = await rollupFreshnessPerGrainProducer(
        contextWith(runnerWith(
          'aggregation_state',
          <Map<String, Object?>>[
            {'grain': 'daily', 'lag': 100},
            {'grain': 'weekly', 'lag': 4000},
          ],
        )),
      );
      expect(metric.status, equals('yellow'));
      final value = metric.value as Map<String, dynamic>;
      expect(value['daily'], equals(100));
      expect(value['weekly'], equals(4000));
      expect(metric.metadata['grain_count'], equals(2));
      expect(metric.metadata['max_lag_seconds'], equals(4000));
    });

    test('rollup_refresh_lag_seconds: yellow at 1h, red at 4h', () async {
      final yellow = await rollupRefreshLagSecondsProducer(
        contextWith(runnerWith(
          'aggregation_state',
          <Map<String, Object?>>[{'lag': 4000}],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await rollupRefreshLagSecondsProducer(
        contextWith(runnerWith(
          'aggregation_state',
          <Map<String, Object?>>[{'lag': 20000}],
        )),
      );
      expect(red.status, equals('red'));
      final missing = await rollupRefreshLagSecondsProducer(
        contextWith(runnerWith(
          'aggregation_state',
          <Map<String, Object?>>[{'lag': null}],
        )),
      );
      expect(missing.status, equals('red'));
      expect(missing.metadata['warning'], equals('no_rollup_refresh_recorded'));
    });

    test('rollup_failed_refreshes_count thresholds 1/5', () async {
      final yellow = await rollupFailedRefreshesCountProducer(
        contextWith(runnerWith('cron.job_run_details', <Map<String, Object?>>[
          {'cnt': 2},
        ])),
      );
      expect(yellow.status, equals('yellow'));
      final red = await rollupFailedRefreshesCountProducer(
        contextWith(runnerWith('cron.job_run_details', <Map<String, Object?>>[
          {'cnt': 6},
        ])),
      );
      expect(red.status, equals('red'));
    });

    test(
      'rollup_concurrent_refresh_status reports running flag',
      () async {
        final running = await rollupConcurrentRefreshStatusProducer(
          contextWith(runnerWith('pg_stat_activity', <Map<String, Object?>>[
            {'cnt': 1},
          ])),
        );
        expect(running.status, equals('green'));
        expect(running.value, isTrue);
        expect(running.metadata['running_count'], equals(1));
      },
    );
  });

  group('rollup_producers — error projections', () {
    test('producer_timeout projection on slow runner', () async {
      final slow = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'aggregation_state': <Map<String, Object?>>[
            {'lag': 100},
          ],
        },
        simulatedLatency: const Duration(milliseconds: 300),
      );
      final metric = await rollupRefreshLagSecondsProducer(
        contextWith(slow, budget: const Duration(milliseconds: 50)),
      );
      expectUnknownProjection(metric, warning: 'producer_timeout');
    });

    test('producer_error projection when runner throws', () async {
      final boom = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'pg_stat_activity': StateError('boom'),
        },
      );
      final metric =
          await rollupConcurrentRefreshStatusProducer(contextWith(boom));
      expectUnknownProjection(metric, warning: 'producer_error');
    });
  });
}
