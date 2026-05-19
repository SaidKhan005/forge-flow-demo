// Phase 9.8 — SendGrid webhook signature verifier tests.
//
// Generates an ephemeral P-256 keypair per test, signs a fixture
// payload with the private key, and asserts the verifier accepts the
// matching signature and rejects every other shape: tampered body,
// tampered signature, swapped public key, missing headers, replayed
// timestamp, malformed base64.
//
// We use pointycastle's signing path here because the production
// verifier never holds a private key — SendGrid does. The test's
// `_signSendGridPayload` mirrors what SendGrid's signing service
// does on the wire so the verifier exercises a real signature, not
// a hand-rolled fixture that might accidentally agree with a bug
// in the verifier.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';

import 'package:forge_and_flow/services/email/sendgrid_webhook_signature_verifier.dart';

void main() {
  group('verifySendGridWebhookSignature', () {
    final kp = _generateP256KeyPair();
    final publicKeyBase64 = _encodeP256PublicKeyAsSpkiBase64(kp.publicKey);

    final body = utf8.encode(
      '[{"event":"delivered","sg_event_id":"abc","sg_message_id":"m1",'
      '"timestamp":1700000000,"email_id":"11111111-2222-3333-4444-555555555555"}]',
    );
    const timestampHeader = '1700000000';
    final fixedNow = DateTime.fromMillisecondsSinceEpoch(
      1700000060 * 1000,
      isUtc: true,
    );

    test('valid signature + in-window timestamp -> Valid', () {
      final sig = _signSendGridPayload(kp.privateKey, timestampHeader, body);
      final outcome = verifySendGridWebhookSignature(
        publicKeyBase64: publicKeyBase64,
        signatureBase64: sig,
        timestampHeader: timestampHeader,
        rawBody: body,
        now: () => fixedNow,
      );
      expect(outcome, isA<SendGridWebhookSignatureValid>());
    });

    test('tampered body -> Invalid', () {
      final sig = _signSendGridPayload(kp.privateKey, timestampHeader, body);
      final tamperedBody = utf8.encode(
        '[{"event":"delivered","sg_event_id":"DIFFERENT"}]',
      );
      final outcome = verifySendGridWebhookSignature(
        publicKeyBase64: publicKeyBase64,
        signatureBase64: sig,
        timestampHeader: timestampHeader,
        rawBody: tamperedBody,
        now: () => fixedNow,
      );
      expect(outcome, isA<SendGridWebhookSignatureInvalid>());
    });

    test('tampered timestamp -> Invalid (signature mismatch)', () {
      final sig = _signSendGridPayload(kp.privateKey, timestampHeader, body);
      final outcome = verifySendGridWebhookSignature(
        publicKeyBase64: publicKeyBase64,
        signatureBase64: sig,
        timestampHeader: '1700000001',
        rawBody: body,
        now: () => fixedNow,
      );
      expect(outcome, isA<SendGridWebhookSignatureInvalid>());
    });

    test('signed by different key -> Invalid', () {
      final otherKp = _generateP256KeyPair();
      final sig = _signSendGridPayload(otherKp.privateKey, timestampHeader, body);
      final outcome = verifySendGridWebhookSignature(
        publicKeyBase64: publicKeyBase64,
        signatureBase64: sig,
        timestampHeader: timestampHeader,
        rawBody: body,
        now: () => fixedNow,
      );
      expect(outcome, isA<SendGridWebhookSignatureInvalid>());
    });

    test('missing signature header -> Invalid', () {
      final outcome = verifySendGridWebhookSignature(
        publicKeyBase64: publicKeyBase64,
        signatureBase64: null,
        timestampHeader: timestampHeader,
        rawBody: body,
        now: () => fixedNow,
      );
      expect(outcome, isA<SendGridWebhookSignatureInvalid>());
    });

    test('missing timestamp header -> TimestampOutOfWindow', () {
      final sig = _signSendGridPayload(kp.privateKey, timestampHeader, body);
      final outcome = verifySendGridWebhookSignature(
        publicKeyBase64: publicKeyBase64,
        signatureBase64: sig,
        timestampHeader: null,
        rawBody: body,
        now: () => fixedNow,
      );
      expect(outcome, isA<SendGridWebhookTimestampOutOfWindow>());
    });

    test('timestamp older than tolerance -> TimestampOutOfWindow', () {
      final sig = _signSendGridPayload(kp.privateKey, timestampHeader, body);
      // Clock is 30 minutes after the timestamp; default tolerance is 10 min.
      final wayLater =
          DateTime.fromMillisecondsSinceEpoch(1700001800 * 1000, isUtc: true);
      final outcome = verifySendGridWebhookSignature(
        publicKeyBase64: publicKeyBase64,
        signatureBase64: sig,
        timestampHeader: timestampHeader,
        rawBody: body,
        now: () => wayLater,
      );
      expect(outcome, isA<SendGridWebhookTimestampOutOfWindow>());
    });

    test('non-numeric timestamp -> TimestampOutOfWindow', () {
      final outcome = verifySendGridWebhookSignature(
        publicKeyBase64: publicKeyBase64,
        signatureBase64: 'whatever',
        timestampHeader: 'not-a-number',
        rawBody: body,
        now: () => fixedNow,
      );
      expect(outcome, isA<SendGridWebhookTimestampOutOfWindow>());
    });

    test('garbage public key -> Invalid', () {
      final sig = _signSendGridPayload(kp.privateKey, timestampHeader, body);
      final outcome = verifySendGridWebhookSignature(
        publicKeyBase64: 'not-base64!!!',
        signatureBase64: sig,
        timestampHeader: timestampHeader,
        rawBody: body,
        now: () => fixedNow,
      );
      expect(outcome, isA<SendGridWebhookSignatureInvalid>());
    });

    test('garbage signature -> Invalid', () {
      final outcome = verifySendGridWebhookSignature(
        publicKeyBase64: publicKeyBase64,
        signatureBase64: 'not-base64!!!',
        timestampHeader: timestampHeader,
        rawBody: body,
        now: () => fixedNow,
      );
      expect(outcome, isA<SendGridWebhookSignatureInvalid>());
    });
  });
}

