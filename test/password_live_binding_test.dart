// Phase 9 live-closeout B14/B15/B16 tests.
//
// Covers:
//   * PasswordHistoryRepository SQL contract (insert + RETURNING +
//     latestHashes ordered by set_at desc + prune-by-not-in +
//     GDPR clearForUser via withSystem).
//   * Sha256PasswordHistoryHasher determinism + per-tenant +
//     per-user isolation.
//   * RepositoryPasswordHistoryCheck.isReusedPassword via injected
//     hasher + repository — match + no-match + constant-time
//     compare correctness.
//   * RepositoryPasswordHistoryCheck.recordAndPrune chains
//     recordHash + prune in order.
//   * RateLimitedHibpRangeFetcher allows requests up to the cap +
//     throws HibpRateLimitExceeded past it + sliding window
//     re-admits past the window boundary.
//   * ScaffoldFailingRecaptchaV3Verifier fails closed.
//   * RecaptchaV3Policy decides accept / challenge / reject from
//     score + action.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/hibp_pwned_password_screener.dart';
import 'package:forge_and_flow/services/auth/rate_limited_hibp_range_fetcher.dart';
import 'package:forge_and_flow/services/auth/recaptcha_v3_verifier.dart';
import 'package:forge_and_flow/services/auth/repository_password_history_check.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';
const String _validEntryId = '44444444-4444-4444-4444-444444444444';

