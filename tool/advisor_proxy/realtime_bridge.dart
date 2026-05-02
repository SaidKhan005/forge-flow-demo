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
//   3. For each claimed row, build a RealtimeEvent (event_id derived
//      from payload['event_id'] when present; falls back to outbox
//      id) and hand to the publisher.
//   4. On publish success → markDelivered(...). On publish failure →
//      log and let the 5-minute lease window reclaim the row. The
//      contract's `attempt_count` / `last_error*` retry ledger lands
//      as a Phase 10a follow-up; the scaffold relies on the lease.
//
// Scope is intentionally minimal — single-shard worker, no concurrency,
// no dead-letter, no tripwires, no retention sweep. Those land in the
// Phase 10a follow-up alongside the real Cloud Pub/Sub publisher.
//
// Hard contract reminders:
//   * NOTIFY is wake-up only; the 60s poll is the catch-all for
//     dropped notifications.
//   * Worker MUST claim rows through `EventOutboxRepository.claimBatch`
//     (FOR UPDATE SKIP LOCKED + lease + ORDER BY id ascending).
//   * Worker MUST run inside `runInTenantContext` so the per-tenant
//     RLS policy admits the row.

import 'dart:async';

import 'package:forge_and_flow/infrastructure/persistence/postgres/outbox_notification_listener.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
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

class RealtimeBridgeWorker {
  RealtimeBridgeWorker({
    required OutboxNotificationListener listener,
    required EventOutboxRepository outboxRepository,
    required RealtimeEventPublisher publisher,
    required BridgeLocationResolver locationResolver,
    BridgeOperatorDiscoverer? operatorDiscoverer,
    Set<String> bootstrapOperatorIds = const <String>{},
    Duration pollInterval = const Duration(seconds: 60),
    int batchSize = 50,
    void Function(RealtimeBridgeLogEvent)? logger,
  }) : _listener = listener,
       _outboxRepository = outboxRepository,
       _publisher = publisher,
       _locationResolver = locationResolver,
       _operatorDiscoverer = operatorDiscoverer ?? _emptyDiscoverer,
       _knownOperatorIds = Set<String>.from(bootstrapOperatorIds),
       _pollInterval = pollInterval,
       _batchSize = batchSize,
       _logger = logger ?? _noopLogger;

  final OutboxNotificationListener _listener;
  final EventOutboxRepository _outboxRepository;
  final RealtimeEventPublisher _publisher;
  final BridgeLocationResolver _locationResolver;
  final BridgeOperatorDiscoverer _operatorDiscoverer;
  final Set<String> _knownOperatorIds;
  final Duration _pollInterval;
  final int _batchSize;
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

    for (final row in claimed) {
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
        // scaffold uses the lease only.
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

  final RealtimeBridgeLogKind kind;
  final String? operatorId;
  final String? outboxId;
  final String? topic;
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
}

void _noopLogger(RealtimeBridgeLogEvent event) {}
