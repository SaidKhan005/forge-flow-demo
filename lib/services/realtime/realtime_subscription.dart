// Phase 10a.0 — RealtimeSubscription.
//
// Client-side WebSocket subscription with exponential back-off and
// tenant-context reset. Designed for the Forge & Flow shell so
// notifiers (today: WeekDataNotifier on `rollup.invalidate.variance_week`)
// can refresh themselves on push instead of polling.
//
// Lifecycle:
//   * `start()` opens the channel and emits frames to [events].
//   * Channel close → schedule reconnect with exponential back-off
//     (1s × 2^n, capped at 30s; jitter omitted for the scaffold).
//   * `setTenantContext(...)` updates the auth token / operator id and
//     resets the back-off, immediately reconnecting against the new
//     scope. Without this reset, a logout/login cycle would inherit
//     the previous back-off delay.
//   * `dispose()` cancels reconnect timers, closes the active channel,
//     and prevents future reconnects.
//
// Out of scope for this scaffold (Phase 10a follow-up):
//   * `last_event_id` resume / Pub/Sub backlog replay
//   * jittered back-off
//   * retry-attempt cap with hard "give up" on cumulative failure
//   * structured client-side telemetry (lag tile, undelivered count)

import 'dart:async';
import 'dart:convert';

import 'realtime_event.dart';
import 'realtime_transport.dart';

/// Connection state surfaced to the UI for the `10a.UX.0` sync-state
/// badge (sub-slice). Today the badge is not yet wired; surfaces are
/// here so a notifier can pick this up without changes to the
/// subscription contract.
enum RealtimeConnectionState {
  /// Subscription is dormant — `start()` not yet called or
  /// `dispose()` has run.
  idle,

  /// Connecting (initial connect or reconnect after back-off).
  connecting,

  /// Connected and emitting frames.
  connected,

  /// Disconnected, waiting on the back-off timer to fire.
  reconnecting,
}

/// Bearer token + operator id resolved from the active session. The
/// subscription connects against this scope; when it changes (e.g. a
/// new login), [RealtimeSubscription.setTenantContext] resets the
/// back-off and reconnects.
class RealtimeTenantContext {
  const RealtimeTenantContext({
    required this.operatorId,
    required this.authToken,
  });

  final String operatorId;
  final String authToken;
}

class RealtimeSubscription {
  RealtimeSubscription({
    required this.proxyBaseUri,
    required RealtimeTransport transport,
    Duration initialBackoff = const Duration(seconds: 1),
    Duration maxBackoff = const Duration(seconds: 30),
    void Function(RealtimeSubscriptionLogEvent)? logger,
  }) : _transport = transport,
       _initialBackoff = initialBackoff,
       _maxBackoff = maxBackoff,
       _logger = logger ?? _noopLogger;

  /// Base URI of the proxy (e.g. `wss://proxy.forgeflow.app`). The
  /// `/v1/realtime` path is appended automatically.
  final Uri proxyBaseUri;

  final RealtimeTransport _transport;
  final Duration _initialBackoff;
  final Duration _maxBackoff;
  final void Function(RealtimeSubscriptionLogEvent) _logger;

  RealtimeTenantContext? _tenantContext;
  RealtimeChannel? _activeChannel;
  StreamSubscription<String>? _channelSubscription;
  Timer? _reconnectTimer;
  Duration _currentBackoff = Duration.zero;
  bool _disposed = false;
  RealtimeConnectionState _state = RealtimeConnectionState.idle;

  /// Monotonic counter incremented on every [setTenantContext] and
  /// [dispose] call. [_connect] snapshots the current generation
  /// before awaiting the transport, then re-checks after the await
  /// resolves. If the generation has moved (a new tenant was set
  /// while the connect was in flight), the resolved channel is closed
  /// and discarded so it cannot bind to the new session and emit the
  /// previous tenant's frames into it.
  int _generation = 0;

  final StreamController<RealtimeEvent> _eventsController =
      StreamController<RealtimeEvent>.broadcast();
  final StreamController<RealtimeConnectionState> _stateController =
      StreamController<RealtimeConnectionState>.broadcast();

  /// Stream of events the subscription has received from the server.
  Stream<RealtimeEvent> get events => _eventsController.stream;

  /// Connection state for the UI sync-state badge (10a.UX.0).
  Stream<RealtimeConnectionState> get connectionState =>
      _stateController.stream;

  RealtimeConnectionState get currentConnectionState => _state;

