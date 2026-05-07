// Phase 10a.0 — Realtime bridge worker.
//
// Wires the durable `event_outbox` table to the in-memory
// `RealtimeEventPublisher` that the WebSocket route fans out from.
// Authority: docs/contracts/event_outbox_contract.md "Consumer
// Contract (Phase 10a)" + docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md.
//
// Pipeline per cycle:
//   1. Wake-up: NOTIFY on `event_outbox` OR 60s scheduled poll tick.
//   2. For each operator with pending work, run inside that operator's
//      tenant context and call EventOutboxRepository.claimBatch(...).
//   3. Phase 10a.2 — partition the claimed rows by
//      `attempt_count > EVENT_OUTBOX_DLQ_CAP`. Rows past the cap MOVE
//      transactionally to `event_outbox_dead_letter` (single CTE so
//      either both writes commit or neither does) and increment the
//      `event_outbox_dead_lettered_total` counter; the publish loop
//      skips them.
//   4. For each remaining claimed row, build a RealtimeEvent
//      (event_id derived from payload['event_id'] when present; falls
//      back to outbox id) and hand to the publisher.
//   5. On publish success → markDelivered(...). On publish failure →
//      log and let the 5-minute lease window reclaim the row. The
//      contract's `attempt_count` / `last_error*` retry ledger lands
//      as a Phase 10a follow-up; the scaffold relies on the lease.
//
// Scope is intentionally minimal — single-shard worker, no concurrency,
// no auto-replay, no retention sweep. Those land in
// the post-V1 lanes alongside the real Cloud Pub/Sub publisher.
//
// Phase 10a.4 — the bridge instruments its publish loop with a
// minute-bucket counter (attempted / failed) and periodically flushes
// deltas to `public.event_outbox_publish_metrics` through the
// injected [RealtimeBridgePublishMetricsWriter]. The proxy `/health`
// `event_outbox_publish_error_rate` producer reads the rolling
// 5-minute sum from that table; tripwire thresholds (yellow ≥ 1 %,
// red ≥ 5 %) live in the producer per Decision 33.
//
// Hard contract reminders:
//   * NOTIFY is wake-up only; the 60s poll is the catch-all for
//     dropped notifications.
//   * Worker MUST claim rows through `EventOutboxRepository.claimBatch`
//     (FOR UPDATE SKIP LOCKED + lease + ORDER BY id ascending).
//   * Worker MUST run inside `runInTenantContext` so the per-tenant
//     RLS policy admits the row.
//   * Phase 10a.2: DLQ logic runs INSIDE the existing claim loop —
//     never in a separate listener. NOTIFY is still wake-up only;
//     the dead-letter MOVE shares the claim transaction's tenant
//     context.
//   * Phase 10a.4: publish-metrics flush runs OUTSIDE the per-
//     operator drain on its own timer, and writes through the admin
//     pool (no tenant context — the metrics table is platform-wide
//     bridge bookkeeping).

import 'dart:async';

import 'package:forge_and_flow/infrastructure/persistence/postgres/outbox_notification_listener.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_dead_letter_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/services/realtime/pubsub_realtime_publisher.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';

/// Resolves a per-operator default `location_id` for the bridge.
/// `EventOutboxRepository.claimBatch(...)` requires a `TenantContext`
/// which carries `location_id`; the claim itself filters only on
/// `operator_id`, but the SET LOCAL bookkeeping needs both.
typedef BridgeLocationResolver = Future<String> Function(String operatorId);

/// Code-Health L8 — invoked on every failed publish so the row's
/// `attempt_count` actually increments. Without this seam the DLQ
/// counter is theatre: `attempt_count` stayed at 0 for the row's
/// entire 7-day retention, so the partition `attempt_count > _dlqCap`
/// never fired and a poison-pill row recycled until retention swept
/// it. Production wires this to a tenant-scoped UPDATE against
/// `event_outbox` (SET attempt_count = attempt_count + 1, last_error
/// = $msg, last_error_at = now(), picked_up_at = NULL); tests inject
/// an in-memory counter that mirrors the same shape.
///
/// Returns the new `attempt_count` AFTER the increment so the bridge
/// can decide whether to MOVE the row to the dead-letter table
/// immediately (without waiting for the next claim cycle to
/// re-discover the row past-cap).
typedef BridgeOutboxFailureMarker = Future<int> Function({
  required String operatorId,
  required String locationId,
  required String eventId,
  required String errorMessage,
});

/// Discovers operators with undelivered `event_outbox` rows. Called
/// at every poll tick so a row enqueued before the bridge came up — or
/// a row whose NOTIFY was dropped under queue pressure — does not get
/// stranded. This is the contract's "real catch-all": polling only
/// the operators that have already notified (the prior shape) is not
/// a catch-all if no notification ever arrived.
typedef BridgeOperatorDiscoverer = Future<Set<String>> Function();

/// Default discoverer. Returns nothing — the bridge then drains only
/// operators learned via NOTIFY or seeded as bootstrap. Callers that
/// want the contract's catch-all behaviour MUST inject a real
/// discoverer (production wires this to a Postgres query against
/// `public.event_outbox` with `delivered_at IS NULL`).
Future<Set<String>> _emptyDiscoverer() async => const <String>{};

