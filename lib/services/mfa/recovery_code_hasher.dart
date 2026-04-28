// Phase 9.4 - Recovery code hash + verify.
//
// "Hashed at rest" per the decision lock. We use SHA-256 of
// `salt || normalized_code` so:
//
//   - the same code, given the same per-user salt, hashes to the
//     same bytes (so verification is deterministic);
//   - the same code, with a different salt, hashes differently (so
//     two operators that happen to mint the same random code never
//     collide);
//   - rainbow-table attacks against the per-user table need to do
//     2^57 work per code (the alphabet entropy from the generator).
//
// Salt is per-user, not per-code: the proxy generates a fresh
// 16-byte salt at MFA enrollment, persists it on the user row, and
// hands it to this hasher for every store + verify call. Codes are
// stored as `(user_id, factor_type='recovery_code', metadata->>hash)`
// in `mfa_factors` (Phase 9.0 schema; one row per recovery code).
//
// Production wiring uses [Sha256RecoveryCodeHasher]; tests use a
// deterministic fake. The scaffold default fails closed.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Stores both the salt (16 bytes, base64-encoded for transport)
/// and the hash (32 bytes, base64-encoded). The proxy persists the
/// pair; the plaintext code never leaves the enrollment screen.
class HashedRecoveryCode {
  const HashedRecoveryCode({required this.saltBase64, required this.hashBase64});

  final String saltBase64;
  final String hashBase64;

  Map<String, Object?> toJson() => <String, Object?>{
    'salt': saltBase64,
    'hash': hashBase64,
  };

  static HashedRecoveryCode fromJson(Map<String, Object?> json) {
    return HashedRecoveryCode(
      saltBase64: json['salt'] as String,
      hashBase64: json['hash'] as String,
    );
  }
}

abstract class RecoveryCodeHasher {
  /// Hashes [normalizedCode] under [saltBytes]. The caller is
  /// responsible for normalizing first via
  /// [RecoveryCodeGenerator.normalize].
  HashedRecoveryCode hash({
    required String normalizedCode,
    required Uint8List saltBytes,
  });

  /// Returns true iff hashing [normalizedCode] under [stored.saltBase64]
  /// produces [stored.hashBase64]. Constant-time on the hash
  /// comparison so timing attacks cannot enumerate matches.
  bool verify({
    required String normalizedCode,
    required HashedRecoveryCode stored,
  });
}

/// Production implementation using `package:crypto`.
class Sha256RecoveryCodeHasher implements RecoveryCodeHasher {
  const Sha256RecoveryCodeHasher();

  @override
  HashedRecoveryCode hash({
    required String normalizedCode,
    required Uint8List saltBytes,
  }) {
    final digest = _digest(normalizedCode, saltBytes);
    return HashedRecoveryCode(
      saltBase64: base64.encode(saltBytes),
      hashBase64: base64.encode(digest.bytes),
    );
  }

  @override
  bool verify({
    required String normalizedCode,
    required HashedRecoveryCode stored,
  }) {
    final Uint8List storedSalt;
    final Uint8List storedHash;
    try {
      storedSalt = base64.decode(stored.saltBase64);
      storedHash = base64.decode(stored.hashBase64);
    } catch (_) {
      return false;
    }
    final candidate = _digest(normalizedCode, storedSalt).bytes;
    return _constantTimeEquals(candidate, storedHash);
  }

  static Digest _digest(String code, Uint8List salt) {
    final input = BytesBuilder();
    input.add(salt);
    input.add(utf8.encode(code));
    return sha256.convert(input.toBytes());
  }

  /// XOR every byte and OR the results so the comparison time is
  /// independent of where the first mismatch is. Both inputs must
  /// be the same length; mismatched lengths short-circuit to false
  /// (timing leak of length is acceptable — 32 bytes always for
  /// SHA-256).
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Hard-fail-closed default. Throws on every call so a deploy that
/// forgets to wire a real hasher refuses MFA enrollment + recovery
/// code attempts rather than silently allowing.
class ScaffoldFailingRecoveryCodeHasher implements RecoveryCodeHasher {
  const ScaffoldFailingRecoveryCodeHasher();

  @override
  HashedRecoveryCode hash({
    required String normalizedCode,
    required Uint8List saltBytes,
  }) {
    throw StateError(
      '9.4 scaffold: real RecoveryCodeHasher is not wired — bind '
      '`Sha256RecoveryCodeHasher` (or another production hasher) in '
      'the proxy bootstrap before issuing recovery codes.',
    );
  }

  @override
  bool verify({
    required String normalizedCode,
    required HashedRecoveryCode stored,
  }) {
    throw StateError(
      '9.4 scaffold: real RecoveryCodeHasher is not wired.',
    );
  }
}
