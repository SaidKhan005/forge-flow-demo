// Phase 11A.B42 — Cost / cache / batch health producers.
//
// Tracks the five cost-discipline levers from Hard Promise #9
// (prompt cache, response cache, semantic cache, tier routing,
// batch API) plus per-class cost so the ops console can spot drift
// before it eats margin.

import '../advisor_proxy.dart' show ProxyHealthMetric;
import 'health_producer.dart';

ProxyHealthMetric _usageCapsBreachTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Count of distinct cap-identity tuples whose month-to-date '
      'sum(cost_usd) has reached or exceeded `usage_caps.monthly_cap_usd`. '
      'The cap identity matches `cap_status_select`: '
      '(operator_id, billing_owner_org_unit_id, scoped_org_unit_id, '
      'location_id, staff_id, workflow_id, usage_class). Yellow at 1, '
      'red at 100.',
  source: 'usage_logs join usage_caps',
  owner: 'B33',
  thresholds: <String, Object?>{'yellow': 1, 'red': 100},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> usageCapsBreachCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _usageCapsBreachTemplate, () async {
    // Roll usage_logs up per cap-identity for the current month, then
    // compare the SUM (not per-row cost_usd) to the matching cap. The
    // cap identity mirrors the locked `usage_caps_two_slot_uq`
    // constraint and the existing cap_status_select semantics — usage
    // is upserted at finer dimensions (cache_hit, llm_tier, model_used,
    // batch_mode, circuit_state, fallback_used) per row, so summing
    // within the cap identity is what matters for "cap reached".
    //
    // `is not distinct from` matches the cap-status query so NULL
    // staff_id / workflow_id rows collide on the cap identity (UNIQUE
    // NULLS NOT DISTINCT semantics).
    final rows = await context.runner.query(
      'with monthly_actuals as ('
      '  select '
      '    operator_id, '
      '    billing_owner_org_unit_id, '
      '    scoped_org_unit_id, '
      '    location_id, '
      '    staff_id, '
      '    workflow_id, '
      '    usage_class, '
      '    sum(cost_usd) as monthly_used_usd '
      '  from public.usage_logs '
      "  where period_start = date_trunc('month', now()) "
      '  group by '
      '    operator_id, '
      '    billing_owner_org_unit_id, '
      '    scoped_org_unit_id, '
      '    location_id, '
      '    staff_id, '
      '    workflow_id, '
      '    usage_class'
      ') '
      'select coalesce(count(*), 0)::bigint as cnt '
      'from monthly_actuals a '
      'join public.usage_caps c '
      '  on c.operator_id = a.operator_id '
      '  and c.billing_owner_org_unit_id = a.billing_owner_org_unit_id '
      '  and c.scoped_org_unit_id = a.scoped_org_unit_id '
      '  and c.location_id = a.location_id '
      '  and c.staff_id is not distinct from a.staff_id '
      '  and c.workflow_id is not distinct from a.workflow_id '
      '  and c.usage_class = a.usage_class '
      'where c.monthly_cap_usd > 0 '
      '  and a.monthly_used_usd >= c.monthly_cap_usd',
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 100 ? 'red' : (count >= 1 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _usageCapsBreachTemplate().description,
      source: 'usage_logs join usage_caps',
      owner: 'B33',
      observedAt: context.now,
      thresholds: _usageCapsBreachTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _cacheHitRateTemplate(String layer) => ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'ratio',
  description:
      '$layer cache hit rate over the last 5 minutes. Yellow below 0.30, '
      'red below 0.10 (Hard Promise #9 cost discipline lever).',
  source: 'cache_metrics',
  owner: 'B42',
  thresholds: const <String, Object?>{'yellow': 0.30, 'red': 0.10},
  metadata: const <String, Object?>{'tier': 3},
);

Future<ProxyHealthMetric> _cacheHitRateProducer(
  ProxyHealthProducerContext context,
  String layer,
) {
  return runProducer(context, () => _cacheHitRateTemplate(layer), () async {
    final rows = await context.runner.query(
      "select coalesce(sum(hit_count), 0)::bigint as h, "
      "coalesce(sum(lookup_count), 0)::bigint as a "
      "from cache_metrics where layer = '$layer' "
      "and window_start > now() - interval '5 minutes'",
    );
    final h = (rows.first['h'] as num?)?.toInt() ?? 0;
    final a = (rows.first['a'] as num?)?.toInt() ?? 0;
    final ratio = a == 0 ? 0.0 : h / a;
    String status;
    if (a == 0) {
      status = 'unknown';
    } else if (ratio < 0.10) {
      status = 'red';
    } else if (ratio < 0.30) {
      status = 'yellow';
    } else {
      status = 'green';
    }
    return ProxyHealthMetric(
      status: status,
      value: ratio,
      unit: 'ratio',
      description: _cacheHitRateTemplate(layer).description,
      source: 'cache_metrics',
      owner: 'B42',
      observedAt: context.now,
      thresholds: const <String, Object?>{'yellow': 0.30, 'red': 0.10},
      metadata: <String, Object?>{
        'tier': 3,
        'layer': layer,
        'lookups': a,
      },
    );
  });
}

Future<ProxyHealthMetric> promptCacheHitRateProducer(
  ProxyHealthProducerContext context,
) =>
    _cacheHitRateProducer(context, 'prompt');

Future<ProxyHealthMetric> responseCacheHitRateProducer(
  ProxyHealthProducerContext context,
) =>
    _cacheHitRateProducer(context, 'response');

Future<ProxyHealthMetric> semanticCacheHitRateProducer(
  ProxyHealthProducerContext context,
) =>
    _cacheHitRateProducer(context, 'semantic');

// Absolute USD-per-request bands per usage_class. The Lock 7
// cost-threshold trigger is 2× expected for the class — these values
// are the working defaults used by the producer until per-class
// baselines land in a separate slice.
const Map<String, ({double yellow, double red})> _costPerClassBands =
    <String, ({double yellow, double red})>{
  'haiku': (yellow: 0.005, red: 0.020),
  'sonnet': (yellow: 0.050, red: 0.200),
  'voyage': (yellow: 0.001, red: 0.005),
};

ProxyHealthMetric _costPerClassTemplate(String klass) {
  final bands = _costPerClassBands[klass] ?? (yellow: 0.0, red: 0.0);
  return ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'usd',
    description:
        'Rolling 1-hour mean cost per request for usage class "$klass" '
        '(USD). Yellow at \$${bands.yellow.toStringAsFixed(3)}, red at '
        '\$${bands.red.toStringAsFixed(3)} per request.',
    source: 'usage_logs',
    owner: 'B42',
    thresholds: <String, Object?>{
      'yellow_usd_per_request': bands.yellow,
      'red_usd_per_request': bands.red,
    },
    metadata: const <String, Object?>{'tier': 3},
  );
}

Future<ProxyHealthMetric> _costPerClassProducer(
  ProxyHealthProducerContext context,
  String klass,
) {
  return runProducer(context, () => _costPerClassTemplate(klass), () async {
    final rows = await context.runner.query(
      'select coalesce(sum(cost_usd), 0)::double precision as total_cost, '
      'coalesce(sum(request_count), 0)::bigint as total_requests '
      'from public.usage_logs '
      'where usage_class = @klass '
      "and created_at > now() - interval '1 hour'",
      parameters: <String, Object?>{'klass': klass},
    );
    final totalCost =
        (rows.first['total_cost'] as num?)?.toDouble() ?? 0.0;
    final totalRequests =
        (rows.first['total_requests'] as num?)?.toInt() ?? 0;
    if (totalRequests == 0) {
      return ProxyHealthMetric(
        status: 'green',
        value: 0.0,
        unit: 'usd',
        description: _costPerClassTemplate(klass).description,
        source: 'usage_logs',
        owner: 'B42',
        observedAt: context.now,
        thresholds: _costPerClassTemplate(klass).thresholds,
        metadata: <String, Object?>{
          'tier': 3,
          'class': klass,
          'requests': 0,
        },
      );
    }
    final avg = totalCost / totalRequests;
    final bands = _costPerClassBands[klass] ?? (yellow: 0.0, red: 0.0);
    final status = bands.red <= 0
        ? 'green'
        : (avg >= bands.red
              ? 'red'
              : (avg >= bands.yellow ? 'yellow' : 'green'));
    return ProxyHealthMetric(
      status: status,
      value: avg,
      unit: 'usd',
      description: _costPerClassTemplate(klass).description,
      source: 'usage_logs',
      owner: 'B42',
      observedAt: context.now,
      thresholds: _costPerClassTemplate(klass).thresholds,
      metadata: <String, Object?>{
        'tier': 3,
        'class': klass,
        'requests': totalRequests,
      },
    );
  });
}

Future<ProxyHealthMetric> costPerQueryClassHaikuProducer(
  ProxyHealthProducerContext context,
) =>
    _costPerClassProducer(context, 'haiku');

Future<ProxyHealthMetric> costPerQueryClassSonnetProducer(
  ProxyHealthProducerContext context,
) =>
    _costPerClassProducer(context, 'sonnet');

Future<ProxyHealthMetric> costPerQueryClassVoyageProducer(
  ProxyHealthProducerContext context,
) =>
    _costPerClassProducer(context, 'voyage');

ProxyHealthMetric _batchApiPendingTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Workflow runs sitting in AWAITING_BATCH (Lock 8). Yellow at 100, '
      'red at 1,000 — large pending pools imply the batch poller is stalled.',
  source: 'workflow_runs',
  owner: 'Phase 12.0',
  thresholds: <String, Object?>{'yellow': 100, 'red': 1000},
  metadata: <String, Object?>{'tier': 3},
);

Future<ProxyHealthMetric> batchApiPendingCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _batchApiPendingTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(count(*), 0)::bigint as cnt "
      "from workflow_runs where status = 'AWAITING_BATCH'",
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 1000 ? 'red' : (count >= 100 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _batchApiPendingTemplate().description,
      source: 'workflow_runs',
      owner: 'Phase 12.0',
      observedAt: context.now,
      thresholds: _batchApiPendingTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 3},
    );
  });
}

final Map<String, ProxyHealthProducer> costProducers =
    <String, ProxyHealthProducer>{
      'usage_caps_breach_count': usageCapsBreachCountProducer,
      'prompt_cache_hit_rate': promptCacheHitRateProducer,
      'response_cache_hit_rate': responseCacheHitRateProducer,
      'semantic_cache_hit_rate': semanticCacheHitRateProducer,
      'cost_per_query_class_haiku': costPerQueryClassHaikuProducer,
      'cost_per_query_class_sonnet': costPerQueryClassSonnetProducer,
      'cost_per_query_class_voyage': costPerQueryClassVoyageProducer,
      'batch_api_pending_count': batchApiPendingCountProducer,
    };
