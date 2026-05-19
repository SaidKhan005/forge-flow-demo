// Lane C C-1 — SendGrid Event Webhook payload parser.
//
// Pure-Dart typed parser for one JSON event in a SendGrid Event
// Webhook batch. Lives under `lib/services/email/` so it carries NO
// `package:postgres` import; the proxy route + repository handle the
// persistence side.
//
// SendGrid Event Webhook contract (V3):
//
//   POST <webhook url>
//   Content-Type: application/json
//   X-Twilio-Email-Event-Webhook-Signature: <base64 ECDSA P-256>
//   X-Twilio-Email-Event-Webhook-Timestamp: <unix seconds>
//
//   Body: a JSON array of event objects. Each object looks like:
//     {
//       "email":      "alice@example.com",
//       "timestamp":  1718000000,
//       "smtp-id":    "<14c5d75ce...>",
//       "event":      "delivered",
//       "sg_event_id": "rbtnWrG1DVDGGGFHFQun8A==",
//       "sg_message_id": "14c5d75ce93...filter0001.5258.5...0",
//       "useragent":  "Mozilla/5.0",
//       "ip":         "203.0.113.1",
//       "category":   ["forge_and_flow"],
//       "response":   "250 OK",
//       ...
//     }
//
//   The webhook may also batch several events for the same email
//   (e.g. processed + delivered + opened). Each carries its own
//   `sg_event_id`; per the migration `202605131700_c_1a_email_event_
//   provider_id.sql`, that is the opaque identifier we persist into
//   `email_event.provider_event_id` and dedupe against via the partial
//   UNIQUE INDEX `email_event_provider_event_id_unique`.
//
// Authority:
//   * docs/_indices/WAVE_EXECUTION_LEDGER.md row C-1 (line 83) — slice
//     scope: route + parser + signature verification + idempotent
//     insert + 6-8 tests.
//   * docs/archive/_execution/lane_c_parity/03_execution_slices.md "Slice C-1
//     — SendGrid Event Webhook receiver" (line 9-29).
//   * db/migrations/202605131700_c_1a_email_event_provider_id.sql
//     (the partial UNIQUE INDEX this parser feeds).
//   * db/migrations/202605040200_phase_9_8_email_provider.sql lines
//     301-344 (the `email_event` table CHECK on event_kind).
//
// Why a separate parser file:
//   The route handler in `tool/advisor_proxy/sendgrid_events_webhook.
//   dart` is a thin HTTP shim. The parsing is pure Dart — given a
//   `Map<String, Object?>` it returns a typed value class — and is
//   reusable from non-proxy contexts (e.g. a future replay tool that
//   reads stored event payloads). Keeping it under `lib/services/
//   email/` follows the service-layer split: `lib/services/**` is
//   runtime orchestration; pure formulas / parsers live alongside.
//
// CLAUDE.md compliance:
//   * No `package:postgres` import (Service-Layer Split).
//   * No `--dart-define=kDemoMode` branch (Hard Promise #2 — pure
//     parser; demo mode does not flow through here).

import 'dart:convert';

/// SendGrid's documented `event` field values. The `email_event` table
/// CHECK constraint at `202605040200_phase_9_8_email_provider.sql:305-
/// 310` admits the same set plus `'unknown'` as a catch-all so a
/// future SendGrid product addition does not 4xx the webhook before
/// we have a chance to refresh the catalog.
///
/// Authority for the canonical list: SendGrid Event Webhook reference
/// (https://docs.sendgrid.com/for-developers/tracking-events/event).
const Set<String> kSendGridEventKinds = <String>{
  'processed',
  'delivered',
  'opened',
  'clicked',
  'bounced',
  'complaint',
  'unsubscribed',
  'dropped',
  'deferred',
};

/// Fallback event_kind value used when SendGrid emits a kind we have
/// not yet catalogued. Mirrors the `email_event.event_kind` CHECK
/// allowlist's `'unknown'` slot.
const String kSendGridEventKindUnknown = 'unknown';

/// Maximum length of `sg_event_id` we admit. SendGrid currently emits
/// 22-char base64; we bound the input to 256 chars so a malformed /
/// malicious body cannot push an outsized opaque string into the
/// `provider_event_id` column. Postgres `text` is unbounded, but this
/// is belt-and-suspenders defense.
const int kSendGridProviderEventIdMaxLength = 256;

/// Maximum length of `sg_message_id` (provider message id) we admit.
/// SendGrid documents this as variable-length (typically 60-80 chars);
/// 512 leaves plenty of slop.
const int kSendGridProviderMessageIdMaxLength = 512;

/// Maximum length of `email` (recipient address) we admit. RFC 5321
/// caps path at 256 octets but we mirror the proxy's existing 320
/// admit value used at `admin_email_routes.dart` to stay consistent.
const int kSendGridRecipientEmailMaxLength = 320;

