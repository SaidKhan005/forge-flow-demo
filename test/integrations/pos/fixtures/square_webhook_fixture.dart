// Phase 8 — Square webhook fixtures (signed + tampered + replay
// variants).
//
// Source: https://developer.squareup.com/docs/webhooks/step3validate
// (retrieved 2026-05-03).
//
// Square computes HMAC-SHA256 over `notification_url + raw_body` and
// base64-encodes the digest into the `x-square-hmacsha256-signature`
// header. The `square-initial-delivery-timestamp` header carries the
// initial delivery instant the framework uses for 24h replay aging
// (V1 lean cut 2 — strict 5-min window deleted).
//
// Variants the test suite exercises:
//   * Valid signed payload (signature verifies; replay window OK).
//   * Tampered signature (one byte flipped — verifier returns invalid).
//   * Future-dated payload (sanity hook rejects via rule 2).
//   * Replay-old payload (delivery timestamp > 24h old — verifier
//     surfaces timestamp; framework drops with `replayTooOld`).

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Notification URL the test fixtures use; mirrors the value the
/// proxy stamps into `x-ff-notification-url`.
const String squareTestNotificationUrl =
    'https://api.forgeflow.app/v1/integrations/square/webhook/op_001/loc_001';

/// Signing secret the test fixtures use. Production never holds this
/// in code — it lives encrypted in `vendor_credentials.metadata`.
const String squareTestSigningSecret = 'test-secret-2026-05-03';

/// Inbound webhook event payload shape (Square's `WebhookEvent`
/// envelope). Square sends `event_id`, `merchant_id`, `type`,
/// `created_at`, and a `data.object` body.
const Map<String, Object?> sampleWebhookPayload = <String, Object?>{
  'event_id': 'sq_evt_550e8400',
  'merchant_id': 'M_TEST_MERCHANT',
  'type': 'order.updated',
  'created_at': '2026-05-03T18:45:01Z',
  'data': <String, Object?>{
    'type': 'order',
    'id': 'sq_ord_001',
    'location_id': 'L_RESTAURANT_A',
    'object': <String, Object?>{
      'order': <String, Object?>{
        'id': 'sq_ord_001',
        'location_id': 'L_RESTAURANT_A',
        'created_at': '2026-05-03T17:30:00Z',
        'updated_at': '2026-05-03T18:45:00Z',
        'closed_at': '2026-05-03T18:45:00Z',
        'total_money': <String, Object?>{
          'amount': 4250,
          'currency': 'CAD',
        },
        'state': 'COMPLETED',
      },
    },
  },
};

/// "Thin" webhook payload — only the order id; adapter must hydrate
/// via RetrieveOrder.
const Map<String, Object?> sampleThinWebhookPayload = <String, Object?>{
  'event_id': 'sq_evt_thin_001',
  'merchant_id': 'M_TEST_MERCHANT',
  'type': 'order.updated',
  'created_at': '2026-05-03T21:30:01Z',
  'data': <String, Object?>{
    'type': 'order',
    'id': 'sq_ord_004',
    'location_id': 'L_RESTAURANT_A',
  },
};

/// Encoded body (UTF-8) for the standard fixture.
Uint8List encodedSamplePayload() => Uint8List.fromList(
      utf8.encode(jsonEncode(sampleWebhookPayload)),
    );

/// Encoded body for the thin payload variant.
Uint8List encodedThinPayload() => Uint8List.fromList(
      utf8.encode(jsonEncode(sampleThinWebhookPayload)),
    );

/// Compute Square's HMAC-SHA256 signature for [body] using the test
/// secret + [notificationUrl]. Mirrors the verifier's logic exactly so
/// the tests assert end-to-end agreement with the production code.
String computeSquareSignature({
  required Uint8List body,
  String notificationUrl = squareTestNotificationUrl,
  String secret = squareTestSigningSecret,
}) {
  final hmac = Hmac(sha256, utf8.encode(secret));
  final input = <int>[
    ...utf8.encode(notificationUrl),
    ...body,
  ];
  return base64.encode(hmac.convert(input).bytes);
}

/// Tamper a signature by flipping the last byte. Useful for the
/// signature-reject test.
String tamperSignature(String validSignature) {
  if (validSignature.isEmpty) return validSignature;
  final tail = validSignature.substring(validSignature.length - 1);
  // Swap a single base64 character to keep the string valid base64
  // length while changing the byte content.
  final swapped = tail == 'A' ? 'B' : 'A';
  return validSignature.substring(0, validSignature.length - 1) + swapped;
}
