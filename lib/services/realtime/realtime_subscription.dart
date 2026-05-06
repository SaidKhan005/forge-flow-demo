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
// Phase 10a.5 — `last_event_id` replay-on-reconnect. The subscription
// tracks the most recent event_id seen on the current tenant scope and
// forwards it to the transport on every (re)connect. The route's
// WebSocket lifecycle section (phase_10a_shared_state_v1_plan.md) calls
// for "On reconnect, client provides last-seen `event_id`; server
// replays missed events from Pub/Sub message backlog (up to 5 minutes
// retention)". Beyond that window the server emits a
// `replay_truncated` control envelope; the client surfaces it on
// [replayTruncated] and clears its cursor so the next reconnect does
// not loop on the same stale id.
//
// Phase 10a.5 — durable watermark. The cursor is mirrored to a
// per-device SQLite table (`realtime_subscription_watermark` keyed
// `(operator_id, topic)`) through the [RealtimeSubscriptionWatermarkStore]
// seam. On reconnect after a process restart, [setTenantContext] (or
// the explicit [resume] entry point) hydrates the in-memory cursor
// from the freshest watermark row for the operator so the very first
// connect can resume against missed events instead of starting from
// "first connect, no replay". Default store is a no-op so this file
// stays free of `dart:io` / `sqflite` imports — concrete platform
// stores live alongside the platform's other persistence helpers and
// are injected at construction.
//
// Watermark write timing: the in-memory cursor advances synchronously
// on every received frame; the durable upsert is unawaited (atomic
// at the SQLite transaction level, but not synchronized with UI
// dispatch). A crash between UI dispatch and persist would replay
// the same event_id on the next reconnect; downstream consumers
// dedupe on event_id per `event_outbox_contract.md`.
//
// Out of scope for this scaffold (Phase 10a follow-up):
//   * jittered back-off
//   * retry-attempt cap with hard "give up" on cumulative failure
//   * structured client-side telemetry (lag tile, undelivered count)

import 'dart:async';
import 'dart:convert';

import 'realtime_event.dart';
import 'realtime_transport.dart';

/// Phase 10a.5 — wire JSON key the route uses to mark non-event
/// control envelopes. Must match the literal in
/// `tool/advisor_proxy/realtime_route.dart`.
const String _controlKey = 'control';

/// Phase 10a.5 — control kind the route emits when the client's
/// `last_event_id` is older than `kRealtimeReplayWindow` (5 min).
const String _controlKindReplayTruncated = 'replay_truncated';

