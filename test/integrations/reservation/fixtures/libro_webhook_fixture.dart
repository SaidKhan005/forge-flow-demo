// Phase 8R.LB — Libro webhook fixture (engineering slice).
//
// Source documentation: https://libroreserve.github.io/api-documentation/
// Retrieved: 2026-05-04 (pinned in
// docs/integrations/libro/webhook_signature.md).
//
// Documented webhook signature shape:
//   Header: `X-Libro-Signature: t=<unix_seconds>,v1=<lowercase_hex_hmac_sha256>`
//   Signed payload: `<timestamp>.<raw_body>` (UTF-8).
//   Algorithm: HMAC-SHA256.
//
// The fixture below provides a reusable payload + a signing helper so
// adapter tests can exercise the framework's signature path without
// hand-rolling HMACs in every test.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'libro_reservations_fixture.dart';

/// Documented Libro webhook event shape per
/// `docs/integrations/libro/webhook_signature.md`. The `event` envelope
/// carries the canonical `reservation` object — same field names as
/// the reservations endpoint so the adapter's mapping code is shared.
const Map<String, Object?> libroWebhookPayloadReservationConfirmed =
    <String, Object?>{
  'id': 'wh-evt-7c2f-100',
  'type': 'reservation.confirmed',
  'venue_id': 'venue-toronto-yorkville',
  'occurred_at': '2026-05-04T11:30:05',
  'reservation': <String, Object?>{
    'id': 'lbr-evt-7c2f-001',
    'venue_id': 'venue-toronto-yorkville',
    'size': 4,
    'status': 'confirmed',
    'reservation_at': '2026-05-04T19:00:00',
    'created_at': '2026-05-04T11:30:00',
    'confirmed_at': '2026-05-04T11:30:04',
    'updated_at': '2026-05-04T11:30:04',
  },
};

/// Build the signed bytes the Libro webhook signs over.
Uint8List buildLibroSignedBody(Map<String, Object?> payload) {
  return Uint8List.fromList(utf8.encode(json.encode(payload)));
}

/// Compute the documented `X-Libro-Signature` header value for [body]
/// at [timestamp] under [signingSecret]. Mirrors the verifier's
/// expected shape exactly so tests cannot drift out of sync with the
/// adapter.
String signLibroWebhook({
  required Uint8List body,
  required String signingSecret,
  required DateTime timestamp,
}) {
  final ts = (timestamp.toUtc().millisecondsSinceEpoch ~/ 1000).toString();
  final prefix = utf8.encode('$ts.');
  final signedBytes = <int>[...prefix, ...body];
  final hmac = Hmac(sha256, utf8.encode(signingSecret));
  final hex = hmac.convert(signedBytes).toString();
  return 't=$ts,v1=$hex';
}

/// Convenience: re-export the documented_per_libro_v1 constant so the
/// adapter test file does not need to import both fixture files.
const Map<String, Object?> documentedPerLibroV1 = documented_per_libro_v1;
