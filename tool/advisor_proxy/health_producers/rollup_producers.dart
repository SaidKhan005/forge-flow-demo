// Phase 11A.B42 — Rollup health producers (B45).

import '../advisor_proxy.dart' show ProxyHealthMetric;
import 'health_producer.dart';

ProxyHealthMetric _rollupFreshnessTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'seconds',
  description:
      'Per-grain rollup freshness lag (max(now() - last_rolled_through_at)). '
      'Returned as a grain-keyed map; yellow at 1h, red at 6h.',
  source: 'aggregation_state',
  owner: 'B45',
  thresholds: <String, Object?>{'yellow': 3600, 'red': 21600},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> rollupFreshnessPerGrainProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _rollupFreshnessTemplate, () async {
    final rows = await context.runner.query(
      "select grain::text as grain, "
      "extract(epoch from (now() - max(last_rolled_through_at)))::bigint as lag "
      "from aggregation_state group by grain",
    );
    final byGrain = <String, int>{};
    var maxLag = 0;
    for (final row in rows) {
      final grain = row['grain']?.toString() ?? 'unknown';
      final lag = (row['lag'] as num?)?.toInt() ?? 0;
      byGrain[grain] = lag;
      if (lag > maxLag) maxLag = lag;
    }
    return ProxyHealthMetric(
      status: maxLag >= 21600
          ? 'red'
          : (maxLag >= 3600 ? 'yellow' : 'green'),
      value: byGrain,
      unit: 'seconds',
      description: _rollupFreshnessTemplate().description,
      source: 'aggregation_state',
      owner: 'B45',
      observedAt: context.now,
      thresholds: _rollupFreshnessTemplate().thresholds,
      metadata: <String, Object?>{
        'tier': 2,
        'grain_count': byGrain.length,
        'max_lag_seconds': maxLag,
      },
    );
  });
}

ProxyHealthMetric _rollupRefreshLagTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'seconds',
  description:
      'Time since the most recent rollup refresh job completed (across all '
      'grains).',
  source: 'aggregation_state',
  owner: 'B45',
  thresholds: <String, Object?>{'yellow': 3600, 'red': 14400},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> rollupRefreshLagSecondsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _rollupRefreshLagTemplate, () async {
    final rows = await context.runner.query(
      'select extract(epoch from (now() - max(updated_at)))::bigint as lag '
      'from aggregation_state',
    );
    if (rows.isEmpty || rows.first['lag'] == null) {
      return ProxyHealthMetric(
        status: 'red',
        value: null,
        unit: 'seconds',
        description: _rollupRefreshLagTemplate().description,
        source: 'aggregation_state',
        owner: 'B45',
        observedAt: context.now,
        thresholds: _rollupRefreshLagTemplate().thresholds,
        metadata: const <String, Object?>{
          'tier': 2,
          'warning': 'no_rollup_refresh_recorded',
        },
      );
    }
    final lag = (rows.first['lag'] as num).toInt();
    return ProxyHealthMetric(
      status: lag >= 14400 ? 'red' : (lag >= 3600 ? 'yellow' : 'green'),
      value: lag,
      unit: 'seconds',
      description: _rollupRefreshLagTemplate().description,
      source: 'aggregation_state',
      owner: 'B45',
      observedAt: context.now,
      thresholds: _rollupRefreshLagTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _rollupFailedRefreshesTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'pg_cron rollup refresh jobs that failed in the last 24 hours.',
  source: 'cron.job_run_details',
  owner: 'B45',
  thresholds: <String, Object?>{'yellow': 1, 'red': 5},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> rollupFailedRefreshesCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _rollupFailedRefreshesTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(count(*), 0)::bigint as cnt "
      "from cron.job_run_details d join cron.job j on d.jobid = j.jobid "
      "where j.command ilike '%refresh materialized view%' "
      "and d.status <> 'succeeded' "
      "and d.end_time > now() - interval '24 hours'",
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 5 ? 'red' : (count >= 1 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _rollupFailedRefreshesTemplate().description,
      source: 'cron.job_run_details',
      owner: 'B45',
      observedAt: context.now,
      thresholds: _rollupFailedRefreshesTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _rollupConcurrentRefreshTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'boolean',
  description:
      'Whether a REFRESH MATERIALIZED VIEW CONCURRENTLY is currently running. '
      'True is informational; long-running concurrent refreshes are tracked '
      'via rollup_refresh_lag_seconds instead.',
  source: 'pg_stat_activity',
  owner: 'B45',
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> rollupConcurrentRefreshStatusProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _rollupConcurrentRefreshTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(count(*), 0)::int as cnt "
      "from pg_stat_activity where query ilike '%REFRESH MATERIALIZED VIEW%'",
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: 'green',
      value: count > 0,
      unit: 'boolean',
      description: _rollupConcurrentRefreshTemplate().description,
      source: 'pg_stat_activity',
      owner: 'B45',
      observedAt: context.now,
      metadata: <String, Object?>{'tier': 2, 'running_count': count},
    );
  });
}

final Map<String, ProxyHealthProducer> rollupProducers =
    <String, ProxyHealthProducer>{
      'rollup_freshness_per_grain': rollupFreshnessPerGrainProducer,
      'rollup_refresh_lag_seconds': rollupRefreshLagSecondsProducer,
      'rollup_failed_refreshes_count': rollupFailedRefreshesCountProducer,
      'rollup_concurrent_refresh_status':
          rollupConcurrentRefreshStatusProducer,
    };
