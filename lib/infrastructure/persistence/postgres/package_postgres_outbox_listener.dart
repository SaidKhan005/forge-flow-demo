// Phase 10a.0 — package:postgres binding for OutboxNotificationListener.
//
// One of two production adapters in this folder that import
// `package:postgres` directly (the other being package_postgres_executor.dart).
// Repositories and the bridge worker continue to depend only on the
// [OutboxNotificationListener] seam.
//
// LISTEN is connection-scoped, so this listener owns its own dedicated
// connection — it does not borrow from `PackagePostgresPool`. The
// connection stays open for the lifetime of the listener; the bridge
// worker also runs a 60s scheduled poll so a dropped notification
// (Postgres queue pressure, transient disconnect) does not strand a
// row.
//
// Reconnection is intentionally NOT in this scaffold. The Phase 10a
// follow-up that swaps in real Cloud Pub/Sub also adds connection
// supervision — for the scaffold the bridge worker's 60s poll is the
// only catch-all and a connection drop merely degrades latency to one
// poll cycle until the bridge is restarted.

import 'dart:async';

import 'package:postgres/postgres.dart' as pg;

import 'outbox_notification_listener.dart';

typedef PackagePostgresListenerConnectionFactory =
    Future<pg.Connection> Function();

class PackagePostgresOutboxListener implements OutboxNotificationListener {
  PackagePostgresOutboxListener({
    required PackagePostgresListenerConnectionFactory openConnection,
    List<String>? channelNames,
  }) : _openConnection = openConnection,
       _channelNames = channelNames ?? defaultChannels;

  PackagePostgresOutboxListener.fromUrl(String connectionString)
    : this(
        openConnection: () => pg.Connection.openFromUrl(connectionString),
      );

  // Default channels: per-category channels (PF5) + legacy fallback.
  static const List<String> defaultChannels = [
    'event_outbox_pos',
    'event_outbox_labor',
    'event_outbox_reservation',
    'event_outbox_admin',
    'event_outbox', // fallback for events not matched by category
  ];

  final PackagePostgresListenerConnectionFactory _openConnection;
  final List<String> _channelNames;

  pg.Connection? _connection;
  final List<StreamSubscription<String>> _subscriptions = [];
  final StreamController<OutboxNotification> _controller =
      StreamController<OutboxNotification>.broadcast();

  @override
  Stream<OutboxNotification> get notifications => _controller.stream;

  @override
  Future<void> start() async {
    if (_connection != null) return;
    final connection = await _openConnection();
    _connection = connection;
    // postgres ^3.x: `Channels[name]` returns a `Stream<String>` where
    // each event is the notification payload (the channel and PID
    // metadata are not exposed by this API). The bridge only needs
    // the payload because the contract says NOTIFY is wake-up only —
    // the bridge claims the row from the table on every drain.
    //
    // PF5 (performance hardening): listen on per-category channels
    // (event_outbox_pos, event_outbox_labor, etc.) + legacy fallback.
    // Each category channel receives events for its topic prefix; the
    // fallback receives everything else. Both are needed until the
    // database guarantees all rows go to at least one category channel
    // (current trigger sends to both for backward compatibility).
    for (final channelName in _channelNames) {
      final sub = connection.channels[channelName].listen(
        _handleNotificationPayload,
        onError: _handleError,
      );
      _subscriptions.add(sub);
    }
  }

  @override
  Future<void> stop() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      try {
        await connection.close(force: true);
      } catch (_) {
        // Closing a connection that is already torn down is fine —
        // the bridge supervisor's job is to restart, not to surface
        // teardown errors.
      }
    }
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  void _handleNotificationPayload(String payload) {
    if (payload.isEmpty) return;
    try {
      _controller.add(OutboxNotification.fromPayload(payload));
    } catch (_) {
      // A malformed notification payload is a hard contract violation —
      // the trigger in 9.0Σ.e is the only producer and it always
      // emits {operator_id, topic, id}. Silently dropping the
      // notification is the right call here: the 60s scheduled poll
      // will pick the row up. Logging the malformed payload is a
      // Phase 10a follow-up so we do not echo what could be a
      // corrupted body.
    }
  }

  void _handleError(Object error, StackTrace stack) {
    // Surface stream errors to subscribers so the bridge supervisor
    // can decide whether to restart the listener. The stream stays
    // open — the supervisor calls [stop] explicitly.
    if (!_controller.isClosed) {
      _controller.addError(error, stack);
    }
  }
}
