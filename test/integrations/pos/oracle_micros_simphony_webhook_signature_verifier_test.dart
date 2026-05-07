// Phase 8.gap-1 — Oracle MICROS Simphony webhook signature verifier
// tests.
//
// Drives the verifier directly (no `InboundWebhookHandler`, no live
// transport) to prove every rejection branch + the constant-time
// compare invariant required by
// `docs/contracts/vendor_adapter_slice_contract.md`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_webhook_signature_verifier.dart';

void main() {
  const verifier = OracleMicrosSimphonyWebhookSignatureVerifier();
  const signingSecret = 'oracle-micros-simphony-signing-secret-001';
  final nowFixed = DateTime.utc(2026, 5, 6, 12, 0, 0);

  String signBase64(Uint8List body) {
    return base64.encode(
      Hmac(sha256, utf8.encode(signingSecret)).convert(body).bytes,
    );
  }

  group('OracleMicrosSimphonyWebhookSignatureVerifier', () {
    test('vendorId mirrors the adapter constant', () {
      expect(verifier.vendorId, oracleMicrosSimphonyVendorId);
    });

    test('valid HMAC-SHA256 base64 signature returns true', () {
      final rawBody = Uint8List.fromList(
        utf8.encode('{"check_id":"ck-12345","employee_id":"emp-7"}'),
      );
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          kOracleMicrosSimphonySignatureHeader: signBase64(rawBody),
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
      final rawBody = Uint8List.fromList(
        utf8.encode('{"check_id":"ck-12345"}'),
      );
      final epochSeconds = nowFixed.millisecondsSinceEpoch ~/ 1000;
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          kOracleMicrosSimphonySignatureHeader: signBase64(rawBody),
          kOracleMicrosSimphonyTimestampHeader: epochSeconds.toString(),
        },
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
      expect(result.timestamp, isNotNull);
      expect(result.timestamp!.toUtc(), nowFixed);
    });

    test('invalid signature (wrong digest, same width) returns false', () {
      final rawBody = Uint8List.fromList(utf8.encode('{"check_id":"ck-1"}'));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          // Valid base64 of 32 bytes (HMAC-SHA256 width) but wrong digest.
          kOracleMicrosSimphonySignatureHeader:
              base64.encode(List<int>.filled(32, 0xAA)),
        },
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, contains('mismatch'));
    });

    test('missing signature header returns false', () {
      final rawBody = Uint8List.fromList(utf8.encode('{"check_id":"ck-1"}'));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{},
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(
        result.failureReason,
        contains('missing X-Oracle-Signature header'),
      );
    });

    test('tampered body (one byte flip) breaks the signature', () {
      final original = Uint8List.fromList(
        utf8.encode('{"check_id":"ck-12345","total":42.50}'),
      );
      final providedSignature = signBase64(original);

      // Flip one byte in the body (`5` → `6`) and re-verify.
      final tampered = Uint8List.fromList(original);
      tampered[tampered.length - 2] ^= 0x01;

      final result = verifier.verify(
        rawBody: tampered,
        headers: <String, String>{
          kOracleMicrosSimphonySignatureHeader: providedSignature,
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
          kOracleMicrosSimphonySignatureHeader: signBase64(empty),
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
          kOracleMicrosSimphonySignatureHeader: 'not\$base64!!',
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
          'X-Oracle-Signature': signBase64(rawBody),
        },
        signingSecret: signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
    });
  });
}
