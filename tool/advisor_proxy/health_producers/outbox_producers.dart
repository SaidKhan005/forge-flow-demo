// Phase 11A.B42 — event_outbox / NOTIFY health producers.
//
// Decision 33 thresholds:
//   - undelivered_count: yellow at 10,000 / red at 100,000
//   - lag_seconds:       yellow at 60    / red at 300
//   - publish_error_rate: yellow at 0.01 / red at 0.05
//   - notify_queue_usage_ratio: yellow at 0.10 / red at 0.25
//
// Phase 10a.3 layered slice adds:
//   - retention_backlog (existing, file-scoped): delivered rows past the
//     7-day window that the sweep has not removed yet.
//   - retention_lag_hours (this file): hours since the most recent
//     run_event_outbox_retention_sweep() pass landed a row in
//     event_outbox_retention_sweep_log. Distinguishes "sweep just ran
//     and the backlog is normal volume churn" from "sweep stopped
//     firing N hours ago".

import 'dart:io' show Platform;

import '../advisor_proxy.dart' show ProxyHealthMetric;
import 'event_outbox_retention_producer.dart';
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
// reissue or accept the loss. See `docs/archive/_walkthroughs/10a.2.md`
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

// ─── Phase 10a.3 (layered) — retention sweep lag in hours ──────────────
//
// Reports the time since the most recent
// `run_event_outbox_retention_sweep()` pass logged a row in
// `public.event_outbox_retention_sweep_log`. Backs the new bounded
// retention sweep that runs daily at 03:00 UTC (cron job
// `event_outbox_retention_sweep_daily`). The producer reads
// `MAX(swept_at)` so a single index probe answers the metric.
//
// Distinguishes two failure modes that the existing
// `event_outbox_retention_backlog` producer cannot tell apart:
//
//   * Sweep ran on schedule, backlog is normal volume churn -> lag is
//     fresh (< 24h), backlog is small -> green/green.
//   * Sweep stopped firing days ago, backlog is climbing -> lag is
//     stale (> 36h), backlog grows past yellow -> yellow/yellow then
//     red/red as the misalignment widens.
//
// Threshold defaults (env overrides below):
//   * Yellow at 36h: the sweep runs daily, so 36h means two cron
//     passes have been missed. One missed pass is normal (clock
//     jitter, rolling restart of the cron host); two passes is a
//     real signal worth a page-class alert at the Tier 2 envelope.
//   * Red at 168h (one week): the sweep has been broken for a full
//     week. With a busy operator emitting hundreds of delivered rows
//     per hour the live table will start to feel the bloat by then.
//
// Env-var override:
//   * `EVENT_OUTBOX_RETENTION_LAG_YELLOW_HOURS` (default 36)
//   * `EVENT_OUTBOX_RETENTION_LAG_RED_HOURS`    (default 168)
// Missing / blank / non-numeric / non-positive values fall back to
// the default. Red MUST be strictly greater than yellow; if a config
// inverts them, the resolver clamps red back to `yellow + 1`.
//
// NULL-safe path: `MAX(swept_at)` over an empty table returns NULL.
// The producer projects an `unknown` placeholder with metadata
// `sweep_never_ran: true` so the envelope distinguishes "table
// truly empty" from "non-zero lag". Once the first sweep lands the
// metric switches to a real numeric value.

const String eventOutboxRetentionLagYellowHoursEnvVar =
    'EVENT_OUTBOX_RETENTION_LAG_YELLOW_HOURS';
const String eventOutboxRetentionLagRedHoursEnvVar =
    'EVENT_OUTBOX_RETENTION_LAG_RED_HOURS';
const int defaultEventOutboxRetentionLagYellowHours = 36;
const int defaultEventOutboxRetentionLagRedHours = 168;

({int yellowHours, int redHours}) resolveEventOutboxRetentionLagThresholds(
  Map<String, String> environment,
) {
  final yellow =
      _parsePositiveInt(environment[eventOutboxRetentionLagYellowHoursEnvVar]) ??
      defaultEventOutboxRetentionLagYellowHours;
  final redRaw =
      _parsePositiveInt(environment[eventOutboxRetentionLagRedHoursEnvVar]) ??
      defaultEventOutboxRetentionLagRedHours;
  // Red MUST be strictly greater than yellow. An inverted pair would
  // make every above-yellow value also above red, collapsing the
  // yellow band entirely.
  final red = redRaw > yellow ? redRaw : yellow + 1;
  return (yellowHours: yellow, redHours: red);
}

