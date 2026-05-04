// Phase 8.S.ADP — ADP webhook signature verifier
// (lifecycle = documented).
//
// ADP Marketplace event subscriptions sign payloads with HMAC-SHA256
// (industry standard for the ADP partner surfaces) but the partner
// doc with the exact header name + encoding is gated on the ADP
// Marketplace Developer Participation Agreement (12-24 weeks). The
// verifier is engineered against the assumed `ADP-Signature` header
// carrying base64-encoded HMAC-SHA256 over the raw request body.
// EVERY assumption in this file is flagged in
// `docs/integrations/adp/webhook_signature.md` as "verify in
// 8.S.ADP.live.sandbox" — the field-mapping diff slice will confirm
// the algorithm, header name, and encoding against an observed
// sandbox payload and cut a bounded fix if any of them differ.
//
// The verifier reports an optional signed timestamp when the vendor
// includes `ADP-Signature-Timestamp` (Unix epoch seconds, assumed).
// The framework's 24h replay ceiling
// (`kInboundWebhookReplayCeiling`) enforces against that timestamp;
// when the vendor does not bind a timestamp into the signed payload
// the verifier returns null and the idempotency UNIQUE on
// `inbound_webhook_idempotency(vendor_id, operator_id, vendor_event_id)`
// is the duplicate-write defense for legitimate retries (per V1 lean
// cut 2 — strict 5-minute window stays deleted).
//
// Constant-time HMAC compare uses the framework's
// `constantTimeBytesEquals` helper so a timing oracle cannot leak the
// signature byte-by-byte.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/integration/inbound_webhook_handler.dart';
import 'adp_labor_adapter.dart';

/// Header carrying the base64-encoded HMAC-SHA256 signature
/// (assumption — verify in `8.S.ADP.live.sandbox`).
const String kAdpSignatureHeader = 'adp-signature';

/// Optional header carrying the signing timestamp (Unix epoch
/// seconds). When present, the framework's 24h replay ceiling
/// enforces against it (assumption — verify in
/// `8.S.ADP.live.sandbox`).
const String kAdpTimestampHeader = 'adp-signature-timestamp';

/// Header carrying the unique event id. The proxy maps this to the
/// framework's standard `x-vendor-event-id` so the inbound handler
/// keys idempotency without re-parsing the body.
const String kAdpEventIdHeader = 'adp-event-id';

/// HMAC-SHA256 verifier for ADP webhooks.
///
/// Computes the digest over the raw request body bytes (NO JSON
/// re-serialization — the framework hands the verifier the verbatim
/// bytes from the request pipeline) and compares against the value
/// in `ADP-Signature` using [constantTimeBytesEquals] to avoid timing
/// oracles.
///
/// Returns `WebhookSignatureVerification.timestamp` populated when
/// the vendor included `ADP-Signature-Timestamp`; otherwise null.
/// Both behaviors are assumptions verified in `8.S.ADP.live.sandbox`.
class AdpWebhookSignatureVerifier
    implements VendorWebhookSignatureVerifier {
  const AdpWebhookSignatureVerifier();

  @override
  String get vendorId => kAdpVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedB64 = _headerOrNull(headers, kAdpSignatureHeader);
    if (providedB64 == null || providedB64.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing ADP-Signature header',
      );
    }
    final providedBytes = _decodeBase64(providedB64);
    if (providedBytes == null) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'ADP-Signature is not valid base64',
      );
    }
    final expectedDigest =
        Hmac(sha256, utf8.encode(signingSecret)).convert(rawBody).bytes;
    if (!constantTimeBytesEquals(providedBytes, expectedDigest)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'ADP-Signature HMAC mismatch',
      );
    }

    DateTime? timestamp;
    final tsRaw = _headerOrNull(headers, kAdpTimestampHeader);
    if (tsRaw != null && tsRaw.isNotEmpty) {
      final epochSeconds = int.tryParse(tsRaw);
      if (epochSeconds == null) {
        return const WebhookSignatureVerification(
          valid: false,
          failureReason:
              'ADP-Signature-Timestamp not parseable as unix epoch seconds',
        );
      }
      timestamp = DateTime.fromMillisecondsSinceEpoch(
        epochSeconds * 1000,
        isUtc: true,
      );
    }
    return WebhookSignatureVerification(valid: true, timestamp: timestamp);
  }

  String? _headerOrNull(Map<String, String> headers, String key) {
    final lower = headers[key];
    if (lower != null) return lower;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == key) {
        return entry.value;
      }
    }
    return null;
  }

  List<int>? _decodeBase64(String value) {
    try {
      return base64.decode(value.trim());
    } on FormatException {
      return null;
    }
  }
}
