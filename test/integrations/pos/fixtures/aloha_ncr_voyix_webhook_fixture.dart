// Phase 8.AL — Aloha (NCR Voyix) webhook fixture.
//
// Source: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
// Retrieval date: 2026-05-04
//
// NCR Voyix Aloha-module webhook signing convention (documented):
//   * HMAC-SHA256 over raw HTTP body bytes.
//   * Encoding: base64.
//   * Header: `NCR-Webhook-Signature` (case-insensitive at the
//     framework).
//   * Optional timestamp header: `NCR-Webhook-Timestamp` (Unix epoch
//     seconds).
//
// Ambiguity calls verified in `8.AL.live.sandbox`:
//   * Exact header name (NCR-Webhook-Signature vs Aloha-module-
//     specific variant). The fixture treats the documented header as
//     canonical.
//   * Whether the signature covers raw body alone or
//     `<timestamp>.<body>`. The fixture uses raw body; live diff fix
//     is bounded.
//
// V1 lean cut 2: replay tolerance is the framework's 24-hour ceiling;
// strict 5-minute window is explicitly NOT used.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// NCR Voyix Aloha-module `aloha.check.modified` event body. The vendor
/// emits the full check shape inline; the adapter normalizes via
/// `_canonicalize` before any fact write.
Map<String, Object?> alohaNcrVoyixCheckModifiedEvent({
  required String checkId,
  required String siteId,
  required DateTime openedAt,
  required DateTime closedAt,
  required DateTime modifiedAt,
  required int numberOfGuests,
  required double totalAmount,
}) {
  return <String, Object?>{
    'eventId': 'evt-$checkId',
    'eventType': 'aloha.check.modified',
    'siteId': siteId,
    'checkId': checkId,
    'modifiedAt': modifiedAt.toIso8601String(),
    'openedAt': openedAt.toIso8601String(),
    'closedAt': closedAt.toIso8601String(),
    'numberOfGuests': numberOfGuests,
    'totalAmount': totalAmount,
    'voided': false,
  };
}

/// Sign a raw body the same way NCR Voyix does: HMAC-SHA256, base64.
String signAlohaNcrVoyixWebhookBody({
  required List<int> rawBody,
  required String signingSecret,
}) {
  final hmac = Hmac(sha256, utf8.encode(signingSecret));
  final digest = hmac.convert(rawBody);
  return base64Encode(digest.bytes);
}

/// Convenience: build matching headers for a fixture body.
Map<String, String> alohaNcrVoyixWebhookHeaders({
  required List<int> rawBody,
  required String signingSecret,
  DateTime? timestamp,
}) {
  final headers = <String, String>{
    'ncr-webhook-signature': signAlohaNcrVoyixWebhookBody(
      rawBody: rawBody,
      signingSecret: signingSecret,
    ),
  };
  if (timestamp != null) {
    headers['ncr-webhook-timestamp'] =
        (timestamp.toUtc().millisecondsSinceEpoch ~/ 1000).toString();
  }
  return headers;
}
