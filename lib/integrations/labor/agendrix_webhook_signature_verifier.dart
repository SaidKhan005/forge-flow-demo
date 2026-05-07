// Phase 8.gap-1 — Agendrix webhook signature verifier
// (lifecycle = documented).
//
// Doctrine: engineering slice at lifecycle = `documented`. This file
// implements the framework's `VendorWebhookSignatureVerifier` contract
// against the assumed Agendrix webhook signing scheme. The Agendrix v2
// API does not currently document a webhook delivery surface —
// `agendrix_labor_adapter.dart` declares `webhookSupport = pollOnly`
// and the framework router will not dispatch webhook traffic to this
// verifier under normal operation. The verifier exists to close the
// production binder's "missing verifier" warning at boot and to give a
// future Agendrix webhook release a documented landing surface that
// mirrors every other vendor.
//
// Documented algorithm (industry-standard SaaS partner convention, to
// be verified live in `8.gap-1.live.sandbox`):
//   * Signed payload  : raw HTTP body bytes (no JSON re-serialization).
//   * Algorithm       : HMAC-SHA256.
//   * Encoding        : base64 (standard, with padding).
//   * Header          : `X-Agendrix-Signature`. Lookup is
//                       case-insensitive; the framework lower-cases
//                       header keys before dispatch.
//   * Timestamp header: `X-Agendrix-Timestamp` (Unix epoch seconds).
//                       Optional; when present, the framework's 24h
//                       replay ceiling (`kInboundWebhookReplayCeiling`)
//                       is enforced.
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
import 'agendrix_labor_adapter.dart';

/// Header name carrying the base64 HMAC-SHA256 digest. Lookup is
/// case-insensitive; the framework lower-cases header keys before
/// dispatch.
const String kAgendrixSignatureHeader = 'x-agendrix-signature';

/// Optional header carrying the signing timestamp (Unix epoch seconds).
/// When present, the framework's replay ceiling is enforced; when
/// absent, the framework skips replay defense for this event (the
/// `(vendor_id, operator_id, vendor_event_id)` idempotency UNIQUE
/// still prevents double-write).
const String kAgendrixTimestampHeader = 'x-agendrix-timestamp';

/// Agendrix documented webhook signature verifier. Stateless;
/// `VendorWebhookSignatureVerifier.verify(...)` does not mutate the
/// instance. One default-constructed verifier per process is fine.
class AgendrixWebhookSignatureVerifier
    implements VendorWebhookSignatureVerifier {
  const AgendrixWebhookSignatureVerifier();

  @override
  String get vendorId => agendrixVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedSignature =
        _readHeader(headers, kAgendrixSignatureHeader);
    if (providedSignature == null || providedSignature.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing X-Agendrix-Signature header',
      );
    }

    final List<int> providedBytes;
    try {
      providedBytes = base64Decode(providedSignature.trim());
    } on FormatException catch (error) {
      return WebhookSignatureVerification(
        valid: false,
        failureReason:
            'X-Agendrix-Signature is not valid base64: ${error.message}',
      );
    }

    final hmac = Hmac(sha256, utf8.encode(signingSecret));
    final expected = hmac.convert(rawBody).bytes;

    if (!constantTimeBytesEquals(providedBytes, expected)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'HMAC mismatch on X-Agendrix-Signature header',
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

  /// Agendrix's optional `X-Agendrix-Timestamp` is Unix epoch seconds.
  /// Returns null when absent or unparseable; the framework then skips
  /// replay defense for the event.
  DateTime? _readTimestamp(Map<String, String> headers) {
    final raw = _readHeader(headers, kAgendrixTimestampHeader);
    if (raw == null || raw.isEmpty) return null;
    final epochSeconds = int.tryParse(raw.trim());
    if (epochSeconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
      isUtc: true,
    );
  }
}
