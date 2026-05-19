// Phase 9.8 — SendGrid event-webhook payload parser.
//
// SendGrid's event webhook POSTs a JSON array of event records, one
// element per event. The proxy's webhook handler verifies the
// signature against the raw body bytes (see
// `sendgrid_webhook_signature_verifier.dart`) and only then hands the
// decoded JSON to this parser to translate provider-shape into the
// shape the Postgres webhook gateway writes.
//
// Per-event fields we depend on:
//
//   * `event`              — SendGrid event type. Mapped to our
//                            `email_event.event_kind` enum below.
//   * `timestamp`          — Unix seconds. Mapped to `occurred_at`.
//   * `sg_event_id`        — per-event UUID, unique across retries.
//                            Used as the idempotency key. The 9.8
//                            slice migration adds
//                            `email_event.provider_event_id` with a
//                            partial UNIQUE index keyed on this value.
//   * `sg_message_id`      — SendGrid's per-message id; matches the
//                            `X-Message-Id` we stamped on
//                            `email_outbox.provider_message_id` at send
//                            time. Used as a fallback when the
//                            custom-arg `email_id` is absent (e.g.
//                            historic rows that pre-date custom_args).
//   * `email_id`           — custom_arg echoed back; the canonical
//                            join key into `email_outbox.email_id`.
//                            See `sendgrid_email_provider.dart` ->
//                            `_buildSendBody` for the producer side.
//
// Event-kind mapping (provider type -> `email_event.event_kind`):
//
//   processed          -> processed
//   deferred           -> deferred
//   delivered          -> delivered
//   open               -> opened
//   click              -> clicked
//   bounce             -> bounced
//   blocked            -> bounced       (treated as bounced for state)
//   dropped            -> dropped
//   spamreport         -> complaint
//   unsubscribe        -> unsubscribed
//   group_unsubscribe  -> unsubscribed
//   anything else      -> unknown       (recorded but no status flip)
//
// Outbox status side-effects:
//
//   bounced  -> set email_outbox.status = 'bounced'
//   complaint -> set email_outbox.status = 'complaint'
//
// Other event kinds DO NOT mutate `email_outbox.status` — they are
// telemetry only. The dispatcher already drove the row to `sent`
// before any webhook event lands; downgrading `sent` to `delivered`
// would mean the column carries two state machines, which the slice
// doc explicitly rejects ("status reflects the dispatcher's sender
// view; webhooks own only the bounced / complaint terminal states").

/// Per-event record produced by the parser and consumed by the
/// gateway. Lives here (not in `sendgrid_webhook_handler.dart`) so the
/// parser ↔ handler import graph stays acyclic — the handler imports
/// the parser, never the other way.
class SendGridEventRecord {
  const SendGridEventRecord({
    required this.providerEventId,
    required this.providerEventKindRaw,
    required this.eventKind,
    required this.occurredAt,
    required this.payload,
    this.emailId,
    this.providerMessageId,
  });

  /// Per-event idempotency key (SendGrid's `sg_event_id`).
  final String providerEventId;

  /// Raw provider type string (e.g. "delivered", "bounce"). Kept so
  /// the gateway logger can name the source even when the mapping
  /// returns `unknown`.
  final String providerEventKindRaw;

  /// Mapped value for `email_event.event_kind`. One of `processed`,
  /// `delivered`, `opened`, `clicked`, `bounced`, `complaint`,
  /// `unsubscribed`, `dropped`, `deferred`, `unknown`.
  final String eventKind;

  /// Provider-side timestamp, UTC.
  final DateTime occurredAt;

  /// Custom-arg `email_id` SendGrid echoes back. Canonical join key
  /// into `email_outbox.email_id`. Null only on legacy events.
  final String? emailId;

  /// SendGrid's `sg_message_id` (= `email_outbox.provider_message_id`).
  /// Fallback join path when [emailId] is absent.
  final String? providerMessageId;

  /// Full event payload, stored verbatim in `email_event.event_payload`.
  final Map<String, Object?> payload;
}

/// Per-event failure produced by the parser. Surfaced in the route
/// log so an operator can spot a malformed batch without enabling
/// debug-level logging.
class SendGridEventParseFailure {
  const SendGridEventParseFailure({
    required this.index,
    required this.reason,
    this.providerEventId,
  });

  /// Index in the JSON array (0-based). `-1` if the body shape itself
  /// failed.
  final int index;
  final String? providerEventId;
  final String reason;
}

/// Container returned by [parseSendGridEventPayload].
class SendGridEventBatch {
  const SendGridEventBatch({
    required this.records,
    required this.failures,
  });

  final List<SendGridEventRecord> records;
  final List<SendGridEventParseFailure> failures;
}

