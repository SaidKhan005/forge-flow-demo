// CODE_OPS_DEBT — Theme C — generic pg_cron NOTIFY consumer.
//
// Five `pg_cron`-emitted channels currently land in production with no
// in-process LISTEN consumer:
//
//   * `audit_anchor_tick`         — daily 02:00 UTC
//   * `rollups_tick`              — every 60 s + 5 min
//   * `forge_email_outbox_tick`   — every minute
//   * `mobile_push_outbox`        — per-row trigger + cron tick
//   * `outbox_tripwire_tick`      — implicit via the tripwire poller
//
// Each cron job runs `pg_notify(<channel>, …)`; without a consumer the
// matching Dart worker never wakes up. The proxy already uses
// `PackagePostgresOutboxListener` for `event_outbox` rows, but that
// listener is contract-bound to the event_outbox payload shape.
// This file provides a generic reusable LISTEN consumer for any cron
// notify channel — the body of the payload is opaque (the worker
// reads its own state from the database on every tick), so the only
// signal the consumer carries is "wake up".
//
// Connection posture matches `package_postgres_outbox_listener.dart`:
//   * One dedicated `package:postgres` connection per consumer
//     (LISTEN is connection-scoped).
//   * Broadcast `Stream<PgCronNotifyTick>` so multiple subscribers
//     can share one consumer (e.g. the rollups worker subscribing to
//     `rollups_tick` and an admin observability badge subscribing to
//     the same channel for log surfacing).
//   * `start()` is idempotent; `stop()` tears down the connection
//     and cannot be reversed (callers create a fresh instance).
//
// CLAUDE.md guardrail: this file lives in
// `lib/infrastructure/persistence/postgres/` because it imports
// `package:postgres` directly; the lint blocks raw driver imports
// from anywhere else.

import 'dart:async';

import 'package:postgres/postgres.dart' as pg;

/// Single tick observed on a cron notify channel. Carries the channel
/// name + payload so log search can confirm a wake-up arrived; the
/// worker treats every tick as "drain now".
class PgCronNotifyTick {
  const PgCronNotifyTick({
    required this.channel,
    required this.payload,
    required this.observedAt,
  });

  /// Channel name the tick arrived on (e.g. `rollups_tick`).
  final String channel;

  /// Raw payload string from `pg_notify(<channel>, <payload>)`. Most
  /// cron functions emit a small JSON envelope (e.g. `{"fired_at":
  /// …}`); workers do not decode it because durability lives in the
  /// table the worker reads, not in the notification.
  final String payload;

  /// Wall-clock instant the consumer received the tick.
  final DateTime observedAt;
}

/// Hook for log-side surfacing of consumer-internal events. Production
/// binds this to the structured `log()` helper; tests substitute a
/// buffered list to assert wiring without a real connection.
typedef PgCronNotifyConsumerLogger = void Function(
  PgCronNotifyConsumerEvent event,
);

enum PgCronNotifyConsumerKind {
  started,
  stopped,
  notificationReceived,
  channelError,
  reconnectFailed,
}

class PgCronNotifyConsumerEvent {
  const PgCronNotifyConsumerEvent({
    required this.kind,
    required this.channel,
    this.payload,
    this.error,
    this.stack,
  });

  final PgCronNotifyConsumerKind kind;
  final String channel;
  final String? payload;
  final Object? error;
  final StackTrace? stack;
}

/// Factory the consumer uses to open its dedicated connection. The
/// production binding wires this to `pg.Connection.openFromUrl(<conn>)`;
/// tests pass a fake that returns a stub.
typedef PgCronNotifyConnectionFactory = Future<pg.Connection> Function();

