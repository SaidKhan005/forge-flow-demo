// Phase 10a.4 — yellow/red tripwires for the realtime bridge.
//
// Pure function over the four Q22-locked metrics that gate the
// `event_outbox` → Pub/Sub → WebSocket bridge. The evaluator is
// deliberately decoupled from the producer envelope so:
//
//   * the proxy's `/v1/realtime/tripwire-status` route can fan out to
//     the four producers, pack their numeric values into typed
//     [OutboxTripwireInputs], and call [evaluateOutboxTripwires]
//     without re-walking the full `/health` envelope, and
//   * widget tests can drive the admin observability section + the
//     degraded sync badge through canned [OutboxTripwireInputs]
//     without spinning up the producer infrastructure.
//
// Q22-locked thresholds (Decision 33 in
// `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`):
//
//   * `event_outbox_bridge_lag_seconds`     — yellow > 60s,    red > 300s
//   * `event_outbox_undelivered_count`      — yellow > 10 000, red > 100 000
//   * `event_outbox_publish_error_rate`     — yellow > 0.01,   red > 0.05
//   * `pg_notification_queue_usage`         — yellow ≥ 0.10,   red ≥ 0.25
//
// The thresholds are stored as constants but the evaluator accepts an
// override map keyed by [OutboxTripwireMetric] so the demo
// walkthrough (`docs/archive/_walkthroughs/10a.4.md`) can force a metric into
// the red band via env-var overrides without modifying the locked
// production thresholds. Production callers pass `overrides: null`
// which collapses to the locked Q22 values.
//
// The file stays free of `dart:io` / `sqflite` imports so the badge
// path that calls into the evaluator from `lib/main_operator_web.dart`
// stays reachable on Flutter Web.

/// One of the four metrics tracked by the Q22 tripwire family.
enum OutboxTripwireMetric {
  bridgeLagSeconds,
  undeliveredCount,
  publishErrorRate,
  notifyQueueUsage,
}

/// Stable wire identifier for a metric. Used as the key in admin /
/// route JSON payloads so the UX can render rows without doing a
/// switch on the enum at every layer.
String outboxTripwireMetricKey(OutboxTripwireMetric metric) {
  switch (metric) {
    case OutboxTripwireMetric.bridgeLagSeconds:
      return 'event_outbox_bridge_lag_seconds';
    case OutboxTripwireMetric.undeliveredCount:
      return 'event_outbox_undelivered_count';
    case OutboxTripwireMetric.publishErrorRate:
      return 'event_outbox_publish_error_rate';
    case OutboxTripwireMetric.notifyQueueUsage:
      return 'pg_notification_queue_usage';
  }
}

/// Operator-facing label for a metric. Plain English per the project's
/// UX-writing standard — no engineering jargon.
String outboxTripwireMetricLabel(OutboxTripwireMetric metric) {
  switch (metric) {
    case OutboxTripwireMetric.bridgeLagSeconds:
      return 'Bridge lag';
    case OutboxTripwireMetric.undeliveredCount:
      return 'Undelivered events';
    case OutboxTripwireMetric.publishErrorRate:
      return 'Publish error rate';
    case OutboxTripwireMetric.notifyQueueUsage:
      return 'Notify queue usage';
  }
}

/// Tripwire severity. Mirrors the producer envelope's `green / yellow
/// / red` vocabulary so the route can stamp the same string back into
/// the response body without translating in two places.
enum OutboxTripwireStatus { green, yellow, red }

String outboxTripwireStatusKey(OutboxTripwireStatus status) {
  switch (status) {
    case OutboxTripwireStatus.green:
      return 'green';
    case OutboxTripwireStatus.yellow:
      return 'yellow';
    case OutboxTripwireStatus.red:
      return 'red';
  }
}

/// Q22-locked default thresholds for one metric. The unit follows the
/// metric (seconds / count / ratio) — the field is named generically
/// so the same shape carries every metric.
class OutboxTripwireThresholds {
  const OutboxTripwireThresholds({required this.yellow, required this.red});

  final num yellow;
  final num red;
}

/// Q22 lock — must NOT be modified outside of a future Q22 amendment
/// in `phase_9_scalability_decisions_*.md`. Demo callers override at
/// the input layer; the constants stay authoritative.
const Map<OutboxTripwireMetric, OutboxTripwireThresholds>
kOutboxTripwireDefaultThresholds = <OutboxTripwireMetric,
    OutboxTripwireThresholds>{
  OutboxTripwireMetric.bridgeLagSeconds: OutboxTripwireThresholds(
    yellow: 60,
    red: 300,
  ),
  OutboxTripwireMetric.undeliveredCount: OutboxTripwireThresholds(
    yellow: 10000,
    red: 100000,
  ),
  OutboxTripwireMetric.publishErrorRate: OutboxTripwireThresholds(
    yellow: 0.01,
    red: 0.05,
  ),
  OutboxTripwireMetric.notifyQueueUsage: OutboxTripwireThresholds(
    yellow: 0.10,
    red: 0.25,
  ),
};

