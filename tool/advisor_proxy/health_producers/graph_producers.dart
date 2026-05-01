// Phase 11A.B42 — AGE / canonical-graph health producers.
//
// Decision 30 thresholds:
//   - graph_edge_count: yellow 3,000,000 / red 4,000,000
//   - graph_growth_projection_90d_edges: red >= 5,000,000

import '../advisor_proxy.dart' show ProxyHealthMetric;
import 'health_producer.dart';

ProxyHealthMetric _graphNodeCountTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Active vertex count from public.graph_health_metrics(). Soft-deleted '
      'and archived nodes are excluded.',
  source: 'public.graph_health_metrics()',
  owner: 'B44',
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> graphNodeCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _graphNodeCountTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(active_vertex_count, 0)::bigint as cnt '
      'from public.graph_health_metrics()',
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: 'green',
      value: count,
      unit: 'count',
      description: _graphNodeCountTemplate().description,
      source: 'public.graph_health_metrics()',
      owner: 'B44',
      observedAt: context.now,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _graphEdgeCountTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Active edge count from public.graph_health_metrics(). Decision 30 '
      'fires yellow at 3M and red at 4M to trigger projection rollover.',
  source: 'public.graph_health_metrics()',
  owner: 'B44',
  thresholds: <String, Object?>{'yellow': 3000000, 'red': 4000000},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> graphEdgeCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _graphEdgeCountTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(active_edge_count, 0)::bigint as cnt '
      'from public.graph_health_metrics()',
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 4000000
          ? 'red'
          : (count >= 3000000 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _graphEdgeCountTemplate().description,
      source: 'public.graph_health_metrics()',
      owner: 'B44',
      observedAt: context.now,
      thresholds: _graphEdgeCountTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _graphTraversalLatencyTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'milliseconds',
  description:
      'p95 graph traversal latency from the most recent benchmark. Lock 3 '
      'gate: isolated p95 ≤ 500ms (yellow at 250ms, red at 500ms).',
  source: 'graph_benchmark_runs',
  owner: 'B44',
  thresholds: <String, Object?>{'yellow': 250, 'red': 500},
  metadata: <String, Object?>{'tier': 2, 'percentile': 'p95'},
);

Future<ProxyHealthMetric> graphTraversalLatencyMsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _graphTraversalLatencyTemplate, () async {
    final rows = await context.runner.query(
      'select p95_ms from graph_benchmark_runs '
      'order by observed_at desc limit 1',
    );
    if (rows.isEmpty) {
      return ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'milliseconds',
        description: _graphTraversalLatencyTemplate().description,
        source: 'graph_benchmark_runs',
        owner: 'B44',
        observedAt: context.now,
        thresholds: _graphTraversalLatencyTemplate().thresholds,
        metadata: const <String, Object?>{
          'tier': 2,
          'percentile': 'p95',
          'warning': 'no_benchmark_recorded',
        },
      );
    }
    final p95 = (rows.first['p95_ms'] as num?)?.toInt();
    return ProxyHealthMetric(
      status: p95 == null
          ? 'unknown'
          : (p95 >= 500 ? 'red' : (p95 >= 250 ? 'yellow' : 'green')),
      value: p95,
      unit: 'milliseconds',
      description: _graphTraversalLatencyTemplate().description,
      source: 'graph_benchmark_runs',
      owner: 'B44',
      observedAt: context.now,
      thresholds: _graphTraversalLatencyTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2, 'percentile': 'p95'},
    );
  });
}

