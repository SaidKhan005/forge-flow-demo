// Shared scaffolding for B42 producer family tests.
//
// Each family test exercises three invariants:
//   1. Happy path: the producer returns a typed [ProxyHealthMetric] with
//      the right `status`, `value`, `unit`, `tier`, and `thresholds`.
//   2. Slow path: the producer's runner sleeps past the producer budget
//      → producer projects to `status: 'unknown'` with `warning:
//      'producer_timeout'` in metadata.
//   3. Error path: the runner throws → producer projects to `status:
//      'unknown'` with `warning: 'producer_error'`.

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';
import '../../../tool/advisor_proxy/health_producers/health_producer.dart';

DateTime fixedNow() => DateTime.utc(2026, 5, 1, 12);

ProxyHealthProducerContext contextWith(
  ProxyHealthQueryRunner runner, {
  Duration budget = const Duration(milliseconds: 250),
}) {
  return ProxyHealthProducerContext(
    runner: runner,
    now: fixedNow(),
    budget: budget,
  );
}

/// Asserts that the supplied metric reflects the producer-level error
/// projection (timeout or thrown exception → unknown placeholder).
void expectUnknownProjection(
  ProxyHealthMetric metric, {
  required String warning,
}) {
  expect(metric.status, equals('unknown'));
  expect(metric.value, isNull);
  expect(metric.metadata['warning'], equals(warning));
  expect(
    metric.metadata.containsKey('operator_id') ||
        metric.metadata.containsKey('location_id'),
    isFalse,
    reason: 'metric metadata must never carry tenant identifiers',
  );
}

/// Convenience: build a fake runner that returns one row of canned data.
FakeProxyHealthQueryRunner runnerWith(
  String pattern,
  List<Map<String, Object?>> rows, {
  Duration? simulatedLatency,
}) {
  return FakeProxyHealthQueryRunner(
    patterns: <String, Object>{pattern: rows},
    simulatedLatency: simulatedLatency,
  );
}
