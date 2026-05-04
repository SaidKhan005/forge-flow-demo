// Phase 8R.OT — OpenTable webhook signature verifier
// (lifecycle = documented).
//
// OpenTable does not publish a developer portal; the signature shape
// is engineered against the industry-standard reservation envelope
// (HMAC-SHA256 over the raw request body, hex-encoded lowercase, in
// `X-OpenTable-Signature`). EVERY assumption in this file is flagged
// in `docs/integrations/opentable/webhook_signature.md` as
// "verify in 8R.OT.live.sandbox" — the field-mapping diff slice will
// confirm the algorithm, header name, and encoding against an
// observed sandbox payload and cut a bounded fix if any of them
// differ.
//
// The verifier reports an optional signed timestamp when the vendor
// includes `X-OpenTable-Timestamp` (Unix epoch seconds, assumed). The
// framework's 24h replay ceiling
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
import 'opentable_reservation_adapter.dart';

/// Header carrying the hex-encoded HMAC-SHA256 signature
/// (assumption — verify in `8R.OT.live.sandbox`).
const String kOpenTableSignatureHeader = 'x-opentable-signature';

/// Optional header carrying the signing timestamp (Unix epoch
/// seconds). When present, the framework's 24h replay ceiling
/// enforces against it (assumption — verify in `8R.OT.live.sandbox`).
const String kOpenTableTimestampHeader = 'x-opentable-timestamp';

/// Header carrying the unique event id. The proxy maps this to the
/// framework's standard `x-vendor-event-id` so the inbound handler
/// keys idempotency without re-parsing the body.
const String kOpenTableEventIdHeader = 'x-opentable-event-id';

/// HMAC-SHA256 verifier for OpenTable webhooks.
///
/// Computes the digest over the raw request body bytes (NO JSON
/// re-serialization — the framework hands the verifier the verbatim
/// bytes from the request pipeline) and compares against the value in
/// `X-OpenTable-Signature` using [constantTimeBytesEquals] to avoid
/// timing oracles.
///
/// Returns `WebhookSignatureVerification.timestamp` populated when the
/// vendor included `X-OpenTable-Timestamp`; otherwise null. Both
/// behaviors are assumptions verified in `8R.OT.live.sandbox`.
class OpenTableWebhookSignatureVerifier
    implements VendorWebhookSignatureVerifier {
  const OpenTableWebhookSignatureVerifier();

  @override
  String get vendorId => kOpenTableVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedHex = _headerOrNull(headers, kOpenTableSignatureHeader);
    if (providedHex == null || providedHex.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing X-OpenTable-Signature header',
      );
    }
    final providedBytes = _decodeHex(providedHex);
    if (providedBytes == null) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'X-OpenTable-Signature is not valid hexadecimal',
      );
    }
    final expectedDigest =
        Hmac(sha256, utf8.encode(signingSecret)).convert(rawBody).bytes;
    if (!constantTimeBytesEquals(providedBytes, expectedDigest)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'X-OpenTable-Signature HMAC mismatch',
      );
    }

    DateTime? timestamp;
    final tsRaw = _headerOrNull(headers, kOpenTableTimestampHeader);
    if (tsRaw != null && tsRaw.isNotEmpty) {
      final epochSeconds = int.tryParse(tsRaw);
      if (epochSeconds == null) {
        return const WebhookSignatureVerification(
          valid: false,
          failureReason:
              'X-OpenTable-Timestamp not parseable as unix epoch seconds',
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
