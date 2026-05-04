// Phase 8.TS — Toast webhook fixture.
//
// Source: https://doc.toasttab.com/openapi/webhooks/webhook-management
// Source: https://doc.toasttab.com/doc/devguide/apiWebhooksOverview.html
// Retrieval date: 2026-05-03
//
// Toast webhook signing convention (documented):
//   * HMAC-SHA256 over raw HTTP body bytes.
//   * Encoding: base64.
//   * Header: `Toast-Signature` (case-insensitive at the framework).
//   * Optional timestamp header: `Toast-Webhook-Timestamp`
//     (Unix epoch seconds).
//
// V1 lean cut 2: replay tolerance is the framework's 24-hour ceiling;
// strict 5-minute window is explicitly NOT used.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Toast `orders.opened` / `orders.modified` event body. Toast emits
/// the full order shape inline; the adapter normalizes via
/// `_canonicalize` before any fact write.
Map<String, Object?> toastOrdersModifiedEvent({
  required String guid,
  required String restaurantGuid,
  required DateTime openedDate,
  required DateTime closedDate,
  required DateTime modifiedDate,
  required int numberOfGuests,
  required double totalAmount,
}) {
  return <String, Object?>{
    'eventGuid': 'evt-$guid',
    'eventType': 'orders.modified',
    'restaurantGuid': restaurantGuid,
    'guid': guid,
    'modifiedDate': modifiedDate.toIso8601String(),
    'openedDate': openedDate.toIso8601String(),
    'closedDate': closedDate.toIso8601String(),
    'numberOfGuests': numberOfGuests,
    'totalAmount': totalAmount,
    'voided': false,
  };
}

/// Sign a raw body the same way Toast does: HMAC-SHA256, base64.
String signToastWebhookBody({
  required List<int> rawBody,
  required String signingSecret,
}) {
  final hmac = Hmac(sha256, utf8.encode(signingSecret));
  final digest = hmac.convert(rawBody);
  return base64Encode(digest.bytes);
}

/// Convenience: build matching headers for a fixture body.
Map<String, String> toastWebhookHeaders({
  required List<int> rawBody,
  required String signingSecret,
  DateTime? timestamp,
}) {
  final headers = <String, String>{
    'toast-signature': signToastWebhookBody(
      rawBody: rawBody,
      signingSecret: signingSecret,
    ),
  };
  if (timestamp != null) {
    headers['toast-webhook-timestamp'] =
        (timestamp.toUtc().millisecondsSinceEpoch ~/ 1000).toString();
  }
  return headers;
}
