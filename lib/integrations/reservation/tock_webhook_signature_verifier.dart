// Phase 8R.TC — Tock (Squarespace) webhook signature verifier.
//
// Doctrine: engineering slice at lifecycle = `documented`. Implements
// the framework's `VendorWebhookSignatureVerifier` contract against
// Tock's documented webhook signing scheme. Live HTTP behavior is
// verified in `8R.TC.live.sandbox` / `8R.TC.live.prod`.
//
// Tock webhook signing reference (retrieved 2026-05-04):
//   https://api.exploretock.com/docs/latest/reservation.html
//   https://www.exploretock.com (Premium-tier developer portal — full
//   webhook detail is gated to Premium-tier customers; engineering
//   builds against the documented surface and `*.live.sandbox` diffs
//   observed shape against `documentedPerTockReservation20260504`).
//
// Algorithm (per Tock's published reservation API + Premium-tier
// developer guide):
//   * Signed payload  : raw HTTP body bytes (no JSON re-serialization).
//   * Algorithm       : HMAC-SHA256.
//   * Encoding        : hex (lowercase). Tock's portal documents the
//                       hex encoding as the default; `*.live.sandbox`
//                       diffs against this assumption — see
//                       `docs/integrations/tock/webhook_signature.md`
//                       Ambiguity calls.
//   * Header          : `X-Tock-Signature`. Lookup is case-insensitive.
//   * Timestamp header: `X-Tock-Webhook-Timestamp` (Unix epoch seconds).
//                       Optional per the Tock subscription
//                       configuration; when present, the framework's
//                       24h replay ceiling
//                       (`kInboundWebhookReplayCeiling`) is enforced.
//
// Webhook delivery shape (per `docs/integrations/tock/webhook_signature.md`):
//   manual paste — operators copy the F&F webhook URL + signing secret
//   from the F&F admin and paste into the Tock Premium-tier dashboard.
//   The adapter does NOT auto-register; `webhookSupport = manualPaste`.
//
// V1 lean cut 2 boundaries respected:
//   * Replay tolerance is the framework's 24h ceiling — no strict
//     5-minute window.
//   * No webhook signing-key rotation UI; signing secret is read from
//     the framework's `vendor_credentials` envelope at request time.
//   * Compare uses `constantTimeBytesEquals` to avoid timing oracles.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/integration/inbound_webhook_handler.dart';

/// Stable vendor key. Mirrors `VendorCapabilityProfile.vendorId` and
/// `connector_connection.vendor_id`.
const String kTockVendorId = 'tock';

/// Header name carrying the lowercase-hex HMAC-SHA256 digest. Lookup is
/// case-insensitive; the framework lower-cases header keys before
/// dispatch.
const String kTockSignatureHeader = 'x-tock-signature';

/// Optional header carrying the signing timestamp (Unix epoch seconds).
/// When present, the framework's replay ceiling is enforced; when
/// absent, the framework skips replay defense for this event (the
/// `(vendor_id, operator_id, vendor_event_id)` idempotency UNIQUE
/// still prevents double-write).
const String kTockTimestampHeader = 'x-tock-webhook-timestamp';

/// Tock's documented webhook signature verifier. Stateless;
/// `VendorWebhookSignatureVerifier.verify(...)` does not mutate the
/// instance. One default-constructed verifier per process is fine.
class TockWebhookSignatureVerifier implements VendorWebhookSignatureVerifier {
  const TockWebhookSignatureVerifier();

  @override
  String get vendorId => kTockVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedSignature = _readHeader(headers, kTockSignatureHeader);
    if (providedSignature == null || providedSignature.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing X-Tock-Signature header',
      );
    }

    final List<int> providedBytes;
    try {
      providedBytes = _decodeHex(providedSignature.trim());
    } on FormatException catch (error) {
      return WebhookSignatureVerification(
        valid: false,
        failureReason:
            'X-Tock-Signature is not valid lowercase hex: ${error.message}',
      );
    }

    final hmac = Hmac(sha256, utf8.encode(signingSecret));
    final expected = hmac.convert(rawBody).bytes;

    if (!constantTimeBytesEquals(providedBytes, expected)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'HMAC mismatch on X-Tock-Signature header',
      );
    }

    final ts = _readTimestamp(headers);
    return WebhookSignatureVerification(
      valid: true,
      timestamp: ts,
    );
  }

  String? _readHeader(Map<String, String> headers, String lowerKey) {
    final direct = headers[lowerKey];
    if (direct != null) return direct;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lowerKey) return entry.value;
    }
    return null;
  }

  DateTime? _readTimestamp(Map<String, String> headers) {
    final raw = _readHeader(headers, kTockTimestampHeader);
    if (raw == null || raw.isEmpty) return null;
    final epochSeconds = int.tryParse(raw.trim());
    if (epochSeconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
      isUtc: true,
    );
  }

  List<int> _decodeHex(String input) {
    if (input.length.isOdd) {
      throw const FormatException('hex string has odd length');
    }
    final bytes = <int>[];
    for (var i = 0; i < input.length; i += 2) {
      final byte = int.tryParse(input.substring(i, i + 2), radix: 16);
      if (byte == null) {
        throw FormatException(
          'invalid hex pair "${input.substring(i, i + 2)}" at offset $i',
        );
      }
      bytes.add(byte);
    }
    return bytes;
  }
}