/// Connection state surfaced to the UI for the `10a.UX.0` sync-state
/// badge (sub-slice). Today the badge is not yet wired; surfaces are
/// here so a notifier can pick this up without changes to the
/// subscription contract.
enum RealtimeConnectionState {
  /// Subscription is dormant — [setTenantContext] has not been
  /// called, [clearTenantContext] has dropped the active scope, or
  /// [dispose] has run. Idle is restartable from the cleared case
  /// (a subsequent [setTenantContext] resumes the lifecycle); the
  /// disposed case is terminal.
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
    RealtimeSubscriptionWatermarkStore? watermarkStore,
  }) : _transport = transport,
       _initialBackoff = initialBackoff,
       _maxBackoff = maxBackoff,
       _logger = logger ?? _noopLogger,
       _watermarkStore =
           watermarkStore ?? const _NoopRealtimeSubscriptionWatermarkStore();

  /// Base URI of the proxy (e.g. `wss://proxy.forgeflow.app`). The
  /// `/v1/realtime` path is appended automatically.
  final Uri proxyBaseUri;

  final RealtimeTransport _transport;
  final Duration _initialBackoff;
  final Duration _maxBackoff;
  final void Function(RealtimeSubscriptionLogEvent) _logger;
  final RealtimeSubscriptionWatermarkStore _watermarkStore;

  RealtimeTenantContext? _tenantContext;
  RealtimeChannel? _activeChannel;
  StreamSubscription<String>? _channelSubscription;
  Timer? _reconnectTimer;
  Duration _currentBackoff = Duration.zero;
  bool _disposed = false;
  RealtimeConnectionState _state = RealtimeConnectionState.idle;

  /// Phase 10a.5 — most recent `event_id` observed on the current
  /// tenant scope. Forwarded to the transport on every (re)connect so
  /// the server can replay events missed during the disconnect window.
  /// Cleared on [setTenantContext] / [clearTenantContext] (a new scope
  /// has nothing to resume from) and on `replay_truncated` (server
  /// signalled the cursor is stale beyond the replay window — full
  /// refresh is the contract).
  String? _lastEventId;

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
  final StreamController<void> _replayTruncatedController =
      StreamController<void>.broadcast();

  /// Stream of events the subscription has received from the server.
  Stream<RealtimeEvent> get events => _eventsController.stream;

  /// Connection state for the UI sync-state badge (10a.UX.0).
  Stream<RealtimeConnectionState> get connectionState =>
      _stateController.stream;

  /// Phase 10a.5 — fires when the server signals it cannot replay the
  /// gap between the client's last_event_id and now (the gap is older
  /// than the contract floor `kRealtimeReplayWindow` — default 5 min).
  /// UI consumers should treat this as a prompt to do a full refresh
  /// from Postgres on the affected tables; the per-event push stream
  /// resumes normally on the same connection right after.
  Stream<void> get replayTruncated => _replayTruncatedController.stream;

  RealtimeConnectionState get currentConnectionState => _state;

  /// Visible for tests — most recent event_id the subscription would
  /// forward to the transport on the next (re)connect. Null on first
  /// connect for a fresh tenant scope and after a `replay_truncated`
  /// signal.
  String? get lastEventIdForTest => _lastEventId;

  /// Open (or reconnect) against the given tenant context. Resets the
  /// back-off curve so the new scope connects immediately. Safe to
  /// call repeatedly; each call cancels the in-flight connect/back-off
  /// and starts fresh.
  ///
  /// Phase 10a.5 — hydrate the in-memory cursor from the durable
  /// watermark store BEFORE scheduling the connect so the very first
  /// reconnect after a process restart resumes against missed events
  /// instead of starting from "first connect, no replay". The store
  /// read is best-effort: a thrown error keeps the cursor null and is
  /// logged, never rethrown — the route falls back to live frames
  /// only on the first connect, exactly the pre-10a.5 behavior.
  Future<void> setTenantContext(RealtimeTenantContext context) async {
    _tenantContext = context;
    _currentBackoff = Duration.zero;
    _generation += 1;
    // The cursor belongs to the previous tenant scope and would be a
    // cross-tenant leak if forwarded to the new operator's first
    // connect. Reset to null so the new scope starts as "first
    // connect, no replay" — then hydrate from the store below.
    _lastEventId = null;
    await _teardownChannel();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_disposed) return;
    final hydratedGeneration = _generation;
    try {
      final hydrated = await _watermarkStore.readNewestForOperator(
        context.operatorId,
      );
      if (hydratedGeneration != _generation || _disposed) {
        // Tenant changed (or the subscription was disposed) while the
        // hydrate read was in flight. The new generation owns its own
        // hydrate; this result belongs to a discarded scope.
        return;
      }
      if (hydrated != null) {
        _lastEventId = hydrated.eventId;
      }
    } catch (error, stack) {
      _logger(
        RealtimeSubscriptionLogEvent.watermarkStoreFailed(
          error: error,
          stack: stack,
        ),
      );
      if (hydratedGeneration != _generation || _disposed) return;
    }
    unawaited(_connect());
  }

  /// Phase 10a.5 — re-establish the connection against the active
  /// tenant context, re-hydrating the in-memory cursor from the
  /// durable watermark. Equivalent to calling [setTenantContext]
  /// with the current context — the hydrate path applies and the
  /// upgrade URI carries `?last_event_id=<uuid>` when the watermark
  /// store has a row for the operator. Idempotent; a no-op when no
  /// tenant context is active or the subscription has been disposed.
  ///
  /// Use this from the consumer when the proxy URI changes, the
  /// app cold-starts and rebuilds the subscription against an
  /// existing operator session, or any other "please reconnect from
  /// durable cursor" trigger that does not change the tenant scope.
  Future<void> resume() async {
    final context = _tenantContext;
    if (context == null || _disposed) return;
    await setTenantContext(context);
  }

  /// Drop the active tenant scope and tear down the channel without
  /// disposing the subscription. Used by the operator shell on
  /// sign-out so the previous operator's WebSocket cannot stay
  /// connected (or keep walking the back-off curve) under the
  /// per-operator isolation rule. The subscription stays alive — a
  /// subsequent [setTenantContext] resumes the lifecycle without
  /// rebuilding the broadcast streams the UI badge is listening on.
  ///
  /// Idempotent: calling on an already-cleared / never-set
  /// subscription is a no-op aside from re-emitting the idle state.
  Future<void> clearTenantContext() async {
    _tenantContext = null;
    _currentBackoff = Duration.zero;
    _generation += 1;
    // Drop the resume cursor on sign-out for the same reason as
    // setTenantContext: the next signed-in operator must not inherit
    // the previous one's last_event_id.
    _lastEventId = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _teardownChannel();
    if (_disposed) return;
    _setState(RealtimeConnectionState.idle);
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
    await _replayTruncatedController.close();
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
      channel = await _transport.connect(
        uri,
        authToken: context.authToken,
        // Phase 10a.5 — forward the resume cursor so the route can
        // replay anything missed during the disconnect window. Null
        // on the very first connect for this tenant scope; set on
        // every subsequent reconnect once at least one frame has
        // arrived. The transport places it on the upgrade URI as a
        // query parameter (browser-compatible — custom headers are
        // not available on the WebSocket upgrade).
        lastEventId: _lastEventId,
      );
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
      // Phase 10a.5 — control envelopes are non-event server signals
      // and never carry an `event_id`. The route emits exactly one
      // control message today (`replay_truncated`) so the client knows
      // its resume cursor is older than the contract floor (5 min) and
      // a full Postgres refresh is required. Control frames take
      // priority over RealtimeEvent.fromJson so the strict required-
      // field check in the latter does not reject them as malformed.
      final controlKind = json[_controlKey];
      if (controlKind is String) {
        _handleControlFrame(controlKind);
        return;
      }
      final event = RealtimeEvent.fromJson(json);
      // Phase 10a.5 — advance the in-memory cursor synchronously and
      // schedule the durable upsert (atomic at the SQLite transaction
      // level via `db.transaction(...)`). The upsert is unawaited so
      // a slow disk write cannot stall UI dispatch; if the process
      // crashes between dispatch and persist, the next reconnect
      // resumes from the prior watermark and the proxy redelivers
      // the duplicate event_id, which downstream consumers dedupe
      // per `event_outbox_contract.md`. A failed upsert is logged
      // via [RealtimeSubscriptionLogKind.watermarkStoreFailed] so a
      // broken store cannot silently desync the cursor.
      _lastEventId = event.eventId;
      final tenantContext = _tenantContext;
      if (tenantContext != null &&
          tenantContext.operatorId == event.operatorId) {
        unawaited(
          _watermarkStore
              .upsert(
                operatorId: event.operatorId,
                topic: event.topic,
                eventId: event.eventId,
                occurredAt: event.occurredAt,
                updatedAt: DateTime.now().toUtc(),
              )
              .catchError((Object error, StackTrace stack) {
                _logger(
                  RealtimeSubscriptionLogEvent.watermarkStoreFailed(
                    error: error,
                    stack: stack,
                  ),
                );
              }),
        );
      }
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

  void _handleControlFrame(String kind) {
    switch (kind) {
      case _controlKindReplayTruncated:
        // Drop the cursor so the next reconnect does not loop on the
        // same stale id. UI consumers refetch from Postgres on the
        // notification; live frames keep arriving on the same socket.
        _lastEventId = null;
        if (!_replayTruncatedController.isClosed) {
          _replayTruncatedController.add(null);
        }
        return;
      default:
        // Unknown control kind: log and drop. Forward-compat — the
        // server may add new control kinds in later slices and the
        // client should not crash on them.
        _logger(
          RealtimeSubscriptionLogEvent.frameParseFailed(
            error: FormatException(
              'unknown realtime control kind "$kind"',
            ),
            stack: StackTrace.current,
          ),
        );
        return;
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

  /// Phase 10a.5 — durable watermark read or write failed. The
  /// subscription continues with the in-memory cursor; the next
  /// reconnect after a process restart simply starts as "first
  /// connect, no replay" if the store cannot be reached.
  factory RealtimeSubscriptionLogEvent.watermarkStoreFailed({
    required Object error,
    required StackTrace stack,
  }) => RealtimeSubscriptionLogEvent._(
    kind: RealtimeSubscriptionLogKind.watermarkStoreFailed,
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
  watermarkStoreFailed,
}

/// Phase 10a.5 — durable per-device watermark store seam. Concrete
/// platform stores (today: `SqliteRealtimeSubscriptionWatermarkStore`)
/// live alongside the platform's other persistence helpers so this
/// file stays free of `dart:io` / `sqflite` imports — the realtime
/// subscription is consumed by both Flutter mobile entrypoints (which
/// have SQLite) and any future web-friendly entrypoint that would
/// inject a no-op store.
///
/// Contract:
///   * [readNewestForOperator] returns the watermark with the latest
///     `occurredAt` for the operator, or null when the operator has
///     no rows. Used by [RealtimeSubscription.setTenantContext] to
///     hydrate the in-memory cursor on the very first connect after
///     a process restart.
///   * [upsert] writes / overwrites the per-(operator, topic) row.
///     Implementations MUST be transactional — a partial write that
///     leaves the row pointing at an event the client never surfaced
///     would create a "phantom missed window" on the next reconnect.
///   * Implementations MUST scope every read AND write to the
///     supplied `operatorId` (cross-operator leaks would be a
///     per-tenant isolation violation).
abstract class RealtimeSubscriptionWatermarkStore {
  Future<RealtimeSubscriptionWatermark?> readNewestForOperator(
    String operatorId,
  );

  Future<void> upsert({
    required String operatorId,
    required String topic,
    required String eventId,
    required DateTime occurredAt,
    required DateTime updatedAt,
  });
}

/// Per-device watermark row. The realtime subscription advances the
/// row inside the same transaction that surfaces the event to the UI;
/// concrete stores serialize the `DateTime` fields as ISO-8601 UTC
/// strings (mirroring the `event_outbox.created_at` convention).
class RealtimeSubscriptionWatermark {
  const RealtimeSubscriptionWatermark({
    required this.operatorId,
    required this.topic,
    required this.eventId,
    required this.occurredAt,
    required this.updatedAt,
  });

  final String operatorId;
  final String topic;
  final String eventId;
  final DateTime occurredAt;
  final DateTime updatedAt;
}

/// No-op default. Used when the consumer does not wire a durable
/// store (today: tests + web-friendly entrypoints). Reading always
/// returns null so the subscription falls back to "first connect, no
/// replay" — the pre-10a.5 behavior is preserved exactly.
class _NoopRealtimeSubscriptionWatermarkStore
    implements RealtimeSubscriptionWatermarkStore {
  const _NoopRealtimeSubscriptionWatermarkStore();

  @override
  Future<RealtimeSubscriptionWatermark?> readNewestForOperator(
    String operatorId,
  ) async => null;

  @override
  Future<void> upsert({
    required String operatorId,
    required String topic,
    required String eventId,
    required DateTime occurredAt,
    required DateTime updatedAt,
  }) async {
    // Intentionally empty: no-op store has nowhere to write to.
  }
}

void _noopLogger(RealtimeSubscriptionLogEvent event) {}
