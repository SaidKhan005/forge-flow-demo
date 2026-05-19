// Phase 9.8 — SendGrid event-webhook signature verifier (ECDSA P-256).
//
// SendGrid signs every event-webhook POST it sends to F&F's
// `/v1/webhooks/email/sendgrid` route. Two headers ride alongside the
// JSON body:
//
//   * X-Twilio-Email-Event-Webhook-Signature — base64 of an ASN.1
//     DER-encoded ECDSA(P-256, SHA-256) signature.
//   * X-Twilio-Email-Event-Webhook-Timestamp — Unix seconds,
//     incorporated into the signed payload to defeat replay.
//
// The signed payload is `timestamp || raw_body` (literal byte
// concatenation; no separator). The public key is issued per app from
// the SendGrid Mail Settings → Event Webhook UI as a base64 string of
// the X.509 SubjectPublicKeyInfo DER for a P-256 / prime256v1 /
// secp256r1 key.
//
// Why a dedicated module:
//   * The route handler must NOT parse the body before signature
//     verification, because the signed bytes are exactly what the
//     handler receives over the wire (whitespace, ordering, all of it).
//     The verifier consumes the raw bytes and stays separate from the
//     event-payload parser.
//   * The signature itself IS the auth — the route is unauthenticated
//     by design (SendGrid's IPs are not stable). Centralising the
//     timestamp tolerance + signature check here keeps the route
//     handler free of crypto code.
//
// Replay defense:
//   * The verifier rejects timestamps further than [tolerance] from
//     the verifier's clock. Default is 10 minutes, generous enough to
//     ride out clock skew between SendGrid and Cloud Run but tight
//     enough that a captured request body cannot be replayed weeks
//     later. SendGrid's own docs recommend "<= 10 minutes" for this.
//
// Cryptography:
//   * Verification uses pointycastle's ECDSASigner with SHA256Digest.
//   * The public key is parsed once per request from the base64 input.
//     We do not cache the parsed key here — the proxy bootstrap holds
//     the base64 string in [ProxyConfig] and passes it on every call;
//     parsing P-256 SubjectPublicKeyInfo is microsecond-cheap.
//
// What this file deliberately does NOT do:
//   * Read [ProxyConfig] or any global state. The verifier is a pure
//     function over (publicKeyBase64, signatureBase64, timestamp,
//     rawBody, now). That keeps tests trivial and lets the caller
//     re-use the verifier from non-proxy contexts (admin self-test
//     surface, integration tests).
//   * Parse the event payload. Event-kind mapping + outbox status
//     transitions live in `sendgrid_event_payload_parser.dart` and
//     `sendgrid_webhook_handler.dart`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';

/// Default tolerance for the timestamp header. SendGrid recommends
/// `<= 10 minutes`; matching that lets clock skew slide while still
/// expiring a captured payload before it can be re-played at scale.
const Duration kSendGridWebhookDefaultTolerance = Duration(minutes: 10);

/// Header names SendGrid uses on event-webhook POSTs. Public for the
/// route handler so it does not redeclare the strings inline.
const String kSendGridSignatureHeader = 'X-Twilio-Email-Event-Webhook-Signature';
const String kSendGridTimestampHeader = 'X-Twilio-Email-Event-Webhook-Timestamp';

/// Outcome of [verifySendGridWebhookSignature]. Sealed so the route
/// handler's `switch` is exhaustive and a future failure shape forces
/// every caller to handle it.
sealed class SendGridWebhookSignatureOutcome {
  const SendGridWebhookSignatureOutcome();
}

class SendGridWebhookSignatureValid extends SendGridWebhookSignatureOutcome {
  const SendGridWebhookSignatureValid();
}

/// Either the signature header was missing, malformed base64, the
/// public-key DER was malformed, or the ECDSA verify returned false.
/// We do not distinguish "wrong key" from "tampered body" because the
/// route returns 401 in both cases and exposing the difference helps
/// nobody.
class SendGridWebhookSignatureInvalid extends SendGridWebhookSignatureOutcome {
  const SendGridWebhookSignatureInvalid(this.reason);