/// Generic LISTEN consumer for one or more cron notify channels.
///
/// Lifecycle:
///   * Construct with a connection factory + the channel names to
///     LISTEN on.
///   * Call `start()` to open the connection and subscribe.
///   * Subscribe to `ticks` to observe wake-ups.
///   * Call `stop()` on shutdown (the proxy SIGTERM handler invokes
///     this for every consumer it created).
///
/// Reconnection is intentionally NOT in this scaffold — matching the
/// posture of `PackagePostgresOutboxListener`. Each worker that
/// consumes a tick already runs a periodic poll as the durability
/// fallback, so a dropped LISTEN merely degrades latency to one poll
/// cycle.
class PgCronNotifyConsumer {
  PgCronNotifyConsumer({
    required PgCronNotifyConnectionFactory openConnection,
    required List<String> channels,
    PgCronNotifyConsumerLogger? logger,
    DateTime Function()? clock,
  })  : _openConnection = openConnection,
        _channels = List<String>.unmodifiable(channels),
        _logger = logger,
        _clock = clock ?? (() => DateTime.now().toUtc()) {
    if (channels.isEmpty) {
      throw ArgumentError.value(
        channels,
        'channels',
        'PgCronNotifyConsumer requires at least one channel name',
      );
    }
  }

  /// Convenience constructor — opens a fresh `package:postgres`
  /// connection from a connection string. Mirrors
  /// `PackagePostgresOutboxListener.fromUrl`.
  PgCronNotifyConsumer.fromUrl(
    String connectionString, {
    required List<String> channels,
    PgCronNotifyConsumerLogger? logger,
    DateTime Function()? clock,
  }) : this(
          openConnection: () => pg.Connection.openFromUrl(connectionString),
          channels: channels,
          logger: logger,
          clock: clock,
        );

  final PgCronNotifyConnectionFactory _openConnection;
  final List<String> _channels;
  final PgCronNotifyConsumerLogger? _logger;
  final DateTime Function() _clock;

  pg.Connection? _connection;
  final List<StreamSubscription<String>> _subscriptions =
      <StreamSubscription<String>>[];
  final StreamController<PgCronNotifyTick> _controller =
      StreamController<PgCronNotifyTick>.broadcast();
  bool _started = false;
  bool _stopped = false;

  /// Hot stream of cron ticks observed across every channel the
  /// consumer subscribes to. Broadcast — multiple listeners share the
  /// same wake-up cadence.
  Stream<PgCronNotifyTick> get ticks => _controller.stream;

  /// Channels the consumer is configured to LISTEN on.
  List<String> get channels => _channels;

  /// Open the connection and start LISTENing. Idempotent — repeated
  /// calls after a successful start are no-ops. Throws when called
  /// after `stop()`; consumers cannot be revived.
  Future<void> start() async {
    if (_stopped) {
      throw StateError('PgCronNotifyConsumer cannot be restarted after stop()');
    }
    if (_started) return;
    _started = true;
    final connection = await _openConnection();
    _connection = connection;
    for (final channel in _channels) {
      final stream = connection.channels[channel];
      final sub = stream.listen(
        (payload) => _onPayload(channel, payload),
        onError: (Object error, StackTrace stack) {
          _emit(
            PgCronNotifyConsumerEvent(
              kind: PgCronNotifyConsumerKind.channelError,
              channel: channel,
              error: error,
              stack: stack,
            ),
          );
        },
      );
      _subscriptions.add(sub);
    }
    _emit(
      PgCronNotifyConsumerEvent(
        kind: PgCronNotifyConsumerKind.started,
        channel: _channels.join(','),
      ),
    );
  }

  void _onPayload(String channel, String payload) {
    final tick = PgCronNotifyTick(
      channel: channel,
      payload: payload,
      observedAt: _clock(),
    );
    _emit(
      PgCronNotifyConsumerEvent(
        kind: PgCronNotifyConsumerKind.notificationReceived,
        channel: channel,
        payload: payload,
      ),
    );
    if (!_controller.isClosed) {
      _controller.add(tick);
    }
  }

  /// Stop listening, close the underlying connection, and close the
  /// broadcast stream. Safe to call multiple times.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    for (final sub in _subscriptions) {
      try {
        await sub.cancel();
      } catch (_) {
        // The connection may already be torn down; nothing to do.
      }
    }
    _subscriptions.clear();
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      try {
        await connection.close(force: true);
      } catch (_) {
        // Closing an already-torn-down connection is benign.
      }
    }
    _emit(
      PgCronNotifyConsumerEvent(
        kind: PgCronNotifyConsumerKind.stopped,
        channel: _channels.join(','),
      ),
    );
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  void _emit(PgCronNotifyConsumerEvent event) {
    final logger = _logger;
    if (logger == null) return;
    try {
      logger(event);
    } catch (_) {
      // Logger faults must not poison the consumer.
    }
  }
}
