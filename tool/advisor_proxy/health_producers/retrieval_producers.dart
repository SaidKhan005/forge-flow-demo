// Phase 11A.B42 — Retrieval / circuit-breaker / provider health producers.
//
// Lock 7 (Anthropic + Voyage circuit breakers): trip on 3 consecutive
// failures within 60s, error rate > 25%, p99 > 3× baseline, or cost > 2×
// baseline. State exposed via circuit_breaker_*_state.
//
// Block 2 (v1) wires per-instance in-memory breakers via the optional
// `ProxyHealthProducerContext.inMemoryBreakerStates` accessor. When
// present the producer reports the live snapshot; when null it falls
// back to the DB-backed `circuit_breaker_state` query (E.2b path).

import 'package:forge_and_flow/domain/services/circuit_breaker.dart';

import '../advisor_proxy.dart' show ProxyHealthMetric;
import 'health_producer.dart';

const Set<String> _validBreakerStates = <String>{'closed', 'half_open', 'open'};

ProxyHealthMetric _circuitBreakerTemplate(String provider) => ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'state',
  description:
      'Lock 7 circuit breaker state for the $provider provider '
      '(closed/half_open/open). Open state = fallback chain in use.',
  source: 'circuit_breaker_state',
  owner: 'B42',
  metadata: const <String, Object?>{'tier': 1},
);

Future<ProxyHealthMetric> _circuitBreakerStateProducer(
  ProxyHealthProducerContext context,
  String provider,
) {
  return runProducer(context, () => _circuitBreakerTemplate(provider), () async {
    final inMemoryAccessor = context.inMemoryBreakerStates;
    if (inMemoryAccessor != null) {
      final snapshot = inMemoryAccessor();
      final state = snapshot[provider];
      if (state == null) {
        return ProxyHealthMetric(
          status: 'green',
          value: 'closed',
          unit: 'state',
          description: _circuitBreakerTemplate(provider).description,
          source: 'in_memory_breaker',
          owner: 'B42',
          observedAt: context.now,
          metadata: <String, Object?>{
            'tier': 1,
            'provider': provider,
            'note': 'no_breaker_registered',
          },
        );
      }
      final wire = circuitStateToWireString(state);
      return ProxyHealthMetric(
        status: state == CircuitState.closed
            ? 'green'
            : (state == CircuitState.halfOpen ? 'yellow' : 'red'),
        value: wire,
        unit: 'state',
        description: _circuitBreakerTemplate(provider).description,
        source: 'in_memory_breaker',
        owner: 'B42',
        observedAt: context.now,
        metadata: <String, Object?>{'tier': 1, 'provider': provider},
      );
    }
    final rows = await context.runner.query(
      "select state::text as state, opened_at "
      "from circuit_breaker_state where provider = '$provider' limit 1",
    );
    if (rows.isEmpty) {
      return ProxyHealthMetric(
        status: 'green',
        value: 'closed',
        unit: 'state',
        description: _circuitBreakerTemplate(provider).description,
        source: 'circuit_breaker_state',
        owner: 'B42',
        observedAt: context.now,
        metadata: <String, Object?>{
          'tier': 1,
          'provider': provider,
          'note': 'no_breaker_row_yet',
        },
      );
    }
    final state =
        rows.first['state']?.toString().toLowerCase() ?? 'unknown';
    final safeState = _validBreakerStates.contains(state) ? state : 'unknown';
    return ProxyHealthMetric(
      status: safeState == 'closed'
          ? 'green'
          : (safeState == 'half_open' ? 'yellow' : 'red'),
      value: safeState,
      unit: 'state',
      description: _circuitBreakerTemplate(provider).description,
      source: 'circuit_breaker_state',
      owner: 'B42',
      observedAt: context.now,
      metadata: <String, Object?>{'tier': 1, 'provider': provider},
    );
  });
}

Future<ProxyHealthMetric> circuitBreakerAnthropicStateProducer(
  ProxyHealthProducerContext context,
) =>
    _circuitBreakerStateProducer(context, 'anthropic');

Future<ProxyHealthMetric> circuitBreakerVoyageStateProducer(
  ProxyHealthProducerContext context,
) =>
    _circuitBreakerStateProducer(context, 'voyage');