  final String reason;
}

/// The timestamp header was missing, not parseable as Unix seconds, or
/// further from `now` than the configured tolerance. Returned even if
/// the signature itself would have been valid, so a captured payload
/// cannot be replayed past the tolerance window.
class SendGridWebhookTimestampOutOfWindow
    extends SendGridWebhookSignatureOutcome {
  const SendGridWebhookTimestampOutOfWindow({
    required this.reason,
    this.skew,
  });

  final String reason;
  final Duration? skew;
}

/// Verify a SendGrid event-webhook POST.
///
/// All inputs are exactly what the route handler captures off the wire,
/// minus the body-decoding step:
///
///   * [publicKeyBase64] — base64 of the X.509 SubjectPublicKeyInfo
///     DER for the P-256 public key SendGrid shows in the Mail Settings
///     → Event Webhook UI. Whitespace / newlines are stripped before
///     decoding so the value can be copy-pasted from the UI as-is.
///   * [signatureBase64] — value of the
///     `X-Twilio-Email-Event-Webhook-Signature` header.
///   * [timestampHeader] — value of the
///     `X-Twilio-Email-Event-Webhook-Timestamp` header (Unix seconds
///     as a decimal string).
///   * [rawBody] — exact bytes of the request body. The handler MUST
///     NOT round-trip through `jsonDecode` before calling this.
///   * [now] — caller-supplied clock; tests inject a fixed instant so
///     timestamp-tolerance assertions are deterministic. Defaults to
///     [DateTime.now] in production.
///   * [tolerance] — replay window. Defaults to
///     [kSendGridWebhookDefaultTolerance].
SendGridWebhookSignatureOutcome verifySendGridWebhookSignature({
  required String publicKeyBase64,
  required String? signatureBase64,
  required String? timestampHeader,
  required List<int> rawBody,
  DateTime Function()? now,
  Duration tolerance = kSendGridWebhookDefaultTolerance,
}) {
  if (signatureBase64 == null || signatureBase64.trim().isEmpty) {
    return const SendGridWebhookSignatureInvalid('signature header missing');
  }
  if (timestampHeader == null || timestampHeader.trim().isEmpty) {
    return const SendGridWebhookTimestampOutOfWindow(
      reason: 'timestamp header missing',
    );
  }

  final timestampSecs = int.tryParse(timestampHeader.trim());
  if (timestampSecs == null) {
    return SendGridWebhookTimestampOutOfWindow(
      reason: 'timestamp header is not an integer: "$timestampHeader"',
    );
  }
  final eventInstant =
      DateTime.fromMillisecondsSinceEpoch(timestampSecs * 1000, isUtc: true);
  final clock = now ?? DateTime.now;
  final skew = clock().toUtc().difference(eventInstant);
  final absSkew = skew.isNegative ? -skew : skew;
  if (absSkew > tolerance) {
    return SendGridWebhookTimestampOutOfWindow(
      reason: 'timestamp is ${absSkew.inSeconds}s from clock; '
          'tolerance is ${tolerance.inSeconds}s',
      skew: skew,
    );
  }

  final ECPublicKey publicKey;
  try {
    publicKey = _parseEcP256PublicKey(publicKeyBase64);
  } on FormatException catch (e) {
    return SendGridWebhookSignatureInvalid('public key malformed: ${e.message}');
  } catch (e) {
    return SendGridWebhookSignatureInvalid('public key parse failure: $e');
  }

  final ECSignature signature;
  try {
    signature = _parseEcdsaDerSignature(signatureBase64.trim());
  } on FormatException catch (e) {
    return SendGridWebhookSignatureInvalid('signature malformed: ${e.message}');
  } catch (e) {
    return SendGridWebhookSignatureInvalid('signature parse failure: $e');
  }

  final timestampBytes = utf8.encode(timestampHeader.trim());
  final messageBytes = Uint8List(timestampBytes.length + rawBody.length)
    ..setRange(0, timestampBytes.length, timestampBytes)
    ..setRange(timestampBytes.length, timestampBytes.length + rawBody.length,
        rawBody);

  final signer = ECDSASigner(SHA256Digest())
    ..init(false, PublicKeyParameter<ECPublicKey>(publicKey));
  bool ok;
  try {
    ok = signer.verifySignature(messageBytes, signature);
  } catch (e) {
    return SendGridWebhookSignatureInvalid('verify threw: $e');
  }
  if (!ok) {
    return const SendGridWebhookSignatureInvalid(
      'ECDSA verify returned false',
    );
  }
  return const SendGridWebhookSignatureValid();
}

