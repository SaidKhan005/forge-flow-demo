// Phase 10a.UX.1 — LastSyncedTimestampsNotifier.
//
// In-memory, per-table last-sync timestamp tracker. Subscribes to a
// `Stream<RealtimeEvent>` (10a.0) and stamps the wall-clock now
// (`DateTime.now().toUtc()`) against the table the event mutated.
//
// Table-extraction rule (Phase 11a Lock 9 — `docs/phases/phase_11a/
// phase_11a_decision_register.md` §9):
//   * The frame MUST be on the `shared_state.<operator_id>.<table>`
//     topic. Any other topic (`auth.*`, `usage.cap.*`,
//     `rollup.invalidate.*`, …) is ignored — those are not shared-
//     state pushes even if they happen to carry a `table` payload
//     field, and stamping freshness for them would mislead operators.
//   * Within a `shared_state.*` frame, `payload['table']` (the Lock 9
//     canonical field) takes precedence as the table name; the topic
//     last segment is the fallback when payload omits the field
//     (e.g., a producer that hasn't migrated to the locked payload
//     schema yet).
//
// Events that do not match the topic rule are ignored. The notifier is
// in-memory only this slice — no schema, no SQLite persistence.
// Restarting the app resets every row to "Never". A persisted column
// across launches is a Phase 10b follow-up.
//
// `subscribeRealtime` is idempotent: a second call cancels the prior
// subscription so callers can re-bind on tenant context change without
// leaking. Mirrors the `WeekDataNotifier.subscribeRealtime` pattern
// shipped in 10a.0.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/realtime/realtime_event.dart';

/// Topic prefix Phase 11a Lock 9 reserves for shared-state row pushes.
const String sharedStateTopicPrefix = 'shared_state.';

class LastSyncedTimestampsNotifier extends ChangeNotifier {
  LastSyncedTimestampsNotifier({DateTime Function()? now})
    : _now = now ?? (() => DateTime.now().toUtc());

  final DateTime Function() _now;
  final Map<String, DateTime> _timestamps = <String, DateTime>{};
  StreamSubscription<RealtimeEvent>? _subscription;

  /// Read-only view of the per-table last-sync timestamps. Tables that
  /// have not received an event are absent from the map; callers
  /// surface "Never" for the absent case.
  Map<String, DateTime> get timestamps =>
      Map<String, DateTime>.unmodifiable(_timestamps);

  /// Last-sync UTC timestamp for [table], or `null` if no event for
  /// that table has been observed in this app session.
  DateTime? lastSyncedAt(String table) => _timestamps[table];

  /// Wire the notifier to a realtime event stream. When a frame whose
  /// payload or topic identifies a shared-state table arrives, stamp
  /// the table's last-sync timestamp and notify listeners. Idempotent:
  /// a second call cancels the previous subscription.
  void subscribeRealtime(Stream<RealtimeEvent> events) {
    _subscription?.cancel();
    _subscription = events.listen(_handle);
  }

  /// Test seam — direct ingestion that bypasses the stream wiring.
  /// Production code uses [subscribeRealtime].
  @visibleForTesting
  void ingest(RealtimeEvent event) => _handle(event);

  /// Phase 10a.UX.1 — drop every per-table timestamp. Called by the
  /// shell when the auth session ends or transitions to a different
  /// tenant so the prior operator's freshness rows do not survive
  /// session loss. No-op when the map is already empty (avoids
  /// spurious `notifyListeners` rebuilds).
  void clear() {
    if (_timestamps.isEmpty) return;
    _timestamps.clear();
    notifyListeners();
  }

  void _handle(RealtimeEvent event) {
    final table = _extractTable(event);
    if (table == null) return;
    _timestamps[table] = _now();
    notifyListeners();
  }

  static String? _extractTable(RealtimeEvent event) {
    // Topic gate: only `shared_state.<operator_id>.<table>` frames are
    // shared-state pushes. Other namespaces with a `table` payload
    // field (e.g. an `auth.*` push that happens to mention a table)
    // are explicitly out of scope per Phase 11a Lock 9.
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
}
