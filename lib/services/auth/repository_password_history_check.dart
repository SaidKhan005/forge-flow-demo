// Phase 9 live-closeout B15 - Production PasswordHistoryCheck.
//
// Backs [PasswordHistoryCheck] with a [PasswordHistoryRepository] +
// a server-side hasher. The candidate is hashed before any
// comparison so the raw password never leaves the proxy boundary.
//
// Hash families (post code-health.M2 + code-health.L12):
//
//   * `sha256-legacy` — pre-M2 unsalted SHA-256(operator || user ||
//     candidate). Existing rows wear this label after the M2 backfill;
//     verification routes them through [PasswordHistoryHasher] (the
//     [Sha256PasswordHistoryHasher] shape that has been in place since
//     Phase 9). NO new rows are written in this family — the writer
//     always emits the salted family below.
//
//   * `sha256-salted` — SHA-256(pepper_bytes || salt_bytes || operator
//     || user || candidate). The pepper is a deploy-time secret
//     injected via the `PASSWORD_HISTORY_PEPPER` env var (rotation key
//     identified by [pepperId]); the salt is a 16-byte CSPRNG value
//     drawn per row. Both bytes are mixed in BEFORE the operator-id +
//     user-id + candidate string the legacy family already binds, so
//     the legacy fingerprint-isolation property carries over while the
//     salted family also resists offline rainbow-table reconstruction
//     against a single (operator_id, user_id) pair on table leak.
//
// Verification dispatches on the row's `password_hash_algo` column.
// Constant-time digest comparison runs over the entire digest with no
// early break.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import 'password_history_check.dart';

/// Hashes a password candidate into the canonical legacy
/// `password_history` hash form (algo = `sha256-legacy`). Production
/// binds [Sha256PasswordHistoryHasher]; tests inject deterministic
/// implementations for the legacy verification path. New rows are
/// always written in the salted family — see
/// [RepositoryPasswordHistoryCheck.recordAndPrune].
abstract class PasswordHistoryHasher {
  /// Returns the canonical hex digest used for legacy re-use detection.
  /// Production binds [Sha256PasswordHistoryHasher].
  String hash({
    required String operatorId,
    required String userId,
    required String candidate,
  });
}

/// Production legacy hasher: SHA-256(operator_id || user_id ||
/// candidate). Including the operator_id + user_id in the hash input
/// makes the stored hashes both per-user AND per-tenant — two
/// operators that happen to mint identical passwords for unrelated
/// users still hash to different digests, so a row-leak across tenants
/// cannot enable a same-password fingerprint attack.
///
/// This hasher is only used to verify pre-M2 rows that wear
/// `password_hash_algo = 'sha256-legacy'`. New writes always use the
/// salted family computed inside [RepositoryPasswordHistoryCheck].
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

/// Source of per-row CSPRNG salt bytes. Production binds
/// [_DefaultSecureSaltSource] (16 bytes from `Random.secure()`); tests
/// can inject a deterministic source.
abstract class PasswordHistorySaltSource {
  /// Returns 16 fresh bytes per call. Implementations MUST use a
  /// cryptographically secure source — no PRNG seeded from clock time
  /// or process id.
  Uint8List nextSalt();
}

/// 16-byte salt drawn from `Random.secure()`. The platform-provided
/// entropy source is the same one Dart's TLS / RNG-backed APIs use.
class _DefaultSecureSaltSource implements PasswordHistorySaltSource {
  _DefaultSecureSaltSource() : _rng = Random.secure();

  final Random _rng;

  @override
  Uint8List nextSalt() {
    final out = Uint8List(_saltLengthBytes);
    for (var i = 0; i < _saltLengthBytes; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }
}

/// Locked salt length in bytes. 16 bytes is the floor pinned by
/// CODE_HEALTH.L12; the schema column is `BYTEA` so longer salts are
/// schema-compatible if a future hardening lane raises this.
const int _saltLengthBytes = 16;

/// Reads the global pepper from the env at construction time.
/// `--dart-define=PASSWORD_HISTORY_PEPPER=...` in production; in tests
/// callers either pass [PasswordHistoryPepperConfig.test] (which uses
/// a deterministic pepper) or run under `kDemoMode = true`.
const String _pepperEnvVar = 'PASSWORD_HISTORY_PEPPER';

/// Read once at compile time. `String.fromEnvironment` returns '' when
/// the define is not provided.
const String _envPepper = String.fromEnvironment(_pepperEnvVar);

/// Read once at compile time. Mirrors the [kDemoMode] convention used
/// elsewhere in the repo (e.g. `lib/services/app_data_status_service.dart`).
const bool _envDemoMode = bool.fromEnvironment('kDemoMode');

/// Typed startup error thrown when `PASSWORD_HISTORY_PEPPER` is missing
/// in non-demo mode. The proxy must surface this as a hard refusal at
/// startup rather than silently writing un-peppered rows.
class PasswordHistoryPepperMissingError extends Error {
  PasswordHistoryPepperMissingError();

