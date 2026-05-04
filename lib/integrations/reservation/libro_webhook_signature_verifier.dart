// Phase 8R.LB — Libro webhook signature verifier.
//
// Implements [VendorWebhookSignatureVerifier] for the Libro Reserve
// public webhook channel.
//
// Documented per `docs/integrations/libro/webhook_signature.md`
// (source: https://libroreserve.github.io/api-documentation/, retrieved
// 2026-05-04). The live slice `8R.LB.live.sandbox` diffs the assumptions
// pinned here against an observed sandbox webhook.
//
// Signature shape (documented):
//   Header: `X-Libro-Signature`
//   Value:  `t=<unix_epoch_seconds>,v1=<hex_lowercase_hmac_sha256>`
//   Signed payload bytes: `<timestamp>.<raw body>` (UTF-8).
//   Algorithm: HMAC-SHA256.
//   Encoding: hex, lowercase.
//   Replay tolerance: 24 hours per V1 lean cut 2 — the strict 5-min
//     window from iter1 was deleted because vendor retries commonly
//     exceed 5 minutes (the framework's idempotency UNIQUE prevents
//     double-write of legitimate retries).
//   Constant-time compare via [constantTimeBytesEquals] from
//     `lib/services/integration/inbound_webhook_handler.dart`.
//
// The verifier MUST NOT depend on `package:postgres` or open any
// connections. It is pure CPU work that the inbound webhook handler
// invokes inside the request pipeline.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/integration/inbound_webhook_handler.dart';
import 'libro_reservation_adapter.dart' show kLibroVendorId;

/// HTTP header carrying the Libro webhook signature.
const String kLibroSignatureHeader = 'x-libro-signature';

class LibroWebhookSignatureVerifier implements VendorWebhookSignatureVerifier {
  const LibroWebhookSignatureVerifier();

  @override
  String get vendorId => kLibroVendorId;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    final headerValue = headers[kLibroSignatureHeader];
    if (headerValue == null || headerValue.isEmpty) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'missing X-Libro-Signature header',
      );
    }

    final parsed = _parseSignatureHeader(headerValue);
    if (parsed == null) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'malformed X-Libro-Signature header',
      );
    }

    final prefix = utf8.encode('${parsed.timestampSeconds}.');
    final signedBytes = <int>[...prefix, ...rawBody];
    final hmac = Hmac(sha256, utf8.encode(signingSecret));
    final expected = hmac.convert(signedBytes).bytes;

    final candidate = _decodeHex(parsed.signatureHex);
    if (candidate == null) {
      return const WebhookSignatureVerification(
        valid: false,
        failureReason: 'signature is not lowercase hex',
      );
    }

    if (!constantTimeBytesEquals(expected, candidate)) {
      return WebhookSignatureVerification(
        valid: false,
        timestamp: parsed.timestamp,
        failureReason: 'signature mismatch',
      );
    }

    return WebhookSignatureVerification(
      valid: true,
      timestamp: parsed.timestamp,
    );
  }

  _ParsedLibroSignature? _parseSignatureHeader(String value) {
    int? timestampSeconds;
    String? signatureHex;
    for (final part in value.split(',')) {
      final equals = part.indexOf('=');
      if (equals <= 0) return null;
      final key = part.substring(0, equals).trim();
      final raw = part.substring(equals + 1).trim();
      if (key == 't') {
        timestampSeconds = int.tryParse(raw);
        if (timestampSeconds == null || timestampSeconds < 0) return null;
      } else if (key == 'v1') {
        if (raw.isEmpty) return null;
        signatureHex = raw;
      }
    }
    if (timestampSeconds == null || signatureHex == null) return null;
    return _ParsedLibroSignature(
      timestampSeconds: timestampSeconds,
      signatureHex: signatureHex,
      timestamp:
          DateTime.fromMillisecondsSinceEpoch(timestampSeconds * 1000, isUtc: true),
    );
  }

  Uint8List? _decodeHex(String hex) {
    if (hex.length.isOdd) return null;
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final c1 = _hexDigit(hex.codeUnitAt(i * 2));
      final c2 = _hexDigit(hex.codeUnitAt(i * 2 + 1));
      if (c1 < 0 || c2 < 0) return null;
      out[i] = (c1 << 4) | c2;
    }
    return out;
  }

  int _hexDigit(int code) {
    if (code >= 0x30 && code <= 0x39) return code - 0x30;
    if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
    return -1;
  }
}

class _ParsedLibroSignature {
  const _ParsedLibroSignature({
    required this.timestampSeconds,
    required this.signatureHex,
    required this.timestamp,
  });

  final int timestampSeconds;
  final String signatureHex;
  final DateTime timestamp;
}
