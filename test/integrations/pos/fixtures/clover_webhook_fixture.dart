// Phase 8 (`8.CL`) — Clover webhook fixture pack.
//
// Source documentation:
//   * Webhooks overview:    https://docs.clover.com/docs/using-webhooks
//   * Signature header doc: https://docs.clover.com/docs/webhooks#verifying-the-webhook
//   * Configuration:        https://docs.clover.com/docs/configuring-webhooks
// Retrieval date: 2026-05-03
//
// Documented intent (verified at `8.CL.live.sandbox`):
//   * Algorithm:        HMAC-SHA256
//   * Encoding:         Base64 (case-sensitive)
//   * Signed payload:   raw request body bytes verbatim
//   * Signature header: `X-Clover-Auth-Signature`
//   * Timestamp header: `X-Clover-Auth-Timestamp` (Unix epoch seconds)
//   * Replay tolerance: 24h (V1 lean cut 2 — see
//                       `kInboundWebhookReplayCeiling`).
//   * Constant-time:    `constantTimeBytesEquals`.
//
// The `8.CL.live.sandbox` slice diffs each of these against observed
// vendor webhook traffic; ambiguity rows in
// `docs/integrations/clover/webhook_signature.md` are the first ones
// re-checked.

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Documented header names. Tests assert on these.
const String cloverWebhookSignatureHeader = 'x-clover-auth-signature';
const String cloverWebhookTimestampHeader = 'x-clover-auth-timestamp';

/// Signing-secret stub used across fixtures. Production secrets live
/// only in Cloud Run env / vendor_credentials encrypted store.
const String fixtureCloverSigningSecret =
    'whsec_clover_fixture_only_do_not_ship';

/// One sample webhook envelope — Clover's documented webhook bodies
/// carry the merchant id, an event type, and a payload of ids the
/// adapter then re-fetches via `/v3/merchants/{mId}/orders/{orderId}`.
const Map<String, Object?> sampleCloverWebhookEnvelope = <String, Object?>{
  'event_id': 'CLV-EVT-9C2A4D7E-2026-05-02-001',
  'merchant': <String, Object?>{'id': 'CLV-MERCH-CCD13C7B'},
  'type': 'ORDER_UPDATED',
  'objectId': 'CLV-ORDER-7HXJ-2026-05-02-001',
  'ts': 1746213781000,
};

/// Encode an envelope deterministically — the same bytes the adapter
/// would have signed at the vendor edge. Sort keys so the fixture is
/// stable across Dart map iteration order.
String cloverWebhookCanonicalBody(Map<String, Object?> envelope) {
  final sorted = SplayTreeMap<String, Object?>.from(envelope);
  return const JsonEncoder().convert(sorted);
}

/// Compute the documented signature header for a body + secret.
/// Tests use this to build the "valid" signature that the verifier
/// must accept; flipping a single byte produces the "tampered"
/// signature for the reject-path test.
String cloverFixtureSignature({
  required Uint8List rawBody,
  required String signingSecret,
}) {
  final hmac = Hmac(sha256, utf8.encode(signingSecret));
  final digest = hmac.convert(rawBody);
  return base64.encode(digest.bytes);
}

/// Build the documented header set for a fixture webhook.
Map<String, String> cloverFixtureHeaders({
  required Uint8List rawBody,
  required DateTime timestamp,
  required String signingSecret,
}) {
  final unixSeconds = timestamp.toUtc().millisecondsSinceEpoch ~/ 1000;
  return <String, String>{
    cloverWebhookSignatureHeader: cloverFixtureSignature(
      rawBody: rawBody,
      signingSecret: signingSecret,
    ),
    cloverWebhookTimestampHeader: '$unixSeconds',
  };
}

/// Build a tampered header set — same shape as
/// [cloverFixtureHeaders] but the signature byte sequence is flipped
/// at one position so the constant-time compare returns false.
Map<String, String> cloverFixtureTamperedHeaders({
  required Uint8List rawBody,
  required DateTime timestamp,
  required String signingSecret,
}) {
  final headers = cloverFixtureHeaders(
    rawBody: rawBody,
    timestamp: timestamp,
    signingSecret: signingSecret,
  );
  final original = headers[cloverWebhookSignatureHeader]!;
  // Flip the last char to a different valid base64 char so the
  // header parses cleanly but the bytes diverge.
  final swapped = original.endsWith('A')
      ? '${original.substring(0, original.length - 1)}B'
      : '${original.substring(0, original.length - 1)}A';
  headers[cloverWebhookSignatureHeader] = swapped;
  return headers;
}
