import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/health_producers/health_producer.dart';
import '../../../tool/advisor_proxy/health_producers/outbox_producers.dart';

import '_test_helpers.dart';

void main() {
  group('outbox_producers — Decision 33 thresholds', () {
    test('event_outbox_undelivered_count: yellow at 10k, red at 100k', () async {
      final yellow = await eventOutboxUndeliveredCountProducer(
        contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
          {'cnt': 10001},
        ])),
      );
      expect(yellow.status, equals('yellow'));
      final red = await eventOutboxUndeliveredCountProducer(
        contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
          {'cnt': 250000},
        ])),
      );
      expect(red.status, equals('red'));
      final green = await eventOutboxUndeliveredCountProducer(
        contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
          {'cnt': 5},
        ])),
      );
      expect(green.status, equals('green'));
    });

    test('event_outbox_lag_seconds: yellow at 60s, red at 300s', () async {
      final yellow = await eventOutboxLagSecondsProducer(
        contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
          {'lag': 90},
        ])),
      );
      expect(yellow.status, equals('yellow'));
      final red = await eventOutboxLagSecondsProducer(
        contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
          {'lag': 600},
        ])),
      );
      expect(red.status, equals('red'));
      final greenEmpty = await eventOutboxLagSecondsProducer(
        contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
          {'lag': null},
        ])),
      );
      expect(greenEmpty.status, equals('green'));
      expect(greenEmpty.value, equals(0));
    });

    test(
      'event_outbox_publish_error_rate: yellow at 0.01, red at 0.05',
      () async {
        final yellow = await eventOutboxPublishErrorRateProducer(
          contextWith(runnerWith(
            'event_outbox_publish_metrics',
            <Map<String, Object?>>[
              {'failed': 2, 'attempted': 100},
            ],
          )),
        );
        expect(yellow.status, equals('yellow'));
        final red = await eventOutboxPublishErrorRateProducer(
          contextWith(runnerWith(
            'event_outbox_publish_metrics',
            <Map<String, Object?>>[
              {'failed': 25, 'attempted': 100},
            ],
          )),
        );
        expect(red.status, equals('red'));
        final greenZero = await eventOutboxPublishErrorRateProducer(
          contextWith(runnerWith(
            'event_outbox_publish_metrics',
            <Map<String, Object?>>[
              {'failed': 0, 'attempted': 0},
            ],
          )),
        );
        expect(greenZero.status, equals('green'));
        expect(greenZero.metadata['attempted'], equals(0));
      },
    );

    test('notify_queue_usage_ratio: yellow at 0.10, red at 0.25', () async {
      final yellow = await notifyQueueUsageRatioProducer(
        contextWith(runnerWith(
          'pg_notification_queue_usage',
          <Map<String, Object?>>[
            {'usage': 0.15},
          ],
        )),
      );
      expect(yellow.status, equals('yellow'));
      final red = await notifyQueueUsageRatioProducer(
        contextWith(runnerWith(
          'pg_notification_queue_usage',
          <Map<String, Object?>>[
            {'usage': 0.30},
          ],
        )),
      );
      expect(red.status, equals('red'));
    });

    test(
      'event_outbox_bridge_lag_seconds: yellow at 60s, red at 300s, NULL→0',
      () async {
        // Phase 10a.4 — bridge-side post-pickup lag. Same Q22 thresholds
        // as event_outbox_lag_seconds; SQL semantic differs.
        final yellow = await eventOutboxBridgeLagSecondsProducer(
          contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
            {'lag': 90},
          ])),
        );
        expect(yellow.status, equals('yellow'));
        expect(yellow.value, equals(90.0));
        final red = await eventOutboxBridgeLagSecondsProducer(
          contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
            {'lag': 600},
          ])),
        );
        expect(red.status, equals('red'));
        // NULL-safe path: zero rows OR row with NULL lag both project
        // to lag = 0 (green) — the bridge has nothing pending to lag on.
        final greenNullRow = await eventOutboxBridgeLagSecondsProducer(
          contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
            {'lag': null},
          ])),
        );
        expect(greenNullRow.status, equals('green'));
        expect(greenNullRow.value, equals(0.0));
      },
    );
  });

  group('outbox_producers — error projections', () {
    test('producer_timeout projection on slow runner', () async {
      final slow = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'event_outbox': <Map<String, Object?>>[
            {'cnt': 0},
          ],
        },
        simulatedLatency: const Duration(milliseconds: 300),
      );
      final metric = await eventOutboxUndeliveredCountProducer(
        contextWith(slow, budget: const Duration(milliseconds: 50)),
      );
      expectUnknownProjection(metric, warning: 'producer_timeout');
    });

    test('producer_error projection when runner throws', () async {
      final boom = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'pg_notification_queue_usage': StateError('boom'),
        },
      );
      final metric = await notifyQueueUsageRatioProducer(contextWith(boom));
      expectUnknownProjection(metric, warning: 'producer_error');
    });
  });
}
