// Slice A4-ENC — correctness + HP#7 tests for the advisor
// conversation-turn AES-256-GCM encryptor.
//
// FAKES ONLY: the fake resolver returns a fixed 32-byte test key. No
// proxy, no Postgres, no real CMK. The decrypt half of the round-trip
// is implemented locally with the same pointycastle GCM primitive so
// the test proves the ciphertext is genuine AES-256-GCM and the
// authentication tag validates — i.e. it proves correctness, not just
// that bytes changed.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;

import 'package:forge_and_flow/infrastructure/crypto/advisor_conversation_envelope.dart';

/// Fake resolver returning a fixed, well-known 32-byte AES-256 key and
/// a fixed key reference. The key is a deterministic test fixture so
/// the round-trip decrypt can reproduce it; it is NOT a real secret.
class _FakeCmkResolver implements AdvisorConversationCmkResolver {
  _FakeCmkResolver({List<int>? keyBytes, this.keyRef = 'kv://test/cmk/v1'})
      : keyBytes = keyBytes ?? _fixedKey;

  // 32 distinct bytes (0x00..0x1f) so a byte-leak in any string surface
  // would be visible and so the key is unambiguously 256-bit.
  static final List<int> _fixedKey =
      List<int>.generate(32, (i) => i, growable: false);

  final List<int> keyBytes;
  final String keyRef;

  @override
  ({List<int> keyBytes, String keyRef}) resolve() =>
      (keyBytes: keyBytes, keyRef: keyRef);
}

/// Deterministic RNG so test (b) can assert two SEPARATE encrypts of
/// the same input still differ. We feed it a counter so successive
/// nonces are distinct; this stands in for `Random.secure()` without
/// flakiness, while still exercising "fresh nonce per call".
class _CountingRandom implements Random {
  int _counter = 0;

  @override
  int nextInt(int max) => (_counter++) % max;

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 20) / (1 << 20);
}

/// Independent AES-256-GCM decrypt for the round-trip assertion.
/// Throws (pointycastle `InvalidCipherTextException`) if the appended
/// tag does not validate, which is exactly what proves authentication.
List<int> _gcmDecrypt({
  required List<int> key,
  required List<int> iv,
  required List<int> ciphertextWithTag,
}) {
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(
      false, // decrypt
      pc.AEADParameters(
        pc.KeyParameter(Uint8List.fromList(key)),
        128, // tag size in bits
        Uint8List.fromList(iv),
        Uint8List(0),
      ),
    );
  return cipher.process(Uint8List.fromList(ciphertextWithTag));
}

/// Rebuilds the canonical payload the encryptor hashes + encrypts, so
/// tests can assert the hash and the decrypted plaintext independently
/// of the production helper (kept private there on purpose).
List<int> _canonicalPayload({required String role, required String content}) {
  return utf8.encode(jsonEncode(<String, String>{
    'role': role,
    'content': content,
  }));
}

