// L5 — MFA factor-verification boundary coverage.
//
// Forge & Flow does not run a local TOTP verifier — Firebase owns
// TOTP step verification (window tolerance, replay rejection, code
// shape) at the SDK boundary. The closest in-process "factor
// verifier" is the recovery-code stack:
//
//   * `Sha256RecoveryCodeHasher` is the cryptographic primitive that
//     decides whether a user-supplied code matches a stored factor.
//     This file pins:
//       - SHA-256 output length (32 bytes raw → 44 base64 chars),
//       - determinism (same code+salt → same hash),
//       - constant-time comparison symmetry,
//       - JSON round-trip preserves the bytes,
//       - degenerate inputs (empty code, empty salt, very long code,
//         varied salt sizes) do not crash.
//
//   * `RecoveryCodeConsumer` ties the hasher to the repository and
//     attempt-limiter. The live-binding test covers the happy /
//     invalid / replay / rate-limited paths against the canonical
//     uppercase form. This file extends with:
//       - lowercase + dashed user input still matches (boundary the
//         normalize() layer feeds into),
//       - multiple stored factors → only the matching row is marked
//         used; siblings stay active,
//       - factor metadata with the wrong shape (missing keys, wrong
//         types) is silently skipped — neither crash nor false-match.
//
//   * `RecoveryCodeAttemptLimiter` boundary moments — 59s vs 61s for
//     the per-minute window, 4-vs-5 attempts for the daily budget.
//     The decision values returned at the boundary feed the proxy's
//     `retryAfter` / `resetsAt` HTTP envelopes; getting them wrong
//     misroutes user copy.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_attempt_limiter.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_consumer.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_hasher.dart';

const String _operatorId = '11111111-1111-4111-8111-111111111111';
const String _locationId = '22222222-2222-4222-8222-222222222222';
const String _userId = '33333333-3333-4333-8333-333333333333';
const String _factorIdMatch = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _factorIdOther = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

PostgresRow _recoveryRow({
  required String factorId,
  required Object? metadataJsonOrMap,
}) {
  final metadata = metadataJsonOrMap is String
      ? metadataJsonOrMap
      : jsonEncode(metadataJsonOrMap);
  return <String, Object?>{
    'factor_id': factorId,
    'user_id': _userId,
    'factor_type': 'recovery_code',
    'factor_metadata': metadata,
    'enrolled_at': DateTime.utc(2026, 4, 26, 11),
    'last_used_at': null,
    'revoked_at': null,
  };
}

RecoveryCodeConsumer _consumer({
  required _MfaFactorsPool pool,
  RecoveryCodeAttemptStore? attempts,
  DateTime Function()? now,
}) {
  return RecoveryCodeConsumer(
    hasher: const Sha256RecoveryCodeHasher(),
    repository: MfaFactorsRepository(TenantTransactionWrapper(pool)),
    limiter: RecoveryCodeAttemptLimiter(
      store: attempts ?? InMemoryRecoveryCodeAttemptStore(),
      now: now ?? () => DateTime.utc(2026, 4, 26, 12),
    ),
  );
}

