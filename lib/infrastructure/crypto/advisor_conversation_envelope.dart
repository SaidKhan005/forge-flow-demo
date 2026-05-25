// Slice A4-ENC — server-side AEAD encryptor for advisor conversation
// turns (gated-inert, ENCRYPTION-FIRST).
//
// This is the FIRST application-level AEAD encrypt path in the
// codebase. It produces exactly the four secret-shaped fields the
// persistence layer expects, computed IN-PROCESS so the database
// NEVER sees plaintext (Hard Promise #7 — F&F holds all provider
// keys server-side; the proxy brokers everything; plaintext advisor
// content is encrypted before it can touch Postgres). The
// pgcrypto / `pgp_sym_*` path is deliberately NOT used here because
// it would hand plaintext to the database engine; this slice
// encrypts in Dart before the row is ever bound.
//
//   * `content_encrypted` (bytea) — AES-256-GCM ciphertext with the
//     128-bit GCM authentication tag appended (standard layout).
//   * `content_iv` (bytea) — a FRESH 96-bit (12-byte) nonce drawn
//     from `Random.secure()` on every call. A GCM nonce is NEVER
//     reused under the same key: reuse is catastrophic (it leaks the
//     XOR of plaintexts and breaks authentication), so the nonce is
//     generated inside `encryptTurn` and is never accepted from a
//     caller.
//   * `content_key_ref` (text) — a stable `kv://` reference to the
//     CMK that performed the encryption (e.g. `kv://forge-flow/cmk/v1`).
//     NEVER the raw key bytes.
//   * `content_hash` (text) — the lowercase SHA-256 hex of the
//     canonical plaintext payload, so a forensic reader can
//     cross-check integrity after decrypt. Matches the 64-char
//     lowercase-hex CHECK constraint the migration enforces and the
//     [AdvisorConversationLogRepository] re-validates in Dart.
//
// Hard Promise #7 / privacy posture (mirrors the secret-omitting
// `toString()` discipline on `AuditPrivacyConversationRow` in
// `advisor_conversation_log_repository.dart`):
//
//   * The 256-bit data key lives ONLY for the duration of a single
//     `encryptTurn` call. It is fetched from the resolver, used to
//     drive one GCM cipher, and dropped. It is NEVER stored on a
//     field, NEVER returned to a caller, NEVER logged, and NEVER
//     placed in an exception message or `toString()`.
//   * The key-length validation error names only the failure mode
//     ("not 32 bytes") and never echoes the key bytes or their value.
//   * The returned value object carries the ciphertext / IV / key
//     reference / hash under explicit named fields, but its
//     `toString()` deliberately surfaces NONE of them — accidental
//     `print(result)` / log interpolation cannot leak the encrypted
//     payload, nonce, key reference, or hash.
//
// Gated-inert: nothing in this file is wired into a route, the
// bootstrap request path, or `recordTurn`. It is dormant until the
// advisor answer endpoint (A4.2) constructs the encryptor with a
// concrete resolver and calls it. The concrete proxy-side resolver
// is only constructed when the optional `ADVISOR_CONVERSATION_CMK`
// secret is present; absent the secret, the encryptor is simply
// never built (the answer endpoint fails closed).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;

/// Resolves the 256-bit advisor-conversation data key and the stable
/// `content_key_ref` that names it.
///
/// Implementations MUST treat the returned key bytes as live secret
/// material: the [AdvisorConversationEnvelope] uses them for exactly
/// one encrypt call and never retains them. A resolver MUST NOT log,
/// cache to disk, or otherwise persist the key bytes outside the
/// process secret store.
///
/// The abstraction lives in the app library (not the proxy) so the
/// encryptor has no dependency on `ProxyConfig`; the concrete,
/// secret-reading resolver lives proxy-side and is wired only when
/// the optional `ADVISOR_CONVERSATION_CMK` secret is provisioned.
abstract class AdvisorConversationCmkResolver {
  /// Returns the live 256-bit (32-byte) data key together with the
  /// `kv://` reference that records which CMK produced the
  /// ciphertext. The key bytes are consumed immediately by the
  /// encryptor and never stored.
  ({List<int> keyBytes, String keyRef}) resolve();
}

/// Thrown when CMK resolution yields a key that is not exactly 32
/// bytes (256 bits). The message names ONLY the failure mode and the
/// observed length — it NEVER echoes the key bytes themselves — so it
/// is safe to surface in logs (Hard Promise #7).
class AdvisorConversationKeyLengthError implements Exception {
  const AdvisorConversationKeyLengthError(this.actualLength);

  /// The number of key bytes the resolver returned. The bytes
  /// themselves are deliberately NOT captured.
  final int actualLength;

  @override
  String toString() =>
      'AdvisorConversationKeyLengthError: advisor-conversation CMK must '
      'be exactly 32 bytes (AES-256); resolver returned $actualLength '
      'bytes. (Key material deliberately omitted from this message.)';
}

/// Result of encrypting one advisor turn: exactly the four
/// secret-shaped fields `AdvisorConversationLogRepository.recordTurn`
/// consumes. Encryption is upstream of the repository; the repository
/// accepts ciphertext only.
///
/// `toString()` deliberately omits the ciphertext, IV, key reference,
/// and hash so accidental log-line interpolation / `print(result)`
/// cannot leak the secret-shaped fields — mirroring the
/// `AuditPrivacyConversationRow` privacy posture. The format is pinned
/// by a test so a future field addition that echoes secret material
/// trips review.
class AdvisorConversationEncryptedTurn {
  AdvisorConversationEncryptedTurn({
    required List<int> contentEncrypted,
    required List<int> contentIv,
    required this.contentKeyRef,
    required this.contentHash,
  })  : contentEncrypted = List<int>.unmodifiable(contentEncrypted),
        contentIv = List<int>.unmodifiable(contentIv);

