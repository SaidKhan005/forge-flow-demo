// Phase 8.RV — Revel Systems webhook signature verifier.
//
// Per `https://developer.revelsystems.com/revelsystems/docs/webhooks`
// (retrieval date 2026-05-03), Revel signs every inbound webhook with
// HMAC-SHA1 over the raw request body, hex-encoded (lowercase), in the
// `X-Revel-Signature` header. Revel does NOT include a timestamp in
// the signed payload; replay defense at the framework layer therefore
// relies on the idempotency UNIQUE on
// `inbound_webhook_idempotency(vendor_id, operator_id, vendor_event_id)`
// rather than a per-event signed-timestamp window. The verifier
// returns `WebhookSignatureVerification.timestamp == null` so the
// framework's 24h replay ceiling is bypassed (the ceiling stays at
// 24h per V1 lean cut 2; Revel just does not bind a timestamp into
// the signature).
//
// Constant-time HMAC compare uses the framework's
// `constantTimeBytesEquals` helper so a timing oracle cannot leak
// the signature byte-by-byte.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/integration/inbound_webhook_handler.dart';
import 'revel_pos_adapter.dart';

/// Header carrying the hex-encoded HMAC-SHA1 signature.
const String kRevelSignatureHeader = 'x-revel-signature';

/// Header carrying the customer instance name (binding cross-check).
const String kRevelInstanceHeader = 'x-revel-instance';

/// Header carrying the event type (`order.finalized`, `ping`, etc.).
const String kRevelEventTypeHeader = 'x-revel-event-type';

/// Header carrying the unique event id. Surfaced to the framework's
/// idempotency key resolver via `headers['x-vendor-event-id']` so the
/// inbound handler keys idempotency on it without re-parsing the body.
const String kRevelEventIdHeader = 'x-revel-event-id';

class RevelWebhookSignatureVerifier implements VendorWebhookSignatureVerifier {
  const RevelWebhookSignatureVerifier();

  @override
  String get vendorId => kRevelVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedHex = _headerOrNull(headers, kRevelSignatureHeader);
    if (providedHex == null || providedHex.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing X-Revel-Signature header',
      );
    }
    final providedBytes = _decodeHex(providedHex);
    if (providedBytes == null) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'X-Revel-Signature is not valid hexadecimal',
      );
    }
    final expectedDigest = Hmac(sha1, utf8.encode(signingSecret))
        .convert(rawBody)
        .bytes;
    final ok = constantTimeBytesEquals(providedBytes, expectedDigest);
    if (!ok) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'X-Revel-Signature HMAC mismatch',
      );
    }
    // Revel does not bind a timestamp into the signed payload. Return
    // null so the framework's 24h replay ceiling is bypassed; the
    // idempotency UNIQUE on (vendor_id, operator_id, vendor_event_id)
    // is the duplicate-write defense for legitimate retries (see
    // `lib/services/integration/inbound_webhook_handler.dart` —
    // `kInboundWebhookReplayCeiling = Duration(hours: 24)` stays the
    // ceiling but only fires when a verifier reports a timestamp).
    return const WebhookSignatureVerification(valid: true);
  }

  String? _headerOrNull(Map<String, String> headers, String key) {
    final lower = headers[key];
    if (lower != null) return lower;
    // Fallback: tolerate a case-bearing key in case the route layer
    // forgot to normalize. The framework already lower-cases on the
    // way in but this keeps the verifier resilient.
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == key) {
        return entry.value;
      }
    }
    return null;
  }

  List<int>? _decodeHex(String hex) {
    final clean = hex.trim();
    if (clean.length.isOdd) return null;
    final out = <int>[];
    for (var i = 0; i < clean.length; i += 2) {
      final byteStr = clean.substring(i, i + 2);
      final byte = int.tryParse(byteStr, radix: 16);
      if (byte == null) return null;
      out.add(byte);
    }
    return out;
  }
}