/// Parse a base64-encoded X.509 SubjectPublicKeyInfo into an
/// [ECPublicKey] on the secp256r1 (prime256v1 / P-256) curve. Throws
/// [FormatException] on malformed input.
///
/// SubjectPublicKeyInfo shape we accept:
///   SEQUENCE {
///     SEQUENCE { OID id-ecPublicKey, OID prime256v1 },
///     BIT STRING { 0x04 || X(32) || Y(32) }   -- uncompressed point
///   }
///
/// We do not validate the OIDs because the verifier is locked to
/// secp256r1 by `ECCurve_secp256r1()` regardless of what the DER says;
/// supplying a key for a different curve will fail at `curveFromX/Y`
/// or at signature verify, both of which surface the same
/// `signature malformed` outcome to the caller.
ECPublicKey _parseEcP256PublicKey(String base64Encoded) {
  final clean = base64Encoded.replaceAll(RegExp(r'\s'), '');
  final der = base64.decode(clean);
  final parser = ASN1Parser(Uint8List.fromList(der));
  final outer = parser.nextObject();
  if (outer is! ASN1Sequence) {
    throw const FormatException('expected SEQUENCE for SubjectPublicKeyInfo');
  }
  if (outer.elements == null || outer.elements!.length < 2) {
    throw const FormatException('SubjectPublicKeyInfo missing BIT STRING');
  }
  final bitString = outer.elements![1];
  if (bitString is! ASN1BitString) {
    throw const FormatException('expected BIT STRING for public key bytes');
  }
  final point = bitString.stringValues;
  if (point == null || point.isEmpty) {
    throw const FormatException('public-key BIT STRING is empty');
  }
  // Uncompressed P-256 point: 0x04 || X(32) || Y(32) = 65 bytes.
  if (point.length != 65 || point[0] != 0x04) {
    throw FormatException(
      'unsupported EC point encoding: length=${point.length}, '
      'leading-byte=0x${point.isEmpty ? "??" : point[0].toRadixString(16)}',
    );
  }
  final params = ECCurve_secp256r1();
  final x = _bytesToUnsignedBigInt(point.sublist(1, 33));
  final y = _bytesToUnsignedBigInt(point.sublist(33, 65));
  final curvePoint = params.curve.createPoint(x, y);
  return ECPublicKey(curvePoint, params);
}

/// Decode `base64` ASN.1-DER ECDSA signature: SEQUENCE { INTEGER r,
/// INTEGER s }. Returns an [ECSignature] (r, s) suitable for
/// [ECDSASigner.verifySignature].
ECSignature _parseEcdsaDerSignature(String base64Encoded) {
  final der = base64.decode(base64Encoded);
  final parser = ASN1Parser(Uint8List.fromList(der));
  final outer = parser.nextObject();
  if (outer is! ASN1Sequence) {
    throw const FormatException('expected SEQUENCE for ECDSA signature');
  }
  if (outer.elements == null || outer.elements!.length < 2) {
    throw const FormatException('ECDSA signature missing r and/or s');
  }
  final rNode = outer.elements![0];
  final sNode = outer.elements![1];
  if (rNode is! ASN1Integer || sNode is! ASN1Integer) {
    throw const FormatException('ECDSA r/s must be INTEGER');
  }
  final r = rNode.integer;
  final s = sNode.integer;
  if (r == null || s == null) {
    throw const FormatException('ECDSA r/s INTEGER value missing');
  }
  return ECSignature(r, s);
}

BigInt _bytesToUnsignedBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final b in bytes) {
    value = (value << 8) | BigInt.from(b & 0xff);
  }
  return value;
}
