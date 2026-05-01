import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/health_producers/cost_producers.dart';
import '../../../tool/advisor_proxy/health_producers/health_producer.dart';

import '_test_helpers.dart';

/// Wraps a [ProxyHealthQueryRunner] and forwards its calls through to
/// the underlying runner while exposing the most recent SQL for
/// assertion.
class _SpyRunner implements ProxyHealthQueryRunner {
  _SpyRunner(this._inner, this._onSql);

  final ProxyHealthQueryRunner _inner;
  final void Function(String sql) _onSql;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, {
    Map<String, Object?> parameters = const <String, Object?>{},
  }) {
    _onSql(sql);
    return _inner.query(sql, parameters: parameters);
  }
}

void main() {
  group('cost_producers — happy paths', () {
    test('usage_caps_breach_count thresholds 1/100', () async {
      final yellow = await usageCapsBreachCountProducer(
        contextWith(runnerWith('usage_logs', <Map<String, Object?>>[
          {'cnt': 5},
        ])),
      );
      expect(yellow.status, equals('yellow'));
      final red = await usageCapsBreachCountProducer(
        contextWith(runnerWith('usage_logs', <Map<String, Object?>>[
          {'cnt': 250},
        ])),
      );
      expect(red.status, equals('red'));
      expect(red.metadata['tier'], equals(2));
    });

    test(
      'usage_caps_breach_count SQL sums cost_usd over the 7-column cap '
      'identity, not per-row compare',
      () async {
        // Capture the SQL the producer emits and assert it groups+sums
        // before comparing to monthly_cap_usd. This is the regression
        // gate for "two $60 rows against a $100 cap" — a per-row
        // comparison would mis-classify that as green.
        String? capturedSql;
        final runner = FakeProxyHealthQueryRunner(
          patterns: <String, Object>{
            'usage_logs': <Map<String, Object?>>[
              {'cnt': 1},
            ],
          },
        );
        final wrapped = _SpyRunner(runner, (sql) => capturedSql = sql);
        await usageCapsBreachCountProducer(contextWith(wrapped));

        expect(capturedSql, isNotNull);
        final sql = capturedSql!.toLowerCase();

        // The cap-status pattern: month-to-date SUM, not per-row cost.
        expect(sql, contains('sum(cost_usd)'));
        expect(sql, contains("date_trunc('month', now())"));
        // Group by the full 7-column cap identity.
        expect(sql, contains('group by'));
        expect(sql, contains('billing_owner_org_unit_id'));
        expect(sql, contains('scoped_org_unit_id'));
        expect(sql, contains('staff_id'));
        expect(sql, contains('workflow_id'));
        // Join condition compares SUM to monthly_cap_usd, not per-row
        // cost.
        expect(sql, contains('monthly_used_usd >= c.monthly_cap_usd'));
        // NULL staff_id/workflow_id collation matches the existing
        // cap_status_select.
        expect(sql, contains('is not distinct from'));
      },
    );

    test('prompt_cache_hit_rate: ratio bands', () async {
      final red = await promptCacheHitRateProducer(
        contextWith(runnerWith('cache_metrics', <Map<String, Object?>>[
          {'h': 5, 'a': 100},
        ])),
      );
      expect(red.status, equals('red'));
      final yellow = await promptCacheHitRateProducer(
        contextWith(runnerWith('cache_metrics', <Map<String, Object?>>[
          {'h': 20, 'a': 100},
        ])),
      );
      expect(yellow.status, equals('yellow'));
      final green = await promptCacheHitRateProducer(
        contextWith(runnerWith('cache_metrics', <Map<String, Object?>>[
          {'h': 50, 'a': 100},
        ])),
      );
      expect(green.status, equals('green'));
      final unknown = await promptCacheHitRateProducer(
        contextWith(runnerWith('cache_metrics', <Map<String, Object?>>[
          {'h': 0, 'a': 0},
        ])),
      );
      expect(unknown.status, equals('unknown'));
    });

    test(
      'cost_per_query_class_haiku: absolute USD/request thresholds 0.005/0.020',
      () async {
        // 100 requests, $0.40 total → $0.004 per request → green.
        final green = await costPerQueryClassHaikuProducer(
          contextWith(runnerWith('usage_logs', <Map<String, Object?>>[
            {'total_cost': 0.40, 'total_requests': 100},
          ])),
        );
        expect(green.status, equals('green'));
        expect((green.value as double), closeTo(0.004, 1e-9));
        expect(green.metadata['requests'], equals(100));
        // 100 requests, $1.00 total → $0.010 → yellow.
        final yellow = await costPerQueryClassHaikuProducer(
          contextWith(runnerWith('usage_logs', <Map<String, Object?>>[
            {'total_cost': 1.00, 'total_requests': 100},
          ])),
        );
        expect(yellow.status, equals('yellow'));
        // 100 requests, $3.00 total → $0.030 → red.
        final red = await costPerQueryClassHaikuProducer(
          contextWith(runnerWith('usage_logs', <Map<String, Object?>>[
            {'total_cost': 3.00, 'total_requests': 100},
          ])),
        );
        expect(red.status, equals('red'));
        // Zero requests in window → green with value=0.
        final greenZero = await costPerQueryClassHaikuProducer(
          contextWith(runnerWith('usage_logs', <Map<String, Object?>>[
            {'total_cost': 0, 'total_requests': 0},
          ])),
        );
        expect(greenZero.status, equals('green'));
        expect(greenZero.value, equals(0.0));
        expect(greenZero.metadata['requests'], equals(0));
      },
    );

    test('batch_api_pending_count thresholds 100/1000', () async {
      final yellow = await batchApiPendingCountProducer(
        contextWith(runnerWith('workflow_runs', <Map<String, Object?>>[
          {'cnt': 200},
        ])),
      );
      expect(yellow.status, equals('yellow'));
      final red = await batchApiPendingCountProducer(
        contextWith(runnerWith('workflow_runs', <Map<String, Object?>>[
          {'cnt': 1500},
        ])),
      );
      expect(red.status, equals('red'));
    });
  });

  group('cost_producers — error projections', () {
    test('producer_timeout projection on slow runner', () async {
      final slow = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'usage_logs': <Map<String, Object?>>[
            {'cnt': 0},
          ],
        },
        simulatedLatency: const Duration(milliseconds: 300),
      );
      final metric = await usageCapsBreachCountProducer(
        contextWith(slow, budget: const Duration(milliseconds: 50)),
      );
      expectUnknownProjection(metric, warning: 'producer_timeout');
    });

    test('producer_error projection when runner throws', () async {
      final boom = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'cache_metrics': StateError('boom'),
        },
      );
      final metric = await responseCacheHitRateProducer(contextWith(boom));
      expectUnknownProjection(metric, warning: 'producer_error');
    });
  });
}