/// Phase 10a.4 — one minute-aligned bucket of publish-attempt /
/// publish-failure deltas the bridge worker accumulates between
/// flushes. The writer (production: a `runAsSystem` UPSERT against
/// `public.event_outbox_publish_metrics`) sums these deltas into the
/// matching row keyed by `window_start`.
class RealtimeBridgePublishMetricsBucket {
  const RealtimeBridgePublishMetricsBucket({
    required this.windowStart,
    required this.attemptedDelta,
    required this.failedDelta,
  });

  /// UTC bucket boundary, truncated to the minute.
  final DateTime windowStart;

  /// Publish attempts observed in the window since the last flush.
  /// Always ≥ [failedDelta]: the bridge increments attempted BEFORE
  /// optionally incrementing failed, so per-bucket cumulative
  /// `failed ≤ attempted` always holds (the migration's CHECK
  /// constraint pins this invariant server-side).
  final int attemptedDelta;

  /// Publish failures observed in the window since the last flush.
  final int failedDelta;
}

/// Phase 10a.4 — sink the bridge worker hands flushed bucket deltas
/// to. Production wires this to a `runAsSystem` UPSERT through the
/// admin pool (see `tool/advisor_proxy/main.dart`); tests inject a
/// recording callback. Returning a `Future` lets the writer batch the
/// per-bucket UPSERTs in one transaction.
typedef RealtimeBridgePublishMetricsWriter =
    Future<void> Function(List<RealtimeBridgePublishMetricsBucket> buckets);

/// Phase 10a.4 — default cadence at which the bridge flushes its
/// accumulated publish-metric buckets to the writer. The proxy
/// `/health` `event_outbox_publish_error_rate` producer reads the
/// rolling 5-minute window, so a 30s flush gives at least 10
/// observations per window in steady state — fine-grained enough that
/// a brief publish-failure cluster is visible before the producer's
/// next probe but coarse enough that the bridge's hot path is not
/// dominated by metric writes.
const Duration defaultRealtimeBridgePublishMetricsFlushInterval =
    Duration(seconds: 30);

/// Phase 10a.2 — env flag that caps the bridge's per-row attempt
/// count before a row moves to `event_outbox_dead_letter`. The
/// contract (`docs/contracts/event_outbox_contract.md` "Worker
/// Responsibilities") requires the cap be tunable and ≥ 5; the
/// default below sits at the contract floor so the live queue cannot
/// recycle a permanently-failing row indefinitely.
///
/// Operators raise this in staging when triaging a vendor-side
/// outage that is expected to clear (so genuinely retriable failures
/// stay in-queue) and lower it when the live queue is filling with
/// the same handful of poison-pill rows.
const String eventOutboxDlqCapEnvVar = 'EVENT_OUTBOX_DLQ_CAP';

/// Phase 10a.2 — default cap value when [eventOutboxDlqCapEnvVar] is
/// unset / non-numeric. Matches the contract floor (≥ 5).
const int defaultEventOutboxDlqCap = 5;

/// Phase 10a.2 — resolves [eventOutboxDlqCapEnvVar] from
/// [environment]. Returns [defaultEventOutboxDlqCap] when the env
/// var is missing, blank, or fails integer parsing; refuses caps
/// below 1 (a non-positive cap would auto-DLQ every row on first
/// failure, which destroys the bridge's retry semantics).
int resolveEventOutboxDlqCap(Map<String, String> environment) {
  final raw = environment[eventOutboxDlqCapEnvVar];
  if (raw == null) return defaultEventOutboxDlqCap;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return defaultEventOutboxDlqCap;
  final parsed = int.tryParse(trimmed);
  if (parsed == null) return defaultEventOutboxDlqCap;
  if (parsed < 1) return defaultEventOutboxDlqCap;
  return parsed;
}

class RealtimeBridgeWorker {
  RealtimeBridgeWorker({
    required OutboxNotificationListener listener,
    required EventOutboxRepository outboxRepository,
    required RealtimeEventPublisher publisher,
    required BridgeLocationResolver locationResolver,
    EventOutboxDeadLetterRepository? deadLetterRepository,
    BridgeOperatorDiscoverer? operatorDiscoverer,
    BridgeOutboxFailureMarker? outboxFailureMarker,
    Set<String> bootstrapOperatorIds = const <String>{},
    Duration pollInterval = const Duration(seconds: 60),
    int batchSize = 50,
    int dlqCap = defaultEventOutboxDlqCap,
    RealtimeBridgePublishMetricsWriter? publishMetricsWriter,
    Duration publishMetricsFlushInterval =
        defaultRealtimeBridgePublishMetricsFlushInterval,
    DateTime Function()? clock,
    void Function(RealtimeBridgeLogEvent)? logger,
  }) : _listener = listener,
       _outboxRepository = outboxRepository,
       _deadLetterRepository = deadLetterRepository,
       _publisher = publisher,
       _locationResolver = locationResolver,
       _operatorDiscoverer = operatorDiscoverer ?? _emptyDiscoverer,
       _outboxFailureMarker = outboxFailureMarker,
       _knownOperatorIds = Set<String>.from(bootstrapOperatorIds),
       _pollInterval = pollInterval,
       _batchSize = batchSize,
       _dlqCap = dlqCap < 1 ? defaultEventOutboxDlqCap : dlqCap,
       _publishMetricsWriter = publishMetricsWriter,
       _publishMetricsFlushInterval = publishMetricsFlushInterval,
       _clock = clock ?? _systemClock,
       _logger = logger ?? _noopLogger;

