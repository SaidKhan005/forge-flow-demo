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

import 'realtime_event.dart';

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
class InProcessRealtimePublisher implements RealtimeEventPublisher {
  final Map<String, StreamController<RealtimeEvent>> _streams = {};

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
    controller.add(event);
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
  }
}
