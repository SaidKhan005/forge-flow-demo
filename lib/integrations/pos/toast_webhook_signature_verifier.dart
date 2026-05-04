// Phase 8.TS — Toast webhook signature verifier.
//
// Doctrine: engineering slice at lifecycle = `documented`. This file
// implements the framework's `VendorWebhookSignatureVerifier` contract
// against Toast's documented webhook signing scheme. Live HTTP behavior
// is verified in `8.TS.live.sandbox` / `8.TS.live.prod`.
//
// Toast webhook signing reference (retrieved 2026-05-03):
//   https://doc.toasttab.com/openapi/webhooks/webhook-management
//   https://doc.toasttab.com/doc/devguide/apiWebhooksOverview.html
//
// Algorithm (per Toast partner docs):
//   * Signed payload  : raw HTTP body bytes (no JSON re-serialization).
//   * Algorithm       : HMAC-SHA256.
//   * Encoding        : base64 (standard, with padding).
//   * Header          : `Toast-Signature`. Toast also references the
//                       capitalized variant; we lower-case lookup.
//   * Timestamp header: `Toast-Webhook-Timestamp` (Unix epoch seconds).
//                       Optional per the webhook subscription
//                       configuration; when present, the framework's
//                       24h replay ceiling
//                       (`kInboundWebhookReplayCeiling`) is enforced.
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
const String kToastVendorId = 'toast';

/// Header name carrying the base64 HMAC-SHA256 digest. Lookup is
/// case-insensitive; the framework lower-cases header keys before
/// dispatch.
const String kToastSignatureHeader = 'toast-signature';

/// Optional header carrying the signing timestamp (Unix epoch seconds).
/// When present, the framework's replay ceiling is enforced; when
/// absent, the framework skips replay defense for this event (the
/// `(vendor_id, operator_id, vendor_event_id)` idempotency UNIQUE
/// still prevents double-write).
const String kToastTimestampHeader = 'toast-webhook-timestamp';

/// Toast's documented webhook signature verifier. Stateless;
/// `VendorWebhookSignatureVerifier.verify(...)` does not mutate the
/// instance. One default-constructed verifier per process is fine.
class ToastWebhookSignatureVerifier implements VendorWebhookSignatureVerifier {
  const ToastWebhookSignatureVerifier();

  @override
  String get vendorId => kToastVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedSignature = _readHeader(headers, kToastSignatureHeader);
    if (providedSignature == null || providedSignature.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing Toast-Signature header',
      );
    }

    final List<int> providedBytes;
    try {
      providedBytes = base64Decode(providedSignature);
    } on FormatException catch (error) {
      return WebhookSignatureVerification(
        valid: false,
        failureReason: 'Toast-Signature is not valid base64: ${error.message}',
      );
    }

    final hmac = Hmac(sha256, utf8.encode(signingSecret));
    final expected = hmac.convert(rawBody).bytes;

    if (!constantTimeBytesEquals(providedBytes, expected)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'HMAC mismatch on Toast-Signature header',
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

  /// Toast's optional `Toast-Webhook-Timestamp` is Unix epoch seconds.
  /// Returns null when absent or unparseable; the framework then skips
  /// replay defense for the event.
  DateTime? _readTimestamp(Map<String, String> headers) {
    final raw = _readHeader(headers, kToastTimestampHeader);
    if (raw == null || raw.isEmpty) return null;
    final epochSeconds = int.tryParse(raw.trim());
    if (epochSeconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
      isUtc: true,
    );
  }
}