  /// Open (or reconnect) against the given tenant context. Resets the
  /// back-off curve so the new scope connects immediately. Safe to
  /// call repeatedly; each call cancels the in-flight connect/back-off
  /// and starts fresh.
  Future<void> setTenantContext(RealtimeTenantContext context) async {
    _tenantContext = context;
    _currentBackoff = Duration.zero;
    _generation += 1;
    await _teardownChannel();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_disposed) return;
    unawaited(_connect());
  }

  /// Tear down the active channel, cancel any pending reconnect, and
  /// stop accepting future reconnects. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _teardownChannel();
    _setState(RealtimeConnectionState.idle);
    await _eventsController.close();
    await _stateController.close();
  }

  /// Visible for tests — current back-off duration that will apply on
  /// the next disconnect. Resets to [_initialBackoff] on a successful
  /// connect.
  Duration get currentBackoffForTest => _currentBackoff;

  Future<void> _connect() async {
    final context = _tenantContext;
    if (context == null || _disposed) return;
    final connectGeneration = _generation;
    _setState(RealtimeConnectionState.connecting);
    final uri = proxyBaseUri.replace(
      path: _joinPath(proxyBaseUri.path, '/v1/realtime'),
    );
    RealtimeChannel channel;
    try {
      channel = await _transport.connect(uri, authToken: context.authToken);
    } catch (error, stack) {
      _logger(
        RealtimeSubscriptionLogEvent.connectFailed(
          error: error,
          stack: stack,
        ),
      );
      // Stale generation: setTenantContext (or dispose) was called
      // while the connect was in flight. The new tenant has its own
      // _connect scheduled; this failed attempt belongs to the
      // discarded session and must NOT walk the back-off curve or
      // schedule a reconnect against the new tenant.
      if (connectGeneration != _generation) return;
      _scheduleReconnect();
      return;
    }
    if (_disposed || connectGeneration != _generation) {
      // Tenant changed while connect was in flight; close the
      // resolved channel so it cannot bind to the new session and
      // emit the previous tenant's frames into it.
      try {
        await channel.close();
      } catch (_) {
        // Ignore — the new generation owns reconnect.
      }
      return;
    }
    _activeChannel = channel;
    // A successful connect is the signal to reset the back-off curve.
    // Without this reset, a flaky connection that drops 5 seconds
    // after each success would walk the back-off curve all the way to
    // the cap.
    _currentBackoff = Duration.zero;
    _setState(RealtimeConnectionState.connected);
    _channelSubscription = channel.incoming.listen(
      _handleFrame,
      onDone: _handleChannelClosed,
      onError: (Object error, StackTrace stack) {
        _logger(
          RealtimeSubscriptionLogEvent.channelError(
            error: error,
            stack: stack,
          ),
        );
        _handleChannelClosed();
      },
      cancelOnError: true,
    );
  }

  void _handleFrame(String raw) {
    if (raw.isEmpty) return;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) {
        throw FormatException('frame is not a JSON object');
      }
      final event = RealtimeEvent.fromJson(json);
      _eventsController.add(event);
    } catch (error, stack) {
      _logger(
        RealtimeSubscriptionLogEvent.frameParseFailed(
          error: error,
          stack: stack,
        ),
      );
    }
  }

  void _handleChannelClosed() {
    _channelSubscription?.cancel();
    _channelSubscription = null;
    _activeChannel = null;
    if (_disposed) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _currentBackoff = _nextBackoff(_currentBackoff);
    _setState(RealtimeConnectionState.reconnecting);
    _reconnectTimer = Timer(_currentBackoff, () {
      _reconnectTimer = null;
      unawaited(_connect());
    });
  }

  Duration _nextBackoff(Duration previous) {
    if (previous == Duration.zero) return _initialBackoff;
    final doubled = previous * 2;
    return doubled > _maxBackoff ? _maxBackoff : doubled;
  }

  Future<void> _teardownChannel() async {
    await _channelSubscription?.cancel();
    _channelSubscription = null;
    final channel = _activeChannel;
    _activeChannel = null;
    if (channel != null) {
      try {
        await channel.close();
      } catch (_) {
        // Closing an already-torn-down channel is fine — the
        // reconnect path opens a fresh one.
      }
    }
  }

  void _setState(RealtimeConnectionState state) {
    if (_state == state) return;
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  static String _joinPath(String base, String tail) {
    if (base.isEmpty || base == '/') return tail;
    final normalizedBase = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final normalizedTail = tail.startsWith('/') ? tail : '/$tail';
    return '$normalizedBase$normalizedTail';
  }
}

class RealtimeSubscriptionLogEvent {
  const RealtimeSubscriptionLogEvent._({
    required this.kind,
    this.error,
    this.stack,
  });

  factory RealtimeSubscriptionLogEvent.connectFailed({
    required Object error,
    required StackTrace stack,
  }) => RealtimeSubscriptionLogEvent._(
    kind: RealtimeSubscriptionLogKind.connectFailed,
    error: error,
    stack: stack,
  );

  factory RealtimeSubscriptionLogEvent.channelError({
    required Object error,
    required StackTrace stack,
  }) => RealtimeSubscriptionLogEvent._(
    kind: RealtimeSubscriptionLogKind.channelError,
    error: error,
    stack: stack,
  );

  factory RealtimeSubscriptionLogEvent.frameParseFailed({
    required Object error,
    required StackTrace stack,
  }) => RealtimeSubscriptionLogEvent._(
    kind: RealtimeSubscriptionLogKind.frameParseFailed,
    error: error,
    stack: stack,
  );

  final RealtimeSubscriptionLogKind kind;
  final Object? error;
  final StackTrace? stack;
}

enum RealtimeSubscriptionLogKind {
  connectFailed,
  channelError,
  frameParseFailed,
}

void _noopLogger(RealtimeSubscriptionLogEvent event) {}
