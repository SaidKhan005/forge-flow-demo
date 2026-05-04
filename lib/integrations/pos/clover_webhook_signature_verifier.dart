// Phase 8 (`8.CL`) — Clover webhook signature verifier.
//
// Implements [VendorWebhookSignatureVerifier] for Clover's
// `X-Clover-Auth-Signature` header per documented intent at
// 2026-05-03 (`docs/integrations/clover/webhook_signature.md`).
//
// Documented intent:
//   * Algorithm:        HMAC-SHA256 over raw body bytes.
//   * Encoding:         Base64 (case-sensitive).
//   * Header name:      `X-Clover-Auth-Signature` (lower-cased by handler).
//   * Timestamp header: `X-Clover-Auth-Timestamp` (Unix epoch seconds);
//                       absent on some payload types per Clover docs.
//   * Replay tolerance: 24h via `kInboundWebhookReplayCeiling`
//                       (V1 lean cut 2 — strict 5-min window deleted).
//   * Constant-time:    [constantTimeBytesEquals] from the framework.
//
// Lifecycle = `documented`. The `8.CL.live.sandbox` slice diffs
// observed Clover headers + signature shape against this verifier; any
// discrepancy lands as a bounded fix on this file before the lifecycle
// promotes to `sandbox_verified`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/integration/inbound_webhook_handler.dart';

/// Header name Clover uses to deliver the base64-encoded HMAC-SHA256
/// signature. Lower-cased; the inbound webhook handler normalises
/// inbound header keys before dispatch.
const String kCloverSignatureHeader = 'x-clover-auth-signature';

/// Header name Clover uses to deliver the signing timestamp (Unix
/// epoch seconds). Optional — when absent, the inbound handler skips
/// the replay-defense step (signature alone is the gate).
const String kCloverTimestampHeader = 'x-clover-auth-timestamp';

class CloverWebhookSignatureVerifier
    implements VendorWebhookSignatureVerifier {
  const CloverWebhookSignatureVerifier();

  @override
  String get vendorId => 'clover';

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final supplied = headers[kCloverSignatureHeader];
    if (supplied == null || supplied.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing $kCloverSignatureHeader header',
      );
    }

    final List<int> suppliedBytes;
    try {
      suppliedBytes = base64.decode(supplied);
    } on FormatException catch (e) {
      return WebhookSignatureVerification(
        valid: false,
        failureReason:
            '$kCloverSignatureHeader is not valid base64: ${e.message}',
      );
    }

    final hmac = Hmac(sha256, utf8.encode(signingSecret));
    final expected = hmac.convert(rawBody).bytes;

    if (!constantTimeBytesEquals(expected, suppliedBytes)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'HMAC-SHA256 mismatch',
      );
    }

    final timestamp = _parseTimestamp(headers[kCloverTimestampHeader]);
    return WebhookSignatureVerification(
      valid: true,
      timestamp: timestamp,
    );
  }

  DateTime? _parseTimestamp(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw);
    if (seconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }
}