class _P256KeyPair {
  _P256KeyPair(this.publicKey, this.privateKey);
  final ECPublicKey publicKey;
  final ECPrivateKey privateKey;
}

_P256KeyPair _generateP256KeyPair() {
  final params = ECCurve_secp256r1();
  final keyParams = ECKeyGeneratorParameters(params);
  final secureRandom = FortunaRandom();
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );
  secureRandom.seed(KeyParameter(seed));
  final generator = ECKeyGenerator()
    ..init(ParametersWithRandom(keyParams, secureRandom));
  final pair = generator.generateKeyPair();
  return _P256KeyPair(
    pair.publicKey as ECPublicKey,
    pair.privateKey as ECPrivateKey,
  );
}

/// Mirror what SendGrid's signing service does: sign
/// `timestamp || raw_body` with ECDSA(P-256, SHA-256), DER-encode the
/// signature, base64-encode the DER.
String _signSendGridPayload(
  ECPrivateKey privateKey,
  String timestampHeader,
  List<int> rawBody,
) {
  final tsBytes = utf8.encode(timestampHeader);
  final message = Uint8List(tsBytes.length + rawBody.length)
    ..setRange(0, tsBytes.length, tsBytes)
    ..setRange(tsBytes.length, tsBytes.length + rawBody.length, rawBody);
  final secureRandom = FortunaRandom();
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );
  secureRandom.seed(KeyParameter(seed));
  final signer = ECDSASigner(SHA256Digest())
    ..init(
      true,
      ParametersWithRandom(PrivateKeyParameter<ECPrivateKey>(privateKey),
          secureRandom),
    );
  final sig = signer.generateSignature(message) as ECSignature;
  final der = _encodeEcdsaDer(sig.r, sig.s);
  return base64.encode(der);
}

/// Encode (r, s) as DER SEQUENCE { INTEGER, INTEGER }.
Uint8List _encodeEcdsaDer(BigInt r, BigInt s) {
  final rBytes = _encodeAsn1Integer(r);
  final sBytes = _encodeAsn1Integer(s);
  final body = <int>[...rBytes, ...sBytes];
  // SEQUENCE tag = 0x30; length is < 128 for P-256 (max ~71 bytes).
  return Uint8List.fromList(<int>[0x30, body.length, ...body]);
}

List<int> _encodeAsn1Integer(BigInt value) {
  // Two's-complement representation, leading 0x00 if high bit set.
  final hex = value.toRadixString(16);
  final padded = hex.length.isOdd ? '0$hex' : hex;
  final raw = <int>[];
  for (var i = 0; i < padded.length; i += 2) {
    raw.add(int.parse(padded.substring(i, i + 2), radix: 16));
  }
  if (raw.first & 0x80 != 0) {
    raw.insert(0, 0x00);
  }
  return <int>[0x02, raw.length, ...raw];
}

/// Encode an [ECPublicKey] as a base64 X.509 SubjectPublicKeyInfo.
/// Matches the format SendGrid surfaces in the Mail Settings → Event
/// Webhook UI.
String _encodeP256PublicKeyAsSpkiBase64(ECPublicKey key) {
  final q = key.Q!;
  final x = _bigIntToFixedLengthBytes(q.x!.toBigInteger()!, 32);
  final y = _bigIntToFixedLengthBytes(q.y!.toBigInteger()!, 32);
  final point = <int>[0x04, ...x, ...y]; // uncompressed point: 65 bytes

  // AlgorithmIdentifier:
  //   SEQUENCE { OID 1.2.840.10045.2.1 (ecPublicKey),
  //              OID 1.2.840.10045.3.1.7 (prime256v1) }
  // OID encodings:
  //   ecPublicKey  -> 06 07 2A 86 48 CE 3D 02 01
  //   prime256v1   -> 06 08 2A 86 48 CE 3D 03 01 07
  final algId = <int>[
    0x30, 0x13, // SEQUENCE, length 19
    0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
  ];
  // BIT STRING wrapping the uncompressed point (with 0 unused bits).
  final bitString = <int>[
    0x03, 1 + point.length, // BIT STRING, length
    0x00, // unused bits
    ...point,
  ];
  final body = <int>[...algId, ...bitString];
  final spki = <int>[0x30, body.length, ...body];
  return base64.encode(spki);
}

List<int> _bigIntToFixedLengthBytes(BigInt value, int length) {
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  while (bytes.length < length) {
    bytes.insert(0, 0);
  }
  if (bytes.length > length) {
    return bytes.sublist(bytes.length - length);
  }
  return bytes;
}
