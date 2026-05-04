// Phase 8R.SR — SevenRooms webhook signature verifier.
//
// Validates inbound webhook payloads using HMAC-SHA256 over the raw
// request body, with the signature delivered in the
// `X-SevenRooms-Signature` header (lowercase hex). 24-hour replay
// tolerance per V1 lean cut 2.
//
// SevenRooms uses `manualPaste` webhook delivery: the operator pastes
// the F&F webhook URL into the SevenRooms admin portal (Settings →
// Integrations) and pastes the signing secret SevenRooms generates
// back into F&F. The signing-secret path through the gateway is the
// SAME as for autoRegister vendors — only the registration step
// differs.
//
// SevenRooms' partner API documentation
// (https://api-docs.sevenrooms.com/) is account-rep-gated; the
// publicly-fetched portion does not enumerate the signature
// mechanism. The verifier is built against the documented partner-API
// pattern (HMAC-SHA256, raw body, hex header). Exact header name +
// encoding live in the Ambiguity calls in
// `docs/integrations/sevenrooms/webhook_signature.md`; the
// `8R.SR.live.sandbox` slice will diff observed vs documented.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/integration/inbound_webhook_handler.dart';
import 'sevenrooms_reservation_adapter.dart';

/// Header carrying the HMAC-SHA256 signature, hex-encoded
/// (lowercase). Documented in
/// `docs/integrations/sevenrooms/webhook_signature.md`.
const String kSevenRoomsSignatureHeader = 'x-sevenrooms-signature';

/// Optional header carrying the signing timestamp (Unix epoch
/// seconds). When present, replay defense triggers using
/// `kInboundWebhookReplayCeiling` (24h) per V1 lean cut 2.
const String kSevenRoomsTimestampHeader = 'x-sevenrooms-timestamp';

/// HMAC-SHA256 verifier for SevenRooms webhooks.
///
/// Computes the digest over the raw request body bytes (NO JSON
/// re-serialization — the framework hands us the verbatim bytes from
/// the request pipeline) and compares against the value in
/// `X-SevenRooms-Signature` using [constantTimeBytesEquals] to avoid
/// timing oracles.
class SevenRoomsWebhookSignatureVerifier
    implements VendorWebhookSignatureVerifier {
  const SevenRoomsWebhookSignatureVerifier();

  @override
  String get vendorId => kSevenRoomsVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final providedHex = headers[kSevenRoomsSignatureHeader];
    if (providedHex == null || providedHex.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing X-SevenRooms-Signature header',
      );
    }

    final providedBytes = _decodeHex(providedHex);
    if (providedBytes == null) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'X-SevenRooms-Signature not lowercase hex',
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
    final timestampRaw = headers[kSevenRoomsTimestampHeader];
    if (timestampRaw != null && timestampRaw.isNotEmpty) {
      final epochSeconds = int.tryParse(timestampRaw);
      if (epochSeconds == null) {
        return const WebhookSignatureVerification(
          valid: false,
          failureReason:
              'X-SevenRooms-Timestamp not parseable as unix epoch seconds',
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

  int _hexNybble(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30; // 0-9
    if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10; // a-f
    return -1;
  }
}
