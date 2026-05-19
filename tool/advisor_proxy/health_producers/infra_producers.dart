// Phase 11A.B42 — Infrastructure-tier health producers.
//
// Producers in this file watch the Azure Postgres / Cloud Run platform
// underneath the proxy: extension allowlist, `pg_cron` scheduler
// liveness, `pg_partman` partition maintenance (Lock 2), idempotency
// cache aliveness, Cloud Run instance count.
//
// All producers honor the contract: no tenant identifiers, coarse
// platform-level counts only, errors and timeouts project to
// `status: 'unknown'`.

import '../advisor_proxy.dart' show ProxyHealthMetric;
import 'health_producer.dart';

const List<String> _requiredAzureExtensions = <String>[
  'age',
  'vector',
  'pg_diskann',
  'pg_partman',
  'pg_stat_statements',
  'pgcrypto',
];

ProxyHealthMetric _azureExtensionsTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Number of required Azure extensions installed in the active business '
      'database. Required set: AGE, pgvector, pg_diskann, pg_partman, '
      'pg_stat_statements, pgcrypto. pg_cron lives in Azure''s maintenance '
      'database and is checked by scheduler-specific metrics.',
  source: 'pg_extension',
  owner: 'B42',
  metadata: <String, Object?>{'tier': 1},
);

Future<ProxyHealthMetric> azureExtensionsPresentProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _azureExtensionsTemplate, () async {
    final rows = await context.runner.query(
      'select extname from pg_extension where extname = any(@names)',
      parameters: <String, Object?>{'names': _requiredAzureExtensions},
    );
    final present = rows
        .map((row) => row['extname']?.toString().toLowerCase())
        .whereType<String>()
        .toSet();
    final missing = _requiredAzureExtensions
        .where((name) => !present.contains(name))
        .toList(growable: false);
    return ProxyHealthMetric(
      status: missing.isEmpty ? 'green' : 'red',
      value: present.length,
      unit: 'count',
      description: _azureExtensionsTemplate().description,
      source: 'pg_extension',
      owner: 'B42',
      observedAt: context.now,
      thresholds: const <String, Object?>{'red_when_missing': true},
      metadata: <String, Object?>{
        'tier': 1,
        'required_count': _requiredAzureExtensions.length,
        if (missing.isNotEmpty) 'missing': missing,
      },
    );
  });
}

ProxyHealthMetric _pgCronSchedulerAliveTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'boolean',
  description:
      'Whether the pg_cron scheduler has reported a successful run inside '
      'the last 5 minutes (pulled from cron.job_run_details).',
  source: 'cron.job_run_details',
  owner: 'B42',
  metadata: <String, Object?>{'tier': 1},
);

Future<ProxyHealthMetric> pgCronSchedulerAliveProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _pgCronSchedulerAliveTemplate, () async {
    final rows = await context.runner.query(
      "select max(end_time) as last_end "
      "from cron.job_run_details "
      "where status = 'succeeded'",
    );
    if (rows.isEmpty || rows.first['last_end'] == null) {
      return ProxyHealthMetric(
        status: 'red',
        value: false,
        unit: 'boolean',
        description: _pgCronSchedulerAliveTemplate().description,
        source: 'cron.job_run_details',
        owner: 'B42',
        observedAt: context.now,
        thresholds: const <String, Object?>{'red_when_no_runs': true},
        metadata: const <String, Object?>{'tier': 1},
      );
    }
    final lastEnd = DateTime.parse(rows.first['last_end']!.toString()).toUtc();
    final age = context.now.toUtc().difference(lastEnd);
    final alive = age.inSeconds <= 300;
    return ProxyHealthMetric(
      status: alive ? 'green' : 'red',
      value: alive,
      unit: 'boolean',
      description: _pgCronSchedulerAliveTemplate().description,
      source: 'cron.job_run_details',
      owner: 'B42',
      observedAt: context.now,
      thresholds: const <String, Object?>{'red_seconds_since_last_run': 300},
      metadata: <String, Object?>{
        'tier': 1,
        'seconds_since_last_run': age.inSeconds,
      },
    );
  });
}

ProxyHealthMetric _proxyIdempotencyCacheAliveTemplate() =>
    const ProxyHealthMetric(
      status: 'unknown',
      value: null,
      unit: 'boolean',
      description:
          'Whether the proxy_requests idempotency table is reachable and '
          'accepting reads (a non-empty count(*) succeeds within budget).',
      source: 'proxy_requests',
      owner: 'B42',
      metadata: <String, Object?>{'tier': 1},
    );

