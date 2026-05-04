// Phase 8.LSK — Lightspeed Restaurant K-Series webhook signature
// verifier.
//
// Validates inbound webhook payloads using HMAC-SHA256 over the raw
// request body, with the signature delivered in the
// `X-Lightspeed-Signature` header (lowercase hex). 24-hour replay
// tolerance per V1 lean cut 2 — the strict 5-minute window from
// iter1 was deleted because vendor retries commonly exceed 5 minutes
// and the idempotency UNIQUE on
// `(vendor_id, operator_id, vendor_event_id)` already prevents
// double-write of legitimate retries.
//
// The K-Series public developer documentation
// (https://api-docs.lsk.lightspeed.app/, retrieved 2026-05-03) does
// not publicly enumerate the signature algorithm in the Create-
// Webhook reference; the verifier is built against the documented
// pattern shared by the Lightspeed family (X-Series + Kounta + O-
// Series HMAC-SHA256 over raw body). The exact header name + encoding
// are flagged as Ambiguity calls in
// `docs/integrations/lightspeed_lsk/webhook_signature.md` and the
// `8.LSK.live.sandbox` slice will diff observed vs documented.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/integration/inbound_webhook_handler.dart';
import 'lightspeed_lsk_pos_adapter.dart';

/// Header carrying the HMAC-SHA256 signature, hex-encoded
/// (lowercase). Documented in
/// `docs/integrations/lightspeed_lsk/webhook_signature.md`.
const String kLightspeedLskSignatureHeader = 'x-lightspeed-signature';

/// Optional header carrying the signing timestamp (Unix epoch
/// seconds). When present, replay defense triggers using
/// `kInboundWebhookReplayCeiling` (24h) per V1 lean cut 2.
const String kLightspeedLskTimestampHeader = 'x-lightspeed-timestamp';

/// HMAC-SHA256 verifier for Lightspeed K-Series webhooks.
///
/// Computes the digest over the raw request body bytes
/// (NO JSON re-serialization — the framework hands us the verbatim
/// bytes from the request pipeline) and compares against the value in
/// `X-Lightspeed-Signature` using
/// [constantTimeBytesEquals] to avoid timing oracles.
class LightspeedLskWebhookSignatureVerifier
    implements VendorWebhookSignatureVerifier {
  const LightspeedLskWebhookSignatureVerifier();

  @override
  String get vendorId => kLightspeedLskVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedHex = headers[kLightspeedLskSignatureHeader];
    if (providedHex == null || providedHex.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing X-Lightspeed-Signature header',
      );
    }

    final providedBytes = _decodeHex(providedHex);
    if (providedBytes == null) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'X-Lightspeed-Signature not lowercase hex',
      );
    }

    final hmac = Hmac(sha256, utf8.encode(signingSecret));
    final expected = hmac.convert(rawBody).bytes;

    if (!constantTimeBytesEquals(providedBytes, expected)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'HMAC-SHA256 signature mismatch',
      );
    }

    DateTime? timestamp;
    final timestampRaw = headers[kLightspeedLskTimestampHeader];
    if (timestampRaw != null && timestampRaw.isNotEmpty) {
      final epochSeconds = int.tryParse(timestampRaw);
      if (epochSeconds == null) {
        return const WebhookSignatureVerification(
          valid: false,
          failureReason:
              'X-Lightspeed-Timestamp not parseable as unix epoch seconds',
        );
      }
      timestamp = DateTime.fromMillisecondsSinceEpoch(
        epochSeconds * 1000,
        isUtc: true,
      );
    }

    return WebhookSignatureVerification(
      valid: true,
      timestamp: timestamp,
    );
  }

  /// Lowercase-hex decode. Returns null on invalid characters or odd
  /// length. We reject uppercase hex to keep the contract strict —
  /// the doc pack documents lowercase only.
  List<int>? _decodeHex(String input) {
    if (input.length.isOdd) return null;
    final bytes = <int>[];
    for (var i = 0; i < input.length; i += 2) {
      final c0 = input.codeUnitAt(i);
      final c1 = input.codeUnitAt(i + 1);
      final n0 = _hexNybble(c0);
      final n1 = _hexNybble(c1);
      if (n0 < 0 || n1 < 0) return null;
      bytes.add((n0 << 4) | n1);
    }
    return bytes;
  }

  /// Returns -1 for any non-lowercase-hex character.
  int _hexNybble(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30; // 0-9
    if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10; // a-f
    return -1;
  }
}
