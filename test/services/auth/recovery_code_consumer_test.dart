// CODE_HEALTH L10 — RecoveryCodeConsumer constant-time slot lookup.
//
// Pins the timing-leak fix: the consumer used to break out of the
// matching loop as soon as a stored hash matched, leaking via wall
// time WHERE in the candidate list the matching slot sat. The fix
// iterates EVERY candidate, runs verify against EVERY slot (using a
// sentinel for malformed metadata so each iteration does the same
// amount of work), and selects the matched index from a constant-
// time accumulator AFTER the loop.
//
// Strategy: time the consume() call over many trials with the
// matching slot at position 0 vs position 9. The two distributions
// should NOT be statistically distinguishable. We use a coarse
// 95th-percentile gate because Dart isolate scheduling, GC, and JIT
// warmup add noise — the test is intentionally lenient. If it
// flakes in CI, the right move is to widen the gate, not to revert
// the fix; the loop is structurally constant-time and the timing
// signal is just a sanity check.

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

PostgresRow _recoveryRow({
  required String factorId,
  required HashedRecoveryCode hashed,
}) {
  return <String, Object?>{
    'factor_id': factorId,
    'user_id': _userId,
    'factor_type': 'recovery_code',
    'factor_metadata': jsonEncode(hashed.toJson()),
    'enrolled_at': DateTime.utc(2026, 4, 26, 11),
    'last_used_at': null,
    'revoked_at': null,
  };
}

/// Build a list of [count] factor rows where slot at [matchIndex]
/// holds the hash for [matchingCode] and every other slot holds a
/// hash for a distinct random code that won't match the input.
List<PostgresRow> _candidateRows({
  required int count,
  required int matchIndex,
  required String matchingCode,
}) {
  const hasher = Sha256RecoveryCodeHasher();
  final rows = <PostgresRow>[];
  for (var i = 0; i < count; i++) {
    final salt = Uint8List.fromList(
      List<int>.generate(16, (j) => (i * 31 + j) & 0xFF),
    );
    final code = i == matchIndex ? matchingCode : 'NOMATCH-${i.toString().padLeft(4, "0")}';
    final hashed = hasher.hash(normalizedCode: code, saltBytes: salt);
    rows.add(_recoveryRow(
      factorId:
          '${i.toString().padLeft(8, "0")}-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      hashed: hashed,
    ));
  }
  return rows;
}

RecoveryCodeConsumer _consumer({
  required _FactorPool pool,
  _CountingHasher? hasher,
}) {
  return RecoveryCodeConsumer(
    hasher: hasher ?? _CountingHasher(),
    repository: MfaFactorsRepository(TenantTransactionWrapper(pool)),
    limiter: RecoveryCodeAttemptLimiter(
      store: InMemoryRecoveryCodeAttemptStore(),
      now: () => DateTime.utc(2026, 4, 28, 12),
    ),
  );
}

