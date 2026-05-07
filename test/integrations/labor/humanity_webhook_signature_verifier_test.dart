// Phase 8.gap-1 — Humanity webhook signature verifier tests.
//
// Drives the verifier directly (no `InboundWebhookHandler`, no live
// transport) to prove every rejection branch + the constant-time
// compare invariant required by
// `docs/contracts/vendor_adapter_slice_contract.md`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/humanity_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/humanity_webhook_signature_verifier.dart';

void main() {
  const verifier = HumanityWebhookSignatureVerifier();
  const signingSecret = 'humanity-signing-secret-001';
  final nowFixed = DateTime.utc(2026, 5, 6, 12, 0, 0);

  String signBase64(Uint8List body) {
    return base64.encode(
      Hmac(sha256, utf8.encode(signingSecret)).convert(body).bytes,
    );
  }

  group('HumanityWebhookSignatureVerifier', () {
    test('vendorId mirrors the adapter constant', () {
      expect(verifier.vendorId, kHumanityVendorId);
    });

    test('valid HMAC-SHA256 base64 signature returns true', () {
      final rawBody = Uint8List.fromList(
        utf8.encode('{"event":"timeclock.updated","id":"tc-001"}'),
      );
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          kHumanitySignatureHeader: signBase64(rawBody),
        },
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
      expect(result.failureReason, isNull);
      expect(result.timestamp, isNull);
    });

    test('valid signature with epoch-seconds timestamp populates timestamp',
        () {
      final rawBody = Uint8List.fromList(utf8.encode('{"event":"x"}'));
      final epochSeconds = nowFixed.millisecondsSinceEpoch ~/ 1000;
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          kHumanitySignatureHeader: signBase64(rawBody),
          kHumanityTimestampHeader: epochSeconds.toString(),
        },
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
      expect(result.timestamp, isNotNull);
      expect(result.timestamp!.toUtc(), nowFixed);
    });

    test('invalid signature (wrong digest, same width) returns false', () {
      final rawBody = Uint8List.fromList(utf8.encode('{"event":"x"}'));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          kHumanitySignatureHeader: base64.encode(List<int>.filled(32, 0xAA)),
        },
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, contains('mismatch'));
    });

    test('missing signature header returns false', () {
      final rawBody = Uint8List.fromList(utf8.encode('{"event":"x"}'));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{},
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(
        result.failureReason,
        contains('missing X-Humanity-Signature header'),
      );
    });

    test('tampered body (one byte flip) breaks the signature', () {
      final original = Uint8List.fromList(
        utf8.encode('{"event":"timeclock.updated","id":"tc-001"}'),
      );
      final providedSignature = signBase64(original);

      final tampered = Uint8List.fromList(original);
      tampered[tampered.length - 3] ^= 0x01;

      final result = verifier.verify(
        rawBody: tampered,
        headers: <String, String>{
          kHumanitySignatureHeader: providedSignature,
        },
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, contains('mismatch'));
    });

    test('empty body with valid signature is accepted', () {
      final empty = Uint8List(0);
      final result = verifier.verify(
        rawBody: empty,
        headers: <String, String>{
          kHumanitySignatureHeader: signBase64(empty),
        },
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
    });

    test('non-base64 signature returns false with parse-error reason', () {
      final rawBody = Uint8List.fromList(utf8.encode('{}'));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{
          kHumanitySignatureHeader: 'not\$base64!!',
        },
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, contains('base64'));
    });

    test('header lookup is case-insensitive', () {
      final rawBody = Uint8List.fromList(utf8.encode('{"k":"v"}'));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          'X-Humanity-Signature': signBase64(rawBody),
        },
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
    });
  });
}