  final OutboxNotificationListener _listener;
  final EventOutboxRepository _outboxRepository;

  /// Phase 10a.2 — repository that writes the live → dead-letter MOVE
  /// transaction. Nullable so existing callers (10a.0 scaffold tests
  /// that predate the DLQ slice, demo wiring without a dead-letter
  /// table) keep working; when null, the bridge falls back to the
  /// pre-DLQ behaviour (lease retry only, no MOVE).
  final EventOutboxDeadLetterRepository? _deadLetterRepository;

  final RealtimeEventPublisher _publisher;
  final BridgeLocationResolver _locationResolver;
  final BridgeOperatorDiscoverer _operatorDiscoverer;

  /// Code-Health L8 — bumps `attempt_count` on every publish failure.
  /// Null preserves the pre-L8 behaviour for callers that have not yet
  /// wired the marker; with the marker null, the bridge logs the
  /// failure but the row's `attempt_count` stays at 0 forever (which
  /// is the documented theatre the L8 lane removed). Production
  /// SHOULD wire this marker; tests inject an in-memory counter.
  final BridgeOutboxFailureMarker? _outboxFailureMarker;
  final Set<String> _knownOperatorIds;
  final Duration _pollInterval;
  final int _batchSize;

  /// Phase 10a.2 — `attempt_count` cap. Claimed rows whose
  /// `attempt_count` is strictly greater than this value MOVE to
  /// `event_outbox_dead_letter` instead of going through the publish
  /// loop. The cap defaults to [defaultEventOutboxDlqCap] when the
  /// caller does not pass one; the constructor clamps non-positive
  /// values back to the default so a misconfigured env var cannot
  /// auto-DLQ every row.
  final int _dlqCap;

  /// Phase 10a.2 — process-local counter that increments by 1 every
  /// time the bridge's MOVE CTE successfully moves a row to
  /// `event_outbox_dead_letter`. Tests assert the counter behaviour
  /// directly and log search can grep
  /// `realtime.bridge.dead_lettered` events. The counter is reset on
  /// worker restart; the authoritative since-restart depth signal is
  /// the proxy `/health` `event_outbox_dlq_depth` metric, which
  /// counts rows in the live DB table, not this in-memory counter.
  int _deadLetteredTotal = 0;

  /// Phase 10a.2 — read-only view of the DLQ counter. Tracks
  /// successful MOVEs since process start; consumed by the bridge's
  /// own log search and by tests. The proxy `/health` envelope's
  /// `event_outbox_dlq_depth` metric is a separate SQL count against
  /// `public.event_outbox_dead_letter`, not this counter — process
  /// restart resets this counter, but the depth metric reflects the
  /// authoritative table state across restarts.
  int get deadLetteredTotal => _deadLetteredTotal;

  /// Phase 10a.2 — read-only view of the configured cap. Tests +
  /// log search read this; per lean cut 2, the V1 surface is logs +
  /// admin SQL only (no operator-facing tile).
  int get dlqCap => _dlqCap;

  /// Phase 10a.4 — writer the bridge hands flushed minute-bucket
  /// publish-metric deltas to. Null in tests / scaffold callers that
  /// don't care about the metrics path; in that case the bridge still
  /// accumulates buckets but the flush timer is never started.
  final RealtimeBridgePublishMetricsWriter? _publishMetricsWriter;

  /// Phase 10a.4 — cadence at which the bridge flushes accumulated
  /// publish-metric buckets to [_publishMetricsWriter]. Tests pass a
  /// short interval; production uses
  /// [defaultRealtimeBridgePublishMetricsFlushInterval].
  final Duration _publishMetricsFlushInterval;

  /// Phase 10a.4 — clock seam so tests can pin the bucket boundary
  /// without depending on wall-clock alignment. Production uses
  /// `DateTime.now().toUtc()`.
  final DateTime Function() _clock;

  /// Phase 10a.4 — accumulator keyed on minute-aligned UTC bucket.
  /// Each entry holds the deltas observed since the last successful
  /// flush; on flush the bridge swaps in a fresh map and hands the
  /// drained snapshot to the writer.
  final Map<DateTime, _PublishMetricsCounter> _publishMetricsBuckets =
      <DateTime, _PublishMetricsCounter>{};

  /// Phase 10a.4 — process-lifetime totals for the publish path.
  /// Tracks all attempts / failures observed since worker start; tests
  /// assert these directly so the bucket-flush mechanics can be
  /// exercised without driving the writer. The /health producer reads
  /// the table, not these counters.
  int _publishAttemptedTotal = 0;
  int _publishFailedTotal = 0;