  @override
  String toString() =>
      'PasswordHistoryPepperMissingError: '
      '`$_pepperEnvVar` is required in non-demo mode. '
      'Inject the pepper via --dart-define=$_pepperEnvVar=<value> '
      '(production) or set --dart-define=kDemoMode=true (demo).';
}

/// Pepper configuration consumed by [RepositoryPasswordHistoryCheck].
/// Production binds [PasswordHistoryPepperConfig.fromEnv]; tests bind
/// [PasswordHistoryPepperConfig.literal] for deterministic salting.
class PasswordHistoryPepperConfig {
  const PasswordHistoryPepperConfig._({
    required this.pepperBytes,
    required this.pepperId,
  });

  /// Raw pepper bytes mixed into every salted hash. Empty allowed
  /// only on the demo-mode path so widget tests / walkthroughs work
  /// without injecting a real secret.
  final Uint8List pepperBytes;

  /// Stable identifier of the pepper. Persisted as
  /// `password_hash_pepper_id` so a future rotation can verify legacy
  /// rows under the old pepper while writing under the new one. The id
  /// is a SHA-256 prefix of the pepper bytes, NEVER the pepper itself.
  final String pepperId;

  /// Reads the pepper from `--dart-define=PASSWORD_HISTORY_PEPPER`. If
  /// empty AND not in demo mode, throws [PasswordHistoryPepperMissingError].
  /// In demo mode, returns a degenerate config that uses an empty
  /// pepper and a fixed id so the walkthrough stays deterministic.
  factory PasswordHistoryPepperConfig.fromEnv() {
    final raw = _envPepper;
    if (raw.isEmpty) {
      if (!_envDemoMode) {
        throw PasswordHistoryPepperMissingError();
      }
      return PasswordHistoryPepperConfig._(
        pepperBytes: Uint8List(0),
        pepperId: 'demo',
      );
    }
    return PasswordHistoryPepperConfig._(
      pepperBytes: Uint8List.fromList(utf8.encode(raw)),
      pepperId: _derivePepperId(utf8.encode(raw)),
    );
  }

  /// Test override. Callers pass an explicit pepper string; the id is
  /// derived deterministically from the bytes so tests can assert it.
  /// The factory does NOT touch the env var or the kDemoMode flag.
  factory PasswordHistoryPepperConfig.literal(String pepper) {
    final bytes = Uint8List.fromList(utf8.encode(pepper));
    return PasswordHistoryPepperConfig._(
      pepperBytes: bytes,
      pepperId: pepper.isEmpty ? 'literal-empty' : _derivePepperId(bytes),
    );
  }

