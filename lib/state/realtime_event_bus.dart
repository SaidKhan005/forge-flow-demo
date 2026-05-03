// Phase 10a.UX.1 — RealtimeEventBus.
//
// Shell-level seam between the (Phase 10a.0) `RealtimeSubscription`
// instance the app shell owns and the operator-facing surfaces this
// slice ships:
//   * `LastSyncedTimestampsNotifier` (Settings → Data → Data freshness)
//   * `PeerEditToast` (transient SnackBar wrapped around the shell)
//
// The bus exists so the surfaces can mount in production without
// hard-pinning a [RealtimeSubscription] reference in [ForgeFlowScope]
// — the producer side is owned by sibling lane 10a.UX.0 (sync-state
// badge), which instantiates the subscription for `connectionState`
// and pipes `subscription.events.listen(bus.publish)` into this bus
// once it lands. Until then the bus has no producer; the providers
// and toast are mounted, listening, and ready for traffic.
//
// Test harnesses publish synthetic frames directly via [publish] to
// drive both surfaces without standing up a WebSocket.
//
// Lifecycle: a single instance per app session (Provider in
// [ForgeFlowScope]); [dispose] closes the controller and is wired
// through the Provider's `dispose` callback.

import 'dart:async';

import '../services/realtime/realtime_event.dart';

class RealtimeEventBus {
  RealtimeEventBus();

  final StreamController<RealtimeEvent> _controller =
      StreamController<RealtimeEvent>.broadcast();

  /// Broadcast stream the toast and the freshness notifier subscribe
  /// to. Multiple listeners are supported — each consumer attaches
  /// independently.
  Stream<RealtimeEvent> get events => _controller.stream;

  /// Forward a frame from the upstream `RealtimeSubscription` (or
  /// from a demo/test harness) into the bus. Silently no-ops when
  /// the bus has been disposed.
  void publish(RealtimeEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  /// Close the underlying controller. Idempotent.
  Future<void> dispose() async {
    if (_controller.isClosed) return;
    await _controller.close();
  }
}