  /// Phase 10a.4 — read-only view of the publish-attempt counter.
  /// Cumulative since worker start; resets on restart. Only the
  /// table-backed producer survives a restart.
  int get publishAttemptedTotal => _publishAttemptedTotal;

  /// Phase 10a.4 — read-only view of the publish-failure counter.
  int get publishFailedTotal => _publishFailedTotal;

  final void Function(RealtimeBridgeLogEvent) _logger;

  StreamSubscription<OutboxNotification>? _notificationSubscription;
  Timer? _pollTimer;
  Timer? _publishMetricsFlushTimer;
  bool _started = false;

  /// Drained operators waiting on a coalesced run. Notifications coming
  /// in faster than [_drainOperator] can complete are merged into a
  /// single follow-up run rather than queued — a notification is just
  /// a wake-up signal, so coalescing is correct (the next
  /// `claimBatch` picks up everything the operator currently has
  /// pending).
  final Map<String, Future<void>> _pendingDrains = {};

  /// Start the listener and the 60s poll timer. Idempotent.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _listener.start();
    _notificationSubscription = _listener.notifications.listen(
      _handleNotification,
      onError: (Object error, StackTrace stack) {
        _logger(
          RealtimeBridgeLogEvent.listenerError(
            error: error,
            stack: stack,
          ),
        );
      },
    );
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      unawaited(_runPollCycle());
    });
    // Phase 10a.4 — start the publish-metrics flush timer ONLY when a
    // writer is wired. Scaffold callers / demo mode pass null and
    // skip the flush; the bridge still accumulates buckets in memory
    // (cheap) but never tries to write them, so a missing admin pool
    // cannot block the bridge from starting.
    if (_publishMetricsWriter != null) {
      _publishMetricsFlushTimer = Timer.periodic(
        _publishMetricsFlushInterval,
        (_) => unawaited(_flushPublishMetrics()),
      );
    }
    // Bootstrap: discover any operators with undelivered rows and
    // drain them. Without the discovery step, rows enqueued before
    // the bridge came up — and rows belonging to operators that have
    // never notified during this process's lifetime — would be
    // stranded until a NOTIFY happens to land. The contract requires
    // the poll/bootstrap to be a real catch-all.
    unawaited(_runPollCycle());
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _publishMetricsFlushTimer?.cancel();
    _publishMetricsFlushTimer = null;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _listener.stop();
    // Wait for in-flight drains to finish so callers can rely on
    // "stopped" meaning no more publishes.
    await Future.wait(_pendingDrains.values);
    // Phase 10a.4 — final flush so a graceful stop does not lose the
    // last bucket of deltas. Nothing else can mutate
    // `_publishMetricsBuckets` after the drains have settled, so
    // racing with a publisher is impossible at this point.
    if (_publishMetricsWriter != null) {
      await _flushPublishMetrics();
    }
    _started = false;
  }

  void _handleNotification(OutboxNotification notification) {
    _knownOperatorIds.add(notification.operatorId);
    unawaited(_drainOperator(notification.operatorId));
  }

  /// One full poll/bootstrap cycle: discover operators with pending
  /// rows (production wires this to a Postgres query against
  /// `event_outbox` filtering on `delivered_at IS NULL`), merge them
  /// into the known set, then drain every known operator. A
  /// discoverer failure does not block the cycle — the bridge still
  /// drains the operators it already knows about so a transient
  /// admin-pool blip cannot strand notification-driven traffic.
  Future<void> _runPollCycle() async {
    try {
      final discovered = await _operatorDiscoverer();
      _knownOperatorIds.addAll(discovered);
    } catch (error, stack) {
      _logger(
        RealtimeBridgeLogEvent.discoveryFailed(
          error: error,
          stack: stack,
        ),
      );
    }
    await _drainAllKnownOperators();
  }

  Future<void> _drainAllKnownOperators() async {
    // Snapshot so a notification adding to the set mid-loop does not
    // mutate it while we iterate.
    final operators = List<String>.from(_knownOperatorIds);
    for (final operatorId in operators) {
      await _drainOperator(operatorId);
    }
  }

  /// Coalesce concurrent calls for the same operator: the second call
  /// awaits the in-flight drain instead of starting a parallel
  /// `claimBatch`. Two parallel claims for the same operator would
  /// race on FOR UPDATE SKIP LOCKED — the second would skip every
  /// locked row and return an empty batch, wasting a round-trip.
  Future<void> _drainOperator(String operatorId) {
    final inFlight = _pendingDrains[operatorId];
    if (inFlight != null) return inFlight;
    final future = _drainOperatorInner(operatorId)
        .whenComplete(() => _pendingDrains.remove(operatorId));
    _pendingDrains[operatorId] = future;
    return future;
  }

  Future<void> _drainOperatorInner(String operatorId) async {
    String locationId;
    try {
      locationId = await _locationResolver(operatorId);
    } catch (error, stack) {
      _logger(
        RealtimeBridgeLogEvent.locationResolveFailed(
          operatorId: operatorId,
          error: error,
          stack: stack,
        ),
      );
      return;
    }

    List<EventOutboxClaimedRow> claimed;
    try {
      claimed = await _outboxRepository.claimBatch(
        operatorId: operatorId,
        locationId: locationId,
        batchSize: _batchSize,
      );
    } catch (error, stack) {
      _logger(
        RealtimeBridgeLogEvent.claimFailed(
          operatorId: operatorId,
          error: error,
          stack: stack,
        ),
      );
      return;
    }

    // Phase 10a.2 — partition the claimed rows by attempt_count >
    // `_dlqCap`. Rows past the cap MOVE transactionally to
    // `event_outbox_dead_letter` and the publish loop skips them; the
    // remaining rows go through the publish + markDelivered path
    // unchanged. The MOVE happens BEFORE any publish call so a poison-
    // pill row cannot pop a publisher-side timeout / exception that
    // delays moving it out of the live queue. When no
    // `_deadLetterRepository` is wired (existing callers / demo
    // mode), the partition is a no-op and the original publish path
    // runs exactly as before.
    final List<EventOutboxClaimedRow> publishable;
    if (_deadLetterRepository != null) {
      final overCap = <EventOutboxClaimedRow>[];
      final keep = <EventOutboxClaimedRow>[];
      for (final row in claimed) {
        if (row.attemptCount > _dlqCap) {
          overCap.add(row);
        } else {
          keep.add(row);
        }
      }
      for (final row in overCap) {
        try {
          final movedId = await _deadLetterRepository.moveFromOutbox(
            operatorId: operatorId,
            locationId: locationId,
            eventId: row.id,
            attemptCountThreshold: _dlqCap,
          );
          if (movedId != null) {
            _deadLetteredTotal += 1;
            _logger(
              RealtimeBridgeLogEvent.deadLettered(
                operatorId: operatorId,
                outboxId: row.id,
                topic: row.topic,
                attemptCount: row.attemptCount,
                cap: _dlqCap,
              ),
            );
          }
          // movedId == null means the predicate filtered the row out
          // (already moved by another shard, or attempt_count not
          // actually past the cap) — skip silently; the row is no
          // longer in the live queue from this worker's perspective.
        } catch (error, stack) {
          _logger(
            RealtimeBridgeLogEvent.deadLetterMoveFailed(
              operatorId: operatorId,
              outboxId: row.id,
              topic: row.topic,
              attemptCount: row.attemptCount,
              cap: _dlqCap,
              error: error,
              stack: stack,
            ),
          );
          // The MOVE failed — leave the row in the live queue and let
          // the next claim cycle re-attempt the partition. The lease
          // window will release the claim so another shard can pick
          // the row up. The publish loop intentionally does NOT touch
          // a row that should have moved (publishing a known-poison
          // row spams subscribers with a payload the bridge already
          // gave up on).
        }
      }
      publishable = keep;
    } else {
      publishable = claimed;
    }

    for (final row in publishable) {
      final event = _toRealtimeEvent(row);
      // Phase 10a.4 — record the attempt BEFORE the publish call so a
      // throwing publisher still increments the attempt counter (the
      // ratio's denominator). Truncating the bucket inside the
      // recorder so the same bucket key is shared with the failure
      // increment that may follow inside the catch.
      final bucket = _publishMetricsBucketFor(_clock());
      _recordPublishAttempted(bucket);
      try {
        await _publisher.publish(event);
      } catch (error, stack) {
        _recordPublishFailed(bucket);
        _logger(
          RealtimeBridgeLogEvent.publishFailed(
            operatorId: operatorId,
            outboxId: row.id,
            topic: row.topic,
            error: error,
            stack: stack,
          ),
        );
        // Code-Health L8 — bump `attempt_count` on the row so the
        // partition `attempt_count >= _dlqCap` actually fires the
        // DLQ MOVE eventually. Without this call, the row's
        // `attempt_count` stayed at 0 forever and the lease window
        // would recycle the row until 7-day retention swept it.
        await _markPublishFailureAndMaybeDlq(
          operatorId: operatorId,
          locationId: locationId,
          row: row,
          error: error,
        );
        // Lease-based retry: the row stays unmarked-as-delivered, so
        // the next claim cycle (after `claimReclaimAfter`, default 5
        // min) will pick it up — UNLESS the marker just MOVEd it to
        // DLQ above. Phase 10a.2 caps the lease's recycle loop at
        // `_dlqCap` attempts via the claim-time partition; L8 closes
        // the gap that let attempt_count stay at 0 indefinitely.
        continue;
      }
      try {
        await _outboxRepository.markDelivered(
          operatorId: operatorId,
          locationId: locationId,
          eventId: row.id,
        );
      } catch (error, stack) {
        _logger(
          RealtimeBridgeLogEvent.markDeliveredFailed(
            operatorId: operatorId,
            outboxId: row.id,
            topic: row.topic,
            error: error,
            stack: stack,
          ),
        );
        // The publish already succeeded — the consumer got the event.
        // The unsealed row will be re-claimed and re-published once
        // the lease expires. Consumers dedupe via `event_id`; the
        // contract acknowledges this at-least-once shape.
      }
    }
  }

  /// Code-Health L8 — bump `attempt_count` on the failing row and, if
  /// the new count is at or past the configured cap, MOVE the row to
  /// `event_outbox_dead_letter` immediately (rather than waiting for
  /// the next claim cycle). Both writes are best-effort: a marker
  /// failure is logged and the row is left to the lease's recycle
  /// path; a MOVE failure is logged via the existing
  /// `deadLetterMoveFailed` event so log search still surfaces it.
  Future<void> _markPublishFailureAndMaybeDlq({
    required String operatorId,
    required String locationId,
    required EventOutboxClaimedRow row,
    required Object error,
  }) async {
    final marker = _outboxFailureMarker;
    if (marker == null) return;
    final errorMessage = _truncateError(error.toString());
    int newAttemptCount;
    try {
      newAttemptCount = await marker(
        operatorId: operatorId,
        locationId: locationId,
        eventId: row.id,
        errorMessage: errorMessage,
      );
    } catch (markErr, markStack) {
      _logger(
        RealtimeBridgeLogEvent.publishFailed(
          operatorId: operatorId,
          outboxId: row.id,
          topic: row.topic,
          error: markErr,
          stack: markStack,
        ),
      );
      return;
    }

    // Inline DLQ MOVE when the increment crossed the cap. The MOVE
    // CTE's own `attempt_count > @threshold` predicate is the
    // server-side check, so we pass `_dlqCap - 1` here so the new
    // count of `_dlqCap` qualifies (`_dlqCap > _dlqCap - 1`). The
    // claim-time partition keeps its existing strictly-greater-than
    // semantics for backward compat with rows that were already
    // past-cap before the L8 fix landed.
    if (newAttemptCount < _dlqCap) return;
    final dlq = _deadLetterRepository;
    if (dlq == null) return;
    try {
      final movedId = await dlq.moveFromOutbox(
        operatorId: operatorId,
        locationId: locationId,
        eventId: row.id,
        attemptCountThreshold: _dlqCap - 1,
      );
      if (movedId != null) {
        _deadLetteredTotal += 1;
        _logger(
          RealtimeBridgeLogEvent.deadLettered(
            operatorId: operatorId,
            outboxId: row.id,
            topic: row.topic,
            attemptCount: newAttemptCount,
            cap: _dlqCap,
          ),
        );
      }
    } catch (moveErr, moveStack) {
      _logger(
        RealtimeBridgeLogEvent.deadLetterMoveFailed(
          operatorId: operatorId,
          outboxId: row.id,
          topic: row.topic,
          attemptCount: newAttemptCount,
          cap: _dlqCap,
          error: moveErr,
          stack: moveStack,
        ),
      );
    }
  }

  /// Bound the marker's `last_error` payload so a misbehaving
  /// publisher cannot push a megabyte stack trace into the queue
  /// row. The migration's CHECK constraint admits up to 4096 chars
  /// on `event_outbox.last_error`; this truncation matches the
  /// pattern in `RetryCappingBackfillJobStore._truncateForLastError`.
  static String _truncateError(String raw) {
    const maxLen = 1024;
    return raw.length <= maxLen ? raw : raw.substring(0, maxLen);
  }

  /// Phase 10a.4 — truncate `now` to the start of its UTC minute so
  /// every event observed inside that 60-second window lands in the
  /// same bucket regardless of when within the second the publisher
  /// was called.
  DateTime _publishMetricsBucketFor(DateTime now) {
    final utc = now.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day, utc.hour, utc.minute);
  }

  void _recordPublishAttempted(DateTime bucket) {
    _publishAttemptedTotal += 1;
    _publishMetricsBuckets
        .putIfAbsent(bucket, _PublishMetricsCounter.new)
        .attempted += 1;
  }

  void _recordPublishFailed(DateTime bucket) {
    _publishFailedTotal += 1;
    _publishMetricsBuckets
        .putIfAbsent(bucket, _PublishMetricsCounter.new)
        .failed += 1;
  }

  /// Phase 10a.4 — drain the bucket map and hand the deltas to
  /// [_publishMetricsWriter]. On writer failure the deltas are merged
  /// back into the live map so the next flush retries; restart-loss
  /// is bounded by the flush interval. Concurrent flushes are
  /// prevented by a flight guard — the periodic timer cannot start a
  /// second flush while one is already running, which keeps the
  /// snapshot semantics clean.
  bool _publishMetricsFlushInFlight = false;

  Future<void> _flushPublishMetrics() async {
    final writer = _publishMetricsWriter;
    if (writer == null) return;
    if (_publishMetricsFlushInFlight) return;
    if (_publishMetricsBuckets.isEmpty) return;
    _publishMetricsFlushInFlight = true;
    final snapshot =
        Map<DateTime, _PublishMetricsCounter>.from(_publishMetricsBuckets);
    _publishMetricsBuckets.clear();
    try {
      final buckets = snapshot.entries
          .map(
            (e) => RealtimeBridgePublishMetricsBucket(
              windowStart: e.key,
              attemptedDelta: e.value.attempted,
              failedDelta: e.value.failed,
            ),
          )
          .toList(growable: false);
      await writer(buckets);
    } catch (error, stack) {
      // Merge the snapshot back so the next flush retries the
      // unwritten deltas. New deltas accumulated since the snapshot
      // are ADDED on top so concurrent publishes don't lose count.
      snapshot.forEach((bucket, counter) {
        final live = _publishMetricsBuckets.putIfAbsent(
          bucket,
          _PublishMetricsCounter.new,
        );
        live.attempted += counter.attempted;
        live.failed += counter.failed;
      });
      _logger(
        RealtimeBridgeLogEvent.publishMetricsFlushFailed(
          error: error,
          stack: stack,
        ),
      );
    } finally {
      _publishMetricsFlushInFlight = false;
    }
  }

  RealtimeEvent _toRealtimeEvent(EventOutboxClaimedRow row) {
    final payloadEventId = row.payload['event_id'];
    final eventId = (payloadEventId is String && payloadEventId.isNotEmpty)
        ? payloadEventId
        : row.id;
    final payloadOccurredAt = row.payload['occurred_at'];
    DateTime occurredAt;
    if (payloadOccurredAt is String && payloadOccurredAt.isNotEmpty) {
      try {
        occurredAt = DateTime.parse(payloadOccurredAt).toUtc();
      } catch (_) {
        occurredAt = row.createdAt.toUtc();
      }
    } else {
      occurredAt = row.createdAt.toUtc();
    }
    return RealtimeEvent(
      eventId: eventId,
      topic: row.topic,
      operatorId: row.operatorId,
      occurredAt: occurredAt,
      payload: row.payload,
    );
  }
}