void main() {
  group('PasswordHistoryRepository (B15 — fake Postgres)', () {
    test('recordHash runs INSERT … RETURNING entry_id with bound params',
        () async {
      final pool = _PasswordHistoryPool(returningEntryId: _validEntryId);
      final repo = PasswordHistoryRepository(TenantTransactionWrapper(pool));

      final id = await repo.recordHash(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        passwordHashHex: 'deadbeef' * 8,
      );

      expect(id, equals(_validEntryId));
      final tx = pool.transactions.single;
      final sql = tx.executedSql.last;
      expect(sql, contains('insert into password_history'));
      expect(sql, contains('returning entry_id'));
      expect(tx.parameters.last['user_id'], equals(_validUserId));
      expect(tx.parameters.last['hash'], equals('deadbeef' * 8));
    });

    test('latestHashes orders by set_at desc and respects the limit',
        () async {
      final pool = _PasswordHistoryPool(
        returningEntryId: _validEntryId,
        historyRows: <PostgresRow>[
          <String, Object?>{
            'entry_id': 'e1',
            'user_id': _validUserId,
            'password_hash': 'newest',
            'set_at': DateTime.utc(2026, 4, 26, 12),
          },
          <String, Object?>{
            'entry_id': 'e2',
            'user_id': _validUserId,
            'password_hash': 'older',
            'set_at': DateTime.utc(2026, 4, 25, 12),
          },
        ],
      );
      final repo = PasswordHistoryRepository(TenantTransactionWrapper(pool));

      final entries = await repo.latestHashes(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        n: 5,
      );

      expect(entries, hasLength(2));
      expect(entries.first.passwordHash, equals('newest'));
      final tx = pool.transactions.single;
      final sql = tx.executedSql.last;
      expect(sql, contains('order by set_at desc'));
      expect(sql, contains('limit @limit'));
      expect(tx.parameters.last['limit'], equals(5));
    });

    test('prune deletes rows beyond the latest N', () async {
      final pool = _PasswordHistoryPool(returningEntryId: _validEntryId);
      final repo = PasswordHistoryRepository(TenantTransactionWrapper(pool));

      await repo.prune(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        n: 5,
      );

      final sql = pool.transactions.single.executedSql.last;
      expect(sql, contains('delete from password_history'));
      // Acceptance: prune uses NOT IN (latest N entry_ids) so it
      // never deletes the rows we want to keep.
      expect(sql, contains('entry_id not in'));
      expect(sql, contains('order by set_at desc limit'));
    });

    test('clearForUser uses withSystem with the provided audit reason',
        () async {
      final pool = _PasswordHistoryPool(returningEntryId: _validEntryId);
      final repo = PasswordHistoryRepository(TenantTransactionWrapper(pool));

      await repo.clearForUser(
        userId: _validUserId,
        adminReason: 'gdpr.erasure_executed',
      );

      final tx = pool.transactions.single;
      // Acceptance: bypass_rls_audit reason carries the system marker.
      expect(
        tx.parameters[0]['value'],
        equals('system:gdpr.erasure_executed'),
      );
      expect(tx.executedSql[1], equals('set local role forge_admin'));
      expect(tx.executedSql.last, contains('delete from password_history'));
    });

    test('recordHash throws when RETURNING produces no rows', () async {
      final pool = _PasswordHistoryPool(returningEntryId: null);
      final repo = PasswordHistoryRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.recordHash(
          operatorId: _validOpId,
          locationId: _validLocId,
          userId: _validUserId,
          passwordHashHex: 'deadbeef',
        ),
        throwsStateError,
      );
    });

    test('prune rejects n <= 0', () async {
      final pool = _PasswordHistoryPool(returningEntryId: _validEntryId);
      final repo = PasswordHistoryRepository(TenantTransactionWrapper(pool));
      expect(
        () => repo.prune(
          operatorId: _validOpId,
          locationId: _validLocId,
          userId: _validUserId,
          n: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('Sha256PasswordHistoryHasher (B15)', () {
    test('same op + user + candidate -> same digest', () {
      const hasher = Sha256PasswordHistoryHasher();
      final h1 = hasher.hash(
        operatorId: _validOpId,
        userId: _validUserId,
        candidate: 'long-passphrase-1',
      );
      final h2 = hasher.hash(
        operatorId: _validOpId,
        userId: _validUserId,
        candidate: 'long-passphrase-1',
      );
      expect(h1, equals(h2));
      // SHA-256 hex digest is 64 chars long.
      expect(h1.length, equals(64));
    });

    test('different operator id -> different digest (cross-tenant '
        'fingerprint isolation)', () {
      const hasher = Sha256PasswordHistoryHasher();
      final h1 = hasher.hash(
        operatorId: _validOpId,
        userId: _validUserId,
        candidate: 'shared-pw',
      );
      final h2 = hasher.hash(
        operatorId: '99999999-9999-9999-9999-999999999999',
        userId: _validUserId,
        candidate: 'shared-pw',
      );
      expect(h1, isNot(equals(h2)));
    });

    test('different user id -> different digest (per-user isolation)', () {
      const hasher = Sha256PasswordHistoryHasher();
      final h1 = hasher.hash(
        operatorId: _validOpId,
        userId: _validUserId,
        candidate: 'shared-pw',
      );
      final h2 = hasher.hash(
        operatorId: _validOpId,
        userId: '99999999-9999-9999-9999-999999999999',
        candidate: 'shared-pw',
      );
      expect(h1, isNot(equals(h2)));
    });
  });

  group('RepositoryPasswordHistoryCheck (B15)', () {
    test('isReusedPassword returns true when the candidate hash matches '
        'an entry', () async {
      const hasher = Sha256PasswordHistoryHasher();
      final candidateHash = hasher.hash(
        operatorId: _validOpId,
        userId: _validUserId,
        candidate: 'reused-passphrase',
      );
      final pool = _PasswordHistoryPool(
        returningEntryId: _validEntryId,
        historyRows: <PostgresRow>[
          <String, Object?>{
            'entry_id': 'e1',
            'user_id': _validUserId,
            'password_hash': candidateHash,
            'set_at': DateTime.utc(2026, 4, 26, 12),
          },
        ],
      );
      final repo = PasswordHistoryRepository(TenantTransactionWrapper(pool));
      final check = RepositoryPasswordHistoryCheck(
        repository: repo,
        hasher: hasher,
        operatorId: _validOpId,
        locationId: _validLocId,
      );
      final reused = await check.isReusedPassword(
        userId: _validUserId,
        candidate: 'reused-passphrase',
      );
      expect(reused, isTrue);
    });

    test('isReusedPassword returns false when no entry matches', () async {
      final pool = _PasswordHistoryPool(
        returningEntryId: _validEntryId,
        historyRows: <PostgresRow>[
          <String, Object?>{
            'entry_id': 'e1',
            'user_id': _validUserId,
            'password_hash': 'unrelated-hash-stored',
            'set_at': DateTime.utc(2026, 4, 26, 12),
          },
        ],
      );
      final check = RepositoryPasswordHistoryCheck(
        repository: PasswordHistoryRepository(TenantTransactionWrapper(pool)),
        hasher: const Sha256PasswordHistoryHasher(),
        operatorId: _validOpId,
        locationId: _validLocId,
      );
      final reused = await check.isReusedPassword(
        userId: _validUserId,
        candidate: 'fresh-passphrase',
      );
      expect(reused, isFalse);
    });

    test('recordAndPrune chains recordHash + prune in order', () async {
      final pool = _PasswordHistoryPool(returningEntryId: _validEntryId);
      final repo = PasswordHistoryRepository(TenantTransactionWrapper(pool));
      final check = RepositoryPasswordHistoryCheck(
        repository: repo,
        hasher: const Sha256PasswordHistoryHasher(),
        operatorId: _validOpId,
        locationId: _validLocId,
      );

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
        pool.transactions[1].executedSql.any(
          (sql) => sql.contains('delete from password_history'),
        ),
        isTrue,
      );
    });
  });

  group('RateLimitedHibpRangeFetcher (B14)', () {
    test('allows requests up to the cap then throws past it', () async {
      final inner = _CountingHibpRangeFetcher();
      final now = DateTime.utc(2026, 4, 26, 12);
      final fetcher = RateLimitedHibpRangeFetcher(
        inner: inner,
        maxRequestsPerWindow: 3,
        window: const Duration(minutes: 1),
        now: () => now,
      );

      await fetcher.fetchRange('AAAAA');
      await fetcher.fetchRange('BBBBB');
      await fetcher.fetchRange('CCCCC');
      expect(inner.calls, equals(3));

      await expectLater(
        fetcher.fetchRange('DDDDD'),
        throwsA(isA<HibpRateLimitExceeded>()),
      );
      // Acceptance: the 4th request never reached the inner fetcher.
      expect(inner.calls, equals(3));
    });

    test('sliding window re-admits past the window boundary', () async {
      final inner = _CountingHibpRangeFetcher();
      DateTime now = DateTime.utc(2026, 4, 26, 12);
      final fetcher = RateLimitedHibpRangeFetcher(
        inner: inner,
        maxRequestsPerWindow: 1,
        window: const Duration(seconds: 60),
        now: () => now,
      );

      await fetcher.fetchRange('AAAAA');
      now = now.add(const Duration(seconds: 30));
      await expectLater(
        fetcher.fetchRange('BBBBB'),
        throwsA(isA<HibpRateLimitExceeded>()),
      );
      now = now.add(const Duration(seconds: 31));
      await fetcher.fetchRange('CCCCC');
      expect(inner.calls, equals(2));
    });
  });

  group('RecaptchaV3 (B16 framework)', () {
    test('ScaffoldFailingRecaptchaV3Verifier fails closed', () async {
      const verifier = ScaffoldFailingRecaptchaV3Verifier();
      await expectLater(
        verifier.verify(token: 't', expectedAction: 'login'),
        throwsStateError,
      );
    });

    test('RecaptchaV3Policy: success + score >= acceptThreshold + matching '
        'action -> accept', () {
      const policy = RecaptchaV3Policy();
      final decision = policy.decide(
        outcome: const RecaptchaV3VerifyOutcome(
          success: true,
          score: 0.9,
          action: 'login',
        ),
        expectedAction: 'login',
      );
      expect(decision, equals(RecaptchaV3Decision.accept));
    });

    test('score in challenge zone -> challenge', () {
      const policy = RecaptchaV3Policy();
      final decision = policy.decide(
        outcome: const RecaptchaV3VerifyOutcome(
          success: true,
          score: 0.4,
          action: 'login',
        ),
        expectedAction: 'login',
      );
      expect(decision, equals(RecaptchaV3Decision.challenge));
    });

    test('score below floor -> reject', () {
      const policy = RecaptchaV3Policy();
      final decision = policy.decide(
        outcome: const RecaptchaV3VerifyOutcome(
          success: true,
          score: 0.2,
          action: 'login',
        ),
        expectedAction: 'login',
      );
      expect(decision, equals(RecaptchaV3Decision.reject));
    });

    test('action mismatch -> reject even when score is high', () {
      const policy = RecaptchaV3Policy();
      final decision = policy.decide(
        outcome: const RecaptchaV3VerifyOutcome(
          success: true,
          score: 0.95,
          action: 'login',
        ),
        expectedAction: 'password_reset',
      );
      expect(decision, equals(RecaptchaV3Decision.reject));
    });

    test('verify success=false -> reject regardless of score', () {
      const policy = RecaptchaV3Policy();
      final decision = policy.decide(
        outcome: const RecaptchaV3VerifyOutcome(
          success: false,
          score: 1.0,
          action: 'login',
          errorCodes: <String>['invalid-input-secret'],
        ),
        expectedAction: 'login',
      );
      expect(decision, equals(RecaptchaV3Decision.reject));
    });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────────

class _PasswordHistoryPool implements PostgresPool {
  _PasswordHistoryPool({
    required this.returningEntryId,
    this.historyRows = const <PostgresRow>[],
  });

  final String? returningEntryId;
  final List<PostgresRow> historyRows;

  final List<_PasswordHistoryTransaction> transactions =
      <_PasswordHistoryTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _PasswordHistoryTransaction(
      returningEntryId: returningEntryId,
      historyRows: historyRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _PasswordHistoryTransaction extends PostgresTransaction {
  _PasswordHistoryTransaction({
    required this.returningEntryId,
    required this.historyRows,
  });

  final String? returningEntryId;
  final List<PostgresRow> historyRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;
  int commitCount = 0;
  int rollbackCount = 0;

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
    return <PostgresRow>[];
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
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    rollbackCount += 1;
  }
}

class _CountingHibpRangeFetcher implements HibpRangeFetcher {
  int calls = 0;

  @override
  Future<String> fetchRange(String hexPrefix) async {
    calls += 1;
    return ''; // empty body — no breach hits.
  }
}
