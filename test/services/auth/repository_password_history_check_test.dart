// CODE_HEALTH.L12 — RepositoryPasswordHistoryCheck salt + pepper tests.
//
// Covers:
//   * Legacy verification path: a row stamped `algo='sha256-legacy'`
//     with NULL salt verifies via the existing
//     [Sha256PasswordHistoryHasher] shape (per-row mutation of the
//     stored digest must NOT verify).
//   * New-format verification path: write a candidate via
//     [recordAndPrune], read it back, verify it matches the candidate
//     and that flipping any byte of the stored digest fails.
//   * Pepper missing: constructing the check in non-demo mode WITHOUT
//     `--dart-define=PASSWORD_HISTORY_PEPPER=...` and WITHOUT a
//     [PasswordHistoryPepperConfig] override throws the typed startup
//     error.
//   * Constant-time best-effort: 1000 iterations of mismatch at byte
//     0 vs byte 31 produce mean timings within a coarse threshold so
//     a partial-prefix oracle is not trivially exploitable.
//   * PepperResolver injection: inject a fake [PepperResolver] so the
//     class does not require a dart-define at test time.
//   * Pepper rotation: a row written with pepper_id=A verifies
//     correctly when pepper_id=B is now active (legacy rows survive
//     rotation).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/pepper_resolver.dart';
import 'package:forge_and_flow/services/auth/repository_password_history_check.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';
const String _validEntryId = '44444444-4444-4444-4444-444444444444';

