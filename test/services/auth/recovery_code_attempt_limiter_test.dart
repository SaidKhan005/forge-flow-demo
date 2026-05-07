// CODE_HEALTH L10 — RecoveryCodeAttemptLimiter atomic check+record.
//
// Pins the TOCTOU fix: the limiter's [checkAndRecord] route MUST
// serialize concurrent callers for the same user under an in-process
// mutex so two consume() calls can't both pass the budget check
// before either has recorded an attempt.
//
// Strategy: a deterministic fake store records every method call
// with the order it observed. We schedule two concurrent
// `checkAndRecord` calls when the user is one slot below the daily
// budget. Without the mutex, both would observe count=4, both would
// be classified Allowed, both would record — exceeding the budget.
// With the mutex, the second waits for the first to release the lock
// before it reads the snapshot, so the second observes count=5 and
// returns DailyExhausted without recording.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_attempt_limiter.dart';

const String _userId = '11111111-1111-4111-8111-111111111111';
const String _otherUserId = '22222222-2222-4222-8222-222222222222';

void main() {
  group('RecoveryCodeAttemptLimiter.checkAndRecord (CODE_HEALTH L10)', () {
    test('records exactly one attempt on Allowed', () async {
      final store = _DeterministicAttemptStore();
      var now = DateTime.utc(2026, 4, 28, 12);
      final limiter = RecoveryCodeAttemptLimiter(
        store: store,
        now: () => now,
      );

      final decision = await limiter.checkAndRecord(userId: _userId);

      expect(decision, isA<RecoveryCodeAttemptAllowed>());
      expect(store.attempts(_userId), hasLength(1));
      // The atomic check+record path issues exactly one read AND one
      // write, in that order, for an Allowed decision.
      expect(
        store.callLog,
        equals(<String>['recentAttempts:$_userId', 'recordAttempt:$_userId']),
      );
    });

    test(
      'TOCTOU regression: two concurrent callers at the boundary do '
      'NOT both pass the budget check before either records',
      () async {
        // Pre-fill 4 of the 5 daily slots so the next call sits at
        // the boundary.
        final store = _DeterministicAttemptStore();
        var now = DateTime.utc(2026, 4, 28, 12);
        for (var i = 0; i < 4; i++) {
          store.attempts(_userId).add(now.subtract(Duration(hours: 2 + i)));
        }
        final limiter = RecoveryCodeAttemptLimiter(
          store: store,
          now: () => now,
        );

        // Fire two concurrent atomic check+record passes for the
        // SAME user. The per-user mutex serializes them; the first
        // observes count=4 (Allowed, records the 5th slot) and the
        // second observes count=5 (DailyExhausted, no record).
        final results =
            await Future.wait(<Future<RecoveryCodeAttemptDecision>>[
          limiter.checkAndRecord(userId: _userId),
          limiter.checkAndRecord(userId: _userId),
        ]);

        // Exactly one Allowed, exactly one DailyExhausted — the
        // budget held under contention.
        final allowedCount = results
            .where((d) => d is RecoveryCodeAttemptAllowed)
            .length;
        final exhaustedCount = results
            .where((d) => d is RecoveryCodeAttemptDailyExhausted)
            .length;
        expect(allowedCount, equals(1));
        expect(exhaustedCount, equals(1));
        // Only the winner appended to the durable store.
        expect(store.attempts(_userId), hasLength(5));
        // Call interleaving proves serialization: the first read
        // completes before the second read starts. (Without the
        // mutex, the call log would interleave reads.)
        expect(store.callLog.first, equals('recentAttempts:$_userId'));
        expect(store.callLog[1], equals('recordAttempt:$_userId'));
        expect(store.callLog[2], equals('recentAttempts:$_userId'));
      },
    );

    test('different users do NOT serialize against each other', () async {
      // Two different users at the budget boundary should be
      // processed in parallel — the mutex is per user. The
      // deterministic store interleaves their reads (otherwise the
      // first user would finish entirely before the second started).
      final store = _DeterministicAttemptStore();
      var now = DateTime.utc(2026, 4, 28, 12);
      for (var i = 0; i < 4; i++) {
        store.attempts(_userId).add(now.subtract(Duration(hours: 2 + i)));
        store.attempts(_otherUserId).add(now.subtract(Duration(hours: 2 + i)));
      }
      final limiter = RecoveryCodeAttemptLimiter(
        store: store,
        now: () => now,
      );

      final results = await Future.wait(<Future<RecoveryCodeAttemptDecision>>[
        limiter.checkAndRecord(userId: _userId),
        limiter.checkAndRecord(userId: _otherUserId),
      ]);

      // Each user gets the 5th slot for itself.
      expect(results.every((d) => d is RecoveryCodeAttemptAllowed), isTrue);
      expect(store.attempts(_userId), hasLength(5));
      expect(store.attempts(_otherUserId), hasLength(5));
      // Reads interleaved: the second user's read happened BEFORE
      // the first user's record. Without per-user mutex separation
      // (i.e. one global lock) the order would be read1, record1,
      // read2, record2 instead.
      expect(store.callLog, hasLength(4));
      expect(
        store.callLog.first,
        equals('recentAttempts:$_userId'),
      );
      // Second log entry is the OTHER user's read, not the first
      // user's record.
      expect(
        store.callLog[1],
        equals('recentAttempts:$_otherUserId'),
      );
    });

    test(
      'rate-limited within the per-minute window does NOT record a '
      'fresh attempt (would let an attacker flood the table)',
      () async {
        final store = _DeterministicAttemptStore();
        var now = DateTime.utc(2026, 4, 28, 12);
        // Last attempt 30s ago — inside the 1-minute window.
        store.attempts(_userId).add(now.subtract(const Duration(seconds: 30)));
        final limiter = RecoveryCodeAttemptLimiter(
          store: store,
          now: () => now,
        );

        final decision = await limiter.checkAndRecord(userId: _userId);

        expect(decision, isA<RecoveryCodeAttemptRateLimited>());
        // Read happened; record did NOT.
        expect(
          store.callLog,
          equals(<String>['recentAttempts:$_userId']),
        );
        expect(store.attempts(_userId), hasLength(1));
      },
    );

    test(
      'daily-exhausted does NOT record a fresh attempt',
      () async {
        final store = _DeterministicAttemptStore();
        var now = DateTime.utc(2026, 4, 28, 12);
        // Already at the budget.
        for (var i = 0; i < 5; i++) {
          store.attempts(_userId).add(now.subtract(Duration(hours: 2 + i)));
        }
        final limiter = RecoveryCodeAttemptLimiter(
          store: store,
          now: () => now,
        );

        final decision = await limiter.checkAndRecord(userId: _userId);

        expect(decision, isA<RecoveryCodeAttemptDailyExhausted>());
        expect(
          store.callLog,
          equals(<String>['recentAttempts:$_userId']),
        );
        expect(store.attempts(_userId), hasLength(5));
      },
    );

    test('lock releases after store error so next caller proceeds', () async {
      // First caller's store throws; second caller MUST not block
      // forever waiting for the lock the failed caller never released.
      final store = _ThrowOnceAttemptStore();
      final limiter = RecoveryCodeAttemptLimiter(
        store: store,
        now: () => DateTime.utc(2026, 4, 28, 12),
      );
      await expectLater(
        limiter.checkAndRecord(userId: _userId),
        throwsStateError,
      );
      // Second call after the throw: lock was released; this
      // proceeds normally.
      final decision = await limiter.checkAndRecord(userId: _userId);
      expect(decision, isA<RecoveryCodeAttemptAllowed>());
    });

    test('legacy check + recordAttempt still work for backward compat', () async {
      final store = _DeterministicAttemptStore();
      var now = DateTime.utc(2026, 4, 28, 12);
      final limiter = RecoveryCodeAttemptLimiter(
        store: store,
        now: () => now,
      );

      final pre = await limiter.check(userId: _userId);
      expect(pre, isA<RecoveryCodeAttemptAllowed>());
      await limiter.recordAttempt(userId: _userId);
      expect(store.attempts(_userId), hasLength(1));
    });
  });
}