/// Map of SendGrid `event` type strings to our `email_event.event_kind`
/// enum literals. Public for tests.
const Map<String, String> kSendGridEventKindMap = <String, String>{
  'processed': 'processed',
  'deferred': 'deferred',
  'delivered': 'delivered',
  'open': 'opened',
  'click': 'clicked',
  'bounce': 'bounced',
  'blocked': 'bounced',
  'dropped': 'dropped',
  'spamreport': 'complaint',
  'unsubscribe': 'unsubscribed',
  'group_unsubscribe': 'unsubscribed',
};

/// Event kinds that, when ingested, also flip the parent
/// `email_outbox.status` to a terminal failure state. Order matters —
/// the gateway uses the literal string as the new status value.
const Map<String, String> kSendGridOutboxTerminalStatuses = <String, String>{
  'bounced': 'bounced',
  'complaint': 'complaint',
};

/// Parse a decoded SendGrid event-webhook payload into a list of
/// [SendGridEventRecord] values. Per-event errors are reported via
/// [SendGridEventParseFailure] alongside the successful records so
/// the route handler can ingest the good ones AND log the bad ones.
///
/// Inputs:
///   * [decoded] — the result of `jsonDecode(rawBody)` on the webhook
///     POST body. Must be a `List`; non-list shapes are rejected at
///     the route boundary so this function fails loudly if violated.
///
/// Returns: a [SendGridEventBatch] holding successfully parsed records
/// AND per-event failures. The route handler uses both: it inserts the
/// successes into `email_event` and writes the failures to the proxy
/// log (no http response code change — SendGrid retries on 5xx, so
/// returning 200 even with per-event failures avoids a retry storm
/// for one malformed event in a 1000-event batch).
SendGridEventBatch parseSendGridEventPayload(Object? decoded) {
  if (decoded is! List) {
    return SendGridEventBatch(
      records: const <SendGridEventRecord>[],
      failures: <SendGridEventParseFailure>[
        SendGridEventParseFailure(
          index: -1,
          reason: 'event payload must be a JSON array',
        ),
      ],
    );
  }
  final records = <SendGridEventRecord>[];
  final failures = <SendGridEventParseFailure>[];
  for (var i = 0; i < decoded.length; i++) {
    final raw = decoded[i];
    if (raw is! Map) {
      failures.add(SendGridEventParseFailure(
        index: i,
        reason: 'event element is not a JSON object',
      ));
      continue;
    }
    final result = _parseOne(i, raw);
    switch (result) {
      case _ParseSuccess(:final record):
        records.add(record);
      case _ParseFailure(:final failure):
        failures.add(failure);
    }
  }
  return SendGridEventBatch(
    records: List<SendGridEventRecord>.unmodifiable(records),
    failures: List<SendGridEventParseFailure>.unmodifiable(failures),
  );
}

sealed class _ParseResult {
  const _ParseResult();
}

class _ParseSuccess extends _ParseResult {
  const _ParseSuccess(this.record);
  final SendGridEventRecord record;
}

class _ParseFailure extends _ParseResult {
  const _ParseFailure(this.failure);
  final SendGridEventParseFailure failure;
}

_ParseResult _parseOne(int index, Map<dynamic, dynamic> raw) {
  final providerEventId = _readString(raw['sg_event_id']);
  if (providerEventId == null) {
    return _ParseFailure(SendGridEventParseFailure(
      index: index,
      reason: 'missing sg_event_id',
    ));
  }
  final providerEventKindRaw = _readString(raw['event']);
  if (providerEventKindRaw == null) {
    return _ParseFailure(SendGridEventParseFailure(
      index: index,
      providerEventId: providerEventId,
      reason: 'missing event field',
    ));
  }
  final timestamp = _readInt(raw['timestamp']);
  if (timestamp == null) {
    return _ParseFailure(SendGridEventParseFailure(
      index: index,
      providerEventId: providerEventId,
      reason: 'missing or non-integer timestamp',
    ));
  }
  final providerMessageId = _readString(raw['sg_message_id']);
  final emailId = _readString(raw['email_id']);
  final occurredAt = DateTime.fromMillisecondsSinceEpoch(
    timestamp * 1000,
    isUtc: true,
  );
  final mappedKind = kSendGridEventKindMap[providerEventKindRaw] ?? 'unknown';
  return _ParseSuccess(SendGridEventRecord(
    providerEventId: providerEventId,
    providerEventKindRaw: providerEventKindRaw,
    eventKind: mappedKind,
    occurredAt: occurredAt,
    emailId: emailId,
    providerMessageId: providerMessageId,
    payload: Map<String, Object?>.from(raw.map(
      (key, value) => MapEntry(key.toString(), value),
    )),
  ));
}

String? _readString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