  /// Derives a stable, non-secret id from the pepper bytes. We expose
  /// the first 16 hex chars of SHA-256(pepper); a partial-preimage
  /// attack against this id would not recover the pepper, and the id
  /// is short enough to keep the column readable in `psql` output.
  static String _derivePepperId(List<int> bytes) {
    final digest = crypto.sha256.convert(bytes).toString();
    return 'sha256:${digest.substring(0, 16)}';
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
  /// [pepper] defaults to reading the `PASSWORD_HISTORY_PEPPER` env
  /// var; the constructor throws [PasswordHistoryPepperMissingError]
  /// at construction time if the env var is missing in non-demo mode.
  /// Tests should pass `pepper: PasswordHistoryPepperConfig.literal(...)`.
  ///
  /// [saltSource] defaults to a `Random.secure()`-backed 16-byte
  /// source; tests can inject a deterministic source.
  RepositoryPasswordHistoryCheck({
    required PasswordHistoryRepository repository,
    required PasswordHistoryHasher hasher,
    required String operatorId,
    required String locationId,
    PasswordHistoryPepperConfig? pepper,
    PasswordHistorySaltSource? saltSource,
    int retentionCount = PasswordHistoryRepository.defaultRetentionCount,
  }) : _repository = repository,
       _legacyHasher = hasher,
       _operatorId = operatorId,
       _locationId = locationId,
       _pepper = pepper ?? PasswordHistoryPepperConfig.fromEnv(),
       _saltSource = saltSource ?? _DefaultSecureSaltSource(),
       _retentionCount = retentionCount;

  final PasswordHistoryRepository _repository;
  final PasswordHistoryHasher _legacyHasher;
  final String _operatorId;
  final String _locationId;
  final PasswordHistoryPepperConfig _pepper;
  final PasswordHistorySaltSource _saltSource;
  final int _retentionCount;

  /// Salted-family algo label persisted in `password_hash_algo` for
  /// every new write. Verification dispatches on this value so a
  /// future hash family can be added without rehashing existing rows.
  static const String saltedAlgo = 'sha256-salted';

  /// Legacy-family algo label backfilled by code-health.M2. Pre-M2
  /// rows wear this; new writes never do.
  static const String legacyAlgo = 'sha256-legacy';

  @override
  Future<bool> isReusedPassword({
    required String userId,
    required String candidate,
  }) async {
    final entries = await _readLatestEntries(userId: userId);
    for (final entry in entries) {
      final expected = entry.passwordHash;
      final actual = _hashCandidateForEntry(
        userId: userId,
        candidate: candidate,
        entry: entry,
      );
      if (_constantTimeHexEquals(expected, actual)) {
        return true;
      }
    }
    return false;
  }

  /// Records [candidate] as the user's new password hash and prunes
  /// rows beyond the retention limit. Caller invokes this only after
  /// the password change has been accepted by Firebase. New rows are
  /// always written in the salted family.
  Future<void> recordAndPrune({
    required String userId,
    required String candidate,
  }) async {
    final salt = _saltSource.nextSalt();
    final hashHex = _saltedHashHex(
      userId: userId,
      candidate: candidate,
      salt: salt,
    );
    await _writeSaltedRow(
      userId: userId,
      passwordHashHex: hashHex,
      salt: salt,
    );
    await _repository.prune(
      operatorId: _operatorId,
      locationId: _locationId,
      userId: userId,
      n: _retentionCount,
    );
  }

  /// Custom INSERT that populates `password_hash_salt`,
  /// `password_hash_pepper_id`, and `password_hash_algo` alongside the
  /// hash hex. We bypass [PasswordHistoryRepository.recordHash] so the
  /// new columns get set in a single SQL statement; routing through
  /// the public [withTenant] helper keeps the tenant-scoped
  /// transaction + SET LOCAL invariants intact.
  Future<void> _writeSaltedRow({
    required String userId,
    required String passwordHashHex,
    required Uint8List salt,
  }) async {
    final ctx = TenantContext(
      operatorId: _operatorId,
      locationId: _locationId,
      userId: userId,
    );
    await _repository.withTenant<void>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into password_history '
        '(user_id, password_hash, password_hash_salt, '
        'password_hash_pepper_id, password_hash_algo) '
        'values (@user_id::uuid, @hash, @salt, @pepper_id, @algo) '
        'returning entry_id::text as entry_id',
        parameters: <String, Object?>{
          'user_id': userId,
          'hash': passwordHashHex,
          'salt': salt,
          'pepper_id': _pepper.pepperId,
          'algo': saltedAlgo,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'password_history insert returned no rows — RLS policy may '
          'have blocked the row even though SET LOCAL ran',
        );
      }
    });
  }

  /// Custom SELECT that returns the hash + salt + pepper_id + algo
  /// columns together so the verifier can route each row to its
  /// correct hash-family code path. We bypass
  /// [PasswordHistoryRepository.latestHashes] because that method's
  /// projection only returns the hex hash.
  Future<List<_HistoryEntry>> _readLatestEntries({required String userId}) {
    final ctx = TenantContext(
      operatorId: _operatorId,
      locationId: _locationId,
      userId: userId,
    );
    return _repository.withTenant<List<_HistoryEntry>>(ctx, (exec) async {
      final rows = await exec.query(
        'select entry_id::text as entry_id, '
        'password_hash, password_hash_salt, password_hash_pepper_id, '
        'password_hash_algo, set_at '
        'from password_history '
        'where user_id = @user_id::uuid '
        'order by set_at desc '
        'limit @limit',
        parameters: <String, Object?>{
          'user_id': userId,
          'limit': _retentionCount,
        },
      );
      return rows.map(_HistoryEntry.fromRow).toList(growable: false);
    });
  }

  /// Compute the candidate hash that should match [entry] if the
  /// candidate is the same plaintext that produced the stored hash.
  ///
  /// `sha256-legacy` rows route to the injected [PasswordHistoryHasher]
  /// (so legacy rows stay verifiable without rehashing); every other
  /// algo (today: `sha256-salted`) recomputes the salted hash with the
  /// row's stored salt + the active pepper. Unknown algos fall back to
  /// a digest that cannot match any stored value (we return a string
  /// of the wrong length so `_constantTimeHexEquals` short-circuits).
  String _hashCandidateForEntry({
    required String userId,
    required String candidate,
    required _HistoryEntry entry,
  }) {
    final algo = entry.algo;
    if (algo == legacyAlgo) {
      return _legacyHasher.hash(
        operatorId: _operatorId,
        userId: userId,
        candidate: candidate,
      );
    }
    if (algo == saltedAlgo) {
      final salt = entry.salt;
      if (salt == null) {
        // CHECK constraint should have prevented this on the server,
        // but defensively treat a NULL salt as un-verifiable rather
        // than booting a NoSuchElement.
        return '';
      }
      return _saltedHashHex(
        userId: userId,
        candidate: candidate,
        salt: salt,
      );
    }
    // Unknown algo — return a sentinel that cannot match any digest.
    return '';
  }

  /// Salted hash construction:
  ///
  ///   SHA-256(pepper_bytes || salt_bytes || operator_id || '|' ||
  ///           user_id || '|' || candidate)
  ///
  /// The bytes-input order mirrors the legacy hasher's tail
  /// (`operator|user|candidate`) so a future migration that wants to
  /// re-prove a plaintext under the new family doesn't need to know
  /// any internal salt-application detail beyond "prefix the legacy
  /// input with pepper_bytes || salt_bytes".
  String _saltedHashHex({
    required String userId,
    required String candidate,
    required Uint8List salt,
  }) {
    final builder = BytesBuilder(copy: false);
    builder.add(_pepper.pepperBytes);
    builder.add(salt);
    builder.add(utf8.encode('$_operatorId|$userId|$candidate'));
    return crypto.sha256.convert(builder.takeBytes()).toString();
  }

  /// Constant-time string equality on equal-length hex digests. Both
  /// inputs are SHA-256 hex (64 chars) in production — mismatched
  /// lengths short-circuit since the digest length is fixed. The XOR
  /// loop runs over every byte with no early break so a partial-match
  /// timing channel cannot leak prefix-length information.
  static bool _constantTimeHexEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// Internal projection of a single password_history row in the shape