/// One typed SendGrid event. The route handler turns each entry of
/// the inbound JSON array into one of these, then hands them to the
/// repository.
///
/// Fields:
///   * [providerEventId] — the value of `sg_event_id`. NEVER NULL on
///     a parsed event (the parser rejects events that omit it). This
///     is the value we INSERT into `email_event.provider_event_id`
///     and dedupe against.
///   * [eventKind] — one of [kSendGridEventKinds] or
///     [kSendGridEventKindUnknown]. The parser normalises to
///     `'unknown'` when SendGrid emits a kind we have not catalogued
///     so the migration's CHECK constraint still admits the INSERT.
///   * [occurredAt] — UTC instant; built from SendGrid's `timestamp`
///     (unix seconds). The `email_event.occurred_at TIMESTAMPTZ`
///     column expects UTC per CLAUDE.md "Time Guardrails".
///   * [recipientEmail] — the `email` field. Required.
///   * [providerMessageId] — the `sg_message_id` field. Nullable on
///     the parsed object because SendGrid documentation describes
///     it as "usually present"; the repository INSERT carries NULL
///     when missing.
///   * [rawPayload] — the verbatim parsed map, preserved as a
///     `Map<String, Object?>` so the route can persist the entire
///     event JSON to `email_event.event_payload` (jsonb) for future
///     replay / diagnostic use.
class SendGridEvent {
  const SendGridEvent({
    required this.providerEventId,
    required this.eventKind,
    required this.occurredAt,
    required this.recipientEmail,
    required this.providerMessageId,
    required this.rawPayload,
  });

  final String providerEventId;
  final String eventKind;
  final DateTime occurredAt;
  final String recipientEmail;
  final String? providerMessageId;
  final Map<String, Object?> rawPayload;

  /// Decode one event object from the inbound batch. Throws
  /// [SendGridEventParseException] on any structural problem so the
  /// route handler can map every malformed entry into a 400 with a
  /// uniform error envelope.
  factory SendGridEvent.fromJson(Map<String, Object?> json) {
    final providerEventId = _readString(
      json,
      'sg_event_id',
      maxLength: kSendGridProviderEventIdMaxLength,
      required: true,
    )!;
    final recipientEmail = _readString(
      json,
      'email',
      maxLength: kSendGridRecipientEmailMaxLength,
      required: true,
    )!;
    final providerMessageId = _readString(
      json,
      'sg_message_id',
      maxLength: kSendGridProviderMessageIdMaxLength,
      required: false,
    );
    final rawKind = _readString(
      json,
      'event',
      maxLength: 64,
      required: true,
    )!;
    final normalisedKind = kSendGridEventKinds.contains(rawKind)
        ? rawKind
        : kSendGridEventKindUnknown;
    final occurredAt = _readTimestamp(json);
    return SendGridEvent(
      providerEventId: providerEventId,
      eventKind: normalisedKind,
      occurredAt: occurredAt,
      recipientEmail: recipientEmail,
      providerMessageId: providerMessageId,
      rawPayload: Map<String, Object?>.unmodifiable(json),
    );
  }

  /// Convenience helper for tests + diagnostic logs. Returns a
  /// deterministically-ordered JSON string for the parsed event.
  String toCompactJson() => jsonEncode(<String, Object?>{
        'provider_event_id': providerEventId,
        'event_kind': eventKind,
        'occurred_at': occurredAt.toUtc().toIso8601String(),
        'recipient_email': recipientEmail,
        'provider_message_id': providerMessageId,
      });

  static String? _readString(
    Map<String, Object?> json,
    String key, {
    required int maxLength,
    required bool required,
  }) {
    final value = json[key];
    if (value == null) {
      if (required) {
        throw SendGridEventParseException(
          field: key,
          message: 'missing required field `$key`',
        );
      }
      return null;
    }
    if (value is! String) {
      throw SendGridEventParseException(
        field: key,
        message: 'field `$key` must be a string',
      );
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      if (required) {
        throw SendGridEventParseException(
          field: key,
          message: 'field `$key` must be a non-empty string',
        );
      }
      return null;
    }
    if (trimmed.length > maxLength) {
      throw SendGridEventParseException(
        field: key,
        message: 'field `$key` must be $maxLength characters or fewer',
      );
    }
    return trimmed;
  }

  static DateTime _readTimestamp(Map<String, Object?> json) {
    final raw = json['timestamp'];
    if (raw == null) {
      throw const SendGridEventParseException(
        field: 'timestamp',
        message: 'missing required field `timestamp`',
      );
    }
    int seconds;
    if (raw is int) {
      seconds = raw;
    } else if (raw is double) {
      seconds = raw.toInt();
    } else if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed == null) {
        throw const SendGridEventParseException(
          field: 'timestamp',
          message: 'field `timestamp` must be an integer (unix seconds)',
        );
      }
      seconds = parsed;
    } else {
      throw const SendGridEventParseException(
        field: 'timestamp',
        message: 'field `timestamp` must be an integer (unix seconds)',
      );
    }
    // Sanity bound: SendGrid timestamps are unix seconds, so they sit
    // in the (10-digit) range for the foreseeable future. Reject
    // negative or absurdly large values so a malformed body cannot
    // produce a year-9999-ish row that breaks downstream pruning.
    if (seconds < 0 || seconds > 9999999999) {
      throw const SendGridEventParseException(
        field: 'timestamp',
        message: 'field `timestamp` is out of the acceptable range',
      );
    }
    return DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    );
  }
}

/// Typed parse failure. The route handler maps every instance into a
/// uniform 400 envelope so a malformed entry surfaces field-level
/// detail without leaking the rest of the payload.
class SendGridEventParseException implements Exception {
  const SendGridEventParseException({
    required this.field,
    required this.message,
  });

  final String field;
  final String message;

  @override
  String toString() => 'SendGridEventParseException($field): $message';
}
