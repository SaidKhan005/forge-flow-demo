// Phase 10a.UX.1 — PeerEditToast.
//
// Shell-level passthrough widget that subscribes to a
// `Stream<RealtimeEvent>` from the 10a.0 RealtimeSubscription and
// surfaces a transient SnackBar ("Peer edit: <table>") on every shared-
// state frame. The toast surfaces the LWW outcome for the current user
// without concealing it (phase_10a plan §UX.1).
//
// Mount once at the shell so toasts appear across all routes — the
// widget renders [child] as a passthrough; the listener lives in its
// State and uses the nearest enclosing [ScaffoldMessenger] (which
// MaterialApp installs above the route stack). Mounting per-screen
// would result in toasts only firing while that screen is active and
// in misses when the route is mid-transition.
//
// Same-device suppression and "row the user is viewing" filtering are
// out of scope for this slice — the shipped behaviour is "toast on
// every shared-state frame," matching the phase doc demo path. A
// device-id origin filter is a Phase 10b concern and slots into the
// `_shouldShow` predicate without changing the public API.
//
// Table-extraction rule mirrors `LastSyncedTimestampsNotifier`:
// only `shared_state.<operator_id>.<table>` topics qualify (Phase 11a
// Lock 9). Within a qualifying frame, `payload['table']` takes
// precedence; the topic last segment is the fallback. Frames on
// other namespaces (`auth.*`, `usage.cap.*`, …) do not toast even if
// they carry a `table` payload field.

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/realtime/realtime_event.dart';
import '../state/last_synced_timestamps_notifier.dart' show sharedStateTopicPrefix;
import '../theme/app_theme.dart';

class PeerEditToast extends StatefulWidget {
  const PeerEditToast({
    super.key,
    required this.events,
    required this.child,
    this.duration = const Duration(seconds: 2),
  });

  /// Live `Stream<RealtimeEvent>` from `RealtimeSubscription.events`.
  /// The shell typically passes `subscription.events`; widget tests
  /// pass a `StreamController<RealtimeEvent>.stream` so they can
  /// publish synthetic frames.
  final Stream<RealtimeEvent> events;

  /// Snackbar lifetime. The phase doc calls for 2-3s; keep the
  /// default at 2s and let callers extend it if needed.
  final Duration duration;

  /// Wrapped subtree. The widget renders [child] without altering the
  /// layout tree — the listener is a side effect of being mounted.
  final Widget child;

  @override
  State<PeerEditToast> createState() => _PeerEditToastState();
}

class _PeerEditToastState extends State<PeerEditToast> {
  StreamSubscription<RealtimeEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe(widget.events);
  }

  @override
  void didUpdateWidget(PeerEditToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.events != widget.events) {
      _subscribe(widget.events);
    }
  }

  void _subscribe(Stream<RealtimeEvent> events) {
    _subscription?.cancel();
    _subscription = events.listen(_onEvent);
  }

  void _onEvent(RealtimeEvent event) {
    if (!mounted) return;
    final table = _extractTable(event);
    if (table == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        key: ValueKey('peer_edit_toast_${event.eventId}'),
        content: Text(
          'Peer edit: $table',
          style: AppTextStyles.mono11(color: AppColors.textPrimary),
        ),
        backgroundColor: AppColors.backgroundMid,
        duration: widget.duration,
      ),
    );
  }

  static String? _extractTable(RealtimeEvent event) {
    // Topic gate: only `shared_state.<operator_id>.<table>` frames
    // identify a shared-state row; see Phase 11a Lock 9.
    if (!event.topic.startsWith(sharedStateTopicPrefix)) return null;
    final segments = event.topic.split('.');
    if (segments.length < 3) return null;
    final topicTable = segments.last;
    if (topicTable.isEmpty) return null;
    final payloadTable = event.payload['table'];
    if (payloadTable is String && payloadTable.isNotEmpty) {
      return payloadTable;
    }
    return topicTable;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