void main() {
  group('RepositoryPasswordHistoryCheck (CODE_HEALTH.L12)', () {
    group('legacy verification', () {
      test(
        'sha256-legacy row with NULL salt + NULL pepper_id verifies via '
        'the unsalted hasher',
        () async {
          const candidate = 'reused-passphrase';
          const hasher = Sha256PasswordHistoryHasher();
          final legacyHashHex = hasher.hash(
            operatorId: _validOpId,
            userId: _validUserId,
            candidate: candidate,
          );

          final pool = _FakePool(
            historyRows: <PostgresRow>[
              <String, Object?>{
                'entry_id': 'e-legacy',
                'password_hash': legacyHashHex,
                'password_hash_salt': null,
                'password_hash_pepper_id': null,
                'password_hash_algo': 'sha256-legacy',
                'set_at': DateTime.utc(2026, 4, 26, 12),
              },
            ],
          );
          final check = _newCheck(pool);

          expect(
            await check.isReusedPassword(
              userId: _validUserId,
              candidate: candidate,
            ),
            isTrue,
          );
        },
      );

      test(
        'sha256-legacy row does NOT verify a different candidate '
        '(per-row digest mutation cannot leak through the legacy path)',
        () async {
          const hasher = Sha256PasswordHistoryHasher();
          final legacyHashHex = hasher.hash(
            operatorId: _validOpId,
            userId: _validUserId,
            candidate: 'stored-pw',
          );
          final pool = _FakePool(
            historyRows: <PostgresRow>[
              <String, Object?>{
                'entry_id': 'e-legacy',
                'password_hash': legacyHashHex,
                'password_hash_salt': null,
                'password_hash_pepper_id': null,
                'password_hash_algo': 'sha256-legacy',
                'set_at': DateTime.utc(2026, 4, 26, 12),
              },
            ],
          );
          final check = _newCheck(pool);

          expect(
            await check.isReusedPassword(
              userId: _validUserId,
              candidate: 'fresh-pw',
            ),
            isFalse,
          );
        },
      );
    });

    group('new-format verification', () {
      test(
        'recordAndPrune writes a salted row that verifies on read-back',
        () async {
          final pool = _FakePool(returningEntryId: _validEntryId);
          final check = _newCheck(pool);

          await check.recordAndPrune(
            userId: _validUserId,
            candidate: 'fresh-pw',
          );

          // Capture the salt + hash that were written; the verifier
          // must reproduce them when given the same candidate.
          final insertParams = _insertParams(pool);
          final salt = insertParams['salt'] as Uint8List;
          final hashHex = insertParams['hash'] as String;
          expect(insertParams['algo'], equals('sha256-salted'));
          expect(salt, hasLength(16));
          expect(insertParams['pepper_id'], isA<String>());
          expect((insertParams['pepper_id'] as String).isNotEmpty, isTrue);

          // Round-trip: a fresh check reading the row back must
          // verify the same candidate.
          final readPool = _FakePool(
            historyRows: <PostgresRow>[
              <String, Object?>{
                'entry_id': 'e-salted',
                'password_hash': hashHex,
                'password_hash_salt': salt,
                'password_hash_pepper_id': insertParams['pepper_id'],
                'password_hash_algo': 'sha256-salted',
                'set_at': DateTime.utc(2026, 5, 7, 12),
              },
            ],
          );
          final readCheck = _newCheck(readPool);

          expect(
            await readCheck.isReusedPassword(
              userId: _validUserId,
              candidate: 'fresh-pw',
            ),
            isTrue,
          );
        },
      );

      test(
        'modifying any byte of the stored digest fails verification',
        () async {
          final pool = _FakePool(returningEntryId: _validEntryId);
          final check = _newCheck(pool);

          await check.recordAndPrune(
            userId: _validUserId,
            candidate: 'fresh-pw',
          );

          final insertParams = _insertParams(pool);
          final salt = insertParams['salt'] as Uint8List;
          final hashHex = insertParams['hash'] as String;

          // Flip the last hex char.
          final tamperedHex =
              hashHex.substring(0, hashHex.length - 1) +
              (hashHex[hashHex.length - 1] == '0' ? '1' : '0');
          expect(tamperedHex, isNot(equals(hashHex)));

          final readPool = _FakePool(
            historyRows: <PostgresRow>[
              <String, Object?>{
                'entry_id': 'e-tampered',
                'password_hash': tamperedHex,
                'password_hash_salt': salt,
                'password_hash_pepper_id': insertParams['pepper_id'],
                'password_hash_algo': 'sha256-salted',
                'set_at': DateTime.utc(2026, 5, 7, 12),
              },
            ],
          );
          final readCheck = _newCheck(readPool);

          expect(
            await readCheck.isReusedPassword(
              userId: _validUserId,
              candidate: 'fresh-pw',
            ),
            isFalse,
          );
        },
      );

      test(
        'recordAndPrune chains insert (with salt + pepper_id + algo) '
        'and prune in order',
        () async {
          final pool = _FakePool(returningEntryId: _validEntryId);
          final check = _newCheck(pool);

          await check.recordAndPrune(
            userId: _validUserId,
            candidate: 'fresh-pw',
          );

          // Two transactions: insert + prune.
          expect(pool.transactions, hasLength(2));
          expect(
            pool.transactions[0].executedSql.any(
              (sql) => sql.contains('insert into password_history'),
            ),
            isTrue,
          );
          expect(
            pool.transactions[0].executedSql.any(
              (sql) =>
                  sql.contains('password_hash_salt') &&
                  sql.contains('password_hash_pepper_id') &&
                  sql.contains('password_hash_algo'),
            ),
            isTrue,
          );
          expect(
            pool.transactions[1].executedSql.any(
              (sql) => sql.contains('delete from password_history'),
            ),
            isTrue,
          );
        },
      );

      test('different rows draw different per-row salts', () async {
        final salts = <List<int>>{};
        for (var i = 0; i < 8; i++) {
          final pool = _FakePool(returningEntryId: _validEntryId);
          final check = _newCheck(pool);
          await check.recordAndPrune(
            userId: _validUserId,
            candidate: 'pw-$i',
          );
          final salt = _insertParams(pool)['salt'] as Uint8List;
          salts.add(List<int>.from(salt));
        }
        // 8 random 16-byte salts colliding is implausibly rare; if
        // any collide the salt source is not actually random.
        expect(salts.length, equals(8));
      });
    });

    group('pepper missing', () {
      test(
        'constructing without env var or override in non-demo mode '
        'throws PasswordHistoryPepperMissingError',
        () {
          // Tests run with `--dart-define=kDemoMode=false` by default
          // and with no PASSWORD_HISTORY_PEPPER define, so the env
          // factory path lands on the typed-startup-error branch.
          expect(
            () => RepositoryPasswordHistoryCheck(
              repository: PasswordHistoryRepository(
                TenantTransactionWrapper(_FakePool()),
              ),
              hasher: const Sha256PasswordHistoryHasher(),
              operatorId: _validOpId,
              locationId: _validLocId,
              // Intentionally no `pepper:` or `pepperResolver:` override.
            ),
            throwsA(isA<PasswordHistoryPepperMissingError>()),
          );
        },
      );

      test(
        'literal pepper override bypasses the env-var check '
        'so tests do not need a dart-define',
        () {
          expect(
            () => RepositoryPasswordHistoryCheck(
              repository: PasswordHistoryRepository(
                TenantTransactionWrapper(_FakePool()),
              ),
              hasher: const Sha256PasswordHistoryHasher(),
              operatorId: _validOpId,
              locationId: _validLocId,
              pepper: PasswordHistoryPepperConfig.literal('pepper-test'),
            ),
            returnsNormally,
          );
        },
      );

      test(
        'PepperResolver injection bypasses the env-var check',
        () {
          expect(
            () => RepositoryPasswordHistoryCheck(
              repository: PasswordHistoryRepository(
                TenantTransactionWrapper(_FakePool()),
              ),
              hasher: const Sha256PasswordHistoryHasher(),
              operatorId: _validOpId,
              locationId: _validLocId,
              pepperResolver: const EnvPepperResolver(
                pepper: 'injected-pepper',
                demoMode: false,
              ),
            ),
            returnsNormally,
          );
        },
      );
    });

    group('pepper rotation (fix(M2.pepper-runtime))', () {
      test(
        'row written with pepper_id=A verifies correctly when pepper_id=B '
        'is now active (legacy rows survive rotation)',
        () async {
          // pepperA is the old pepper; pepperB is the new active pepper.
          const pepperA = 'pepper-rotation-A';
          const pepperB = 'pepper-rotation-B';

          // Write with pepperA as the active pepper.
          final writeResolver = _FixedPepperResolver(activePepper: pepperA);
          final writePool = _FakePool(returningEntryId: _validEntryId);
          final writeCheck = _newCheckWithResolver(writePool, writeResolver);

          await writeCheck.recordAndPrune(
            userId: _validUserId,
            candidate: 'rotation-pw',
          );

          final insertParams = _insertParams(writePool);
          final salt = insertParams['salt'] as Uint8List;
          final hashHex = insertParams['hash'] as String;
          final writtenPepperId = insertParams['pepper_id'] as String;

          // Confirm the row was written with pepperA's derived id.
          expect(writtenPepperId, isNot(equals('demo')));
          expect(writtenPepperId, startsWith('sha256:'));

          // Now rotate: pepperB is active but pepperA is still known
          // (so the old row can be verified).
          final rotatedResolver = _RotatedPepperResolver(
            activePepper: pepperB,
            retiredPeppers: <String, String>{writtenPepperId: pepperA},
          );

          final readPool = _FakePool(
            historyRows: <PostgresRow>[
              <String, Object?>{
                'entry_id': 'e-rotated',
                'password_hash': hashHex,
                'password_hash_salt': salt,
                'password_hash_pepper_id': writtenPepperId,
                'password_hash_algo': 'sha256-salted',
                'set_at': DateTime.utc(2026, 5, 7, 12),
              },
            ],
          );
          final readCheck = _newCheckWithResolver(readPool, rotatedResolver);

          // Must verify correctly using the old pepperA for the old row.
          expect(
            await readCheck.isReusedPassword(
              userId: _validUserId,
              candidate: 'rotation-pw',
            ),
            isTrue,
            reason: 'old row with pepperA must verify after pepperB rotation',
          );

          // New candidates that do NOT match must still return false.
          expect(
            await readCheck.isReusedPassword(
              userId: _validUserId,
              candidate: 'different-pw',
            ),
            isFalse,
          );
        },
      );

      test(
        'row written with pepper_id=A returns false (un-verifiable) when '
        'pepperA is no longer available after rotation',
        () async {
          const pepperA = 'pepper-gone-A';
          const pepperB = 'pepper-new-B';

          final writeResolver = _FixedPepperResolver(activePepper: pepperA);
          final writePool = _FakePool(returningEntryId: _validEntryId);
          final writeCheck = _newCheckWithResolver(writePool, writeResolver);

          await writeCheck.recordAndPrune(
            userId: _validUserId,
            candidate: 'gone-pw',
          );

          final insertParams = _insertParams(writePool);
          final salt = insertParams['salt'] as Uint8List;
          final hashHex = insertParams['hash'] as String;
          final writtenPepperId = insertParams['pepper_id'] as String;

          // Rotate: pepperA is completely removed from the store.
          final rotatedResolver = _RotatedPepperResolver(
            activePepper: pepperB,
            retiredPeppers: const <String, String>{}, // pepperA not available
          );

          final readPool = _FakePool(
            historyRows: <PostgresRow>[
              <String, Object?>{
                'entry_id': 'e-un-verifiable',
                'password_hash': hashHex,
                'password_hash_salt': salt,
                'password_hash_pepper_id': writtenPepperId,
                'password_hash_algo': 'sha256-salted',
                'set_at': DateTime.utc(2026, 5, 7, 12),
              },
            ],
          );
          final readCheck = _newCheckWithResolver(readPool, rotatedResolver);

          // The row is un-verifiable (returns false, not crash).
          expect(
            await readCheck.isReusedPassword(
              userId: _validUserId,
              candidate: 'gone-pw',
            ),
            isFalse,
            reason:
                'row with unknown pepper_id should not crash — '
                'returns false (un-verifiable)',
          );
        },
      );
    });

    group('constant-time digest comparison', () {
      test(
        'mean comparison time at byte-0 mismatch ≈ mean at byte-31 '
        'mismatch (1000 iterations, coarse threshold)',
        () async {
          // Stage two stored digests that differ from the candidate
          // hash at the FIRST hex character vs the LAST hex character.
          // A naive prefix-sensitive comparator would return faster
          // when the mismatch is at byte 0; the constant-time
          // comparator should not.
          //
          // Generate the candidate hash by performing a write, then
          // synthesize two stored digests by mutating the first vs
          // last hex char. We measure isReusedPassword over 1000
          // iterations for each scenario and assert the mean timings
          // are within a coarse 5x threshold of each other.
          final writePool = _FakePool(returningEntryId: _validEntryId);
          final writer = _newCheck(writePool);
          await writer.recordAndPrune(
            userId: _validUserId,
            candidate: 'timing-pw',
          );
          final params = _insertParams(writePool);
          final salt = params['salt'] as Uint8List;
          final hashHex = params['hash'] as String;
          final pepperId = params['pepper_id'] as String;

          String mutateChar(String s, int idx) {
            final ch = s[idx];
            final next = ch == '0' ? '1' : '0';
            return s.substring(0, idx) + next + s.substring(idx + 1);
          }

          final mismatchByte0 = mutateChar(hashHex, 0);
          final mismatchByte31 = mutateChar(hashHex, hashHex.length - 1);

          Future<int> measure(String storedDigest) async {
            final stopwatch = Stopwatch()..start();
            for (var i = 0; i < 1000; i++) {
              final pool = _FakePool(
                historyRows: <PostgresRow>[
                  <String, Object?>{
                    'entry_id': 'e-timing',
                    'password_hash': storedDigest,
                    'password_hash_salt': salt,
                    'password_hash_pepper_id': pepperId,
                    'password_hash_algo': 'sha256-salted',
                    'set_at': DateTime.utc(2026, 5, 7, 12),
                  },
                ],
              );
              final reader = _newCheck(pool);
              await reader.isReusedPassword(
                userId: _validUserId,
                candidate: 'timing-pw',
              );
            }
            stopwatch.stop();
            return stopwatch.elapsedMicroseconds;
          }

          final t0 = await measure(mismatchByte0);
          final t31 = await measure(mismatchByte31);
          final ratio = (t0 > t31 ? t0 / t31 : t31 / t0);

          // Coarse threshold: noisy CI hosts can swing by ~3x even
          // for a constant-time comparator. A naive `==`-based
          // comparator would diverge by orders of magnitude on a
          // 1000-iteration sample. 5x is a best-effort sanity check.
          expect(
            ratio,
            lessThan(5.0),
            reason:
                'byte-0 vs byte-31 mismatch timing ratio $ratio '
                'suggests a non-constant-time digest comparator',
          );
        },
        // Marked slow only by virtue of 1000 iterations; should still
        // complete well under a second on CI.
      );
    });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────

RepositoryPasswordHistoryCheck _newCheck(_FakePool pool) {
  return RepositoryPasswordHistoryCheck(
    repository: PasswordHistoryRepository(TenantTransactionWrapper(pool)),
    hasher: const Sha256PasswordHistoryHasher(),
    operatorId: _validOpId,
    locationId: _validLocId,
    pepper: PasswordHistoryPepperConfig.literal('pepper-for-tests'),
  );
}

RepositoryPasswordHistoryCheck _newCheckWithResolver(
  _FakePool pool,
  PepperResolver resolver,
) {
  return RepositoryPasswordHistoryCheck(
    repository: PasswordHistoryRepository(TenantTransactionWrapper(pool)),
    hasher: const Sha256PasswordHistoryHasher(),
    operatorId: _validOpId,
    locationId: _validLocId,
    pepperResolver: resolver,
  );
}

Map<String, Object?> _insertParams(_FakePool pool) {
  for (final tx in pool.transactions) {
    for (var i = 0; i < tx.executedSql.length; i++) {
      if (tx.executedSql[i].contains('insert into password_history')) {
        return tx.parameters[i];
      }
    }
  }
  fail('expected an insert into password_history but none was issued');
}

// ─── Fake PepperResolvers ─────────────────────────────────────────────

/// A resolver that always returns one known pepper as active.
class _FixedPepperResolver implements PepperResolver {
  const _FixedPepperResolver({required this.activePepper});
  final String activePepper;

  @override
  Future<String> resolveActive() async => activePepper;

  @override
  Future<String?> resolveById(String pepperId) async => activePepper;
}

/// A resolver that returns a new active pepper and resolves retired
/// peppers by id. Returns `null` for unknown ids so the row is treated
/// as un-verifiable.
class _RotatedPepperResolver implements PepperResolver {
  const _RotatedPepperResolver({
    required this.activePepper,
    required this.retiredPeppers,
  });

  final String activePepper;
  final Map<String, String> retiredPeppers;

  @override
  Future<String> resolveActive() async => activePepper;

  @override
  Future<String?> resolveById(String pepperId) async =>
      retiredPeppers[pepperId];
}

// ─── Fake Postgres pool / transaction ────────────────────────────────

class _FakePool implements PostgresPool {
  _FakePool({
    this.returningEntryId,
    this.historyRows = const <PostgresRow>[],
  });

  final String? returningEntryId;
  final List<PostgresRow> historyRows;
  final List<_FakeTransaction> transactions = <_FakeTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeTransaction(
      returningEntryId: returningEntryId,
      historyRows: historyRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _FakeTransaction extends PostgresTransaction {
  _FakeTransaction({
    required this.returningEntryId,
    required this.historyRows,
  });

  final String? returningEntryId;
  final List<PostgresRow> historyRows;
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
    if (sql.contains('insert into password_history') &&
        sql.contains('returning entry_id')) {
      final id = returningEntryId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'entry_id': id},
      ];
    }
    if (sql.contains('select entry_id') &&
        sql.contains('from password_history')) {
      return historyRows;
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
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
  }
}