int? _parsePositiveInt(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final parsed = int.tryParse(trimmed);
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

ProxyHealthMetric _eventOutboxRetentionLagTemplate(
  int yellowHours,
  int redHours,
) => ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'hours',
  description:
      'Hours since the most recent run_event_outbox_retention_sweep() '
      'pass landed in event_outbox_retention_sweep_log. Phase 10a.3 '
      'fires yellow at ${yellowHours}h (sweep missed two daily cron '
      'passes) and red at ${redHours}h (sweep missed a full week).',
  source: 'event_outbox_retention_sweep_log',
  owner: 'Phase 10a',
  thresholds: <String, Object?>{'yellow': yellowHours, 'red': redHours},
  metadata: const <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> eventOutboxRetentionLagProducer(
  ProxyHealthProducerContext context,
) {
  final thresholds = resolveEventOutboxRetentionLagThresholds(
    Platform.environment,
  );
  ProxyHealthMetric template() => _eventOutboxRetentionLagTemplate(
    thresholds.yellowHours,
    thresholds.redHours,
  );
  return runProducer(context, template, () async {
    final rows = await context.runner.query(
      'select extract(epoch from (now() - max(swept_at))) / 3600 '
      'as lag_hours '
      'from public.event_outbox_retention_sweep_log',
    );
    final raw = rows.first['lag_hours'];
    if (raw == null) {
      // No sweep has ever logged a row. The metric is unknown rather
      // than green: a freshly-deployed proxy can legitimately see
      // this state during the first 24 hours; after that it means
      // the cron was never registered or never fired. The envelope
      // surfaces the sweep_never_ran metadata so triage can tell
      // the two apart by reading deploy time.
      final base = template();
      return ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'hours',
        description: base.description,
        source: base.source,
        owner: base.owner,
        observedAt: context.now,
        thresholds: base.thresholds,
        metadata: const <String, Object?>{
          'tier': 2,
          'sweep_never_ran': true,
        },
      );
    }
    final lagHours = (raw as num).toDouble();
    final yellow = thresholds.yellowHours;
    final red = thresholds.redHours;
    final status = lagHours >= red
        ? 'red'
        : (lagHours >= yellow ? 'yellow' : 'green');
    return ProxyHealthMetric(
      status: status,
      value: lagHours,
      unit: 'hours',
      description: template().description,
      source: 'event_outbox_retention_sweep_log',
      owner: 'Phase 10a',
      observedAt: context.now,
      thresholds: <String, Object?>{'yellow': yellow, 'red': red},
      metadata: const <String, Object?>{'tier': 2},
    );
  });
}

// ─── Phase 10a.4 — bridge-lag tripwire producer ────────────────────
//
// Sister metric to `event_outbox_lag_seconds`. Where the existing
// producer measures the AGE of the OLDEST UNDELIVERED row by
// `created_at` (worst-case staleness across the table), this one
// measures the seconds since the MOST RECENT pickup that has not
// yet committed `delivered_at`. The two metrics catch different
// failure modes:
//
//   * `event_outbox_lag_seconds` (created_at) — slow producer flush
//     OR slow bridge: rises whenever rows pile up undelivered no
//     matter where the slowness is.
//   * `event_outbox_bridge_lag_seconds` (picked_up_at, this one) —
//     bridge-side stuck-after-pickup: rises only when rows were
//     claimed but not yet acknowledged by Pub/Sub.
//
// Q22 (Decision 33) thresholds bind both interpretations to the same
// 60s / 300s pair; the single Q22 number is reported through both
// producers so the tripwire evaluator can pick whichever the
// admin/UX surface wants to surface and the producer envelope keeps
// a single point of authority for the SQL semantics.
//
// SQL semantics: the prompt locks the body to
// `EXTRACT(EPOCH FROM (now() - max(picked_up_at)))` over rows where
// `delivered_at IS NULL`. A zero-row result and a NULL `max`
// (every undelivered row still has `picked_up_at = NULL` waiting for
// the bridge to claim) both project to lag = 0 — the green path —
// because the bridge has nothing to be lagging on at that moment.
// `event_outbox_lag_seconds` already covers the "rows piling up
// unclaimed" case from the other angle.

ProxyHealthMetric _eventOutboxBridgeLagTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'seconds',
  description:
      'Seconds since the most recent event_outbox pickup that has not yet '
      'committed delivered_at. Decision 33 fires yellow at 60s and red at '
      '300s. Same Q22 lock as event_outbox_lag_seconds, different angle '
      '(post-pickup bridge stall vs oldest-row staleness).',
  source: 'event_outbox',
  owner: 'Phase 10a',
  thresholds: <String, Object?>{'yellow': 60, 'red': 300},
  metadata: <String, Object?>{'tier': 2},
);

Future<ProxyHealthMetric> eventOutboxBridgeLagSecondsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _eventOutboxBridgeLagTemplate, () async {
    final rows = await context.runner.query(
      'select extract(epoch from (now() - max(picked_up_at)))::double precision '
      'as lag from public.event_outbox where delivered_at is null',
    );
    final raw = rows.isEmpty ? null : rows.first['lag'];
    final lag = (raw as num?)?.toDouble() ?? 0.0;
    return ProxyHealthMetric(
      status: lag >= 300 ? 'red' : (lag >= 60 ? 'yellow' : 'green'),
      value: lag,
      unit: 'seconds',
      description: _eventOutboxBridgeLagTemplate().description,
      source: 'event_outbox',
      owner: 'Phase 10a',
      observedAt: context.now,
      thresholds: _eventOutboxBridgeLagTemplate().thresholds,
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
      // Phase 10a.3 — retention sweep backlog.
      'event_outbox_retention_backlog': eventOutboxRetentionBacklogProducer,
      // Phase 10a.3 (layered) — retention sweep lag in hours.
      'event_outbox_retention_lag_hours': eventOutboxRetentionLagProducer,
      // Phase 10a.4 — bridge-side post-pickup lag (sister metric).
      'event_outbox_bridge_lag_seconds':
          eventOutboxBridgeLagSecondsProducer,
    };
