// Phase 8.AL — Aloha (NCR Voyix) webhook signature verifier.
//
// Doctrine: engineering slice at lifecycle = `documented`. This file
// implements the framework's `VendorWebhookSignatureVerifier` contract
// against the documented NCR Voyix webhook signing scheme for the
// Aloha module. Live HTTP behavior is verified in `8.AL.live.sandbox`
// / `8.AL.live.prod`.
//
// NCR Voyix Aloha-module webhook signing reference (retrieved
// 2026-05-04):
//   https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
//
// Documented algorithm (per the NCR Voyix Developer Program webhook
// signing convention; verified live in `8.AL.live.sandbox`):
//   * Signed payload  : raw HTTP body bytes (no JSON re-serialization).
//   * Algorithm       : HMAC-SHA256.
//   * Encoding        : base64 (standard, with padding).
//   * Header          : `NCR-Webhook-Signature`. Lookup is
//                       case-insensitive; the framework lower-cases
//                       header keys before dispatch.
//   * Timestamp header: `NCR-Webhook-Timestamp` (Unix epoch seconds).
//                       Optional per the subscription configuration;
//                       when present, the framework's 24h replay
//                       ceiling (`kInboundWebhookReplayCeiling`) is
//                       enforced.
//
// Ambiguity calls (verified in `8.AL.live.sandbox`):
//   * Exact header name (`NCR-Webhook-Signature` vs an Aloha-module
//     -specific variant). The verifier treats the documented header
//     as canonical; if the live shape differs, the bounded fix is a
//     constant rename.
//   * Whether the signature is computed over the raw body alone or
//     over `<timestamp>.<body>` (Stripe-style). The verifier assumes
//     raw-body-only per the documented portal landing; live diff
//     fix is also bounded.
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

/// Header name carrying the base64 HMAC-SHA256 digest. Lookup is
/// case-insensitive; the framework lower-cases header keys before
/// dispatch.
const String kAlohaNcrVoyixSignatureHeader = 'ncr-webhook-signature';

/// Optional header carrying the signing timestamp (Unix epoch seconds).
/// When present, the framework's replay ceiling is enforced; when
/// absent, the framework skips replay defense for this event (the
/// `(vendor_id, operator_id, vendor_event_id)` idempotency UNIQUE
/// still prevents double-write).
const String kAlohaNcrVoyixTimestampHeader = 'ncr-webhook-timestamp';

/// Aloha (NCR Voyix) documented webhook signature verifier. Stateless;
/// `VendorWebhookSignatureVerifier.verify(...)` does not mutate the
/// instance. One default-constructed verifier per process is fine.
class AlohaNcrVoyixWebhookSignatureVerifier
    implements VendorWebhookSignatureVerifier {
  const AlohaNcrVoyixWebhookSignatureVerifier();

  /// Stable vendor key matching `VendorCapabilityProfile.vendorId` and
  /// `connector_connection.vendor_id`. Mirrors
  /// `kAlohaNcrVoyixVendorId` from the adapter file.
  @override
  String get vendorId => 'aloha_ncr_voyix';

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedSignature =
        _readHeader(headers, kAlohaNcrVoyixSignatureHeader);
    if (providedSignature == null || providedSignature.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing NCR-Webhook-Signature header',
      );
    }

    final List<int> providedBytes;
    try {
      providedBytes = base64Decode(providedSignature);
    } on FormatException catch (error) {
      return WebhookSignatureVerification(
        valid: false,
        failureReason:
            'NCR-Webhook-Signature is not valid base64: ${error.message}',
      );
    }

    final hmac = Hmac(sha256, utf8.encode(signingSecret));
    final expected = hmac.convert(rawBody).bytes;

    if (!constantTimeBytesEquals(providedBytes, expected)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'HMAC mismatch on NCR-Webhook-Signature header',
      );
    }

    final ts = _readTimestamp(headers);
    return WebhookSignatureVerification(
      valid: true,
      timestamp: ts,
    );
  }

  /// Header read with case-insensitive lookup. The framework lower-cases
  /// header keys, but production proxies sometimes preserve the
  /// vendor's original case — defensive lookup keeps that orthogonal.
  String? _readHeader(Map<String, String> headers, String lowerKey) {
    final direct = headers[lowerKey];
    if (direct != null) return direct;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lowerKey) return entry.value;
    }
    return null;
  }

  /// NCR Voyix's optional `NCR-Webhook-Timestamp` is Unix epoch seconds.
  /// Returns null when absent or unparseable; the framework then skips
  /// replay defense for the event.
  DateTime? _readTimestamp(Map<String, String> headers) {
    final raw = _readHeader(headers, kAlohaNcrVoyixTimestampHeader);
    if (raw == null || raw.isEmpty) return null;
    final epochSeconds = int.tryParse(raw.trim());
    if (epochSeconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
      isUtc: true,
    );
  }
}
