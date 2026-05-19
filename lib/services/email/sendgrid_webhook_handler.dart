// Phase 9.8 — SendGrid event-webhook handler.
//
// Composes the three layers a SendGrid webhook POST must clear:
//
//   1. signature verification (ECDSA P-256, see
//      `sendgrid_webhook_signature_verifier.dart`)
//   2. event-payload parse + event-kind mapping
//      (`sendgrid_event_payload_parser.dart`)
//   3. dual-write to `public.email_event` + conditional flip of
//      `public.email_outbox.status` for terminal `bounced` /
//      `complaint` kinds (Postgres binding lives in
//      `tool/advisor_proxy/postgres_sendgrid_webhook_gateway.dart`).
//
// The handler is the single integration seam the route handler in
// `advisor_proxy.dart` calls. Tests substitute a fake gateway to
// pin the dispatch contract.
//
// Outcome semantics: SendGrid retries on 5xx, treats 2xx as ack, and
// treats 4xx as a delivery failure (the event is dropped, not
// retried). Mapping:
//
//   * Signature missing / invalid     -> [SendGridWebhookOutcomeRejected] (HTTP 401)
//   * Timestamp missing / out of window -> [SendGridWebhookOutcomeRejected] (HTTP 401)
//   * Body not a JSON array            -> [SendGridWebhookOutcomeBadRequest] (HTTP 400)
//   * Empty array                      -> [SendGridWebhookOutcomeAccepted] with 0 ingested
//   * Mixed batch (some events parse, some fail) -> [SendGridWebhookOutcomeAccepted] with
//                                                  ingested + failed counts; 200 OK
//   * Gateway throws                   -> rethrows; route handler maps to 503 so
//                                          SendGrid retries the batch
//
// Dispatch order: events are ingested in array order. The gateway
// upserts each event with `INSERT … ON CONFLICT (provider_event_id)
// DO NOTHING` so a retried batch with overlapping events is a partial
// no-op. Outbox status flips run AFTER the matching event row is
// successfully inserted; if a retry hits the conflict, the gateway
// returns `inserted: false` and the status flip is skipped (avoids
// flapping the status on every retry).

import 'dart:convert';

import 'sendgrid_event_payload_parser.dart';
import 'sendgrid_webhook_signature_verifier.dart';

// Re-export the header-name constants so callers (advisor_proxy.dart
// route, integration tests) need a single import to wire the route
// without reaching into the verifier file directly.
export 'sendgrid_webhook_signature_verifier.dart'
    show
        kSendGridSignatureHeader,
        kSendGridTimestampHeader,
        kSendGridWebhookDefaultTolerance;

/// Result the gateway returns from `ingest`. Tests pin the contract:
/// `inserted` is true on a fresh upsert and false on an
/// `ON CONFLICT DO NOTHING` no-op.
class SendGridEventIngestResult {
  const SendGridEventIngestResult({
    required this.providerEventId,
    required this.inserted,
    required this.outboxStatusUpdated,
    this.boundEmailId,
  });

  final String providerEventId;
  final bool inserted;
  final bool outboxStatusUpdated;

  /// `email_outbox.email_id` the gateway joined the event to. Null
  /// when neither [SendGridEventRecord.emailId] nor a
  /// `provider_message_id` lookup matched a row (out-of-band events
  /// for messages that aged out of the outbox, etc.).
  final String? boundEmailId;
}

/// Persistence seam. Production binds this to the Postgres gateway in
/// `tool/advisor_proxy/postgres_sendgrid_webhook_gateway.dart`; tests
/// substitute an in-memory fake.
abstract class SendGridWebhookGateway {
  /// Upsert one event row (ON CONFLICT (provider_event_id) DO NOTHING)
  /// and, if the event is a terminal `bounced` / `complaint` kind AND
  /// the row is fresh, transition the parent
  /// `email_outbox.status`. Idempotent.
  Future<SendGridEventIngestResult> ingest(SendGridEventRecord event);
}

/// Outcome the route handler emits. Sealed so the route's `switch` is
/// exhaustive; adding a new case forces every caller to handle it.
sealed class SendGridWebhookOutcome {
  const SendGridWebhookOutcome();
}