/// Structured log event emitted by [RealtimeBridgeWorker]. The proxy
/// wires this to the structured log() helper in production; tests
/// inspect the event list directly.
class RealtimeBridgeLogEvent {
  const RealtimeBridgeLogEvent._({
    required this.kind,
    this.operatorId,
    this.outboxId,
    this.topic,
    this.attemptCount,
    this.cap,
    this.error,
    this.stack,
  });

  factory RealtimeBridgeLogEvent.listenerError({
    required Object error,
    required StackTrace stack,
  }) => RealtimeBridgeLogEvent._(
    kind: RealtimeBridgeLogKind.listenerError,
    error: error,
    stack: stack,
  );

  factory RealtimeBridgeLogEvent.discoveryFailed({
    required Object error,
    required StackTrace stack,
  }) => RealtimeBridgeLogEvent._(
    kind: RealtimeBridgeLogKind.discoveryFailed,
    error: error,
    stack: stack,
  );

  factory RealtimeBridgeLogEvent.locationResolveFailed({
    required String operatorId,
    required Object error,
    required StackTrace stack,
  }) => RealtimeBridgeLogEvent._(
    kind: RealtimeBridgeLogKind.locationResolveFailed,
    operatorId: operatorId,
    error: error,
    stack: stack,
  );

  factory RealtimeBridgeLogEvent.claimFailed({
    required String operatorId,
    required Object error,
    required StackTrace stack,
  }) => RealtimeBridgeLogEvent._(
    kind: RealtimeBridgeLogKind.claimFailed,
    operatorId: operatorId,
    error: error,
    stack: stack,
  );

