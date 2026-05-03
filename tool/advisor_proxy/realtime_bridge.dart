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
// no auto-replay, no tripwires, no retention sweep. Those land in
// the post-V1 lanes alongside the real Cloud Pub/Sub publisher.
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
    Set<String> bootstrapOperatorIds = const <String>{},
    Duration pollInterval = const Duration(seconds: 60),
    int batchSize = 50,
    int dlqCap = defaultEventOutboxDlqCap,
    void Function(RealtimeBridgeLogEvent)? logger,
  }) : _listener = listener,
       _outboxRepository = outboxRepository,
       _deadLetterRepository = deadLetterRepository,
       _publisher = publisher,
       _locationResolver = locationResolver,
       _operatorDiscoverer = operatorDiscoverer ?? _emptyDiscoverer,
       _knownOperatorIds = Set<String>.from(bootstrapOperatorIds),
       _pollInterval = pollInterval,
       _batchSize = batchSize,
       _dlqCap = dlqCap < 1 ? defaultEventOutboxDlqCap : dlqCap,
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

  final void Function(RealtimeBridgeLogEvent) _logger;

  StreamSubscription<OutboxNotification>? _notificationSubscription;
  Timer? _pollTimer;
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
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _listener.stop();
    // Wait for in-flight drains to finish so callers can rely on
    // "stopped" meaning no more publishes.
    await Future.wait(_pendingDrains.values);
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
      try {
        await _publisher.publish(event);
      } catch (error, stack) {
        _logger(
          RealtimeBridgeLogEvent.publishFailed(
            operatorId: operatorId,
            outboxId: row.id,
            topic: row.topic,
            error: error,
            stack: stack,
          ),
        );
        // Lease-based retry: the row stays unmarked, so the next
        // claim cycle (after `claimReclaimAfter`, default 5 min) will
        // pick it up. The `attempt_count` / `last_error*` retry
        // ledger is documented as a Phase 10a follow-up — this
        // scaffold uses the lease only. Phase 10a.2 caps the lease's
        // recycle loop at `_dlqCap` attempts via the partition above.
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
}

void _noopLogger(RealtimeBridgeLogEvent event) {}

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
