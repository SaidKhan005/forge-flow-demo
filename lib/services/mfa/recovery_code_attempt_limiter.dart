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

  /// Decides whether the next attempt is allowed. Does NOT record
  /// the attempt — the caller invokes [recordAttempt] after the
  /// verify pass (regardless of verify outcome).
  Future<RecoveryCodeAttemptDecision> check({required String userId}) async {
    final now = _now();
    final recent24h = await _store.recentAttempts(
      userId: userId,
      now: now,
      window: _dailyWindow,
    );
    if (recent24h.length >= _dailyBudget) {
      // Oldest attempt in the window rolls off after _dailyWindow.
      final oldest = recent24h.reduce((a, b) => a.isBefore(b) ? a : b);
      return RecoveryCodeAttemptDailyExhausted(
        resetsAt: oldest.add(_dailyWindow),
      );
    }
    final recent1m = recent24h
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

  /// Records a fresh attempt timestamp. Caller invokes this after
  /// every verify pass — even when the code was wrong.
  Future<void> recordAttempt({required String userId}) {
    return _store.recordAttempt(userId: userId, at: _now());
  }
}
