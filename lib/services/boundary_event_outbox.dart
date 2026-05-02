// HARD-H — durable backlog seam for the foreground boundary monitor.
//
// `CurrentStateBoundaryMonitor` calls `persist(...)` BEFORE the
// synchronous `onBoundaryChanged` callback runs and `markDelivered(...)`
// AFTER it returns successfully. If the in-process callback throws (or
// the app crashes / is killed mid-fire), the row stays
// undelivered and the next supervisor `start()` invokes `drainBacklog`
// to replay it.
//
// Two adapters ship today:
//   * [PostgresBoundaryEventOutbox] — server-side
//     (`tool/advisor_proxy/...`, live-binding tests). Wraps the
//     `EventOutboxRepository` so boundary rows land in the canonical
//     `event_outbox` table that the Phase 10a Pub/Sub bridge will
//     publish.
//   * [SqliteBoundaryEventOutbox] — client-side (Flutter app shell).
//     The Flutter app cannot hold Postgres credentials (Hard Promise
//     #7 in CLAUDE.md), so the per-device backlog uses a local SQLite
//     table instead. The boundary monitor's purpose is local UI
//     refresh, so the backlog only needs to survive client crashes /
//     backgrounds — not roundtrip through Pub/Sub.
//
// The interface deliberately hides scope (operator_id, location_id,
// user_id). Each adapter wires its own scope at construction time so
// the supervisor — which already has a `RestaurantLocation` — does
// not need to thread credentials.

abstract class BoundaryEventOutbox {
  /// Persist one rollover event. Returns the storage-assigned id the
  /// supervisor will pass back to [markDelivered] once the in-process
  /// callback succeeds.
  ///
  /// Returning `null` means "persistence failed — proceed with the
  /// in-process callback anyway, but do not attempt to mark
  /// delivered." The supervisor falls back to in-process
  /// `lastKnownBusinessDate` dedup for the rest of the session.
  Future<String?> persist({
    required String restaurantId,
    required String businessDate,
  });

  /// Read up to [batchSize] persisted-but-undelivered rows so the
  /// supervisor can replay the missed callback. The returned rows
  /// are claimed (e.g. `picked_up_at` stamped, lock acquired) so
  /// concurrent supervisors cannot double-fire the same row.
  Future<List<PendingBoundaryEvent>> claimPending({int batchSize = 100});

  /// Stamp the row identified by [eventId] as delivered so subsequent
  /// [claimPending] calls skip it.
  Future<void> markDelivered(String eventId);
}

class PendingBoundaryEvent {
  const PendingBoundaryEvent({
    required this.eventId,
    required this.restaurantId,
    required this.businessDate,
  });

  final String eventId;
  final String restaurantId;
  final String businessDate;
}
