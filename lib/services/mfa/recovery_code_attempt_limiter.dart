// Phase 9 live-closeout B13 - Recovery-code attempt rate limiter.
//
// The Phase 9 decision lock pins recovery-code attempt limits at:
//
//   * 1 attempt per minute per user
//   * 5 attempts per 24-hour rolling window per user
//
// Both invalid AND valid attempts count toward the limit so an
// attacker who throws random codes can't burn the legitimate user's
// budget either way.
//
// The limiter is intentionally pure: an injected [AttemptStore]
// keeps the timestamps. Production wires a Postgres-backed store;
// tests use the in-memory store. The default [AttemptStore] is
// [ScaffoldFailingAttemptStore] so a misconfigured deploy that wires
// the limiter but forgets the persistence binding fail-closes the
// recovery-code path rather than silently accepting unbounded
// attempts.
//
// CODE_HEALTH L10 (TOCTOU): the legacy `check` + later
// `recordAttempt` pair leaves a window where two concurrent callers
// could both pass the limit check before either records its
// attempt. The fix is the [checkAndRecord] entrypoint, which:
//
//   1. acquires a per-user in-process mutex,
//   2. reads recent attempts AND inserts a fresh attempt iff the
//      decision will be Allowed, and
//   3. classifies the decision from the snapshot taken before the
//      insert.
//
// The mutex serializes the read+write inside one proxy process so
// two `consume` calls for the same user can't both see "below the
// budget" at the same time. Cross-process atomicity (multiple proxy
// instances racing) requires a Postgres row-level lock or a CTE
// gating the INSERT on `(SELECT count(*) FROM recovery_code_attempts
// WHERE ... ) < $budget`; that override lives on the
// `PostgresRecoveryCodeAttemptStore` and is a separate follow-up
// outside this lane's file scope. The in-process mutex closes the
// hot single-process TOCTOU and is what the L10 unit tests pin.

import 'dart:async';

/// Persistence boundary for recovery-code attempt timestamps.
abstract class RecoveryCodeAttemptStore {
  /// Returns every attempt timestamp recorded for [userId] within the
  /// last [window] from [now], sorted oldest-first. Implementations
  /// SHOULD prune older rows on read; the limiter only reads what it
  /// needs.
  Future<List<DateTime>> recentAttempts({
    required String userId,
    required DateTime now,
    required Duration window,
  });

  /// Records a fresh attempt timestamp.
  Future<void> recordAttempt({
    required String userId,
    required DateTime at,
  });
}

/// In-memory store for tests + previewer harnesses.
class InMemoryRecoveryCodeAttemptStore implements RecoveryCodeAttemptStore {
  final Map<String, List<DateTime>> _byUser = <String, List<DateTime>>{};