  factory RealtimeBridgeLogEvent.publishFailed({
    required String operatorId,
    required String outboxId,
    required String topic,
    required Object error,
    required StackTrace stack,
  }) => RealtimeBridgeLogEvent._(
    kind: RealtimeBridgeLogKind.publishFailed,
    operatorId: operatorId,
    outboxId: outboxId,
    topic: topic,
    error: error,
    stack: stack,
  );

  factory RealtimeBridgeLogEvent.markDeliveredFailed({
    required String operatorId,
    required String outboxId,
    required String topic,
    required Object error,
    required StackTrace stack,
  }) => RealtimeBridgeLogEvent._(
    kind: RealtimeBridgeLogKind.markDeliveredFailed,
    operatorId: operatorId,
    outboxId: outboxId,
    topic: topic,
    error: error,
    stack: stack,
  );

  /// Phase 10a.2 — emitted after the bridge successfully MOVEs a row
  /// to `event_outbox_dead_letter`. Carries the attempt_count + cap
  /// so the F&F-internal log search can correlate which rows are
  /// hitting the cap and how often.
  factory RealtimeBridgeLogEvent.deadLettered({
    required String operatorId,
    required String outboxId,
    required String topic,
    required int attemptCount,
    required int cap,
  }) => RealtimeBridgeLogEvent._(
    kind: RealtimeBridgeLogKind.deadLettered,
    operatorId: operatorId,
    outboxId: outboxId,
    topic: topic,
    attemptCount: attemptCount,
    cap: cap,
  );

