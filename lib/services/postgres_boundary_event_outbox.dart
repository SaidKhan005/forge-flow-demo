// HARD-H — server-side [BoundaryEventOutbox] backed by the canonical
// `event_outbox` Postgres table.
//
// Used by the live-binding test (driving the production persist /
// claim / mark-delivered path against a real Postgres) and any
// future server-side consumer that runs a boundary supervisor with a
// real Postgres connection. The Flutter app uses
// [SqliteBoundaryEventOutbox] instead because the app cannot hold
// Postgres credentials (Hard Promise #7 in CLAUDE.md).
//
// This adapter pins the `(operator_id, location_id, user_id)` tenant
// scope at construction time so the supervisor — which only knows
// about a `RestaurantLocation` — does not need to thread credentials
// through every persist / claim call.

import '../infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'boundary_event_outbox.dart';

/// HARD-H — durable backlog topic for boundary rollover events.
///
/// Every persist + claim runs against the operator-scoped
/// `event_outbox` table filtered by this topic. The
/// `EventOutboxRepository.claimBatch` `topic` parameter pushes the
/// filter into the inner `FOR UPDATE SKIP LOCKED` CTE so unrelated
/// rows (Phase 10a payloads, rollups, etc.) are never locked or
/// stamped as side effects of the boundary backlog drain.
const String boundaryRolloverEventTopic = 'boundary.business_day.rollover';

class PostgresBoundaryEventOutbox implements BoundaryEventOutbox {
  PostgresBoundaryEventOutbox({
    required EventOutboxRepository repository,
    required String operatorId,
    required String locationId,
    String? userId,
  })  : _repository = repository,
        _operatorId = operatorId,
        _locationId = locationId,
        _userId = userId;

  final EventOutboxRepository _repository;
  final String _operatorId;
  final String _locationId;
  final String? _userId;

  @override
  Future<String?> persist({
    required String restaurantId,
    required String businessDate,
  }) {
    return _repository.enqueue(
      operatorId: _operatorId,
      locationId: _locationId,
      userId: _userId,
      topic: boundaryRolloverEventTopic,
      payload: <String, Object?>{
        'restaurant_id': restaurantId,
        'business_date': businessDate,
      },
    );
  }

  @override
  Future<List<PendingBoundaryEvent>> claimPending({int batchSize = 100}) async {
    final claimed = await _repository.claimBatch(
      operatorId: _operatorId,
      locationId: _locationId,
      userId: _userId,
      batchSize: batchSize,
      topic: boundaryRolloverEventTopic,
    );
    return <PendingBoundaryEvent>[
      for (final row in claimed)
        PendingBoundaryEvent(
          eventId: row.id,
          restaurantId: (row.payload['restaurant_id'] as String?) ?? '',
          businessDate: (row.payload['business_date'] as String?) ?? '',
        ),
    ];
  }

  @override
  Future<void> markDelivered(String eventId) async {
    await _repository.markDelivered(
      operatorId: _operatorId,
      locationId: _locationId,
      userId: _userId,
      eventId: eventId,
    );
  }
}