  /// AES-256-GCM ciphertext with the 128-bit authentication tag
  /// appended. Stored unmodifiable so a downstream consumer cannot
  /// mutate the buffer.
  final List<int> contentEncrypted;

  /// The fresh 96-bit (12-byte) GCM nonce that pairs with
  /// [contentEncrypted]. Stored unmodifiable.
  final List<int> contentIv;

  /// Stable `kv://` reference to the CMK that produced the
  /// ciphertext (e.g. `kv://forge-flow/cmk/v1`). Never the raw key.
  final String contentKeyRef;

  /// Lowercase SHA-256 hex of the canonical plaintext payload.
  /// 64 characters, matching the migration's CHECK constraint.
  final String contentHash;

  /// Metadata-free rendering. Deliberately omits ciphertext, IV, key
  /// reference, and hash so `print(result)` / log interpolation
  /// cannot leak the secret-shaped fields. Pinned by tests.
  @override
  String toString() => 'AdvisorConversationEncryptedTurn('
      'contentEncrypted: ${contentEncrypted.length} bytes, '
      'contentIv: ${contentIv.length} bytes)';
}

/// In-process AES-256-GCM envelope encryptor for advisor conversation
/// turns. Constructed with a [AdvisorConversationCmkResolver]; each
/// [encryptTurn] call resolves a fresh view of the key, encrypts with
/// a fresh nonce, and discards the key.
class AdvisorConversationEnvelope {
  AdvisorConversationEnvelope({
    required AdvisorConversationCmkResolver resolver,
    Random? random,
  })  : _resolver = resolver,
        _random = random ?? Random.secure();

  /// AES-256 requires a 256-bit (32-byte) key.
  static const int _keyLengthBytes = 32;

  /// GCM's recommended nonce length is 96 bits (12 bytes). The IV is
  /// generated fresh per call and never reused under the same key.
  static const int _ivLengthBytes = 12;

  /// GCM authentication tag length in BITS, as `AEADParameters`
  /// expects it. 128 bits = the full 16-byte tag (the only value the
  /// pointycastle GCM mode accepts).
  static const int _macSizeBits = 128;

  final AdvisorConversationCmkResolver _resolver;
  final Random _random;

  /// Encrypts one advisor turn and returns the four secret-shaped
  /// fields the persistence layer consumes.
  ///
  /// The canonical plaintext payload is a deterministic JSON object
  /// `{"role": <role>, "content": <content>}` (keys in fixed order)
  /// so the SHA-256 [AdvisorConversationEncryptedTurn.contentHash] is
  /// reproducible by a forensic reader who decrypts the ciphertext and
  /// rebuilds the same canonical form. Both the ciphertext and the
  /// hash are computed over these UTF-8 bytes.
  ///
  /// [role] is bound verbatim; the repository validates it against its
  /// allowed-role set, so this method does not duplicate that check
  /// (it would only diverge over time).
  ///
  /// A fresh 12-byte nonce is drawn from the secure RNG on every call.
  /// The 256-bit key is resolved, used once, and dropped — it is never
  /// retained on the instance.
  AdvisorConversationEncryptedTurn encryptTurn({
    required String role,
    required String content,
  }) {
    final payloadBytes = _canonicalPayloadBytes(role: role, content: content);

    // SHA-256 of the canonical plaintext payload, lowercase hex.
    // `crypto.sha256` already renders lowercase hex via `toString()`.
    final contentHash = crypto.sha256.convert(payloadBytes).toString();

    // Resolve the key for exactly this call. `resolved` holds the live
    // key bytes; they are never assigned to a field and go out of
    // scope when this method returns.
    final resolved = _resolver.resolve();
    final keyBytes = resolved.keyBytes;
    if (keyBytes.length != _keyLengthBytes) {
      // Typed error; names the length only, never the bytes (HP #7).
      throw AdvisorConversationKeyLengthError(keyBytes.length);
    }

    // Fresh 96-bit nonce. NEVER reused under the same key.
    final iv = _newNonce();

    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        true, // forEncryption
        pc.AEADParameters(
          pc.KeyParameter(Uint8List.fromList(keyBytes)),
          _macSizeBits,
          iv,
          Uint8List(0), // no associated data
        ),
      );

    // `process` on a GCM cipher returns ciphertext || authTag.
    final ciphertextWithTag = cipher.process(
      Uint8List.fromList(payloadBytes),
    );

    return AdvisorConversationEncryptedTurn(
      contentEncrypted: ciphertextWithTag,
      contentIv: iv,
      contentKeyRef: resolved.keyRef,
      contentHash: contentHash,
    );
  }

  /// Canonical UTF-8 bytes of the advisor-turn payload. Deterministic
  /// key order so the content hash is reproducible after decrypt.
  static List<int> _canonicalPayloadBytes({
    required String role,
    required String content,
  }) {
    // A fixed-key-order JSON object. `jsonEncode` preserves insertion
    // order for a `Map` literal, so the bytes are stable for a given
    // (role, content) pair.
    final canonical = jsonEncode(<String, String>{
      'role': role,
      'content': content,
    });
    return utf8.encode(canonical);
  }

  /// Draws a fresh [_ivLengthBytes]-byte nonce from the secure RNG.
  Uint8List _newNonce() {
    final nonce = Uint8List(_ivLengthBytes);
    for (var i = 0; i < _ivLengthBytes; i++) {
      nonce[i] = _random.nextInt(256);
    }
    return nonce;
  }
}
