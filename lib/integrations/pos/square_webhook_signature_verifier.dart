// Phase 8 — Square webhook signature verifier (lifecycle = `documented`).
//
// Source: https://developer.squareup.com/docs/webhooks/step3validate
// (retrieved 2026-05-03).
//
// Square signs webhook deliveries with HMAC-SHA256. The signed payload
// is `notification_url + raw_request_body` — concatenation of the
// configured webhook URL with the raw bytes of the body. The signature
// is base64-encoded and arrives in the `x-square-hmacsha256-signature`
// header. The verifier MUST run constant-time compare against the
// expected digest to avoid timing oracles.
//
// Replay defense (V1 lean cut 2): 24 hours via the
// `square-initial-delivery-timestamp` header — Square stamps the
// initial delivery instant on every event so retries can be aged
// against it. The framework's strict 5-minute window from iter1 was
// deleted because vendor retry windows commonly exceed 5 minutes.
// Idempotency on `(vendor_id, operator_id, vendor_event_id)` is the
// backstop against double-write.
//
// The verifier reads the F&F-side notification URL from the
// `x-ff-notification-url` header — the proxy route handler stamps
// this header from `connector_connection.metadata.notification_url`
// (the URL the adapter registered with Square at connect time) so
// the verifier never has to call back into the gateway.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/integration/inbound_webhook_handler.dart';

/// Header carrying the base64 HMAC-SHA256 of `notification_url + body`.
const String kSquareSignatureHeader = 'x-square-hmacsha256-signature';

/// Header carrying the initial-delivery timestamp Square uses for
/// replay aging. ISO 8601, UTC. Documented at
/// https://developer.squareup.com/docs/webhooks/step3validate.
const String kSquareDeliveryTimestampHeader =
    'square-initial-delivery-timestamp';

/// Header the proxy stamps with the F&F notification URL the operator
/// registered with Square (read from
/// `connector_connection.metadata.notification_url`). The verifier
/// folds this into the HMAC input.
const String kSquareNotificationUrlHeader = 'x-ff-notification-url';

/// Replay tolerance — matches `kInboundWebhookReplayCeiling` (24h)
/// from `inbound_webhook_handler.dart`. Square retries can stretch
/// hours during outages; tighter than this kills legitimate retries.
const Duration kSquareReplayTolerance = Duration(hours: 24);

/// Square webhook signature verifier.
///
/// Stateless; one instance per process. Header lookups are
/// case-insensitive — `InboundWebhookHandler` lowercases keys before
/// dispatch, so we read lowercase keys directly.
class SquareWebhookSignatureVerifier
    implements VendorWebhookSignatureVerifier {
  const SquareWebhookSignatureVerifier();

  @override
  String get vendorId => 'square';

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedSig = headers[kSquareSignatureHeader];
    if (providedSig == null || providedSig.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing $kSquareSignatureHeader header',
      );
    }

    final notificationUrl = headers[kSquareNotificationUrlHeader];
    if (notificationUrl == null || notificationUrl.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason:
            'missing $kSquareNotificationUrlHeader header (proxy must stamp the registered Square notification URL)',
      );
    }

    final hmac = Hmac(sha256, utf8.encode(signingSecret));
    final input = <int>[
      ...utf8.encode(notificationUrl),
      ...rawBody,
    ];
    final expectedDigest = hmac.convert(input).bytes;
    final List<int> providedDigest;
    try {
      providedDigest = base64.decode(providedSig);
    } on FormatException {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'signature header is not valid base64',
      );
    }

    if (!constantTimeBytesEquals(expectedDigest, providedDigest)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'HMAC-SHA256 mismatch',
      );
    }

    final timestamp = _parseDeliveryTimestamp(headers);
    return WebhookSignatureVerification(
      valid: true,
      timestamp: timestamp,
    );
  }

  DateTime? _parseDeliveryTimestamp(Map<String, String> headers) {
    final raw = headers[kSquareDeliveryTimestampHeader];
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    return parsed?.toUtc();
  }
}
