// Phase 11A.B42 — pgvector / DiskANN health producers.
//
// Decision 31 thresholds:
//   - vector_active_count_per_corpus: yellow 5,000,000 / red 8,000,000
//   - vector_growth_projection_90d_count: red ≥ 10,000,000

import '../advisor_proxy.dart' show ProxyHealthMetric;
import 'health_producer.dart';

ProxyHealthMetric _vectorIndexSizeTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Per-corpus vector index size (sum of indexed embeddings). Returns a '
      'corpus_id-keyed map with count-band buckets only — no tenant rows.',
  source: 'vector_index_health',
  owner: 'B47',
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> vectorIndexSizePerCorpusProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _vectorIndexSizeTemplate, () async {
    final rows = await context.runner.query(
      'select corpus_id::text as corpus_id, indexed_count::bigint as cnt '
      'from vector_index_health',
    );
    final byCorpus = <String, int>{};
    var anyRed = false;
    var anyYellow = false;
    for (final row in rows) {
      final corpus = row['corpus_id']?.toString() ?? 'unknown';
      final cnt = (row['cnt'] as num?)?.toInt() ?? 0;
      byCorpus[corpus] = cnt;
      if (cnt >= 8000000) anyRed = true;
      if (cnt >= 5000000) anyYellow = true;
    }
    return ProxyHealthMetric(
      status: anyRed ? 'red' : (anyYellow ? 'yellow' : 'green'),
      value: byCorpus,
      unit: 'count',
      description: _vectorIndexSizeTemplate().description,
      source: 'vector_index_health',
      owner: 'B47',
      observedAt: context.now,
      thresholds: const <String, Object?>{'yellow': 5000000, 'red': 8000000},
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _vectorQueryLatencyTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'milliseconds',
  description:
      'Filtered vector search p50 latency from the most recent benchmark.',
  source: 'vector_benchmark_runs',
  owner: 'B47',
  thresholds: <String, Object?>{'yellow': 200, 'red': 400},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> vectorQueryLatencyMsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _vectorQueryLatencyTemplate, () async {
    final rows = await context.runner.query(
      'select p50_ms from vector_benchmark_runs '
      'order by observed_at desc limit 1',
    );
    final p50 = rows.isEmpty ? null : (rows.first['p50_ms'] as num?)?.toInt();
    return ProxyHealthMetric(
      status: p50 == null
          ? 'unknown'
          : (p50 >= 400 ? 'red' : (p50 >= 200 ? 'yellow' : 'green')),
      value: p50,
      unit: 'milliseconds',
      description: _vectorQueryLatencyTemplate().description,
      source: 'vector_benchmark_runs',
      owner: 'B47',
      observedAt: context.now,
      thresholds: _vectorQueryLatencyTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _vectorRecallTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'ratio',
  description:
      'Filtered vector search recall@10 from the most recent benchmark. '
      'Yellow at 0.85, red at 0.70.',
  source: 'vector_benchmark_runs',
  owner: 'B47',
  thresholds: <String, Object?>{'yellow': 0.85, 'red': 0.70},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> vectorRecallProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _vectorRecallTemplate, () async {
    final rows = await context.runner.query(
      'select recall_at_10 from vector_benchmark_runs '
      'order by observed_at desc limit 1',
    );
    final recall = rows.isEmpty
        ? null
        : (rows.first['recall_at_10'] as num?)?.toDouble();
    String status;
    if (recall == null) {
      status = 'unknown';
    } else if (recall < 0.70) {
      status = 'red';
    } else if (recall < 0.85) {
      status = 'yellow';
    } else {
      status = 'green';
    }
    return ProxyHealthMetric(
      status: status,
      value: recall,
      unit: 'ratio',
      description: _vectorRecallTemplate().description,
      source: 'vector_benchmark_runs',
      owner: 'B47',
      observedAt: context.now,
      thresholds: _vectorRecallTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _vectorQueryP99Template() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'milliseconds',
  description:
      'Filtered vector search p99 latency from the most recent benchmark.',
  source: 'vector_benchmark_runs',
  owner: 'B47',
  thresholds: <String, Object?>{'yellow': 600, 'red': 1200},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> vectorQueryP99LatencyMsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _vectorQueryP99Template, () async {
    final rows = await context.runner.query(
      'select p99_ms from vector_benchmark_runs '
      'order by observed_at desc limit 1',
    );
    final p99 = rows.isEmpty ? null : (rows.first['p99_ms'] as num?)?.toInt();
    return ProxyHealthMetric(
      status: p99 == null
          ? 'unknown'
          : (p99 >= 1200 ? 'red' : (p99 >= 600 ? 'yellow' : 'green')),
      value: p99,
      unit: 'milliseconds',
      description: _vectorQueryP99Template().description,
      source: 'vector_benchmark_runs',
      owner: 'B47',
      observedAt: context.now,
      thresholds: _vectorQueryP99Template().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _vectorTimeoutRateTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'ratio',
  description:
      'Rolling 5-minute filtered vector search timeout rate.',
  source: 'vector_query_metrics',
  owner: 'B47',
  thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> vectorQueryTimeoutRateProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _vectorTimeoutRateTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(sum(timeout_count), 0)::bigint as t, "
      "coalesce(sum(query_count), 0)::bigint as a "
      "from vector_query_metrics "
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
      description: _vectorTimeoutRateTemplate().description,
      source: 'vector_query_metrics',
      owner: 'B47',
      observedAt: context.now,
      thresholds: _vectorTimeoutRateTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _vectorActiveCountTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Active vector count per corpus (per Decision 31 HNSW-to-DiskANN '
      'tripwire). Yellow at 5M, red at 8M per corpus.',
  source: 'vector_index_health',
  owner: 'B47',
  thresholds: <String, Object?>{'yellow': 5000000, 'red': 8000000},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> vectorActiveCountPerCorpusProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _vectorActiveCountTemplate, () async {
    final rows = await context.runner.query(
      'select corpus_id::text as corpus_id, active_count::bigint as cnt '
      'from vector_index_health',
    );
    final maxActive = rows.fold<int>(0, (acc, row) {
      final c = (row['cnt'] as num?)?.toInt() ?? 0;
      return c > acc ? c : acc;
    });
    return ProxyHealthMetric(
      status: maxActive >= 8000000
          ? 'red'
          : (maxActive >= 5000000 ? 'yellow' : 'green'),
      value: maxActive,
      unit: 'count',
      description: _vectorActiveCountTemplate().description,
      source: 'vector_index_health',
      owner: 'B47',
      observedAt: context.now,
      thresholds: _vectorActiveCountTemplate().thresholds,
      metadata: <String, Object?>{
        'tier': 2,
        'corpus_count': rows.length,
      },
    );
  });
}

ProxyHealthMetric _vectorIndexBuildAgeTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'seconds',
  description:
      'Age of the most recent vector index build. Yellow at 7d, red at 30d.',
  source: 'vector_index_health',
  owner: 'B47',
  thresholds: <String, Object?>{'yellow': 604800, 'red': 2592000},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> vectorIndexBuildAgeSecondsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _vectorIndexBuildAgeTemplate, () async {
    final rows = await context.runner.query(
      "select extract(epoch from (now() - max(last_built_at)))::bigint as age "
      "from vector_index_health where last_built_at is not null",
    );
    if (rows.isEmpty || rows.first['age'] == null) {
      return ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description: _vectorIndexBuildAgeTemplate().description,
        source: 'vector_index_health',
        owner: 'B47',
        observedAt: context.now,
        thresholds: _vectorIndexBuildAgeTemplate().thresholds,
        metadata: const <String, Object?>{
          'tier': 2,
          'warning': 'no_index_build_recorded',
        },
      );
    }
    final age = (rows.first['age'] as num).toInt();
    return ProxyHealthMetric(
      status: age >= 2592000 ? 'red' : (age >= 604800 ? 'yellow' : 'green'),
      value: age,
      unit: 'seconds',
      description: _vectorIndexBuildAgeTemplate().description,
      source: 'vector_index_health',
      owner: 'B47',
      observedAt: context.now,
      thresholds: _vectorIndexBuildAgeTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _vectorGrowthProjectionTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      '90-day projected vector count per corpus. Decision 31 fires red when '
      'projection ≥ 10M (DiskANN cutover trigger).',
  source: 'vector_growth_projection',
  owner: 'B47',
  thresholds: <String, Object?>{'red': 10000000},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> vectorGrowthProjection90dCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _vectorGrowthProjectionTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(max(projected_count_90d), 0)::bigint as projected '
      'from vector_growth_projection',
    );
    final projected = (rows.first['projected'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: projected >= 10000000 ? 'red' : 'green',
      value: projected,
      unit: 'count',
      description: _vectorGrowthProjectionTemplate().description,
      source: 'vector_growth_projection',
      owner: 'B47',
      observedAt: context.now,
      thresholds: _vectorGrowthProjectionTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

final Map<String, ProxyHealthProducer> vectorProducers =
    <String, ProxyHealthProducer>{
      'vector_index_size_per_corpus': vectorIndexSizePerCorpusProducer,
      'vector_query_latency_ms': vectorQueryLatencyMsProducer,
      'vector_recall': vectorRecallProducer,
      'vector_query_p99_latency_ms': vectorQueryP99LatencyMsProducer,
      'vector_query_timeout_rate': vectorQueryTimeoutRateProducer,
      'vector_active_count_per_corpus': vectorActiveCountPerCorpusProducer,
      'vector_index_build_age_seconds': vectorIndexBuildAgeSecondsProducer,
      'vector_growth_projection_90d_count':
          vectorGrowthProjection90dCountProducer,
    };
