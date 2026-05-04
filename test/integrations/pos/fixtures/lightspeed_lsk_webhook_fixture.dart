// Phase 8.LSK — Lightspeed Restaurant K-Series webhook fixtures.
//
// Source documentation: https://api-docs.lsk.lightspeed.app/
//   * Create Webhook (orders/payments): https://api-docs.lsk.lightspeed.app/operation/operation-apecreatewebhookoo
//   * Create Webhook (staff): https://api-docs.lsk.lightspeed.app/operation/operation-staff-apicreatewebhook
//   * Family-wide HMAC pattern: see X-Series, Kounta, O-Series docs
//     cited in `docs/integrations/lightspeed_lsk/webhook_signature.md`.
// Retrieved: 2026-05-03.
//
// These fixtures generate signed and tampered request payloads the
// signature verifier + inbound webhook handler tests drive. Each
// helper returns the raw body bytes + a header map so the tests can
// pass the verbatim bytes to the signature verifier (no JSON re-
// serialization between fixture and verifier).

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class LightspeedLskWebhookEnvelope {
  const LightspeedLskWebhookEnvelope({
    required this.rawBody,
    required this.payload,
    required this.headers,
  });

  final Uint8List rawBody;
  final Map<String, Object?> payload;
  final Map<String, String> headers;
}

/// Signed-payload variant. Returns a verbatim signature in the
/// `X-Lightspeed-Signature` header so the verifier passes.
LightspeedLskWebhookEnvelope signedLightspeedLskWebhook({
  required String signingSecret,
  required Map<String, Object?> payload,
  DateTime? signingTimestamp,
}) {
  final body = utf8.encode(jsonEncode(payload));
  final hmac = Hmac(sha256, utf8.encode(signingSecret));
  final digest = hmac.convert(body);
  final signatureHex = _toHex(digest.bytes);

  final headers = <String, String>{
    'x-lightspeed-signature': signatureHex,
    if (signingTimestamp != null)
      'x-lightspeed-timestamp':
          (signingTimestamp.toUtc().millisecondsSinceEpoch ~/ 1000).toString(),
    'content-type': 'application/json',
  };

  return LightspeedLskWebhookEnvelope(
    rawBody: Uint8List.fromList(body),
    payload: payload,
    headers: headers,
  );
}

/// Tampered-signature variant. The body is unchanged but the
/// signature header has one byte flipped — the verifier MUST refuse.
LightspeedLskWebhookEnvelope tamperedLightspeedLskWebhook({
  required String signingSecret,
  required Map<String, Object?> payload,
}) {
  final clean = signedLightspeedLskWebhook(
    signingSecret: signingSecret,
    payload: payload,
  );
  final tamperedHex = _flipFirstNybble(clean.headers['x-lightspeed-signature']!);
  final headers = Map<String, String>.from(clean.headers);
  headers['x-lightspeed-signature'] = tamperedHex;
  return LightspeedLskWebhookEnvelope(
    rawBody: clean.rawBody,
    payload: clean.payload,
    headers: headers,
  );
}

/// Future-dated event — exercises the framework's sanity rule 2
/// (`opened_in_future`). Signature is still valid; sanity drops at
/// step 4.
LightspeedLskWebhookEnvelope futureDatedLightspeedLskWebhook({
  required String signingSecret,
  required DateTime nowUtc,
}) {
  final payload = <String, Object?>{
    'event_id': 'evt-future',
    'business_id': 'lsk-biz-7c2f',
    'accountFiscId': 'A65315.future',
    'opened_at': nowUtc.add(const Duration(days: 5)).toIso8601String(),
    'closed_at': nowUtc.add(const Duration(days: 5, hours: 1)).toIso8601String(),
    'timeOfOpening': nowUtc.add(const Duration(days: 5)).toIso8601String(),
    'timeClosed': nowUtc.add(const Duration(days: 5, hours: 1)).toIso8601String(),
    'nbCovers': 1,
    'payments': const <Map<String, Object?>>[],
  };
  return signedLightspeedLskWebhook(
    signingSecret: signingSecret,
    payload: payload,
  );
}

/// Replay-old event — signing timestamp is 25h old, tripping the
/// 24h replay ceiling per V1 lean cut 2.
LightspeedLskWebhookEnvelope replayOldLightspeedLskWebhook({
  required String signingSecret,
  required DateTime nowUtc,
}) {
  final payload = <String, Object?>{
    'event_id': 'evt-replay',
    'business_id': 'lsk-biz-7c2f',
    'accountFiscId': 'A65315.replay',
    'timeOfOpening':
        nowUtc.subtract(const Duration(hours: 25)).toIso8601String(),
    'timeClosed':
        nowUtc.subtract(const Duration(hours: 24, minutes: 30)).toIso8601String(),
    'nbCovers': 2,
    'payments': const <Map<String, Object?>>[],
  };
  return signedLightspeedLskWebhook(
    signingSecret: signingSecret,
    payload: payload,
    signingTimestamp: nowUtc.subtract(const Duration(hours: 25)),
  );
}

/// Standard well-formed sale payload used by accept-path tests.
Map<String, Object?> standardLightspeedLskWebhookPayload({
  required DateTime nowUtc,
  String accountFiscId = 'A65315.17',
  int covers = 3,
  String netAmount = '142.55',
}) =>
    <String, Object?>{
      'event_id': 'evt-$accountFiscId',
      'business_id': 'lsk-biz-7c2f',
      'accountFiscId': accountFiscId,
      'timeOfOpening': nowUtc.subtract(const Duration(hours: 2)).toIso8601String(),
      'timeClosed': nowUtc.subtract(const Duration(hours: 1)).toIso8601String(),
      'nbCovers': covers,
      'payments': <Map<String, Object?>>[
        <String, Object?>{'netAmountWithTax': netAmount},
      ],
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
  // Flip 0 -> 1 -> 0 etc., staying within lowercase hex.
  final next = first == 0x30 ? 0x31 : (first == 0x31 ? 0x32 : 0x30);
  return String.fromCharCode(next) + hex.substring(1);
}