ProxyHealthMetric _circuitBreakerOpenCountTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Number of breakers currently in open or half_open state. Coarse fleet '
      'view across all configured providers.',
  source: 'circuit_breaker_state',
  owner: 'B42',
  metadata: <String, Object?>{'tier': 3},
);

Future<ProxyHealthMetric> circuitBreakerOpenCountTotalProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _circuitBreakerOpenCountTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(count(*), 0)::int as cnt "
      "from circuit_breaker_state where state in ('open', 'half_open')",
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: 'green',
      value: count,
      unit: 'count',
      description: _circuitBreakerOpenCountTemplate().description,
      source: 'circuit_breaker_state',
      owner: 'B42',
      observedAt: context.now,
      metadata: const <String, Object?>{'tier': 3},
    );
  });
}

ProxyHealthMetric _fallbackChainTemplate(String provider) => ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Requests in the last 5 minutes that traversed the $provider fallback '
      'chain (Lock 7). Informational — fallback usage is not red on its own.',
  source: 'usage_logs',
  owner: 'B42',
  metadata: const <String, Object?>{'tier': 3},
);

Future<ProxyHealthMetric> _fallbackChainCountProducer(
  ProxyHealthProducerContext context,
  String provider,
) {
  return runProducer(context, () => _fallbackChainTemplate(provider), () async {
    final rows = await context.runner.query(
      "select coalesce(count(*), 0)::bigint as cnt from usage_logs "
      "where fallback_used is not null and primary_provider = '$provider' "
      "and observed_at > now() - interval '5 minutes'",
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: 'green',
      value: count,
      unit: 'count',
      description: _fallbackChainTemplate(provider).description,
      source: 'usage_logs',
      owner: 'B42',
      observedAt: context.now,
      metadata: <String, Object?>{'tier': 3, 'provider': provider},
    );
  });
}

Future<ProxyHealthMetric> fallbackChainUsageCountAnthropicProducer(
  ProxyHealthProducerContext context,
) =>
    _fallbackChainCountProducer(context, 'anthropic');

Future<ProxyHealthMetric> fallbackChainUsageCountVoyageProducer(
  ProxyHealthProducerContext context,
) =>
    _fallbackChainCountProducer(context, 'voyage');

ProxyHealthMetric _providerErrorRateTemplate(
  String provider,
  String label,
) =>
    ProxyHealthMetric(
      status: 'unknown',
      value: null,
      unit: 'ratio',
      description:
          'Rolling 5-minute $label rate for $provider '
          '($label / total_requests). Yellow at 0.05, red at 0.25 (Lock 7).',
      source: 'usage_logs',
      owner: 'B42',
      thresholds: const <String, Object?>{'yellow': 0.05, 'red': 0.25},
      metadata: const <String, Object?>{'tier': 3},
    );

Future<ProxyHealthMetric> _providerErrorRateProducer(
  ProxyHealthProducerContext context,
  String provider,
  String label,
  String column,
) {
  return runProducer(context, () => _providerErrorRateTemplate(provider, label),
      () async {
    final rows = await context.runner.query(
      "select coalesce(sum($column), 0)::bigint as e, "
      "coalesce(sum(request_count), 0)::bigint as a "
      "from provider_request_metrics "
      "where provider = '$provider' "
      "and window_start > now() - interval '5 minutes'",
    );
    final e = (rows.first['e'] as num?)?.toInt() ?? 0;
    final a = (rows.first['a'] as num?)?.toInt() ?? 0;
    final ratio = a == 0 ? 0.0 : e / a;
    return ProxyHealthMetric(
      status: a == 0
          ? 'green'
          : (ratio >= 0.25 ? 'red' : (ratio >= 0.05 ? 'yellow' : 'green')),
      value: ratio,
      unit: 'ratio',
      description: _providerErrorRateTemplate(provider, label).description,
      source: 'provider_request_metrics',
      owner: 'B42',
      observedAt: context.now,
      thresholds: const <String, Object?>{'yellow': 0.05, 'red': 0.25},
      metadata: <String, Object?>{
        'tier': 3,
        'provider': provider,
        'label': label,
      },
    );
  });
}

Future<ProxyHealthMetric> provider5xxRateAnthropicProducer(
  ProxyHealthProducerContext context,
) =>
    _providerErrorRateProducer(context, 'anthropic', '5xx', 'count_5xx');

