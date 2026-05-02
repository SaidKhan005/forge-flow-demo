// Phase 10a.0 — RealtimeEvent.
//
// Wire frame for realtime events fanning out from the
// `event_outbox` bridge to subscribed WebSocket clients. The shape
// follows `docs/contracts/event_outbox_contract.md` "Payload Shape":
// `event_id` for consumer dedupe across at-least-once redelivery and
// `occurred_at` so consumers can compute lag without joining back to
// `event_outbox`. Operator scoping is on the envelope so the proxy can
// fan to the right WebSocket without parsing the payload.

import 'dart:convert';

class RealtimeEvent {
  const RealtimeEvent({
    required this.eventId,
    required this.topic,
    required this.operatorId,
    required this.occurredAt,
    required this.payload,
  });

  /// Stable per-event identifier. Producers SHOULD set
  /// `payload['event_id']`; the bridge derives this field from that
  /// when present and falls back to the `event_outbox.id` (rendered as
  /// a string) otherwise. Consumers dedupe on this across reconnects
  /// and Pub/Sub at-least-once redelivery.
  final String eventId;

  /// Dotted-namespace topic (`rollup.invalidate.variance_week`,
  /// `auth.session.login`, etc). Locked namespaces in the contract.
  final String topic;

  /// Operator the event belongs to. The WebSocket leg only delivers
  /// frames matching the connected operator's id.
  final String operatorId;

  /// When the producer enqueued the row. Derived from the producer
  /// payload's `occurred_at` field when present; otherwise from the
  /// `event_outbox.created_at` column.
  final DateTime occurredAt;

  /// Producer-supplied JSON object body. Contract caps payload size at
  /// 32 KiB target / 256 KiB hard, enforced at the DB layer; the
  /// publisher is allowed to assume the row already cleared that
  /// CHECK.
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
    'event_id': eventId,
    'topic': topic,
    'operator_id': operatorId,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'payload': payload,
  };

  String encode() => jsonEncode(toJson());

  static RealtimeEvent fromJson(Map<String, Object?> json) {
    final eventId = json['event_id'];
    final topic = json['topic'];
    final operatorId = json['operator_id'];
    final occurredAtRaw = json['occurred_at'];
    final payloadRaw = json['payload'];
    if (eventId is! String ||
        topic is! String ||
        operatorId is! String ||
        occurredAtRaw is! String) {
      throw FormatException(
        'RealtimeEvent.fromJson: required fields missing or wrong type',
      );
    }
    final occurredAt = DateTime.parse(occurredAtRaw);
    final Map<String, Object?> payload;
    if (payloadRaw == null) {
      payload = const <String, Object?>{};
    } else if (payloadRaw is Map<String, Object?>) {
      payload = payloadRaw;
    } else if (payloadRaw is Map) {
      payload = payloadRaw.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    } else {
      throw FormatException(
        'RealtimeEvent.fromJson: payload must be a JSON object',
      );
    }
    return RealtimeEvent(
      eventId: eventId,
      topic: topic,
      operatorId: operatorId,
      occurredAt: occurredAt,
      payload: payload,
    );
  }
}