class SendGridWebhookOutcomeRejected extends SendGridWebhookOutcome {
  const SendGridWebhookOutcomeRejected({
    required this.reason,
  });
  final String reason;
}

class SendGridWebhookOutcomeBadRequest extends SendGridWebhookOutcome {
  const SendGridWebhookOutcomeBadRequest({
    required this.reason,
  });
  final String reason;
}

class SendGridWebhookOutcomeAccepted extends SendGridWebhookOutcome {
  const SendGridWebhookOutcomeAccepted({
    required this.ingested,
    required this.deduplicated,
    required this.outboxStatusFlips,
    required this.parseFailures,
  });

  final int ingested;
  final int deduplicated;
  final int outboxStatusFlips;
  final List<SendGridEventParseFailure> parseFailures;
}

/// Orchestrator. The route handler instantiates this once at proxy
/// boot with the public key, gateway, and (optionally) a fixed clock
/// for tests. Per-request it calls [handle] with the raw bytes + the
/// signature/timestamp headers.
class SendGridWebhookHandler {
  SendGridWebhookHandler({
    required this.publicKeyBase64,
    required SendGridWebhookGateway gateway,
    DateTime Function()? now,
    Duration tolerance = kSendGridWebhookDefaultTolerance,
  })  : _gateway = gateway,
        _now = now,
        _tolerance = tolerance;

  /// Base64 of the SendGrid event-webhook public key (DER X.509 SPKI
  /// for a P-256 / prime256v1 ECDSA key). Single value, F&F-platform-wide.
  final String publicKeyBase64;
  final SendGridWebhookGateway _gateway;
  final DateTime Function()? _now;
  final Duration _tolerance;

  Future<SendGridWebhookOutcome> handle({
    required List<int> rawBody,
    required String? signatureHeader,
    required String? timestampHeader,
  }) async {
    final sigOutcome = verifySendGridWebhookSignature(
      publicKeyBase64: publicKeyBase64,
      signatureBase64: signatureHeader,
      timestampHeader: timestampHeader,
      rawBody: rawBody,
      now: _now,
      tolerance: _tolerance,
    );
    switch (sigOutcome) {
      case SendGridWebhookSignatureValid():
        break;
      case SendGridWebhookSignatureInvalid(:final reason):
        return SendGridWebhookOutcomeRejected(
          reason: 'signature: $reason',
        );
      case SendGridWebhookTimestampOutOfWindow(:final reason):
        return SendGridWebhookOutcomeRejected(
          reason: 'timestamp: $reason',
        );
    }

    final Object? decoded;
    try {
      if (rawBody.isEmpty) {
        return const SendGridWebhookOutcomeBadRequest(
          reason: 'empty body',
        );
      }
      decoded = jsonDecode(utf8.decode(rawBody));
    } on FormatException catch (e) {
      return SendGridWebhookOutcomeBadRequest(
        reason: 'JSON parse failed: ${e.message}',
      );
    }

    final batch = parseSendGridEventPayload(decoded);
    if (batch.records.isEmpty && batch.failures.isNotEmpty) {
      // Body shape itself was wrong (top-level not a list, etc.).
      // Surface as 400 so the operator sees the malformed batch in
      // SendGrid's failed-deliveries log.
      final shapeFailure = batch.failures.firstWhere(
        (f) => f.index == -1,
        orElse: () => batch.failures.first,
      );
      return SendGridWebhookOutcomeBadRequest(
        reason: 'payload shape: ${shapeFailure.reason}',
      );
    }

    var ingested = 0;
    var deduplicated = 0;
    var outboxFlips = 0;
    for (final record in batch.records) {
      final result = await _gateway.ingest(record);
      if (result.inserted) {
        ingested++;
        if (result.outboxStatusUpdated) outboxFlips++;
      } else {
        deduplicated++;
      }
    }

    return SendGridWebhookOutcomeAccepted(
      ingested: ingested,
      deduplicated: deduplicated,
      outboxStatusFlips: outboxFlips,
      parseFailures: batch.failures,
    );
  }
}