Future<ProxyHealthMetric> proxyIdempotencyCacheAliveProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _proxyIdempotencyCacheAliveTemplate, () async {
    final rows = await context.runner.query(
      'select 1 as ok from proxy_requests limit 1',
    );
    final ok = rows.isNotEmpty || rows.isEmpty; // table reachable.
    return ProxyHealthMetric(
      status: ok ? 'green' : 'red',
      value: ok,
      unit: 'boolean',
      description: _proxyIdempotencyCacheAliveTemplate().description,
      source: 'proxy_requests',
      owner: 'B42',
      observedAt: context.now,
      metadata: const <String, Object?>{'tier': 1},
    );
  });
}

ProxyHealthMetric _partitionMaintenanceLastRunTemplate() =>
    const ProxyHealthMetric(
      status: 'unknown',
      value: null,
      unit: 'seconds',
      description:
          'Age of the last successful pg_partman run_maintenance() invocation '
          'recorded in cron.job_run_details. Lock 2 schedules this hourly.',
      source: 'cron.job_run_details',
      owner: 'B42',
      thresholds: <String, Object?>{'yellow': 7200, 'red': 14400},
      metadata: <String, Object?>{'tier': 2},
    );

Future<ProxyHealthMetric> partitionMaintenanceLastRunAgeSecondsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _partitionMaintenanceLastRunTemplate, () async {
    final rows = await context.runner.query(
      "select max(end_time) as last_end "
      "from cron.job_run_details d "
      "join cron.job j on d.jobid = j.jobid "
      "where j.command ilike '%run_maintenance%' "
      "and d.status = 'succeeded'",
    );
    if (rows.isEmpty || rows.first['last_end'] == null) {
      return ProxyHealthMetric(
        status: 'red',
        value: null,
        unit: 'seconds',
        description: _partitionMaintenanceLastRunTemplate().description,
        source: 'cron.job_run_details',
        owner: 'B42',
        observedAt: context.now,
        thresholds: _partitionMaintenanceLastRunTemplate().thresholds,
        metadata: const <String, Object?>{
          'tier': 2,
          'warning': 'no_partman_run_recorded',
        },
      );
    }
    final lastEnd = DateTime.parse(rows.first['last_end']!.toString()).toUtc();
    final age = context.now.toUtc().difference(lastEnd).inSeconds;
    return ProxyHealthMetric(
      status: age >= 14400 ? 'red' : (age >= 7200 ? 'yellow' : 'green'),
      value: age,
      unit: 'seconds',
      description: _partitionMaintenanceLastRunTemplate().description,
      source: 'cron.job_run_details',
      owner: 'B42',
      observedAt: context.now,
      thresholds: _partitionMaintenanceLastRunTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _partitionDefaultRowCountTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Rows that landed in the pg_partman default partition for usage_logs. '
      'Any row in default = pg_partman missed a future partition (Lock 2).',
  source: 'usage_logs_default',
  owner: 'B42',
  thresholds: <String, Object?>{'yellow': 1, 'red': 1000},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> partitionDefaultRowCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _partitionDefaultRowCountTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(count(*), 0)::bigint as cnt from usage_logs_default',
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 1000 ? 'red' : (count >= 1 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _partitionDefaultRowCountTemplate().description,
      source: 'usage_logs_default',
      owner: 'B42',
      observedAt: context.now,
      thresholds: _partitionDefaultRowCountTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _partitionCountActiveTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Number of active child partitions registered with pg_partman for '
      'operator-scoped fact tables.',
  source: 'partman.part_config',
  owner: 'B42',
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> partitionCountActiveProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _partitionCountActiveTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(count(*), 0)::bigint as cnt from partman.part_config',
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 1 ? 'green' : 'yellow',
      value: count,
      unit: 'count',
      description: _partitionCountActiveTemplate().description,
      source: 'partman.part_config',
      owner: 'B42',
      observedAt: context.now,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _pgCronJobsFailed24hTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'pg_cron job runs that finished with status != succeeded inside the '
      'last 24 hours. Yellow at 1, red at 5 to surface scheduler regressions.',
  source: 'cron.job_run_details',
  owner: 'B42',
  thresholds: <String, Object?>{'yellow': 1, 'red': 5},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> pgCronJobsFailed24hProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _pgCronJobsFailed24hTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(count(*), 0)::bigint as cnt "
      "from cron.job_run_details "
      "where status <> 'succeeded' and end_time > now() - interval '24 hours'",
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 5 ? 'red' : (count >= 1 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _pgCronJobsFailed24hTemplate().description,
      source: 'cron.job_run_details',
      owner: 'B42',
      observedAt: context.now,
      thresholds: _pgCronJobsFailed24hTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _cloudRunInstanceCountTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Active Cloud Run instance count for the proxy. Coarse value used by '
      'ops console to detect cold-start storms or scale-down anomalies.',
  source: 'cloud_run.instance_metrics',
  owner: 'B42',
  metadata: <String, Object?>{'tier': 3},
);

Future<ProxyHealthMetric> cloudRunInstanceCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _cloudRunInstanceCountTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(instance_count, 0)::int as instance_count '
      'from cloud_run_instance_metrics order by observed_at desc limit 1',
    );
    if (rows.isEmpty) {
      return ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: _cloudRunInstanceCountTemplate().description,
        source: 'cloud_run.instance_metrics',
        owner: 'B42',
        observedAt: context.now,
        metadata: const <String, Object?>{
          'tier': 3,
          'warning': 'no_metrics_recorded',
        },
      );
    }
    final count = (rows.first['instance_count'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: 'green',
      value: count,
      unit: 'count',
      description: _cloudRunInstanceCountTemplate().description,
      source: 'cloud_run.instance_metrics',
      owner: 'B42',
      observedAt: context.now,
      metadata: const <String, Object?>{'tier': 3},
    );
  });
}

