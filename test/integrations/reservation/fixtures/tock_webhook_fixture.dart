// Phase 8R.TC — Tock webhook fixture.
//
// Source: https://api.exploretock.com/docs/latest/reservation.html
// Source: Tock Premium-tier developer portal (gated; HMAC-SHA256
// signing scheme summarized in
// docs/integrations/tock/webhook_signature.md)
// Retrieval date: 2026-05-04
//
// Tock webhook signing convention (documented):
//   * HMAC-SHA256 over raw HTTP body bytes.
//   * Encoding: lowercase hex.
//   * Header: `X-Tock-Signature` (case-insensitive at the framework).
//   * Optional timestamp header: `X-Tock-Webhook-Timestamp`
//     (Unix epoch seconds).
//   * Webhook delivery is `manualPaste`: operators paste the F&F
//     webhook URL + signing secret into the Tock Premium-tier
//     dashboard. The adapter does NOT auto-register.
//
// V1 lean cut 2: replay tolerance is the framework's 24-hour ceiling;
// strict 5-minute window is explicitly NOT used.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Tock `reservation.updated` event body. Tock emits the full
/// reservation shape inline; the adapter normalizes via
/// `_canonicalize` before any fact write.
Map<String, Object?> tockReservationUpdatedEvent({
  required String reservationId,
  required String businessId,
  required DateTime serviceDateTimestamp,
  required DateTime lastUpdatedTimestamp,
  required DateTime createdTimestamp,
  required int partySize,
  required String status,
}) {
  return <String, Object?>{
    'eventId': 'evt_$reservationId',
    'eventType': 'reservation.updated',
    'businessId': businessId,
    'id': reservationId,
    'serviceDateTimestamp': serviceDateTimestamp.toIso8601String(),
    'lastUpdatedTimestamp': lastUpdatedTimestamp.toIso8601String(),
    'createdTimestamp': createdTimestamp.toIso8601String(),
    'partySize': partySize,
    'status': status,
  };
}

/// Sign a raw body the same way Tock does: HMAC-SHA256, lowercase hex.
String signTockWebhookBody({
  required List<int> rawBody,
  required String signingSecret,
}) {
  final hmac = Hmac(sha256, utf8.encode(signingSecret));
  final digest = hmac.convert(rawBody);
  // Lowercase hex per Tock's documented convention.
  final hex = StringBuffer();
  for (final byte in digest.bytes) {
    hex.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString();
}

/// Convenience: build matching headers for a fixture body.
Map<String, String> tockWebhookHeaders({
  required List<int> rawBody,
  required String signingSecret,
  DateTime? timestamp,
}) {
  final headers = <String, String>{
    'x-tock-signature': signTockWebhookBody(
      rawBody: rawBody,
      signingSecret: signingSecret,
    ),
  };
  if (timestamp != null) {
    headers['x-tock-webhook-timestamp'] =
        (timestamp.toUtc().millisecondsSinceEpoch ~/ 1000).toString();
  }
  return headers;
}