ProxyHealthMetric _graphTraversalP99Template() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'milliseconds',
  description:
      'p99 graph traversal latency from the most recent benchmark. Lock 3 '
      'gate: 10× concurrent p95 ≤ 1000ms.',
  source: 'graph_benchmark_runs',
  owner: 'B44',
  thresholds: <String, Object?>{'yellow': 750, 'red': 1500},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> graphTraversalP99LatencyMsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _graphTraversalP99Template, () async {
    final rows = await context.runner.query(
      'select p99_ms from graph_benchmark_runs '
      'order by observed_at desc limit 1',
    );
    final p99 = rows.isEmpty ? null : (rows.first['p99_ms'] as num?)?.toInt();
    return ProxyHealthMetric(
      status: p99 == null
          ? 'unknown'
          : (p99 >= 1500 ? 'red' : (p99 >= 750 ? 'yellow' : 'green')),
      value: p99,
      unit: 'milliseconds',
      description: _graphTraversalP99Template().description,
      source: 'graph_benchmark_runs',
      owner: 'B44',
      observedAt: context.now,
      thresholds: _graphTraversalP99Template().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _graphTraversalTimeoutRateTemplate() =>
    const ProxyHealthMetric(
      status: 'unknown',
      value: null,
      unit: 'ratio',
      description:
          'Rolling 5-minute graph traversal timeout rate '
          '(timeout_count / traversal_count).',
      source: 'graph_traversal_metrics',
      owner: 'B44',
      thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
      metadata: <String, Object?>{'tier': 2},
    );

Future<ProxyHealthMetric> graphTraversalTimeoutRateProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _graphTraversalTimeoutRateTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(sum(timeout_count), 0)::bigint as t, "
      "coalesce(sum(traversal_count), 0)::bigint as a "
      "from graph_traversal_metrics "
      "where window_start > now() - interval '5 minutes'",
    );
    final t = (rows.first['t'] as num?)?.toInt() ?? 0;
    final a = (rows.first['a'] as num?)?.toInt() ?? 0;
    final ratio = a == 0 ? 0.0 : t / a;
    return ProxyHealthMetric(
      status: a == 0
          ? 'green'
          : (ratio >= 0.05 ? 'red' : (ratio >= 0.01 ? 'yellow' : 'green')),
      value: ratio,
      unit: 'ratio',
      description: _graphTraversalTimeoutRateTemplate().description,
      source: 'graph_traversal_metrics',
      owner: 'B44',
      observedAt: context.now,
      thresholds: _graphTraversalTimeoutRateTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _graphHighDegreeNodeTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Vertices with degree above the high-degree band (>1,000 edges). '
      'Decision 30 surfaces these as projection-tuning hints.',
  source: 'public.graph_health_metrics()',
  owner: 'B44',
  thresholds: <String, Object?>{'yellow': 100, 'red': 1000},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> graphHighDegreeNodeCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _graphHighDegreeNodeTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(high_degree_node_count, 0)::bigint as cnt '
      'from public.graph_health_metrics()',
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 1000 ? 'red' : (count >= 100 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _graphHighDegreeNodeTemplate().description,
      source: 'public.graph_health_metrics()',
      owner: 'B44',
      observedAt: context.now,
      thresholds: _graphHighDegreeNodeTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _graphFailedTraversalsTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Graph traversal failure count over the last 5 minutes. Decision 30 '
      'surfaces this for projection rollover decisions.',
  source: 'graph_traversal_metrics',
  owner: 'B44',
  thresholds: <String, Object?>{'yellow': 1, 'red': 100},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> graphFailedTraversalsCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _graphFailedTraversalsTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(sum(failure_count), 0)::bigint as cnt "
      "from graph_traversal_metrics "
      "where window_start > now() - interval '5 minutes'",
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 100 ? 'red' : (count >= 1 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _graphFailedTraversalsTemplate().description,
      source: 'graph_traversal_metrics',
      owner: 'B44',
      observedAt: context.now,
      thresholds: _graphFailedTraversalsTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _graphProjectionAgeTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'seconds',
  description:
      'Age of the most recent AGE projection rebuild. Yellow at 24h, red at '
      '7d to flag stale projections behind canonical graph_nodes/graph_edges.',
  source: 'graph_projection_runs',
  owner: 'B44',
  thresholds: <String, Object?>{'yellow': 86400, 'red': 604800},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> graphProjectionAgeSecondsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _graphProjectionAgeTemplate, () async {
    final rows = await context.runner.query(
      "select extract(epoch from (now() - max(completed_at)))::bigint as age "
      "from graph_projection_runs where status = 'succeeded'",
    );
    if (rows.isEmpty || rows.first['age'] == null) {
      return ProxyHealthMetric(
        status: 'red',
        value: null,
        unit: 'seconds',
        description: _graphProjectionAgeTemplate().description,
        source: 'graph_projection_runs',
        owner: 'B44',
        observedAt: context.now,
        thresholds: _graphProjectionAgeTemplate().thresholds,
        metadata: const <String, Object?>{
          'tier': 2,
          'warning': 'no_projection_recorded',
        },
      );
    }
    final age = (rows.first['age'] as num).toInt();
    return ProxyHealthMetric(
      status: age >= 604800 ? 'red' : (age >= 86400 ? 'yellow' : 'green'),
      value: age,
      unit: 'seconds',
      description: _graphProjectionAgeTemplate().description,
      source: 'graph_projection_runs',
      owner: 'B44',
      observedAt: context.now,
      thresholds: _graphProjectionAgeTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _graphGrowthProjectionTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      '90-day projected edge count derived from rolling growth rate. '
      'Decision 30 fires red when projection ≥ 5M.',
  source: 'graph_growth_projection',
  owner: 'B44',
  thresholds: <String, Object?>{'red': 5000000},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> graphGrowthProjection90dEdgesProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _graphGrowthProjectionTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(projected_edges_90d, 0)::bigint as projected '
      'from graph_growth_projection order by observed_at desc limit 1',
    );
    if (rows.isEmpty) {
      return ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: _graphGrowthProjectionTemplate().description,
        source: 'graph_growth_projection',
        owner: 'B44',
        observedAt: context.now,
        thresholds: _graphGrowthProjectionTemplate().thresholds,
        metadata: const <String, Object?>{
          'tier': 2,
          'warning': 'no_projection_recorded',
        },
      );
    }
    final projected = (rows.first['projected'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: projected >= 5000000 ? 'red' : 'green',
      value: projected,
      unit: 'count',
      description: _graphGrowthProjectionTemplate().description,
      source: 'graph_growth_projection',
      owner: 'B44',
      observedAt: context.now,
      thresholds: _graphGrowthProjectionTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

final Map<String, ProxyHealthProducer> graphProducers =
    <String, ProxyHealthProducer>{
      'graph_node_count': graphNodeCountProducer,
      'graph_edge_count': graphEdgeCountProducer,
      'graph_traversal_latency_ms': graphTraversalLatencyMsProducer,
      'graph_traversal_p99_latency_ms': graphTraversalP99LatencyMsProducer,
      'graph_traversal_timeout_rate': graphTraversalTimeoutRateProducer,
      'graph_high_degree_node_count': graphHighDegreeNodeCountProducer,
      'graph_failed_traversals_count': graphFailedTraversalsCountProducer,
      'graph_projection_age_seconds': graphProjectionAgeSecondsProducer,
      'graph_growth_projection_90d_edges':
          graphGrowthProjection90dEdgesProducer,
    };
