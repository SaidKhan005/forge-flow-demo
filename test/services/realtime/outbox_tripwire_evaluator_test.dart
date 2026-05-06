// Phase 10a.4 — outbox tripwire evaluator unit tests.
//
// Pins the Q22 thresholds (Decision 33) and the worst-wins severity
// rollup that drives the admin section + the degraded sync badge
// branch. Threshold drift here would silently shift when the bridge
// reports degraded — the contract under test is the boundary
// classification + the multi-metric rollup, not the SQL upstream.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/realtime/outbox_tripwire_evaluator.dart';

void main() {
  group('evaluateOutboxTripwires — green path', () {
    test('all four metrics under threshold → green, zero breaches', () {
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: 30,
          undeliveredCount: 5000,
          publishErrorRate: 0.005,
          notifyQueueUsage: 0.05,
        ),
      );
      expect(result.status, OutboxTripwireStatus.green);
      expect(result.breaches, isEmpty);
    });

    test('all four metrics null → green, zero breaches', () {
      // Every producer projected to unknown (timeout / error). The
      // contract pins this to green so a stuck-at-unknown metric
      // never on its own trips the bridge into degraded state.
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: null,
          undeliveredCount: null,
          publishErrorRate: null,
          notifyQueueUsage: null,
        ),
      );
      expect(result.status, OutboxTripwireStatus.green);
      expect(result.breaches, isEmpty);
    });

    test('boundary values just under threshold stay green', () {
      // bridgeLag fires "> 60" (strict), so 60 stays green.
      // notifyQueueUsage fires "≥ 0.10" so 0.099… stays green.
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: 60,
          undeliveredCount: 10000,
          publishErrorRate: 0.01,
          notifyQueueUsage: 0.0999,
        ),
      );
      expect(result.status, OutboxTripwireStatus.green);
      expect(result.breaches, isEmpty);
    });
  });

  group('evaluateOutboxTripwires — single-metric breaches', () {
    test('bridge_lag > 60s only → yellow with one breach', () {
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: 90,
          undeliveredCount: 0,
          publishErrorRate: 0.0,
          notifyQueueUsage: 0.0,
        ),
      );
      expect(result.status, OutboxTripwireStatus.yellow);
      expect(result.breaches, hasLength(1));
      final breach = result.breaches.single;
      expect(breach.metric, OutboxTripwireMetric.bridgeLagSeconds);
      expect(breach.value, 90);
      expect(breach.severity, OutboxTripwireStatus.yellow);
      expect(breach.thresholds.yellow, 60);
      expect(breach.thresholds.red, 300);
    });

    test('undelivered_count > 100 000 → red with one breach', () {
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: 0,
          undeliveredCount: 150000,
          publishErrorRate: 0.0,
          notifyQueueUsage: 0.0,
        ),
      );
      expect(result.status, OutboxTripwireStatus.red);
      expect(result.breaches, hasLength(1));
      final breach = result.breaches.single;
      expect(breach.metric, OutboxTripwireMetric.undeliveredCount);
      expect(breach.severity, OutboxTripwireStatus.red);
    });

    test('notify_queue_usage at 0.10 → yellow (≥ boundary)', () {
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: 0,
          undeliveredCount: 0,
          publishErrorRate: 0.0,
          notifyQueueUsage: 0.10,
        ),
      );
      expect(result.status, OutboxTripwireStatus.yellow);
      expect(result.breaches.single.metric,
          OutboxTripwireMetric.notifyQueueUsage);
    });

    test('notify_queue_usage at 0.25 → red (≥ boundary)', () {
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: 0,
          undeliveredCount: 0,
          publishErrorRate: 0.0,
          notifyQueueUsage: 0.25,
        ),
      );
      expect(result.status, OutboxTripwireStatus.red);
    });
  });

  group('evaluateOutboxTripwires — worst-wins rollup', () {
    test('two yellows → status yellow, two breaches', () {
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: 90,
          undeliveredCount: 50000,
          publishErrorRate: 0.0,
          notifyQueueUsage: 0.0,
        ),
      );
      expect(result.status, OutboxTripwireStatus.yellow);
      expect(result.breaches, hasLength(2));
    });

    test('one red + three yellow → status red', () {
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: 90,
          undeliveredCount: 50000,
          publishErrorRate: 0.02,
          notifyQueueUsage: 0.30, // red
        ),
      );
      expect(result.status, OutboxTripwireStatus.red);
      expect(result.breaches, hasLength(4));
      final reds = result.breaches
          .where((b) => b.severity == OutboxTripwireStatus.red)
          .toList();
      expect(reds, hasLength(1));
      expect(reds.single.metric, OutboxTripwireMetric.notifyQueueUsage);
    });

    test('all four metrics breach simultaneously', () {
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: 600,
          undeliveredCount: 200000,
          publishErrorRate: 0.10,
          notifyQueueUsage: 0.30,
        ),
      );
      expect(result.status, OutboxTripwireStatus.red);
      expect(result.breaches, hasLength(4));
      final metrics =
          result.breaches.map((b) => b.metric).toSet();
      expect(metrics, equals(OutboxTripwireMetric.values.toSet()));
      // Every breach should be red at these values.
      for (final breach in result.breaches) {
        expect(
          breach.severity,
          OutboxTripwireStatus.red,
          reason: '${breach.metric} expected red at ${breach.value}',
        );
      }
    });
  });

  group('evaluateOutboxTripwires — threshold overrides', () {
    test(
      'env-var override forces a metric into red even with a small value',
      () {
        // Walkthrough step 5 — sync badge degraded state demo.
        // Override bridge-lag thresholds so any positive value is red.
        final result = evaluateOutboxTripwires(
          const OutboxTripwireInputs(
            bridgeLagSeconds: 5,
            undeliveredCount: 0,
            publishErrorRate: 0.0,
            notifyQueueUsage: 0.0,
            thresholdOverrides: <OutboxTripwireMetric,
                OutboxTripwireThresholds>{
              OutboxTripwireMetric.bridgeLagSeconds:
                  OutboxTripwireThresholds(yellow: 1, red: 2),
            },
          ),
        );
        expect(result.status, OutboxTripwireStatus.red);
        expect(result.breaches.single.metric,
            OutboxTripwireMetric.bridgeLagSeconds);
      },
    );

    test('default thresholds apply when no override is given', () {
      final result = evaluateOutboxTripwires(
        const OutboxTripwireInputs(
          bridgeLagSeconds: 5,
          undeliveredCount: 0,
          publishErrorRate: 0.0,
          notifyQueueUsage: 0.0,
        ),
      );
      expect(result.status, OutboxTripwireStatus.green);
    });
  });

  group('Q22 metric metadata', () {
    test('every metric has a stable wire key + plain-English label', () {
      // The wire keys are the contract for the route's JSON response
      // and the admin section's row keys. Drift here breaks the UX
      // surface silently.
      expect(
        outboxTripwireMetricKey(OutboxTripwireMetric.bridgeLagSeconds),
        'event_outbox_bridge_lag_seconds',
      );
      expect(
        outboxTripwireMetricKey(OutboxTripwireMetric.undeliveredCount),
        'event_outbox_undelivered_count',
      );
      expect(
        outboxTripwireMetricKey(OutboxTripwireMetric.publishErrorRate),
        'event_outbox_publish_error_rate',
      );
      expect(
        outboxTripwireMetricKey(OutboxTripwireMetric.notifyQueueUsage),
        'pg_notification_queue_usage',
      );
      for (final metric in OutboxTripwireMetric.values) {
        expect(outboxTripwireMetricLabel(metric), isNotEmpty);
      }
    });

    test('default thresholds match Q22 lock', () {
      expect(
        kOutboxTripwireDefaultThresholds[
            OutboxTripwireMetric.bridgeLagSeconds]!
            .yellow,
        60,
      );
      expect(
        kOutboxTripwireDefaultThresholds[
            OutboxTripwireMetric.bridgeLagSeconds]!
            .red,
        300,
      );
      expect(
        kOutboxTripwireDefaultThresholds[
            OutboxTripwireMetric.undeliveredCount]!
            .yellow,
        10000,
      );
      expect(
        kOutboxTripwireDefaultThresholds[
            OutboxTripwireMetric.undeliveredCount]!
            .red,
        100000,
      );
      expect(
        kOutboxTripwireDefaultThresholds[
            OutboxTripwireMetric.publishErrorRate]!
            .yellow,
        0.01,
      );
      expect(
        kOutboxTripwireDefaultThresholds[
            OutboxTripwireMetric.publishErrorRate]!
            .red,
        0.05,
      );
      expect(
        kOutboxTripwireDefaultThresholds[
            OutboxTripwireMetric.notifyQueueUsage]!
            .yellow,
        0.10,
      );
      expect(
        kOutboxTripwireDefaultThresholds[
            OutboxTripwireMetric.notifyQueueUsage]!
            .red,
        0.25,
      );
    });
  });
}
