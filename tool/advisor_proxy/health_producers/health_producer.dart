// Phase 11A.B42 deep-health producer infrastructure.
//
// A "producer" answers a single signal in the proxy `/health` envelope.
// Each producer:
//   - takes a tightly-scoped read-only [ProxyHealthQueryRunner],
//   - runs inside an explicit budget (default 250ms),
//   - returns a typed [ProxyHealthMetric] honoring the contract's metric
//     envelope (status, value, unit, description, source, owner,
//     observed_at, thresholds, metadata),
//   - projects every error/timeout to a `status: 'unknown', value: null`
//     metric so a single bad signal can never tip the whole `/health`
//     route to 5xx.
//
// Producers never see operator/location identifiers — per the
// `proxy_health_contract.md`, the deep-health envelope must not return
// tenant identifiers. Producer queries use coarse, platform-wide counts
// or count-bands only.

import 'dart:async';

import 'package:forge_and_flow/domain/services/circuit_breaker.dart';
import 'package:forge_and_flow/services/observability/dependency_timeout_exception.dart';

import '../advisor_proxy.dart' show ProxyHealthMetric;
import '../health_operation_budget.dart';

/// Read-only execution surface for producers. The default production
/// implementation wraps a Postgres pool; tests inject a fake.
abstract class ProxyHealthQueryRunner {
  /// Run a parameterized SQL statement. Returns rows as
  /// `Map<columnName, value>`. The runner is responsible for
  /// connection acquisition and release.
  Future<List<Map<String, Object?>>> query(
    String sql, {
    Map<String, Object?> parameters = const <String, Object?>{},
  });
}

/// Constant inputs available to every producer call.
///
/// Block 2 (Lock 7 v1) added [inMemoryBreakerStates]: a side-channel into
/// the per-instance circuit breakers maintained by `routeRequest`. When
/// non-null, breaker producers prefer the in-memory snapshot over the
/// `circuit_breaker_state` DB query (which v1 does not write to). The
/// nullable default preserves every existing producer call site and keeps
/// the DB-backed path live for the day E.2b adds Memorystore-backed
/// cross-instance state.
class ProxyHealthProducerContext {
  ProxyHealthProducerContext({
    required this.runner,
    required this.now,
    this.budget = const Duration(milliseconds: 250),
    this.inMemoryBreakerStates,
    this.sessionRecordIncompleteSnapshot,
  });

  final ProxyHealthQueryRunner runner;
  final DateTime now;
  final Duration budget;
  final Map<String, CircuitState> Function()? inMemoryBreakerStates;

  /// Slice A11.1.b — optional accessor into the per-instance
  /// [SessionRecordIncompleteGauge] held by `routeRequest`. Mirrors
  /// [inMemoryBreakerStates]: when non-null, the session-record producer
  /// reads the live in-memory snapshot; when null the producer renders
  /// `status: 'unknown'` with a `not_wired` warning.
  /// Shape: route -> missing_field -> increment count since process start.
  /// Per-pod identity is conveyed by envelope-level pod labels; this
  /// accessor only exposes the gauge counts.
  final Map<String, Map<String, int>> Function()?
  sessionRecordIncompleteSnapshot;
}

/// Function shape every producer implements.
typedef ProxyHealthProducer =
    Future<ProxyHealthMetric> Function(ProxyHealthProducerContext context);

/// Wraps a producer body with the explicit budget + error projection.
///
/// Producer authors pass a SQL-running closure that returns a fully
/// formed [ProxyHealthMetric]. On timeout or any exception, the wrapper
/// substitutes the [unknownTemplate] metric and adds a `warning` entry
/// describing the failure mode (no exception text — to avoid leaking
/// sensitive substrings).
Future<ProxyHealthMetric> runProducer(
  ProxyHealthProducerContext context,
  ProxyHealthMetric Function() unknownTemplate,
  Future<ProxyHealthMetric> Function() body,
) async {
  try {
    final result = await awaitHealthOperationWithBudget(
      body(),
      budget: context.budget,
    );
    return result;
  } on TimeoutException {
    return _timeoutProjection(context, unknownTemplate);
  } on DependencyTimeoutException {
    return _timeoutProjection(context, unknownTemplate);
  } catch (_) {
    final base = unknownTemplate();
    return ProxyHealthMetric(
      status: 'unknown',
      value: null,
      unit: base.unit,
      description: base.description,
      source: base.source,
      owner: base.owner,
      observedAt: context.now,
      thresholds: base.thresholds,
      metadata: <String, Object?>{
        ...base.metadata,
        'warning': 'producer_error',
      },
    );
  }
}

ProxyHealthMetric _timeoutProjection(
  ProxyHealthProducerContext context,
  ProxyHealthMetric Function() unknownTemplate,
) {
  final base = unknownTemplate();
  return ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: base.unit,
    description: base.description,
    source: base.source,
    owner: base.owner,
    observedAt: context.now,
    thresholds: base.thresholds,
    metadata: <String, Object?>{
      ...base.metadata,
      'warning': 'producer_timeout',
      'budget_ms': context.budget.inMilliseconds,
    },
  );
}

/// Test fake for [ProxyHealthQueryRunner]. Maps SQL prefixes (or full
/// SQL) onto canned row sets or thrown errors. The first matching
/// pattern wins; unmatched SQL throws so producer tests fail loudly
/// rather than silently returning empty rows.
class FakeProxyHealthQueryRunner implements ProxyHealthQueryRunner {
  FakeProxyHealthQueryRunner({
    Map<String, Object> patterns = const <String, Object>{},
    Duration? simulatedLatency,
  }) : _patterns = Map<String, Object>.from(patterns),
       _simulatedLatency = simulatedLatency;

  final Map<String, Object> _patterns;
  final Duration? _simulatedLatency;
  final List<String> calls = <String>[];

  void register(String pattern, Object response) {
    _patterns[pattern] = response;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, {
    Map<String, Object?> parameters = const <String, Object?>{},
  }) async {
    calls.add(sql);
    if (_simulatedLatency != null) {
      await Future<void>.delayed(_simulatedLatency);
    }
    for (final entry in _patterns.entries) {
      if (sql.contains(entry.key)) {
        final response = entry.value;
        if (response is Exception) {
          throw response;
        }
        if (response is Error) {
          throw response;
        }
        if (response is List) {
          return List<Map<String, Object?>>.from(
            response.map((row) => Map<String, Object?>.from(row as Map)),
          );
        }
        throw StateError('FakeProxyHealthQueryRunner: bad response shape');
      }
    }
    throw StateError(
      'FakeProxyHealthQueryRunner: no pattern matched for SQL: '
      '${sql.substring(0, sql.length.clamp(0, 80))}',
    );
  }
}