/// Deterministic in-memory store that logs every call so tests can
/// assert on the call ordering. The data plane mirrors the real
/// [InMemoryRecoveryCodeAttemptStore] but exposes the call log.
class _DeterministicAttemptStore implements RecoveryCodeAttemptStore {
  final Map<String, List<DateTime>> _byUser = <String, List<DateTime>>{};
  final List<String> callLog = <String>[];

  List<DateTime> attempts(String userId) =>
      _byUser.putIfAbsent(userId, () => <DateTime>[]);

  @override
  Future<List<DateTime>> recentAttempts({
    required String userId,
    required DateTime now,
    required Duration window,
  }) async {
    callLog.add('recentAttempts:$userId');
    final cutoff = now.subtract(window);
    return attempts(userId)
        .where((ts) => ts.isAfter(cutoff))
        .toList(growable: false);
  }

  @override
  Future<void> recordAttempt({
    required String userId,
    required DateTime at,
  }) async {
    callLog.add('recordAttempt:$userId');
    attempts(userId).add(at);
  }
}

/// Throws on the first `recentAttempts` call so the test can verify
/// the limiter's mutex releases on error.
class _ThrowOnceAttemptStore implements RecoveryCodeAttemptStore {
  bool _thrown = false;
  final Map<String, List<DateTime>> _byUser = <String, List<DateTime>>{};

  @override
  Future<List<DateTime>> recentAttempts({
    required String userId,
    required DateTime now,
    required Duration window,
  }) async {
    if (!_thrown) {
      _thrown = true;
      throw StateError('synthetic store outage');
    }
    final all = _byUser[userId] ?? const <DateTime>[];
    final cutoff = now.subtract(window);
    return all.where((ts) => ts.isAfter(cutoff)).toList(growable: false);
  }

  @override
  Future<void> recordAttempt({
    required String userId,
    required DateTime at,
  }) async {
    _byUser.putIfAbsent(userId, () => <DateTime>[]).add(at);
  }
}
