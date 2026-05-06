// Phase 10a.4 — production wiring for `/v1/realtime/tripwire-status`.
//
// The route is the only consumer of [RealtimeTripwireProxyGateway].
// This file holds the production `runAsSystem`-backed implementation
// + the env-var threshold-override resolver the walkthrough relies
// on; the gateway interface itself lives in `advisor_proxy.dart` so
// existing tests can inject fakes without dragging this file in.
//
// The gateway runs the four Q22 producers directly (instead of going
// through the full `/health` envelope) so the route stays cheap to
// poll: four single-row aggregate queries through the admin pool,
// answered in a few milliseconds. Per-call cost matters because the
// sync badge polls every ~60 seconds and the admin observability
// section refetches on demand.

import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/realtime/outbox_tripwire_evaluator.dart';

import 'advisor_proxy.dart' show RealtimeTripwireProxyGateway;

/// Env-var keys for the demo walkthrough threshold-override path.
/// Each variable accepts a positive number; non-numeric or non-positive
/// values fall back to the locked Q22 default. The locked thresholds
/// in [kOutboxTripwireDefaultThresholds] are the production contract;
/// these env vars exist only so a demo / dev environment can force a
/// metric into the red band on demand without manipulating the live
/// `event_outbox` table.
const String tripwireBridgeLagYellowEnvVar =
    'EVENT_OUTBOX_BRIDGE_LAG_YELLOW_SECONDS';
const String tripwireBridgeLagRedEnvVar =
    'EVENT_OUTBOX_BRIDGE_LAG_RED_SECONDS';
const String tripwireUndeliveredYellowEnvVar =
    'EVENT_OUTBOX_UNDELIVERED_YELLOW';
const String tripwireUndeliveredRedEnvVar = 'EVENT_OUTBOX_UNDELIVERED_RED';
const String tripwirePublishErrorYellowEnvVar =
    'EVENT_OUTBOX_PUBLISH_ERROR_YELLOW';
const String tripwirePublishErrorRedEnvVar =
    'EVENT_OUTBOX_PUBLISH_ERROR_RED';
const String tripwireNotifyQueueYellowEnvVar =
    'PG_NOTIFICATION_QUEUE_USAGE_YELLOW';
const String tripwireNotifyQueueRedEnvVar =
    'PG_NOTIFICATION_QUEUE_USAGE_RED';

/// Resolve the threshold map the gateway hands to the evaluator. The
/// returned map is non-null only when at least one env override is in
/// play; otherwise the gateway passes `null` and the evaluator uses
/// the Q22 defaults. Returning a sparse map (missing entries fall
/// back to the locked defaults inside the evaluator) means a
/// walkthrough can override a single metric without having to specify
/// thresholds for the other three.
Map<OutboxTripwireMetric, OutboxTripwireThresholds>?
    resolveTripwireThresholdOverrides(Map<String, String> environment) {
  final overrides = <OutboxTripwireMetric, OutboxTripwireThresholds>{};
  void apply(
    OutboxTripwireMetric metric,
    String yellowKey,
    String redKey,
  ) {
    final yellow = _parsePositiveNum(environment[yellowKey]);
    final red = _parsePositiveNum(environment[redKey]);
    if (yellow == null && red == null) return;
    final defaults = kOutboxTripwireDefaultThresholds[metric]!;
    final resolvedYellow = yellow ?? defaults.yellow;
    var resolvedRed = red ?? defaults.red;
    if (resolvedRed <= resolvedYellow) {
      // Inverted thresholds collapse the yellow band entirely; clamp
      // red just above yellow so the demo override still produces
      // a sensible green/yellow/red ladder.
      resolvedRed = resolvedYellow + 1;
    }
    overrides[metric] = OutboxTripwireThresholds(
      yellow: resolvedYellow,
      red: resolvedRed,
    );
  }

  apply(
    OutboxTripwireMetric.bridgeLagSeconds,
    tripwireBridgeLagYellowEnvVar,
    tripwireBridgeLagRedEnvVar,
  );
  apply(
    OutboxTripwireMetric.undeliveredCount,
    tripwireUndeliveredYellowEnvVar,
    tripwireUndeliveredRedEnvVar,
  );
  apply(
    OutboxTripwireMetric.publishErrorRate,
    tripwirePublishErrorYellowEnvVar,
    tripwirePublishErrorRedEnvVar,
  );
  apply(
    OutboxTripwireMetric.notifyQueueUsage,
    tripwireNotifyQueueYellowEnvVar,
    tripwireNotifyQueueRedEnvVar,
  );

  return overrides.isEmpty ? null : overrides;
}