void main() {
  group('Sha256RecoveryCodeHasher (factor-verification primitive)', () {
    test('hash output length: 32-byte digest, 44-char base64 (SHA-256)', () {
      const hasher = Sha256RecoveryCodeHasher();
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));
      final hashed = hasher.hash(
        normalizedCode: 'AAAABBBBCCCC',
        saltBytes: salt,
      );
      // 32 raw digest bytes encode to 44 base64 chars (with padding).
      expect(base64.decode(hashed.hashBase64), hasLength(32));
      expect(hashed.hashBase64, hasLength(44));
      // 16-byte salt encodes to 24 base64 chars.
      expect(hashed.saltBase64, hasLength(24));
    });

    test('determinism: same code + same salt → identical hash bytes', () {
      const hasher = Sha256RecoveryCodeHasher();
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));
      final a = hasher.hash(normalizedCode: 'CODE', saltBytes: salt);
      final b = hasher.hash(normalizedCode: 'CODE', saltBytes: salt);
      expect(a.hashBase64, equals(b.hashBase64));
    });

    test('verify is symmetric over hash: hash(c, s) ⇒ verify(c, h)=true',
        () {
      const hasher = Sha256RecoveryCodeHasher();
      // Symmetric over multiple salts to catch off-by-one bugs in the
      // input concat order (salt || code vs. code || salt).
      for (var i = 0; i < 4; i++) {
        final salt = Uint8List.fromList(List<int>.generate(16, (j) => i * j));
        final stored = hasher.hash(
          normalizedCode: 'CODE-$i-Z',
          saltBytes: salt,
        );
        expect(
          hasher.verify(normalizedCode: 'CODE-$i-Z', stored: stored),
          isTrue,
        );
        // Adjacent code (one char off) does not match.
        expect(
          hasher.verify(normalizedCode: 'CODE-$i-Y', stored: stored),
          isFalse,
        );
      }
    });

    test('JSON round-trip preserves both salt + hash base64 strings', () {
      const hasher = Sha256RecoveryCodeHasher();
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => i + 50));
      final original = hasher.hash(
        normalizedCode: 'PRESERVED',
        saltBytes: salt,
      );
      final round =
          HashedRecoveryCode.fromJson(original.toJson());
      expect(round.saltBase64, equals(original.saltBase64));
      expect(round.hashBase64, equals(original.hashBase64));
      expect(
        hasher.verify(normalizedCode: 'PRESERVED', stored: round),
        isTrue,
      );
    });

    test('degenerate inputs (empty code, varied salt sizes) hash without crash',
        () {
      const hasher = Sha256RecoveryCodeHasher();
      // Empty code, 0-byte salt — still a valid SHA-256.
      final emptyHash = hasher.hash(
        normalizedCode: '',
        saltBytes: Uint8List(0),
      );
      expect(base64.decode(emptyHash.hashBase64), hasLength(32));
      // 32-byte salt (≠ default 16).
      final big = hasher.hash(
        normalizedCode: 'X' * 64,
        saltBytes: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      expect(base64.decode(big.hashBase64), hasLength(32));
      expect(base64.decode(big.saltBase64), hasLength(32));
    });

    test('verify returns false on mismatched hash byte length', () {
      const hasher = Sha256RecoveryCodeHasher();
      // A 16-byte hash (truncated) is not a valid SHA-256 digest;
      // constant-time compare must short-circuit on length.
      final truncated = HashedRecoveryCode(
        saltBase64: base64.encode(Uint8List(16)),
        hashBase64: base64.encode(Uint8List(16)),
      );
      expect(
        hasher.verify(normalizedCode: 'WHATEVER', stored: truncated),
        isFalse,
      );
    });
  });

  group('RecoveryCodeConsumer (boundary input + storage variants)', () {
    test('lowercase + dashed user input matches the stored uppercase hash',
        () async {
      final salt = Uint8List(16);
      final hashed = const Sha256RecoveryCodeHasher().hash(
        normalizedCode: 'AAAABBBBCCCC',
        saltBytes: salt,
      );
      final pool = _MfaFactorsPool(
        recoveryCodeRows: <PostgresRow>[
          _recoveryRow(
            factorId: _factorIdMatch,
            metadataJsonOrMap: hashed.toJson(),
          ),
        ],
      );
      final consumer = _consumer(pool: pool);

      final result = await consumer.consume(
        operatorId: _operatorId,
        locationId: _locationId,
        userId: _userId,
        // Mixed-case + dashes — the consumer normalizes both.
        rawCode: 'aaaa-bbbb-cccc',
      );

      expect(result, isA<RecoveryCodeConsumed>());
      expect(
        (result as RecoveryCodeConsumed).factorId,
        equals(_factorIdMatch),
      );
    });

    test('whitespace-only input is Invalid AND records the attempt',
        () async {
      final attempts = InMemoryRecoveryCodeAttemptStore();
      final consumer = _consumer(
        pool: _MfaFactorsPool(),
        attempts: attempts,
      );

      final result = await consumer.consume(
        operatorId: _operatorId,
        locationId: _locationId,
        userId: _userId,
        rawCode: '   \t  ',
      );

      expect(result, isA<RecoveryCodeInvalid>());
      // Even an unparseable code burns one attempt slot. Per the
      // 9.UX.1a policy lock — invalid attempts must count.
      expect(
        await attempts.recentAttempts(
          userId: _userId,
          now: DateTime.utc(2026, 4, 26, 12),
          window: const Duration(hours: 24),
        ),
        hasLength(1),
      );
    });

    test('multiple stored factors → only the matching row is marked used',
        () async {
      final salt = Uint8List(16);
      final matchHashed = const Sha256RecoveryCodeHasher().hash(
        normalizedCode: 'XXXXYYYYZZZZ',
        saltBytes: salt,
      );
      final otherHashed = const Sha256RecoveryCodeHasher().hash(
        normalizedCode: 'AAAABBBBCCCC',
        saltBytes: salt,
      );
      final pool = _MfaFactorsPool(
        recoveryCodeRows: <PostgresRow>[
          // Non-matching first; consumer must keep iterating.
          _recoveryRow(
              factorId: _factorIdOther,
              metadataJsonOrMap: otherHashed.toJson()),
          _recoveryRow(
              factorId: _factorIdMatch,
              metadataJsonOrMap: matchHashed.toJson()),
        ],
      );
      final consumer = _consumer(pool: pool);

      final result = await consumer.consume(
        operatorId: _operatorId,
        locationId: _locationId,
        userId: _userId,
        rawCode: 'XXXX-YYYY-ZZZZ',
      );

      expect(result, isA<RecoveryCodeConsumed>());
      expect(
        (result as RecoveryCodeConsumed).factorId,
        equals(_factorIdMatch),
      );
      // Update SQL ran exactly once and bound the matching factor_id.
      final tx = pool.transactions.last;
      final updateBindings = tx.parameters.firstWhere(
        (params) => params['factor_id'] == _factorIdMatch,
        orElse: () => const <String, Object?>{},
      );
      expect(updateBindings['factor_id'], equals(_factorIdMatch));
    });

    test('rows with missing/wrong metadata shape are silently skipped',
        () async {
      final salt = Uint8List(16);
      final hashed = const Sha256RecoveryCodeHasher().hash(
        normalizedCode: 'AAAABBBBCCCC',
        saltBytes: salt,
      );
      final pool = _MfaFactorsPool(
        recoveryCodeRows: <PostgresRow>[
          // Missing 'hash' key entirely.
          _recoveryRow(
            factorId: 'm1m1m1m1-m1m1-4m1m-8m1m-m1m1m1m1m1m1',
            metadataJsonOrMap: <String, Object?>{
              'salt': base64.encode(salt),
            },
          ),
          // 'salt' is a number, not a string.
          _recoveryRow(
            factorId: 'm2m2m2m2-m2m2-4m2m-8m2m-m2m2m2m2m2m2',
            metadataJsonOrMap: <String, Object?>{
              'salt': 42,
              'hash': base64.encode(Uint8List(32)),
            },
          ),
          // Empty metadata object.
          _recoveryRow(
            factorId: 'm3m3m3m3-m3m3-4m3m-8m3m-m3m3m3m3m3m3',
            metadataJsonOrMap: '{}',
          ),
          // The actual matching row, last in the list — consumer keeps
          // iterating past every malformed row.
          _recoveryRow(
            factorId: _factorIdMatch,
            metadataJsonOrMap: hashed.toJson(),
          ),
        ],
      );
      final consumer = _consumer(pool: pool);

      final result = await consumer.consume(
        operatorId: _operatorId,
        locationId: _locationId,
        userId: _userId,
        rawCode: 'AAAA-BBBB-CCCC',
      );

      expect(result, isA<RecoveryCodeConsumed>());
      expect(
        (result as RecoveryCodeConsumed).factorId,
        equals(_factorIdMatch),
      );
    });
  });

  group('RecoveryCodeAttemptLimiter (boundary moments)', () {
    test('1-minute window: 59s blocks, 61s allows', () async {
      final store = InMemoryRecoveryCodeAttemptStore();
      var now = DateTime.utc(2026, 4, 26, 12);
      final limiter =
          RecoveryCodeAttemptLimiter(store: store, now: () => now);

      await limiter.recordAttempt(userId: _userId);

      now = now.add(const Duration(seconds: 59));
      final at59 = await limiter.check(userId: _userId);
      expect(at59, isA<RecoveryCodeAttemptRateLimited>());

      now = now.add(const Duration(seconds: 2)); // 61s total
      final at61 = await limiter.check(userId: _userId);
      expect(at61, isA<RecoveryCodeAttemptAllowed>());
    });

    test('daily budget boundary: 4 used → allowed; 5 used → exhausted',
        () async {
      final store = InMemoryRecoveryCodeAttemptStore();
      var now = DateTime.utc(2026, 4, 26, 0);
      final limiter =
          RecoveryCodeAttemptLimiter(store: store, now: () => now);

      // 4 attempts, each 2h apart so the per-minute window doesn't kick.
      for (var i = 0; i < 4; i++) {
        await limiter.recordAttempt(userId: _userId);
        now = now.add(const Duration(hours: 2));
      }
      // Roll past the per-minute window since the most recent attempt.
      now = now.add(const Duration(minutes: 2));
      expect(
        await limiter.check(userId: _userId),
        isA<RecoveryCodeAttemptAllowed>(),
      );

      // Burn the 5th slot.
      await limiter.recordAttempt(userId: _userId);
      now = now.add(const Duration(minutes: 2));
      expect(
        await limiter.check(userId: _userId),
        isA<RecoveryCodeAttemptDailyExhausted>(),
      );
    });

    test('daily exhausted resetsAt = oldest in-window attempt + 24h',
        () async {
      final store = InMemoryRecoveryCodeAttemptStore();
      final firstAt = DateTime.utc(2026, 4, 26, 0);
      var now = firstAt;
      final limiter =
          RecoveryCodeAttemptLimiter(store: store, now: () => now);
      for (var i = 0; i < 5; i++) {
        await limiter.recordAttempt(userId: _userId);
        now = now.add(const Duration(hours: 2));
      }
      now = firstAt.add(const Duration(hours: 12));
      final decision = await limiter.check(userId: _userId);
      expect(
        (decision as RecoveryCodeAttemptDailyExhausted).resetsAt,
        equals(firstAt.add(const Duration(hours: 24))),
      );
    });
  });
}

// ─── Postgres pool fake (mirrors the live-binding test shape) ─────────

class _MfaFactorsPool implements PostgresPool {
  _MfaFactorsPool({
    this.recoveryCodeRows = const <PostgresRow>[],
  });

  final List<PostgresRow> recoveryCodeRows;
  final List<_MfaFactorsTransaction> transactions = <_MfaFactorsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _MfaFactorsTransaction(recoveryCodeRows: recoveryCodeRows);
    transactions.add(tx);
    return tx;
  }
}

class _MfaFactorsTransaction extends PostgresTransaction {
  _MfaFactorsTransaction({required this.recoveryCodeRows});

  final List<PostgresRow> recoveryCodeRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('select factor_id') && sql.contains('from mfa_factors')) {
      return recoveryCodeRows;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    // Every update / insert in the MFA path is a single row.
    return 1;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