  /// Phase 10a.2 — emitted when the dead-letter MOVE fails (DB error
  /// during the transactional CTE). The row stays in the live queue
  /// and the next claim cycle re-attempts the partition + MOVE.
  factory RealtimeBridgeLogEvent.deadLetterMoveFailed({
    required String operatorId,
    required String outboxId,
    required String topic,
    required int attemptCount,
    required int cap,
    required Object error,
    required StackTrace stack,
  }) => RealtimeBridgeLogEvent._(
    kind: RealtimeBridgeLogKind.deadLetterMoveFailed,
    operatorId: operatorId,
    outboxId: outboxId,
    topic: topic,
    attemptCount: attemptCount,
    cap: cap,
    error: error,
    stack: stack,
  );

  /// Phase 10a.4 — emitted when the publish-metrics writer throws.
  /// The bridge merges the unwritten deltas back into the live map
  /// and retries on the next flush; this event lets log search alarm
  /// when the producer's `event_outbox_publish_error_rate` metric is
  /// stale because the writer (not the producer) is broken.
  factory RealtimeBridgeLogEvent.publishMetricsFlushFailed({
    required Object error,
    required StackTrace stack,
  }) => RealtimeBridgeLogEvent._(
    kind: RealtimeBridgeLogKind.publishMetricsFlushFailed,
    error: error,
    stack: stack,
  );