  @override
  Future<List<DateTime>> recentAttempts({
    required String userId,
    required DateTime now,
    required Duration window,
  }) async {
    final all = _byUser[userId];
    if (all == null) return const <DateTime>[];
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

/// Hard-fail-closed default. Refuses recovery-code attempts when
/// nothing is wired so a deploy that forgets the persistence binding
/// surfaces a clear "no attempt store wired" error rather than
/// silently allowing unbounded attempts.
class ScaffoldFailingRecoveryCodeAttemptStore
    implements RecoveryCodeAttemptStore {
  const ScaffoldFailingRecoveryCodeAttemptStore();

  @override
  Future<List<DateTime>> recentAttempts({
    required String userId,
    required DateTime now,
    required Duration window,
  }) async {
    throw StateError(_message);
  }

  @override
  Future<void> recordAttempt({
    required String userId,
    required DateTime at,
  }) async {
    throw StateError(_message);
  }

  static const String _message =
      'B13 scaffold: real RecoveryCodeAttemptStore is not wired — bind '
      'the Postgres-backed attempt store in the proxy bootstrap '
      'before exposing the recovery-code consumption surface.';
}

/// Outcome of [RecoveryCodeAttemptLimiter.check].
sealed class RecoveryCodeAttemptDecision {
  const RecoveryCodeAttemptDecision();
}

/// Attempt is allowed; consumer should proceed with verification +
/// must call [RecoveryCodeAttemptLimiter.recordAttempt] regardless
/// of verify outcome (per the locked policy: invalid attempts also
/// count toward the budget).
class RecoveryCodeAttemptAllowed extends RecoveryCodeAttemptDecision {
  const RecoveryCodeAttemptAllowed();
}

/// Attempt is blocked because the per-minute rate limit kicked in.
/// [retryAfter] is the earliest moment a fresh attempt can succeed.
class RecoveryCodeAttemptRateLimited extends RecoveryCodeAttemptDecision {
  const RecoveryCodeAttemptRateLimited({required this.retryAfter});

  final DateTime retryAfter;
}

/// Attempt is blocked because the 24-hour budget has been exhausted.
/// [resetsAt] is when the oldest in-window attempt rolls off.
class RecoveryCodeAttemptDailyExhausted extends RecoveryCodeAttemptDecision {
  const RecoveryCodeAttemptDailyExhausted({required this.resetsAt});

  final DateTime resetsAt;
}

class RecoveryCodeAttemptLimiter {
  RecoveryCodeAttemptLimiter({
    required RecoveryCodeAttemptStore store,
    DateTime Function()? now,
    Duration perMinuteWindow = const Duration(minutes: 1),
    Duration dailyWindow = const Duration(hours: 24),
    int dailyBudget = defaultDailyBudget,
  }) : _store = store,
       _now = now ?? DateTime.now,
       _perMinuteWindow = perMinuteWindow,
       _dailyWindow = dailyWindow,
       _dailyBudget = dailyBudget;

  /// Locked decision: 5 recovery-code attempts per rolling 24h.
  static const int defaultDailyBudget = 5;

  final RecoveryCodeAttemptStore _store;
  final DateTime Function() _now;
  final Duration _perMinuteWindow;
  final Duration _dailyWindow;
  final int _dailyBudget;

  /// Per-user mutex queue. Each entry is the tail Future that the
  /// next caller awaits before grabbing the lock. CODE_HEALTH L10:
  /// the queue is what closes the in-process TOCTOU window between
  /// `recentAttempts` (the read) and `recordAttempt` (the write).
  /// Map keyed by user so different users never block each other.
  final Map<String, Future<void>> _userLocks = <String, Future<void>>{};

  /// Decides whether the next attempt is allowed. Does NOT record
  /// the attempt — the caller invokes [recordAttempt] after the
  /// verify pass (regardless of verify outcome).
  ///
  /// CODE_HEALTH L10: prefer [checkAndRecord] for new code. The
  /// non-atomic [check] + [recordAttempt] split is preserved only
  /// for backward compatibility with existing test surfaces;
  /// production paths route through [checkAndRecord].
  Future<RecoveryCodeAttemptDecision> check({required String userId}) async {
    final now = _now();
    final recent24h = await _store.recentAttempts(
      userId: userId,
      now: now,
      window: _dailyWindow,
    );
    return _classify(now: now, attempts: recent24h);
  }

  /// Records a fresh attempt timestamp. Caller invokes this after
  /// every verify pass — even when the code was wrong.
  Future<void> recordAttempt({required String userId}) {
    return _store.recordAttempt(userId: userId, at: _now());
  }

  /// Atomic-in-process check + record. Acquires a per-user mutex
  /// before reading the attempt window and (when the decision will
  /// be Allowed) recording the fresh attempt. Two concurrent callers
  /// for the SAME user serialize through the mutex, so the second
  /// caller cannot read a stale snapshot — by the time it grabs the
  /// lock the first caller's record has already landed in the
  /// store. The TOCTOU window the legacy `check + finally
  /// recordAttempt` split left open is closed.
  ///
  /// When the decision is [RecoveryCodeAttemptAllowed] the store has
  /// already burned a slot; the caller MUST NOT call [recordAttempt]
  /// again. When the decision is rate-limited or exhausted, no slot
  /// was burned — burning a fresh slot for a request we are about to
  /// reject would let a brute-force attacker flood the table.
  ///
  /// Cross-process atomicity (multiple proxy instances racing) is
  /// not provided here; that requires a Postgres row-level lock or
  /// a single-CTE INSERT gated on the count, which lives on the
  /// `PostgresRecoveryCodeAttemptStore` follow-up. The in-process
  /// mutex closes the hot common case (one proxy, two concurrent
  /// HTTP handlers).
  Future<RecoveryCodeAttemptDecision> checkAndRecord({
    required String userId,
  }) async {
    return _withUserLock(userId, () async {
      final now = _now();
      final attempts = await _store.recentAttempts(
        userId: userId,
        now: now,
        window: _dailyWindow,
      );
      final decision = _classify(now: now, attempts: attempts);
      if (decision is RecoveryCodeAttemptAllowed) {
        await _store.recordAttempt(userId: userId, at: now);
      }
      return decision;
    });
  }

  /// Run [body] under the per-user serialization lock so two
  /// concurrent callers for [userId] never observe each other's
  /// pre-record snapshot. The lock is released even when [body]
  /// throws; the next waiter is unblocked through the completer.
  Future<R> _withUserLock<R>(
    String userId,
    Future<R> Function() body,
  ) async {
    final previous = _userLocks[userId];
    final completer = Completer<void>();
    _userLocks[userId] = completer.future;
    try {
      if (previous != null) {
        // Wait for the prior holder to release. Errors from the
        // prior body are NOT propagated here — the lock contract is
        // "release the slot regardless of outcome".
        try {
          await previous;
        } catch (_) {
          // Intentional swallow: the prior caller's failure does not
          // poison this one. The lock contract is "release the slot
          // regardless of outcome" (see method-level comment above).
        }
      }
      return await body();
    } finally {
      // Detach BEFORE completing so a fast follow-up call doesn't
      // briefly observe the just-completed future under our key.
      if (identical(_userLocks[userId], completer.future)) {
        _userLocks.remove(userId);
      }
      completer.complete();
    }
  }

  RecoveryCodeAttemptDecision _classify({
    required DateTime now,
    required List<DateTime> attempts,
  }) {
    if (attempts.length >= _dailyBudget) {
      // Oldest attempt in the window rolls off after _dailyWindow.
      final oldest = attempts.reduce((a, b) => a.isBefore(b) ? a : b);
      return RecoveryCodeAttemptDailyExhausted(
        resetsAt: oldest.add(_dailyWindow),
      );
    }
    final recent1m = attempts
        .where((ts) => ts.isAfter(now.subtract(_perMinuteWindow)))
        .toList();
    if (recent1m.isNotEmpty) {
      final mostRecent = recent1m.reduce((a, b) => a.isAfter(b) ? a : b);
      return RecoveryCodeAttemptRateLimited(
        retryAfter: mostRecent.add(_perMinuteWindow),
      );
    }
    return const RecoveryCodeAttemptAllowed();
  }
}