num? _parsePositiveNum(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final parsed = num.tryParse(trimmed);
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

/// Production binding. Reads the four Q22 metric values through the
/// admin pool's `runAsSystem` (platform-wide aggregate, no
/// per-tenant filter, no tenant identifiers in the response).
class PostgresRealtimeTripwireGateway implements RealtimeTripwireProxyGateway {
  PostgresRealtimeTripwireGateway({
    required TenantTransactionWrapper adminWrapper,
    required DateTime Function() now,
    Map<OutboxTripwireMetric, OutboxTripwireThresholds>? thresholdOverrides,
  })  : _adminWrapper = adminWrapper,
        _now = now,
        _thresholdOverrides = thresholdOverrides;

  final TenantTransactionWrapper _adminWrapper;
  final DateTime Function() _now;
  final Map<OutboxTripwireMetric, OutboxTripwireThresholds>?
      _thresholdOverrides;

  @override
  Future<Map<String, Object?>> fetch() async {
    final inputs = await _readMetrics();
    final result = evaluateOutboxTripwires(inputs);
    return _renderEnvelope(inputs, result, _now().toUtc());
  }

  Future<OutboxTripwireInputs> _readMetrics() async {
    return _adminWrapper.runAsSystem<OutboxTripwireInputs>(
      (exec) async {
        final lagRows = await exec.query(
          'select extract(epoch from (now() - max(picked_up_at)))'
          '::double precision as lag '
          'from public.event_outbox where delivered_at is null',
        );
        final undeliveredRows = await exec.query(
          'select coalesce(count(*), 0)::bigint as cnt '
          'from public.event_outbox where delivered_at is null',
        );
        final publishErrorRows = await exec.query(
          'select coalesce(sum(failed_publish_count), 0)::bigint as failed, '
          'coalesce(sum(attempted_publish_count), 0)::bigint as attempted '
          'from public.event_outbox_publish_metrics '
          "where window_start > now() - interval '5 minutes'",
        );
        final notifyRows = await exec.query(
          'select coalesce(pg_notification_queue_usage(), 0.0)::double precision '
          'as usage',
        );

        final lagRaw = lagRows.isEmpty ? null : lagRows.first['lag'];
        final lag = (lagRaw as num?)?.toDouble() ?? 0.0;
        final undelivered =
            (undeliveredRows.first['cnt'] as num?)?.toInt() ?? 0;
        final failed =
            (publishErrorRows.first['failed'] as num?)?.toInt() ?? 0;
        final attempted =
            (publishErrorRows.first['attempted'] as num?)?.toInt() ?? 0;
        final ratio = attempted == 0 ? 0.0 : failed / attempted;
        final usage = (notifyRows.first['usage'] as num?)?.toDouble() ?? 0.0;

        return OutboxTripwireInputs(
          bridgeLagSeconds: lag,
          undeliveredCount: undelivered,
          publishErrorRate: ratio,
          notifyQueueUsage: usage,
          thresholdOverrides: _thresholdOverrides,
        );
      },
      reason: 'realtime_tripwire_status_fetch',
    );
  }

  Map<String, Object?> _renderEnvelope(
    OutboxTripwireInputs inputs,
    OutboxTripwireResult result,
    DateTime checkedAt,
  ) {
    return renderRealtimeTripwireEnvelope(
      inputs: inputs,
      result: result,
      checkedAt: checkedAt,
    );
  }
}

/// Pure rendering function. Exposed for tests so the route's wire
/// contract can be exercised without a Postgres pool.
Map<String, Object?> renderRealtimeTripwireEnvelope({
  required OutboxTripwireInputs inputs,
  required OutboxTripwireResult result,
  required DateTime checkedAt,
}) {
  final metrics = <String, Object?>{};
  for (final metric in OutboxTripwireMetric.values) {
    final value = inputs.valueFor(metric);
    final thresholds = inputs.thresholdsFor(metric);
    final breach = _findBreach(result.breaches, metric);
    metrics[outboxTripwireMetricKey(metric)] = <String, Object?>{
      'value': value,
      'status': breach == null
          ? (value == null ? 'unknown' : 'green')
          : outboxTripwireStatusKey(breach.severity),
      'thresholds': <String, Object?>{
        'yellow': thresholds.yellow,
        'red': thresholds.red,
      },
    };
  }
  return <String, Object?>{
    'status': outboxTripwireStatusKey(result.status),
    'metrics': metrics,
    'breaches': result.breaches
        .map(
          (b) => <String, Object?>{
            'metric': outboxTripwireMetricKey(b.metric),
            'value': b.value,
            'status': outboxTripwireStatusKey(b.severity),
          },
        )
        .toList(growable: false),
    'checked_at': checkedAt.toUtc().toIso8601String(),
  };
}

OutboxTripwireBreach? _findBreach(
  List<OutboxTripwireBreach> breaches,
  OutboxTripwireMetric metric,
) {
  for (final b in breaches) {
    if (b.metric == metric) return b;
  }
  return null;
}
