// Phase 10a.0 — OutboxNotificationListener seam.
//
// `event_outbox` rows fire `pg_notify('event_outbox', '{operator_id,
// topic, id}')` after every INSERT (see
// `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql`).
// The Phase 10a.0 bridge worker uses these notifications as a wake-up
// signal so it does not have to poll on idle operators.
//
// Important contract reminder (event_outbox_contract.md):
//   * NOTIFY is a wake-up signal only. The worker MUST also poll on a
//     60s schedule because Postgres drops notifications under
//     connection failure or queue pressure.
//   * The worker MUST claim full rows through
//     `EventOutboxRepository.claimBatch(...)` — it must not treat the
//     notification payload as the row body.
//
// LISTEN is connection-scoped (not transaction-scoped), so the listener
// owns its own dedicated `package:postgres` connection rather than
// going through `TenantTransactionWrapper`. This is one of the few
// places where the seam's "every operation runs inside a transaction"
// rule does not fit; the listener does no application reads/writes,
// only LISTEN + parse.

import 'dart:async';
import 'dart:convert';

class OutboxNotification {
  const OutboxNotification({
    required this.operatorId,
    required this.topic,
    required this.outboxId,
  });

  /// Operator the row belongs to. The bridge worker uses this to pick
  /// the right tenant context for the follow-up `claimBatch` call.
  final String operatorId;

  /// Dotted-namespace topic from the producer
  /// (`rollup.invalidate.variance_week`, etc).
  final String topic;

  /// `event_outbox.id` rendered as a string. The contract intentionally
  /// keeps the notification payload tiny — the bridge reads the full
  /// row from the table on claim.
  final String outboxId;

  static OutboxNotification fromPayload(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      throw FormatException(
        'OutboxNotification payload was not a JSON object',
      );
    }
    final operatorId = decoded['operator_id'];
    final topic = decoded['topic'];
    final id = decoded['id'];
    if (operatorId is! String ||
        topic is! String ||
        operatorId.isEmpty ||
        topic.isEmpty) {
      throw FormatException(
        'OutboxNotification payload missing operator_id/topic',
      );
    }
    final String outboxId;
    if (id is String) {
      outboxId = id;
    } else if (id is int) {
      outboxId = id.toString();
    } else if (id is num) {
      outboxId = id.toInt().toString();
    } else {
      throw FormatException(
        'OutboxNotification payload id must be a string or integer',
      );
    }
    return OutboxNotification(
      operatorId: operatorId,
      topic: topic,
      outboxId: outboxId,
    );
  }
}

abstract class OutboxNotificationListener {
  /// Stream of notifications received on the `event_outbox` channel.
  /// The stream is broadcast so the bridge worker can subscribe
  /// without preventing later test fakes from also subscribing.
  Stream<OutboxNotification> get notifications;

  /// Open the underlying connection and start LISTENing. Idempotent:
  /// repeated calls are no-ops once the listener is started.
  Future<void> start();

  /// Stop listening and close the underlying connection. After
  /// [stop], the listener cannot be restarted — create a new one.
  Future<void> stop();
}