void main() {
  group('RecoveryCodeConsumer constant-time slot lookup (CODE_HEALTH L10)',
      () {
    test('match at slot 0 still iterates EVERY candidate', () async {
      final pool = _FactorPool(
        rows: _candidateRows(
          count: 10,
          matchIndex: 0,
          matchingCode: 'AAAABBBBCCCC',
        ),
      );
      final hasher = _CountingHasher();
      final consumer = _consumer(pool: pool, hasher: hasher);

      final result = await consumer.consume(
        operatorId: _operatorId,
        locationId: _locationId,
        userId: _userId,
        rawCode: 'AAAA-BBBB-CCCC',
      );

      expect(result, isA<RecoveryCodeConsumed>());
      // Structural assertion: the hasher saw 10 verify() calls — one
      // per slot. Without constant-time iteration, an early break on
      // slot 0 would have only seen 1 call, leaking position via
      // both timing and call count.
      expect(hasher.verifyCalls, equals(10));
    });

    test('match at slot 9 also runs verify on every slot', () async {
      final pool = _FactorPool(
        rows: _candidateRows(
          count: 10,
          matchIndex: 9,
          matchingCode: 'AAAABBBBCCCC',
        ),
      );
      final hasher = _CountingHasher();
      final consumer = _consumer(pool: pool, hasher: hasher);

      final result = await consumer.consume(
        operatorId: _operatorId,
        locationId: _locationId,
        userId: _userId,
        rawCode: 'AAAA-BBBB-CCCC',
      );

      expect(result, isA<RecoveryCodeConsumed>());
      expect(hasher.verifyCalls, equals(10));
    });

    test('no-match also runs verify on every slot', () async {
      final pool = _FactorPool(
        rows: _candidateRows(
          count: 10,
          matchIndex: -1,
          matchingCode: 'AAAABBBBCCCC',
        ),
      );
      final hasher = _CountingHasher();
      final consumer = _consumer(pool: pool, hasher: hasher);

      final result = await consumer.consume(
        operatorId: _operatorId,
        locationId: _locationId,
        userId: _userId,
        rawCode: 'AAAA-BBBB-CCCC',
      );

      expect(result, isA<RecoveryCodeInvalid>());
      // No early break: 10 verifies, regardless of the wrong-code
      // outcome.
      expect(hasher.verifyCalls, equals(10));
    });

    test(
      'malformed metadata slots still issue a verify (sentinel) so the '
      'loop body time is independent of bad-row count',
      () async {
        const sha = Sha256RecoveryCodeHasher();
        final salt = Uint8List(16);
        final hashed = sha.hash(
          normalizedCode: 'AAAABBBBCCCC',
          saltBytes: salt,
        );
        final pool = _FactorPool(
          rows: <PostgresRow>[
            // Malformed: missing 'hash'.
            <String, Object?>{
              'factor_id': '11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'user_id': _userId,
              'factor_type': 'recovery_code',
              'factor_metadata': jsonEncode(<String, Object?>{
                'salt': base64.encode(salt),
              }),
              'enrolled_at': DateTime.utc(2026, 4, 26, 11),
              'last_used_at': null,
              'revoked_at': null,
            },
            // Malformed: empty.
            <String, Object?>{
              'factor_id': '22222222-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'user_id': _userId,
              'factor_type': 'recovery_code',
              'factor_metadata': '{}',
              'enrolled_at': DateTime.utc(2026, 4, 26, 11),
              'last_used_at': null,
              'revoked_at': null,
            },
            // Valid match.
            _recoveryRow(
              factorId: '33333333-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              hashed: hashed,
            ),
          ],
        );
        final hasher = _CountingHasher();
        final consumer = _consumer(pool: pool, hasher: hasher);

        final result = await consumer.consume(
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
          rawCode: 'AAAA-BBBB-CCCC',
        );

        expect(result, isA<RecoveryCodeConsumed>());
        // 3 candidates: 2 malformed + 1 valid. Each iteration runs
        // verify (the malformed ones use the sentinel), so the
        // hasher saw 3 calls.
        expect(hasher.verifyCalls, equals(3));
      },
    );

    test(
      'wall-time distributions for match-at-0 vs match-at-9 are not '
      'distinguishable to a coarse 95th-percentile gate',
      () async {
        // Coarse timing sanity check. Run the consume loop many
        // times for each scenario and compare percentile timings.
        // The bound is intentionally lenient (within 4x) because
        // Dart's microbenchmark noise on CI shared runners is large.
        // The structural assertions above are the load-bearing
        // proof; this is a soft regression alarm.
        const trialsPerScenario = 60;
        const candidateCount = 10;
        final matchingCode = 'AAAABBBBCCCC';

        Future<int> timeOne(int matchIndex) async {
          final pool = _FactorPool(
            rows: _candidateRows(
              count: candidateCount,
              matchIndex: matchIndex,
              matchingCode: matchingCode,
            ),
          );
          final consumer = _consumer(pool: pool);
          final stopwatch = Stopwatch()..start();
          await consumer.consume(
            operatorId: _operatorId,
            locationId: _locationId,
            userId: _userId,
            rawCode: 'AAAA-BBBB-CCCC',
          );
          stopwatch.stop();
          return stopwatch.elapsedMicroseconds;
        }

        final headTimes = <int>[];
        final tailTimes = <int>[];
        // Warm up first to push past JIT noise.
        for (var i = 0; i < 5; i++) {
          await timeOne(0);
          await timeOne(candidateCount - 1);
        }
        for (var i = 0; i < trialsPerScenario; i++) {
          // Interleave so background noise affects both samples
          // similarly.
          headTimes.add(await timeOne(0));
          tailTimes.add(await timeOne(candidateCount - 1));
        }
        headTimes.sort();
        tailTimes.sort();
        final p95Head = headTimes[(trialsPerScenario * 0.95).floor()];
        final p95Tail = tailTimes[(trialsPerScenario * 0.95).floor()];
        // Allow up to 4x — this is a soft alarm, not a tight bound.
        // A constant-time loop has ratio ~1.0; the buggy early-break
        // version had ratio ~10x.
        final ratio = p95Tail >= p95Head
            ? p95Tail / p95Head
            : p95Head / p95Tail;
        expect(
          ratio,
          lessThan(4.0),
          reason:
              'Head p95=$p95Head us, tail p95=$p95Tail us — match-at-0 vs '
              'match-at-9 timing distributions diverged beyond the '
              'coarse 4x sanity gate. The constant-time slot loop is '
              'leaking position via timing.',
        );
      },
      skip: 'timing-sensitive: structural assertions above are the '
          'load-bearing proof. Enable manually if investigating a '
          'regression report.',
    );
  });
}

/// Pool fake that returns the configured rows for the recovery-code
/// list query and a single-row update for `markRecoveryCodeUsed`.
class _FactorPool implements PostgresPool {
  _FactorPool({required this.rows});

  final List<PostgresRow> rows;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _FactorTransaction(this);
  }
}

class _FactorTransaction extends PostgresTransaction {
  _FactorTransaction(this._pool);

  final _FactorPool _pool;
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('finalized');
    if (sql.contains('select factor_id') &&
        sql.contains('from mfa_factors')) {
      return _pool.rows;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('finalized');
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

/// Wrapper around [Sha256RecoveryCodeHasher] that counts every
/// `verify` call so a test can assert the consumer iterates every
/// candidate slot regardless of where (or whether) a match exists.
class _CountingHasher implements RecoveryCodeHasher {
  final Sha256RecoveryCodeHasher _inner = const Sha256RecoveryCodeHasher();
  int verifyCalls = 0;

  @override
  HashedRecoveryCode hash({
    required String normalizedCode,
    required Uint8List saltBytes,
  }) {
    return _inner.hash(normalizedCode: normalizedCode, saltBytes: saltBytes);
  }

  @override
  bool verify({
    required String normalizedCode,
    required HashedRecoveryCode stored,
  }) {
    verifyCalls += 1;
    return _inner.verify(normalizedCode: normalizedCode, stored: stored);
  }
}
