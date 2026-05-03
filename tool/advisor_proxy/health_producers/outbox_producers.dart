// Phase 11A.B42 — event_outbox / NOTIFY health producers.
//
// Decision 33 thresholds:
//   - undelivered_count: yellow at 10,000 / red at 100,000
//   - lag_seconds:       yellow at 60    / red at 300
//   - publish_error_rate: yellow at 0.01 / red at 0.05
//   - notify_queue_usage_ratio: yellow at 0.10 / red at 0.25

import '../advisor_proxy.dart' show ProxyHealthMetric;
import 'health_producer.dart';

ProxyHealthMetric _eventOutboxUndeliveredTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Undelivered event_outbox rows awaiting bridge delivery. Decision 33 '
      'fires yellow at 10,000 and red at 100,000.',
  source: 'event_outbox',
  owner: 'Phase 10a',
  thresholds: <String, Object?>{'yellow': 10000, 'red': 100000},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> eventOutboxUndeliveredCountProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _eventOutboxUndeliveredTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(count(*), 0)::bigint as cnt "
      "from event_outbox where delivered_at is null",
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 100000 ? 'red' : (count >= 10000 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _eventOutboxUndeliveredTemplate().description,
      source: 'event_outbox',
      owner: 'Phase 10a',
      observedAt: context.now,
      thresholds: _eventOutboxUndeliveredTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _eventOutboxLagTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'seconds',
  description:
      'Age of the oldest undelivered event_outbox row. Decision 33 fires '
      'yellow at 60s and red at 300s.',
  source: 'event_outbox',
  owner: 'Phase 10a',
  thresholds: <String, Object?>{'yellow': 60, 'red': 300},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> eventOutboxLagSecondsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _eventOutboxLagTemplate, () async {
    final rows = await context.runner.query(
      "select extract(epoch from (now() - min(created_at)))::bigint as lag "
      "from event_outbox where delivered_at is null",
    );
    final raw = rows.first['lag'];
    if (raw == null) {
      return ProxyHealthMetric(
        status: 'green',
        value: 0,
        unit: 'seconds',
        description: _eventOutboxLagTemplate().description,
        source: 'event_outbox',
        owner: 'Phase 10a',
        observedAt: context.now,
        thresholds: _eventOutboxLagTemplate().thresholds,
        metadata: const <String, Object?>{'tier': 2},
      );
    }
    final lag = (raw as num).toInt();
    return ProxyHealthMetric(
      status: lag >= 300 ? 'red' : (lag >= 60 ? 'yellow' : 'green'),
      value: lag,
      unit: 'seconds',
      description: _eventOutboxLagTemplate().description,
      source: 'event_outbox',
      owner: 'Phase 10a',
      observedAt: context.now,
      thresholds: _eventOutboxLagTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _eventOutboxErrorRateTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'ratio',
  description:
      'Rolling event_outbox publish error rate over the last 5 minutes '
      '(failed_publish_count / attempted_publish_count). Decision 33 fires '
      'yellow at 0.01 and red at 0.05.',
  source: 'event_outbox_publish_metrics',
  owner: 'Phase 10a',
  thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> eventOutboxPublishErrorRateProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _eventOutboxErrorRateTemplate, () async {
    final rows = await context.runner.query(
      "select coalesce(sum(failed_publish_count), 0)::bigint as failed, "
      "coalesce(sum(attempted_publish_count), 0)::bigint as attempted "
      "from event_outbox_publish_metrics "
      "where window_start > now() - interval '5 minutes'",
    );
    final failed = (rows.first['failed'] as num?)?.toInt() ?? 0;
    final attempted = (rows.first['attempted'] as num?)?.toInt() ?? 0;
    if (attempted == 0) {
      return ProxyHealthMetric(
        status: 'green',
        value: 0.0,
        unit: 'ratio',
        description: _eventOutboxErrorRateTemplate().description,
        source: 'event_outbox_publish_metrics',
        owner: 'Phase 10a',
        observedAt: context.now,
        thresholds: _eventOutboxErrorRateTemplate().thresholds,
        metadata: const <String, Object?>{'tier': 2, 'attempted': 0},
      );
    }
    final ratio = failed / attempted;
    return ProxyHealthMetric(
      status: ratio >= 0.05 ? 'red' : (ratio >= 0.01 ? 'yellow' : 'green'),
      value: ratio,
      unit: 'ratio',
      description: _eventOutboxErrorRateTemplate().description,
      source: 'event_outbox_publish_metrics',
      owner: 'Phase 10a',
      observedAt: context.now,
      thresholds: _eventOutboxErrorRateTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

ProxyHealthMetric _notifyQueueUsageTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'ratio',
  description:
      'pg_notification_queue_usage(). Decision 33 fires yellow at 0.10 and '
      'red at 0.25 — large NOTIFY backlogs make the bridge fall behind.',
  source: 'pg_notification_queue_usage',
  owner: 'Phase 10a',
  thresholds: <String, Object?>{'yellow': 0.10, 'red': 0.25},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> notifyQueueUsageRatioProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _notifyQueueUsageTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(pg_notification_queue_usage(), 0.0)::double precision as usage',
    );
    final usage = (rows.first['usage'] as num?)?.toDouble() ?? 0.0;
    return ProxyHealthMetric(
      status: usage >= 0.25 ? 'red' : (usage >= 0.10 ? 'yellow' : 'green'),
      value: usage,
      unit: 'ratio',
      description: _notifyQueueUsageTemplate().description,
      source: 'pg_notification_queue_usage',
      owner: 'Phase 10a',
      observedAt: context.now,
      thresholds: _notifyQueueUsageTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

// ─── Phase 10a.2 — event_outbox_dead_letter depth ──────────────────────
//
// Reports the number of rows currently sitting in the dead-letter
// table. The bridge worker MOVEs rows here when their attempt_count
// exceeds `EVENT_OUTBOX_DLQ_CAP` (see
// `tool/advisor_proxy/realtime_bridge.dart`).
//
// Thresholds: yellow at 1 (any DLQ depth means at least one
// permanently-failing row needs F&F-engineer triage); red at 100 (a
// DLQ that big indicates either a producer running wild on bad
// payloads or a Pub/Sub-side outage that cleared after the cap
// kicked in). V1 has no auto-replay and per
// `memory/project_v1_lean_cut_2_2026_05_03.md` no operator-facing
// tile — F&F engineers triage via log search +
// `SELECT * FROM public.event_outbox_dead_letter ORDER BY
// dead_lettered_at DESC LIMIT N` and decide whether to manually
// reissue or accept the loss. See `docs/_walkthroughs/10a.2.md`
// for the click-path.
//
// The producer aggregates platform-wide (no operator filter) so the
// envelope contract's "no tenant identifiers in /health" rule
// holds. Per-operator drilldown is admin SQL only at V1; future
// per-operator surfaces would re-enter the per-tenant RLS policy
// via `EventOutboxDeadLetterRepository.countByOperator`.

ProxyHealthMetric _eventOutboxDlqDepthTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Rows sitting in event_outbox_dead_letter awaiting operator triage. '
      'Phase 10a.2 fires yellow at 1 (any DLQ depth needs review) and red '
      'at 100 (producer / consumer-side outage suspected).',
  source: 'event_outbox_dead_letter',
  owner: 'Phase 10a',
  thresholds: <String, Object?>{'yellow': 1, 'red': 100},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> eventOutboxDlqDepthProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _eventOutboxDlqDepthTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(count(*), 0)::bigint as cnt '
      'from event_outbox_dead_letter',
    );
    final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: count >= 100 ? 'red' : (count >= 1 ? 'yellow' : 'green'),
      value: count,
      unit: 'count',
      description: _eventOutboxDlqDepthTemplate().description,
      source: 'event_outbox_dead_letter',
      owner: 'Phase 10a',
      observedAt: context.now,
      thresholds: _eventOutboxDlqDepthTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

final Map<String, ProxyHealthProducer> outboxProducers =
    <String, ProxyHealthProducer>{
      'event_outbox_undelivered_count': eventOutboxUndeliveredCountProducer,
      'event_outbox_lag_seconds': eventOutboxLagSecondsProducer,
      'event_outbox_publish_error_rate': eventOutboxPublishErrorRateProducer,
      'notify_queue_usage_ratio': notifyQueueUsageRatioProducer,
      // Phase 10a.2 — DLQ depth.
      'event_outbox_dlq_depth': eventOutboxDlqDepthProducer,
    };
