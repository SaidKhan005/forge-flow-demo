// Phase 9 live-closeout B15 - Production PasswordHistoryCheck.
//
// Backs [PasswordHistoryCheck] with a [PasswordHistoryRepository] +
// a server-side hasher. The candidate is hashed before any
// comparison so the raw password never leaves the proxy boundary.
//
// Hash family: SHA-256 (re-use detection only, NOT a credential
// hash — Firebase still handles credential hashing). Per the
// `password_history.password_hash` schema comment in 9.0:
//
//   `password_hash text not null
//    -- re-use detection only — Firebase still handles the credential hash`
//
// Constant-time comparison on the digest pair so timing attacks
// cannot enumerate hash matches.

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../../infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import 'password_history_check.dart';

/// Hashes a password candidate into the canonical `password_history`
/// hash form. Tests inject deterministic implementations.
abstract class PasswordHistoryHasher {
  /// Returns the canonical hex digest used for re-use detection.
  /// Production binds [Sha256PasswordHistoryHasher].
  String hash({required String operatorId, required String userId, required String candidate});
}

/// Production hasher: SHA-256(operator_id || user_id || candidate).
/// Including the operator_id + user_id in the hash input makes the
/// stored hashes both per-user AND per-tenant — two operators that
/// happen to mint identical passwords for unrelated users still hash
/// to different digests, so a row-leak across tenants cannot enable
/// a same-password fingerprint attack.
class Sha256PasswordHistoryHasher implements PasswordHistoryHasher {
  const Sha256PasswordHistoryHasher();

  @override
  String hash({
    required String operatorId,
    required String userId,
    required String candidate,
  }) {
    final input = utf8.encode('$operatorId|$userId|$candidate');
    return crypto.sha256.convert(input).toString();
  }
}

/// Production [PasswordHistoryCheck] backed by the Postgres
/// `password_history` table via [PasswordHistoryRepository].
///
/// The check signature `isReusedPassword({userId, candidate})` does
/// not carry tenant context — the proxy must inject it via the
/// constructor. That keeps the existing service interface stable
/// while still routing every read through the tenant-scoped
/// transaction wrapper.
class RepositoryPasswordHistoryCheck implements PasswordHistoryCheck {
  RepositoryPasswordHistoryCheck({
    required PasswordHistoryRepository repository,
    required PasswordHistoryHasher hasher,
    required String operatorId,
    required String locationId,
    int retentionCount = PasswordHistoryRepository.defaultRetentionCount,
  }) : _repository = repository,
       _hasher = hasher,
       _operatorId = operatorId,
       _locationId = locationId,
       _retentionCount = retentionCount;

  final PasswordHistoryRepository _repository;
  final PasswordHistoryHasher _hasher;
  final String _operatorId;
  final String _locationId;
  final int _retentionCount;

  @override
  Future<bool> isReusedPassword({
    required String userId,
    required String candidate,
  }) async {
    final candidateHash = _hasher.hash(
      operatorId: _operatorId,
      userId: userId,
      candidate: candidate,
    );
    final entries = await _repository.latestHashes(
      operatorId: _operatorId,
      locationId: _locationId,
      userId: userId,
      n: _retentionCount,
    );
    for (final entry in entries) {
      if (_constantTimeEquals(entry.passwordHash, candidateHash)) {
        return true;
      }
    }
    return false;
  }

  /// Records [candidate] as the user's new password hash and prunes
  /// rows beyond the retention limit. Caller invokes this only after
  /// the password change has been accepted by Firebase.
  Future<void> recordAndPrune({
    required String userId,
    required String candidate,
  }) async {
    final hash = _hasher.hash(
      operatorId: _operatorId,
      userId: userId,
      candidate: candidate,
    );
    await _repository.recordHash(
      operatorId: _operatorId,
      locationId: _locationId,
      userId: userId,
      passwordHashHex: hash,
    );
    await _repository.prune(
      operatorId: _operatorId,
      locationId: _locationId,
      userId: userId,
      n: _retentionCount,
    );
  }

  /// Constant-time string equality on equal-length hex digests. Both
  /// inputs are SHA-256 hex (64 chars) in production — mismatched
  /// lengths short-circuit since the digest length is fixed.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