/// Inputs the evaluator consumes. Every numeric field is nullable so
/// the route can pass `null` when the upstream producer projected its
/// metric to the `unknown` placeholder (e.g. timeout, query error).
/// Null values short-circuit to green for that single metric — the
/// `unknown` warning surfaces separately in the producer envelope and
/// the admin tile, and a stuck-at-unknown metric must not by itself
/// flip the bridge into degraded state.
class OutboxTripwireInputs {
  const OutboxTripwireInputs({
    required this.bridgeLagSeconds,
    required this.undeliveredCount,
    required this.publishErrorRate,
    required this.notifyQueueUsage,
    this.thresholdOverrides,
  });

  final num? bridgeLagSeconds;
  final num? undeliveredCount;
  final num? publishErrorRate;
  final num? notifyQueueUsage;

  /// Optional per-metric threshold overrides. Used by the
  /// 10a.4 walkthrough's env-var demo to force a metric into red
  /// without manipulating production data. When `null`, every metric
  /// uses [kOutboxTripwireDefaultThresholds].
  final Map<OutboxTripwireMetric, OutboxTripwireThresholds>?
      thresholdOverrides;

  num? valueFor(OutboxTripwireMetric metric) {
    switch (metric) {
      case OutboxTripwireMetric.bridgeLagSeconds:
        return bridgeLagSeconds;
      case OutboxTripwireMetric.undeliveredCount:
        return undeliveredCount;
      case OutboxTripwireMetric.publishErrorRate:
        return publishErrorRate;
      case OutboxTripwireMetric.notifyQueueUsage:
        return notifyQueueUsage;
    }
  }

  OutboxTripwireThresholds thresholdsFor(OutboxTripwireMetric metric) {
    final override = thresholdOverrides?[metric];
    if (override != null) return override;
    return kOutboxTripwireDefaultThresholds[metric]!;
  }
}

/// One metric breach. Carries everything the admin tile + route JSON
/// need to render without re-querying the evaluator.
class OutboxTripwireBreach {
  const OutboxTripwireBreach({
    required this.metric,
    required this.value,
    required this.thresholds,
    required this.severity,
  });

  final OutboxTripwireMetric metric;
  final num value;
  final OutboxTripwireThresholds thresholds;
  final OutboxTripwireStatus severity;
}

/// Full evaluator result.
class OutboxTripwireResult {
  const OutboxTripwireResult({required this.status, required this.breaches});

  /// Worst severity across all metrics. `green` when zero breaches.
  final OutboxTripwireStatus status;

  /// Every metric that fired yellow or red. Green metrics are not
  /// listed — the admin section reads the active producer envelope
  /// directly to render the green rows alongside, so the breach list
  /// stays tightly scoped to "what tripped".
  final List<OutboxTripwireBreach> breaches;
}

OutboxTripwireStatus _classify(
  num value,
  OutboxTripwireThresholds thresholds,
  OutboxTripwireMetric metric,
) {
  // Q22 lock pins notify_queue_usage at "≥ 0.10 / ≥ 0.25" while the
  // other three metrics are "> yellow / > red". The classification
  // mirrors that asymmetry so the boundary values fire correctly.
  if (metric == OutboxTripwireMetric.notifyQueueUsage) {
    if (value >= thresholds.red) return OutboxTripwireStatus.red;
    if (value >= thresholds.yellow) return OutboxTripwireStatus.yellow;
    return OutboxTripwireStatus.green;
  }
  if (value > thresholds.red) return OutboxTripwireStatus.red;
  if (value > thresholds.yellow) return OutboxTripwireStatus.yellow;
  return OutboxTripwireStatus.green;
}

OutboxTripwireStatus _worst(
  OutboxTripwireStatus a,
  OutboxTripwireStatus b,
) {
  if (a == OutboxTripwireStatus.red || b == OutboxTripwireStatus.red) {
    return OutboxTripwireStatus.red;
  }
  if (a == OutboxTripwireStatus.yellow || b == OutboxTripwireStatus.yellow) {
    return OutboxTripwireStatus.yellow;
  }
  return OutboxTripwireStatus.green;
}

/// Evaluate every metric against its thresholds. Pure function; safe
/// to call from server route handlers, widget tests, and demo
/// walkthroughs alike.
OutboxTripwireResult evaluateOutboxTripwires(OutboxTripwireInputs inputs) {
  final breaches = <OutboxTripwireBreach>[];
  var worst = OutboxTripwireStatus.green;
  for (final metric in OutboxTripwireMetric.values) {
    final value = inputs.valueFor(metric);
    if (value == null) continue;
    final thresholds = inputs.thresholdsFor(metric);
    final severity = _classify(value, thresholds, metric);
    if (severity != OutboxTripwireStatus.green) {
      breaches.add(
        OutboxTripwireBreach(
          metric: metric,
          value: value,
          thresholds: thresholds,
          severity: severity,
        ),
      );
    }
    worst = _worst(worst, severity);
  }
  return OutboxTripwireResult(status: worst, breaches: breaches);
}
