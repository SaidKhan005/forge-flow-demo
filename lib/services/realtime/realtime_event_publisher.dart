// Phase 10a.0 — RealtimeEventPublisher seam.
//
// The bridge worker (tool/advisor_proxy/realtime_bridge.dart) hands
// claimed `event_outbox` rows to a [RealtimeEventPublisher]. The
// publisher returns a Future that completes when the underlying
// transport has accepted the event (Pub/Sub ack semantic in the
// production binding); the bridge marks the outbox row delivered only
// after that future completes.
//
// This slice ships ONE binding: [InProcessRealtimePublisher], which
// fans events to in-memory per-operator broadcast streams. The proxy
// WebSocket route subscribes to those streams to deliver frames to
// connected clients. Phase 10a follow-up swaps in
// `CloudPubSubRealtimePublisher` against the same interface; nothing
// else has to change.
//
// The seam is intentionally narrow:
//   * `publish(event)` succeeds → bridge marks delivered
//   * `publish(event)` throws    → bridge increments attempt_count,
//                                  re-NULLs picked_up_at, retries
//
// The publisher MUST NOT swallow failures silently — Q22's durable
// queue contract relies on the throw.

import 'dart:async';
import 'dart:collection';

import 'realtime_event.dart';
import 'realtime_replay_resolver.dart';

abstract class RealtimeEventPublisher {
  /// Hand the event to the underlying transport. Returns when the
  /// transport has accepted the event. Throws on transport failure so
  /// the bridge worker can apply the retry ledger.
  Future<void> publish(RealtimeEvent event);
}