/// the verifier needs. Kept private to this file so the public
/// [PasswordHistoryEntry] surface from the repository stays stable.
class _HistoryEntry {
  _HistoryEntry({
    required this.passwordHash,
    required this.salt,
    required this.pepperId,
    required this.algo,
  });

  final String passwordHash;
  final Uint8List? salt;
  final String? pepperId;
  final String algo;

  static _HistoryEntry fromRow(Map<String, Object?> row) {
    final hash = row['password_hash'];
    if (hash is! String || hash.isEmpty) {
      throw StateError(
        'password_history row missing password_hash — schema drift?',
      );
    }
    final rawSalt = row['password_hash_salt'];
    Uint8List? salt;
    if (rawSalt is Uint8List) {
      salt = rawSalt;
    } else if (rawSalt is List<int>) {
      salt = Uint8List.fromList(rawSalt);
    }
    final pepperId = row['password_hash_pepper_id'];
    final algoRaw = row['password_hash_algo'];
    // Defensive default: rows that pre-date the M2 migration column
    // (or test mocks that omit the column) verify under the legacy
    // code path. The CHECK constraint added in M2 prevents the
    // ambiguous case from arising in production.
    final algo = algoRaw is String && algoRaw.isNotEmpty
        ? algoRaw
        : RepositoryPasswordHistoryCheck.legacyAlgo;
    return _HistoryEntry(
      passwordHash: hash,
      salt: salt,
      pepperId: pepperId is String ? pepperId : null,
      algo: algo,
    );
  }
}
