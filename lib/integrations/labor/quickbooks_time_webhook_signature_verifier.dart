// Phase 8.gap-1 — QuickBooks Time (Intuit) webhook signature verifier
// (lifecycle = documented).
//
// Doctrine: engineering slice at lifecycle = `documented`. This file
// implements the framework's `VendorWebhookSignatureVerifier` contract
// against the documented Intuit webhook signing convention. The
// QuickBooks Time API as documented at
// https://tsheetsteam.github.io/api_docs/ does not currently expose a
// webhook delivery surface — `quickbooks_time_labor_adapter.dart`
// declares `webhookSupport = pollOnly` and the framework router will
// not dispatch webhook traffic to this verifier under normal
// operation. The verifier exists to close the production binder's
// "missing verifier" warning at boot and to give a future Intuit
// webhook release for QuickBooks Time a documented landing surface
// that mirrors every other vendor.
//
// Algorithm (Intuit webhook signing convention used across Intuit
// developer surfaces, to be verified live in `8.gap-1.live.sandbox`):
//   * Signed payload  : raw HTTP body bytes (no JSON re-serialization).
//   * Algorithm       : HMAC-SHA256.
//   * Encoding        : base64 (standard, with padding).
//   * Secret          : the per-app webhook verifier token issued by
//                       Intuit. Stored in the framework's
//                       `vendor_credentials` envelope and handed to
//                       `verify()` as `signingSecret`.
//   * Header          : `intuit-signature`. Lookup is
//                       case-insensitive; the framework lower-cases
//                       header keys before dispatch.
//   * Timestamp header: `intuit-t-hash` is sometimes paired with the
//                       signature on Intuit surfaces; treated as the
//                       Unix-epoch-seconds timestamp when present.
//                       When absent, the framework's idempotency
//                       UNIQUE on
//                       `inbound_webhook_idempotency(vendor_id,
//                       operator_id, vendor_event_id)` is the
//                       duplicate-write defense.
//
// V1 lean cut 2 boundaries respected:
//   * Replay tolerance is the framework's 24h ceiling
//     (`kInboundWebhookReplayCeiling`) — no strict 5-minute window.
//   * No webhook signing-key rotation UI; the verifier token is read
//     from the framework's `vendor_credentials` envelope at request
//     time.
//   * Compare uses `constantTimeBytesEquals` to avoid timing oracles.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/integration/inbound_webhook_handler.dart';
import 'quickbooks_time_labor_adapter.dart';

/// Header name carrying the base64 HMAC-SHA256 digest computed with
/// the per-app Intuit webhook verifier token. Lookup is
/// case-insensitive; the framework lower-cases header keys before
/// dispatch.
const String kQuickBooksTimeSignatureHeader = 'intuit-signature';

/// Optional header carrying a signing timestamp (Unix epoch seconds).
/// When present, the framework's replay ceiling is enforced; when
/// absent, the framework skips replay defense for this event (the
/// `(vendor_id, operator_id, vendor_event_id)` idempotency UNIQUE
/// still prevents double-write).
const String kQuickBooksTimeTimestampHeader = 'intuit-t-hash';

/// QuickBooks Time (Intuit) documented webhook signature verifier.
/// Stateless; `VendorWebhookSignatureVerifier.verify(...)` does not
/// mutate the instance. One default-constructed verifier per process
/// is fine.
class QuickBooksTimeWebhookSignatureVerifier
    implements VendorWebhookSignatureVerifier {
  const QuickBooksTimeWebhookSignatureVerifier();

  @override
  String get vendorId => kQuickBooksTimeVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedSignature =
        _readHeader(headers, kQuickBooksTimeSignatureHeader);
    if (providedSignature == null || providedSignature.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing intuit-signature header',
      );
    }

    final List<int> providedBytes;
    try {
      providedBytes = base64Decode(providedSignature.trim());
    } on FormatException catch (error) {
      return WebhookSignatureVerification(
        valid: false,
        failureReason:
            'intuit-signature is not valid base64: ${error.message}',
      );
    }

    final hmac = Hmac(sha256, utf8.encode(signingSecret));
    final expected = hmac.convert(rawBody).bytes;

    if (!constantTimeBytesEquals(providedBytes, expected)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'HMAC mismatch on intuit-signature header',
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

  /// Optional `intuit-t-hash` header parsed as Unix epoch seconds.
  /// Returns null when absent or unparseable; the framework then skips
  /// replay defense for the event.
  DateTime? _readTimestamp(Map<String, String> headers) {
    final raw = _readHeader(headers, kQuickBooksTimeTimestampHeader);
    if (raw == null || raw.isEmpty) return null;
    final epochSeconds = int.tryParse(raw.trim());
    if (epochSeconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
      isUtc: true,
    );
  }
}
