// Phase 8R.SR — SevenRooms webhook fixtures.
//
// Source documentation:
//   * Marketing overview (mentions reservation webhooks):
//     https://sevenrooms.com/platform/integrations-apis/
//   * Partner API portal (account-rep gated):
//     https://api-docs.sevenrooms.com/
// Retrieved: 2026-05-04.
//
// These fixtures generate signed and tampered request payloads the
// signature verifier + inbound webhook handler tests drive. Each
// helper returns the raw body bytes + a header map so the tests can
// pass the verbatim bytes to the signature verifier (no JSON
// re-serialization between fixture and verifier).

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class SevenRoomsWebhookEnvelope {
  const SevenRoomsWebhookEnvelope({
    required this.rawBody,
    required this.payload,
    required this.headers,
  });

  final Uint8List rawBody;
  final Map<String, Object?> payload;
  final Map<String, String> headers;
}

/// Signed-payload variant. Returns a verbatim signature in the
/// `X-SevenRooms-Signature` header so the verifier passes.
SevenRoomsWebhookEnvelope signedSevenRoomsWebhook({
  required String signingSecret,
  required Map<String, Object?> payload,
  DateTime? signingTimestamp,
}) {
  final body = utf8.encode(jsonEncode(payload));
  final hmac = Hmac(sha256, utf8.encode(signingSecret));
  final digest = hmac.convert(body);
  final signatureHex = _toHex(digest.bytes);

  final headers = <String, String>{
    'x-sevenrooms-signature': signatureHex,
    if (signingTimestamp != null)
      'x-sevenrooms-timestamp':
          (signingTimestamp.toUtc().millisecondsSinceEpoch ~/ 1000).toString(),
    'content-type': 'application/json',
  };

  return SevenRoomsWebhookEnvelope(
    rawBody: Uint8List.fromList(body),
    payload: payload,
    headers: headers,
  );
}

/// Tampered-signature variant. The body is unchanged but the
/// signature header has one byte flipped — the verifier MUST refuse.
SevenRoomsWebhookEnvelope tamperedSevenRoomsWebhook({
  required String signingSecret,
  required Map<String, Object?> payload,
}) {
  final clean = signedSevenRoomsWebhook(
    signingSecret: signingSecret,
    payload: payload,
  );
  final tamperedHex = _flipFirstNybble(clean.headers['x-sevenrooms-signature']!);
  final headers = Map<String, String>.from(clean.headers);
  headers['x-sevenrooms-signature'] = tamperedHex;
  return SevenRoomsWebhookEnvelope(
    rawBody: clean.rawBody,
    payload: clean.payload,
    headers: headers,
  );
}

/// Standard well-formed reservation payload used by accept-path tests.
Map<String, Object?> standardSevenRoomsWebhookPayload({
  required DateTime nowUtc,
  String reservationId = 'sr-resv-1001',
  int partySize = 2,
  String status = 'BOOKED',
}) =>
    <String, Object?>{
      'event_id': 'evt-$reservationId',
      'venue_id': 'sr-venue-7c2f',
      'id': reservationId,
      'arrival_time':
          nowUtc.add(const Duration(hours: 6)).toIso8601String(),
      'party_size': partySize,
      'status': status,
      'last_updated_at': nowUtc.toIso8601String(),
    };

String _toHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    final hex = b.toRadixString(16);
    if (hex.length == 1) buffer.write('0');
    buffer.write(hex);
  }
  return buffer.toString();
}

String _flipFirstNybble(String hex) {
  if (hex.isEmpty) return hex;
  final first = hex.codeUnitAt(0);
  final next = first == 0x30 ? 0x31 : (first == 0x31 ? 0x32 : 0x30);
  return String.fromCharCode(next) + hex.substring(1);
}
