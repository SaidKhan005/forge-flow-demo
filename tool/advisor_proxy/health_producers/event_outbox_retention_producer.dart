// Phase 10a.3 — event_outbox retention sweep health producer.
//
// Reports the count of `event_outbox` rows whose `delivered_at` is
// past the contract's 7-day retention window but are still in the
// live table. The retention sweep
// (`db/migrations/202605050200_phase_10a_3_event_outbox_retention.sql`)
// runs once per day; in steady state it deletes every delivered row
// older than 7 days so this count stays at zero. A non-zero count
// means either the sweep has not run yet for this window or — the
// failure mode this producer alarms on — the cron schedule is
// missing / the function errored / the proxy host's pg_cron
// extension is misconfigured.
//
// Authority:
//   * `docs/contracts/event_outbox_contract.md` "Retention" section —
//     "delivered_at IS NOT NULL rows: retained 7 days, then deleted
//     by the Phase 10a retention sweep".
//   * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md`
//     scope "Retention sweep" subsection.
//
// Thresholds (yellow at 100, red at 10000):
//
//   * Green at 0 — the sweep just ran and cleared the backlog. Also
//     green between 1 and 99: the small intra-day window between
//     03:00 UTC sweep firings can leave a handful of rows that
//     crossed the 7-day mark since the last sweep. A busy operator
//     emitting ~hundreds of rows/day past the threshold is normal.
//   * Yellow at 100 — sustained backlog past the inter-sweep window
//     suggests the sweep is falling behind (cron firing but
//     function timing out, or the partition the rows live in is too
//     large for the daily window). 100 is comfortably above the
//     expected per-day churn at single-restaurant V1 traffic; raise
//     the threshold post-launch if the steady-state churn climbs.
//   * Red at 10000 — multi-day backlog. The sweep is clearly broken
//     (cron job missing, function erroring, or extension
//     misconfigured). 10000 matches the order-of-magnitude shape of
//     the existing event_outbox_undelivered_count yellow threshold;
//     a delivered-row backlog that big means retention is not
//     running at all.
//
// The producer aggregates platform-wide (no operator filter) — the
// retention contract is platform-wide policy, not per-tenant
// configuration. The deep-health envelope rules
// (`tool/advisor_proxy/health_producers/health_producer.dart` "Producers
// never see operator/location identifiers") forbid tenant identifiers
// in the metric output anyway. Per-operator drilldown for triage runs
// through the per-tenant RLS policy via direct SQL by F&F engineers.

import '../advisor_proxy.dart' show ProxyHealthMetric;
import 'health_producer.dart';

ProxyHealthMetric _eventOutboxRetentionBacklogTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Delivered event_outbox rows older than the 7-day retention '
      'window that are still in the live table. The Phase 10a.3 '
      'daily sweep should keep this near zero. Yellow at 100 '
      '(sustained backlog past the inter-sweep window); red at '
      '10000 (sweep clearly broken).',
  source: 'event_outbox',
  owner: 'Phase 10a',
  thresholds: <String, Object?>{'yellow': 100, 'red': 10000},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> eventOutboxRetentionBacklogProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _eventOutboxRetentionBacklogTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(count(*), 0)::bigint as cnt "
      "from event_outbox "
      "where delivered_at is not null "
      "and delivered_at < now() - interval '7 days'",
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 10000 ? 'red' : (count >= 100 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _eventOutboxRetentionBacklogTemplate().description,
      source: 'event_outbox',
      owner: 'Phase 10a',
      observedAt: context.now,
      thresholds: _eventOutboxRetentionBacklogTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}