/// In-process publisher for the Phase 10a.0 scaffold. Holds one
/// broadcast stream per operator; subscribers (today: the WebSocket
/// route) get exactly the events for the operator they care about.
///
/// **Why per-operator streams.** Every WebSocket connection is bound
/// to one operator (resolved server-side from the JWT). Filtering on
/// the subscribe side instead would mean every connection sees every
/// operator's events and discards them — that is the cross-tenant
/// leak the contract explicitly forbids.
///
/// Replaced by `CloudPubSubRealtimePublisher` in a Phase 10a follow-up
/// once Pub/Sub topics are provisioned. The bridge worker, the
/// WebSocket route, and the client are all unchanged by that swap.
class InProcessRealtimePublisher
    implements RealtimeEventPublisher, RealtimeReplayBacklog {
  InProcessRealtimePublisher({
    int ringBufferCapacity = kRealtimeReplayRingBufferCapacity,
  }) : _ringBufferCapacity = ringBufferCapacity {
    if (ringBufferCapacity <= 0) {
      throw ArgumentError.value(
        ringBufferCapacity,
        'ringBufferCapacity',
        'ring buffer capacity must be positive; replay would otherwise '
            'be a no-op for every reconnect',
      );
    }
  }

  final Map<String, StreamController<RealtimeEvent>> _streams = {};

  /// Phase 10a.5 — recent-events ring buffer keyed by
  /// `(operator_id, topic)` so the demo / single-instance route can
  /// answer reconnect replay queries via [RealtimeReplayBacklog]
  /// without a Pub/Sub round-trip. Per-key capacity is fixed at
  /// construction; the oldest entry is evicted when a publish would
  /// push the buffer past the cap.
  final Map<_InProcessRingKey, Queue<RealtimeEvent>> _ringBuffers =
      <_InProcessRingKey, Queue<RealtimeEvent>>{};
  final int _ringBufferCapacity;

  /// Subscribe to events for one operator. Returns a broadcast stream
  /// so multiple WebSocket connections from the same operator (host
  /// stand tablet + office computer) can each open their own
  /// subscription without duplicating events.
  Stream<RealtimeEvent> subscribe(String operatorId) {
    return _controllerFor(operatorId).stream;
  }

  @override
  Future<void> publish(RealtimeEvent event) async {
    // The publisher owns the controller's lifecycle: created lazily
    // by [_controllerFor] on the first publish/subscribe for an
    // operator and torn down in [close].
    // ignore: close_sinks
    final controller = _controllerFor(event.operatorId);
    if (controller.isClosed) {
      throw StateError(
        'InProcessRealtimePublisher: controller for operator '
        '${event.operatorId} is already closed',
      );
    }
    _appendToRingBuffer(event);
    controller.add(event);
  }

  /// Phase 10a.5 — RealtimeReplayBacklog implementation.
  ///
  /// Contract: "events with `occurred_at > lookup(lastEventId).occurred_at`"
  /// (slice prompt). The cursor lookup is GLOBAL across the operator's
  /// rings because `event_id` is globally unique per the `event_outbox`
  /// contract — a cursor observed on topic A lives only in topic A's
  /// ring, and a per-topic lookup against topic B would otherwise
  /// falsely report "cursor unknown" and force the route to truncate
  /// every topic the cursor was not originally on. Cross-operator
  /// isolation still holds because the lookup only inspects rings
  /// keyed to the supplied `operatorId`.
  ///
  /// Returns:
  ///   * [RealtimeReplayStaleSentinel.instance] — cursor not in any
  ///     of the operator's rings (evicted by ring overflow, or never
  ///     seen on this proxy instance), OR cursor is in a ring but
  ///     its `occurred_at` is older than `window` (production
  ///     Pub/Sub would have evicted it by retention).
  ///   * Empty list — cursor known and inside `window`, but the
  ///     queried `topic` has no events newer than the cursor.
  ///   * Non-empty list — events on the queried topic with
  ///     `occurred_at > cursor.occurredAt`, ordered oldest → newest.
  @override
  Future<List<RealtimeEvent>> replayMissed({
    required String operatorId,
    required String topic,
    required String lastEventId,
    required Duration window,
  }) async {
    final cursorOccurredAt = _lookupCursorOccurredAt(operatorId, lastEventId);
    if (cursorOccurredAt == null) {
      return RealtimeReplayStaleSentinel.instance;
    }
    // Time-window stale check: production Pub/Sub backlog evicts by
    // age (default 5 min); a cursor still physically in some ring but
    // whose `occurred_at` is older than `window` qualifies as
    // "outside retention" so the route emits `replay_truncated`.
    final cutoff = DateTime.now().toUtc().subtract(window);
    if (cursorOccurredAt.toUtc().isBefore(cutoff)) {
      return RealtimeReplayStaleSentinel.instance;
    }
    final ring = _ringBuffers[_InProcessRingKey(operatorId, topic)];
    if (ring == null || ring.isEmpty) {
      // Cursor known, but no events were ever published on this
      // (operator, topic) pair on this proxy instance — return empty
      // (no missed events on this topic), NOT sentinel. Other topics'
      // closures may still find missed events.
      return const <RealtimeEvent>[];
    }
    final missed = <RealtimeEvent>[];
    for (final entry in ring) {
      if (entry.occurredAt.isAfter(cursorOccurredAt)) {
        missed.add(entry);
      }
    }
    return List<RealtimeEvent>.unmodifiable(missed);
  }

  /// Search every ring belonging to [operatorId] for the supplied
  /// [eventId] and return its `occurred_at`, or null if not found.
  /// Cross-operator isolation: rings keyed to a different
  /// `operatorId` are skipped before the inner scan.
  DateTime? _lookupCursorOccurredAt(String operatorId, String eventId) {
    for (final key in _ringBuffers.keys) {
      if (key.operatorId != operatorId) continue;
      final ring = _ringBuffers[key]!;
      for (final entry in ring) {
        if (entry.eventId == eventId) return entry.occurredAt;
      }
    }
    return null;
  }

  /// Phase 10a.5 — topics the publisher has seen frames on for the
  /// supplied operator. Mirrors the same accessor on
  /// `PubsubRealtimePublisher` so the route's replay closure can
  /// iterate per-topic without a separate inventory lookup.
  List<String> topicsForOperator(String operatorId) {
    final topics = <String>[];
    for (final key in _ringBuffers.keys) {
      if (key.operatorId == operatorId) topics.add(key.topic);
    }
    return List<String>.unmodifiable(topics);
  }

  /// Visible for tests — current ring length for (operator, topic).
  int ringLengthForTest(String operatorId, String topic) {
    final ring = _ringBuffers[_InProcessRingKey(operatorId, topic)];
    return ring?.length ?? 0;
  }

  void _appendToRingBuffer(RealtimeEvent event) {
    final key = _InProcessRingKey(event.operatorId, event.topic);
    final ring = _ringBuffers.putIfAbsent(key, () => Queue<RealtimeEvent>());
    ring.addLast(event);
    while (ring.length > _ringBufferCapacity) {
      ring.removeFirst();
    }
  }

  StreamController<RealtimeEvent> _controllerFor(String operatorId) {
    return _streams.putIfAbsent(
      operatorId,
      () => StreamController<RealtimeEvent>.broadcast(),
    );
  }

  Future<void> close() async {
    for (final controller in _streams.values) {
      await controller.close();
    }
    _streams.clear();
    _ringBuffers.clear();
  }
}

/// Composite ring-buffer key for [InProcessRealtimePublisher]. Two
/// separate strings instead of an interpolated `$op|$topic` so a
/// topic literal that happens to contain `|` cannot collide with
/// another operator's slice.
class _InProcessRingKey {
  const _InProcessRingKey(this.operatorId, this.topic);

  final String operatorId;
  final String topic;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _InProcessRingKey &&
          other.operatorId == operatorId &&
          other.topic == topic);

  @override
  int get hashCode => Object.hash(operatorId, topic);
}