void main() {
  group('AdvisorConversationEnvelope — AES-256-GCM correctness', () {
    test('(a) ciphertext differs from the plaintext payload', () {
      final enc = AdvisorConversationEnvelope(resolver: _FakeCmkResolver());
      final result = enc.encryptTurn(
        role: 'user',
        content: 'How is my labor target this week?',
      );
      final plaintext = _canonicalPayload(
        role: 'user',
        content: 'How is my labor target this week?',
      );
      expect(
        result.contentEncrypted,
        isNot(equals(plaintext)),
        reason: 'ciphertext must not equal plaintext bytes',
      );
      // Ciphertext carries the 16-byte GCM tag, so it is also longer
      // than the bare plaintext.
      expect(result.contentEncrypted.length, equals(plaintext.length + 16));
    });

    test('(b) a fresh IV is drawn on every call (two encrypts differ)', () {
      // A counting RNG guarantees distinct nonces across the two calls
      // without relying on Random.secure() entropy in CI.
      final enc = AdvisorConversationEnvelope(
        resolver: _FakeCmkResolver(),
        random: _CountingRandom(),
      );
      final first = enc.encryptTurn(role: 'user', content: 'same input');
      final second = enc.encryptTurn(role: 'user', content: 'same input');

      expect(
        first.contentIv,
        isNot(equals(second.contentIv)),
        reason: 'each encrypt must use a fresh nonce',
      );
      expect(
        first.contentEncrypted,
        isNot(equals(second.contentEncrypted)),
        reason: 'same plaintext under a fresh nonce yields different '
            'ciphertext (no nonce reuse)',
      );
      // Nonce is the GCM-recommended 96 bits.
      expect(first.contentIv.length, equals(12));
      expect(second.contentIv.length, equals(12));
    });

    test('the default constructor uses a secure RNG and still varies IVs',
        () {
      // Exercises the production Random.secure() default path: two
      // encrypts of identical input must still differ.
      final enc = AdvisorConversationEnvelope(resolver: _FakeCmkResolver());
      final a = enc.encryptTurn(role: 'assistant', content: 'reply text');
      final b = enc.encryptTurn(role: 'assistant', content: 'reply text');
      expect(a.contentIv, isNot(equals(b.contentIv)));
      expect(a.contentEncrypted, isNot(equals(b.contentEncrypted)));
    });

    test('(c) round-trip: decrypt returns the original payload + the GCM '
        'tag validates', () {
      final resolver = _FakeCmkResolver();
      final enc = AdvisorConversationEnvelope(resolver: resolver);
      const role = 'user';
      const content = 'Round-trip me: unícode ✓ and "quotes".';
      final result = enc.encryptTurn(role: role, content: content);

      // Decrypt with the SAME key + IV. If the tag did not validate,
      // pointycastle throws InvalidCipherTextException and the test
      // fails — so a clean decrypt proves authentication.
      final decrypted = _gcmDecrypt(
        key: resolver.keyBytes,
        iv: result.contentIv,
        ciphertextWithTag: result.contentEncrypted,
      );
      final expectedPlaintext = _canonicalPayload(role: role, content: content);
      expect(decrypted, equals(expectedPlaintext));
      // And the decoded JSON carries the original fields back.
      final decoded =
          jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
      expect(decoded['role'], equals(role));
      expect(decoded['content'], equals(content));
    });

    test('round-trip FAILS (tag rejects) when the ciphertext is tampered',
        () {
      final resolver = _FakeCmkResolver();
      final enc = AdvisorConversationEnvelope(resolver: resolver);
      final result = enc.encryptTurn(role: 'user', content: 'integrity');
      final tampered = List<int>.from(result.contentEncrypted);
      tampered[0] = tampered[0] ^ 0xFF; // flip a bit in the ciphertext

      expect(
        () => _gcmDecrypt(
          key: resolver.keyBytes,
          iv: result.contentIv,
          ciphertextWithTag: tampered,
        ),
        throwsA(isA<pc.InvalidCipherTextException>()),
        reason: 'GCM must reject a tampered ciphertext at tag check',
      );
    });

    test('(d) content_hash is the correct lowercase sha256 of the canonical '
        'payload', () {
      final enc = AdvisorConversationEnvelope(resolver: _FakeCmkResolver());
      const role = 'system';
      const content = 'hash me deterministically';
      final result = enc.encryptTurn(role: role, content: content);

      final expectedHash = crypto.sha256
          .convert(_canonicalPayload(role: role, content: content))
          .toString();
      expect(result.contentHash, equals(expectedHash));
      // Shape matches the migration's CHECK: 64-char lowercase hex.
      expect(result.contentHash, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('content_key_ref is the resolver-provided stable reference', () {
      final enc = AdvisorConversationEnvelope(
        resolver: _FakeCmkResolver(keyRef: 'kv://forge-flow/cmk/v1'),
      );
      final result = enc.encryptTurn(role: 'user', content: 'x');
      expect(result.contentKeyRef, equals('kv://forge-flow/cmk/v1'));
    });
  });

  group('AdvisorConversationEnvelope — key validation (HP#7)', () {
    test('(e) a wrong-length key throws the typed length error', () {
      final shortKey = AdvisorConversationEnvelope(
        resolver: _FakeCmkResolver(keyBytes: List<int>.filled(16, 7)),
      );
      expect(
        () => shortKey.encryptTurn(role: 'user', content: 'x'),
        throwsA(isA<AdvisorConversationKeyLengthError>()),
      );

      final longKey = AdvisorConversationEnvelope(
        resolver: _FakeCmkResolver(keyBytes: List<int>.filled(64, 9)),
      );
      expect(
        () => longKey.encryptTurn(role: 'user', content: 'x'),
        throwsA(isA<AdvisorConversationKeyLengthError>()),
      );
    });

    test('(f) the length error message carries the length but NOT the key '
        'bytes', () {
      // A recognisable repeated byte (0xAB) would show up in any naive
      // dump of the key. Assert it is absent from the message.
      final err = const AdvisorConversationKeyLengthError(16);
      final message = err.toString();
      expect(message, contains('16'));
      expect(message.toLowerCase(), contains('32 bytes'));
      // No byte rendering of the key (hex or decimal list) leaks.
      expect(message, isNot(contains('0xab')));
      expect(message, isNot(contains('[171')));
      expect(message, isNot(contains('171, 171')));
    });
  });

  group('AdvisorConversationEnvelope — HP#7 toString omission', () {
    test('(f) value-object toString omits ciphertext, IV, key ref, and hash',
        () {
      // Use a sentinel key ref + assert none of the secret-shaped
      // fields surface in toString().
      final enc = AdvisorConversationEnvelope(
        resolver: _FakeCmkResolver(keyRef: 'kv://SENTINEL-KEYREF/v9'),
        random: _CountingRandom(),
      );
      final result = enc.encryptTurn(
        role: 'user',
        content: 'secret-conversation-content',
      );
      final s = result.toString();

      // Key reference must not appear.
      expect(s, isNot(contains('SENTINEL-KEYREF')));
      // Content hash must not appear.
      expect(s, isNot(contains(result.contentHash)));
      // No raw byte dump of the ciphertext / IV (their list-rendered
      // forms) appears. We check the first few byte values rendered as
      // a list fragment do not show up.
      final ivFragment = result.contentIv.take(4).join(', ');
      expect(s, isNot(contains(ivFragment)));
      // Plaintext content never appears (it is encrypted).
      expect(s, isNot(contains('secret-conversation-content')));

      // It DOES disclose only the harmless byte lengths.
      expect(s, contains('${result.contentEncrypted.length} bytes'));
      expect(s, contains('${result.contentIv.length} bytes'));
    });

    test('the encryptor instance toString is the default (no secret state)',
        () {
      final enc = AdvisorConversationEnvelope(resolver: _FakeCmkResolver());
      // The default Object.toString is "Instance of '...'" — assert it
      // does not leak the fixed key bytes (0..31 rendered).
      final s = enc.toString();
      expect(s, isNot(contains('[0, 1, 2, 3')));
    });
  });
}
