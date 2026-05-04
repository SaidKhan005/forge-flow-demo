// Phase 8.S.7S — 7shifts webhook signature verifier
// (lifecycle = documented).
//
// 7shifts signs webhook payloads with HMAC-SHA256 over the raw request
// body and delivers the base64-encoded digest in the
// `X-7Shifts-Hmac-SHA256` header per the developer reference
// (https://developers.7shifts.com/reference/webhooks). The verifier
// preserves the raw bytes through the request pipeline (no JSON
// re-serialization between the proxy and the verifier) and uses the
// framework's `constantTimeBytesEquals` helper so a timing oracle
// cannot leak the signature byte-by-byte.
//
// The verifier reports an optional signed timestamp when 7shifts binds
// one into the payload via the `X-7Shifts-Timestamp` header (Unix
// epoch seconds, assumption — verify in `8.S.7S.live.sandbox`). When
// present, the framework's 24h replay ceiling
// (`kInboundWebhookReplayCeiling` per V1 lean cut 2) enforces against
// it; when absent, the idempotency UNIQUE on
// `inbound_webhook_idempotency(vendor_id, operator_id, vendor_event_id)`
// is the duplicate-write defense for legitimate retries.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/integration/inbound_webhook_handler.dart';
import 'seven_shifts_labor_adapter.dart';

/// Header carrying the base64-encoded HMAC-SHA256 signature per
/// developers.7shifts.com/reference/webhooks. Lower-cased to match the
/// framework's header normalization.
const String kSevenShiftsSignatureHeader = 'x-7shifts-hmac-sha256';

/// Optional header carrying the signing timestamp (Unix epoch
/// seconds). When present, the framework's 24h replay ceiling
/// enforces against it (assumption — verify in `8.S.7S.live.sandbox`).
const String kSevenShiftsTimestampHeader = 'x-7shifts-timestamp';

/// Header carrying the unique event id. The proxy maps this to the
/// framework's standard `x-vendor-event-id` so the inbound handler
/// keys idempotency without re-parsing the body.
const String kSevenShiftsEventIdHeader = 'x-7shifts-event-id';

/// HMAC-SHA256 verifier for 7shifts webhooks.
///
/// Computes the digest over the raw request body bytes and compares
/// against the value in `X-7Shifts-Hmac-SHA256` using
/// [constantTimeBytesEquals] to avoid timing oracles.
///
/// Returns `WebhookSignatureVerification.timestamp` populated when the
/// vendor included `X-7Shifts-Timestamp`; otherwise null.
class SevenShiftsWebhookSignatureVerifier
    implements VendorWebhookSignatureVerifier {
  const SevenShiftsWebhookSignatureVerifier();

  @override
  String get vendorId => kSevenShiftsVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedBase64 = _headerOrNull(headers, kSevenShiftsSignatureHeader);
    if (providedBase64 == null || providedBase64.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing X-7Shifts-Hmac-SHA256 header',
      );
    }
    final providedBytes = _decodeBase64(providedBase64);
    if (providedBytes == null) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'X-7Shifts-Hmac-SHA256 is not valid base64',
      );
    }
    final expectedDigest =
        Hmac(sha256, utf8.encode(signingSecret)).convert(rawBody).bytes;
    if (!constantTimeBytesEquals(providedBytes, expectedDigest)) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'X-7Shifts-Hmac-SHA256 HMAC mismatch',
      );
    }

    DateTime? timestamp;
    final tsRaw = _headerOrNull(headers, kSevenShiftsTimestampHeader);
    if (tsRaw != null && tsRaw.isNotEmpty) {
      final epochSeconds = int.tryParse(tsRaw);
      if (epochSeconds == null) {
        return const WebhookSignatureVerification(
          valid: false,
          failureReason:
              'X-7Shifts-Timestamp not parseable as unix epoch seconds',
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
