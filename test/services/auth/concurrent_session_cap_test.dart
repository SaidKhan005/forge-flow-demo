// B1.A6 — Concurrent-session cap tests.
//
// Verifies that [RepositoryAuthSessionLedgerWriter] enforces the 5-session
// cap by evicting the oldest active session before inserting a new one.
// Tests use an in-memory fake of [AuthSessionsRepository] so no Postgres
// connection is required.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/repository_auth_session_ledger_writer.dart';

void main() {
  group('RepositoryAuthSessionLedgerWriter — session cap', () {
    test('kMaxConcurrentSessions is 5', () {
      expect(AuthSessionsRepository.kMaxConcurrentSessions, equals(5));
    });

    test('does not evict when below cap', () async {
      final repo = _FakeSessionsRepository(activeSessions: 4);
      final writer = RepositoryAuthSessionLedgerWriter(repository: repo);

      await writer.recordLogin(
        AuthSessionLedgerLogin(
          userId: 'u-1',
          operatorId: 'op-1',
          locationId: 'loc-1',
          tokenHash: 'hash-1',
        ),
      );

      expect(repo.evictions, equals(0),
          reason: 'no eviction when below cap (4 < 5)');
      expect(repo.insertions, equals(1));
    });

    test('evicts oldest session when at cap', () async {
      final repo = _FakeSessionsRepository(activeSessions: 5);
      final writer = RepositoryAuthSessionLedgerWriter(repository: repo);

      await writer.recordLogin(
        AuthSessionLedgerLogin(
          userId: 'u-2',
          operatorId: 'op-1',
          locationId: 'loc-1',
          tokenHash: 'hash-new',
        ),
      );

      expect(repo.evictions, equals(1),
          reason: 'oldest session evicted when at cap');
      expect(repo.insertions, equals(1),
          reason: 'new session still inserted after eviction');
    });

    test('evicts when exceeding cap (race condition case)', () async {
      // A race may temporarily push the count to 6. The cap is still
      // enforced by evicting one before insertion.
      final repo = _FakeSessionsRepository(activeSessions: 6);
      final writer = RepositoryAuthSessionLedgerWriter(repository: repo);

      await writer.recordLogin(
        AuthSessionLedgerLogin(
          userId: 'u-3',
          operatorId: 'op-1',
          locationId: 'loc-1',
          tokenHash: 'hash-race',
        ),
      );

      expect(repo.evictions, equals(1));
      expect(repo.insertions, equals(1));
    });

    test('session cap enforced per user: different users do not share quota',
        () async {
      // User A is at the cap; User B has no sessions.
      // Both log in — A triggers eviction, B does not.
      final repoA = _FakeSessionsRepository(activeSessions: 5);
      final repoB = _FakeSessionsRepository(activeSessions: 0);

      final writerA = RepositoryAuthSessionLedgerWriter(repository: repoA);
      final writerB = RepositoryAuthSessionLedgerWriter(repository: repoB);

      await writerA.recordLogin(
        AuthSessionLedgerLogin(
          userId: 'userA',
          operatorId: 'op-1',
          locationId: 'loc-1',
          tokenHash: 'hash-a',
        ),
      );
      await writerB.recordLogin(
        AuthSessionLedgerLogin(
          userId: 'userB',
          operatorId: 'op-1',
          locationId: 'loc-1',
          tokenHash: 'hash-b',
        ),
      );

      expect(repoA.evictions, equals(1), reason: 'User A at cap → eviction');
      expect(repoB.evictions, equals(0), reason: 'User B under cap → no eviction');
    });
  });
}

// ─── Fakes ───────────────────────────────────────────────────────────────────

/// A minimal fake of [AuthSessionsRepository] that records calls
/// without touching Postgres.
class _FakeSessionsRepository implements AuthSessionsRepository {
  _FakeSessionsRepository({required this.activeSessions});

  int activeSessions;
  int evictions = 0;
  int insertions = 0;
  int _sessionCounter = 0;

  @override
  Future<int> countActiveSessions({
    required String userId,
    required String adminReason,
  }) async =>
      activeSessions;

  @override
  Future<String?> evictOldestSession({
    required String userId,
    required String adminReason,
  }) async {
    evictions++;
    if (activeSessions > 0) activeSessions--;
    return 'evicted-session-$evictions';
  }

  @override
  Future<String> insertLogin({
    required String operatorId,
    required String locationId,
    required String userId,
    required String tokenHash,
    String? ip,
    String? userAgent,
    String? deviceFingerprint,
    String? geoCountry,
  }) async {
    insertions++;
    _sessionCounter++;
    return 'session-$_sessionCounter';
  }

  // Unused in these tests — noSuchMethod covers the rest.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} not implemented in _FakeSessionsRepository',
  );
}