ProxyHealthMetric _sessionRecordIncompleteCountTemplate() =>
    const ProxyHealthMetric(
      status: 'unknown',
      value: null,
      unit: 'count',
      description:
          'Total per-instance increments of '
          'proxy.session_record.incomplete{route, missing_field} since '
          'process start. Observability-only; the route never branches '
          'on the gauge. Metadata.buckets carries the route -> '
          'missing_field -> count slice for multi-instance rollup.',
      source: 'session_record_incomplete_gauge',
      owner: 'B42',
      metadata: <String, Object?>{'tier': 2},
    );

/// Slice A11.1.b — consume the per-instance [SessionRecordIncompleteGauge]
/// snapshot wired by Slice A11.1. The accessor is optional: when the
/// production bootstrap plumbs it in, the producer surfaces the live
/// counter map; otherwise the producer reports `status: 'unknown'` with a
/// `not_wired` warning so back-compat tests + scaffolds keep passing.
///
/// Defensive contract:
///   - Any accessor throw projects to `status: 'unknown'` + `warning:
///     'producer_error'` via `runProducer`'s outer catch, so a buggy gauge
///     can never crash the /health endpoint.
///   - Labels carry only `route` (a proxy path constant) and
///     `missing_field` (predicate-defined field name). NO PII, NO tenant
///     identifiers, matching the gauge's own contract (see
///     `SessionRecordIncompleteGauge` doc comment in advisor_proxy.dart).
///
/// Authority: docs/archive/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md
/// finding #2 (gauge data invisible to observability surface) +
/// docs/_execution/lane_a_code_health/03_execution_slices.md Slice A11.1
/// (consumer side).
Future<ProxyHealthMetric> sessionRecordIncompleteCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _sessionRecordIncompleteCountTemplate, () async {
    final accessor = context.sessionRecordIncompleteSnapshot;
    if (accessor == null) {
      return ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: _sessionRecordIncompleteCountTemplate().description,
        source: 'session_record_incomplete_gauge',
        owner: 'B42',
        observedAt: context.now,
        metadata: const <String, Object?>{
          'tier': 2,
          'warning': 'not_wired',
        },
      );
    }
    final snapshot = accessor();
    var total = 0;
    final buckets = <Map<String, Object?>>[];
    for (final routeEntry in snapshot.entries) {
      for (final fieldEntry in routeEntry.value.entries) {
        total += fieldEntry.value;
        buckets.add(<String, Object?>{
          'route': routeEntry.key,
          'missing_field': fieldEntry.key,
          'count': fieldEntry.value,
        });
      }
    }
    return ProxyHealthMetric(
      status: 'green',
      value: total,
      unit: 'count',
      description: _sessionRecordIncompleteCountTemplate().description,
      source: 'session_record_incomplete_gauge',
      owner: 'B42',
      observedAt: context.now,
      metadata: <String, Object?>{
        'tier': 2,
        // The route -> missing_field -> count slice for multi-instance
        // Cloud Run rollup at the observability sink. Empty list when
        // the gauge has not observed any incomplete records (the steady
        // state on a healthy proxy).
        'buckets': buckets,
      },
    );
  });
}

/// Map of producer key → producer function for this family.
final Map<String, ProxyHealthProducer> infraProducers =
    <String, ProxyHealthProducer>{
      'azure_extensions_present': azureExtensionsPresentProducer,
      'pg_cron_scheduler_alive': pgCronSchedulerAliveProducer,
      'proxy_idempotency_cache_alive': proxyIdempotencyCacheAliveProducer,
      'partition_maintenance_last_run_age_seconds':
          partitionMaintenanceLastRunAgeSecondsProducer,
      'partition_default_row_count': partitionDefaultRowCountProducer,
      'partition_count_active': partitionCountActiveProducer,
      'pg_cron_jobs_failed_24h': pgCronJobsFailed24hProducer,
      'cloud_run_instance_count': cloudRunInstanceCountProducer,
      // Slice A11.1.b — session-record gauge consumer.
      'session_record_incomplete_count': sessionRecordIncompleteCountProducer,
    };