  final RealtimeBridgeLogKind kind;
  final String? operatorId;
  final String? outboxId;
  final String? topic;

  /// Phase 10a.2 — set on `deadLettered` and `deadLetterMoveFailed`
  /// events so log readers can see how far past the cap a poison-pill
  /// row went. Null for other kinds.
  final int? attemptCount;

  /// Phase 10a.2 — set on `deadLettered` and `deadLetterMoveFailed`
  /// events; the cap that was active when the bridge made the
  /// decision. Lets log readers correlate cap changes (env var bumps)
  /// with DLQ-rate changes. Null for other kinds.
  final int? cap;

  final Object? error;
  final StackTrace? stack;
}

enum RealtimeBridgeLogKind {
  listenerError,
  discoveryFailed,
  locationResolveFailed,
  claimFailed,
  publishFailed,
  markDeliveredFailed,
  // Phase 10a.2 — DLQ MOVE outcomes.
  deadLettered,
  deadLetterMoveFailed,
  // Phase 10a.4 — publish-metrics writer failed.
  publishMetricsFlushFailed,
}

void _noopLogger(RealtimeBridgeLogEvent event) {}

/// Phase 10a.4 — system clock used by the bridge worker when a test
/// does not pin the clock seam. Returns UTC so the bucket truncation
/// in `_publishMetricsBucketFor` is locale-independent.
DateTime _systemClock() => DateTime.now().toUtc();

/// Phase 10a.4 — mutable counter pair behind each minute bucket in
/// the bridge's accumulator map. Private to the file because callers
/// only ever see the immutable [RealtimeBridgePublishMetricsBucket]
/// snapshot the writer receives.
class _PublishMetricsCounter {
  int attempted = 0;
  int failed = 0;
}

/// Phase 10a.1 - env flag that swaps the bridge's outbound publisher
/// to the Cloud Pub/Sub adapter. Default off; in-process binding
/// remains the demo/local default per Hard Promise #2.
const String pubsubRealtimeEnabledEnvVar = 'PUBSUB_REALTIME_ENABLED';

/// Phase 10a.1 - selects the [RealtimeEventPublisher] the bridge
/// worker should hand claimed `event_outbox` rows to. The default is
/// the existing 10a.0 [InProcessRealtimePublisher] (same single-
/// instance fan-out semantics); setting [pubsubRealtimeEnabledEnvVar]
/// to `true`, `1`, or `yes` swaps in [PubsubRealtimePublisher] without
/// touching the bridge worker, the WebSocket route, or the client
/// `RealtimeSubscription`. Only the implementation behind the seam
/// changes.
///
/// The Pub/Sub adapter validates every locked topic namespace at
/// construction (see [PubsubRealtimePublisher]); a misconfigured
/// resolver fails the bridge's startup rather than silently dropping
/// events. That keeps the swap fail-closed.
RealtimeEventPublisher selectRealtimePublisher({
  required Map<String, String> environment,
  required InProcessRealtimePublisher inProcessPublisher,
  required PubsubMessagePublisher pubsubMessagePublisher,
  PubsubTopicNameResolver? topicNameResolver,
  Set<String> lockedNamespaces = defaultLockedNamespaces,
  void Function(PubsubRealtimePublisherLogEvent)? pubsubLogger,
}) {
  if (!_isPubsubRealtimeEnabled(environment)) {
    return inProcessPublisher;
  }
  return PubsubRealtimePublisher(
    messagePublisher: pubsubMessagePublisher,
    topicNameResolver: topicNameResolver,
    lockedNamespaces: lockedNamespaces,
    logger: pubsubLogger,
  );
}

bool _isPubsubRealtimeEnabled(Map<String, String> environment) {
  final raw = environment[pubsubRealtimeEnabledEnvVar];
  if (raw == null) return false;
  final lower = raw.trim().toLowerCase();
  return lower == 'true' || lower == '1' || lower == 'yes';
}