Future<ProxyHealthMetric> provider5xxRateVoyageProducer(
  ProxyHealthProducerContext context,
) =>
    _providerErrorRateProducer(context, 'voyage', '5xx', 'count_5xx');

Future<ProxyHealthMetric> provider429RateAnthropicProducer(
  ProxyHealthProducerContext context,
) =>
    _providerErrorRateProducer(context, 'anthropic', '429', 'count_429');

Future<ProxyHealthMetric> provider429RateVoyageProducer(
  ProxyHealthProducerContext context,
) =>
    _providerErrorRateProducer(context, 'voyage', '429', 'count_429');

ProxyHealthMetric _proxyP99LatencyTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'milliseconds',
  description:
      'p99 proxy request latency over the last 5 minutes (across all '
      'authenticated routes). Yellow at 2,000 ms, red at 5,000 ms.',
  source: 'proxy_request_metrics',
  owner: 'B42',
  thresholds: <String, Object?>{'yellow': 2000, 'red': 5000},
  metadata: <String, Object?>{'tier': 3},
);

Future<ProxyHealthMetric> proxyRequestP99LatencyMsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _proxyP99LatencyTemplate, () async {
    final rows = await context.runner.query(
      "select max(p99_ms)::int as p99 from proxy_request_metrics "
      "where window_start > now() - interval '5 minutes'",
    );
    final p99 = rows.isEmpty ? null : (rows.first['p99'] as num?)?.toInt();
    return ProxyHealthMetric(
      status: p99 == null
          ? 'unknown'
          : (p99 >= 5000 ? 'red' : (p99 >= 2000 ? 'yellow' : 'green')),
      value: p99,
      unit: 'milliseconds',
      description: _proxyP99LatencyTemplate().description,
      source: 'proxy_request_metrics',
      owner: 'B42',
      observedAt: context.now,
      thresholds: _proxyP99LatencyTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 3},
    );
  });
}

ProxyHealthMetric _proxy5xxRateTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'ratio',
  description:
      'Proxy 5xx response rate over the last 5 minutes. Yellow at 0.01, '
      'red at 0.05.',
  source: 'proxy_request_metrics',
  owner: 'B42',
  thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
  metadata: <String, Object?>{'tier': 3},
);

Future<ProxyHealthMetric> proxyRequest5xxRateProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _proxy5xxRateTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(sum(count_5xx), 0)::bigint as e, "
      "coalesce(sum(request_count), 0)::bigint as a "
      "from proxy_request_metrics "
      "where window_start > now() - interval '5 minutes'",
    );
    final e = (rows.first['e'] as num?)?.toInt() ?? 0;
    final a = (rows.first['a'] as num?)?.toInt() ?? 0;
    final ratio = a == 0 ? 0.0 : e / a;
    return ProxyHealthMetric(
      status: a == 0
          ? 'green'
          : (ratio >= 0.05 ? 'red' : (ratio >= 0.01 ? 'yellow' : 'green')),
      value: ratio,
      unit: 'ratio',
      description: _proxy5xxRateTemplate().description,
      source: 'proxy_request_metrics',
      owner: 'B42',
      observedAt: context.now,
      thresholds: _proxy5xxRateTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 3},
    );
  });
}

final Map<String, ProxyHealthProducer> retrievalProducers =
    <String, ProxyHealthProducer>{
      'circuit_breaker_anthropic_state': circuitBreakerAnthropicStateProducer,
      'circuit_breaker_voyage_state': circuitBreakerVoyageStateProducer,
      'circuit_breaker_open_count_total':
          circuitBreakerOpenCountTotalProducer,
      'fallback_chain_usage_count_anthropic':
          fallbackChainUsageCountAnthropicProducer,
      'fallback_chain_usage_count_voyage':
          fallbackChainUsageCountVoyageProducer,
      'provider_5xx_rate_anthropic': provider5xxRateAnthropicProducer,
      'provider_5xx_rate_voyage': provider5xxRateVoyageProducer,
      'provider_429_rate_anthropic': provider429RateAnthropicProducer,
      'provider_429_rate_voyage': provider429RateVoyageProducer,
      'proxy_request_p99_latency_ms': proxyRequestP99LatencyMsProducer,
      'proxy_request_5xx_rate': proxyRequest5xxRateProducer,
    };
