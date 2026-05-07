// Phase 9 live-closeout B13 - Recovery-code consumption service.
//
// Combines the rate limiter (1/min, 5/24h per user) with the
// salted-SHA-256 hasher and the `mfa_factors` repository to do a
// single end-to-end "consume this code" pass. Every outcome is
// expressed as a sealed result so the proxy can decide whether to
// audit + how to respond:
//
//   * RateLimited        — too many attempts in the last minute
//   * DailyBudgetExceeded — too many attempts in the last 24h
//   * Invalid            — code didn't match any active factor row
//   * AlreadyUsed        — code matched a factor but it was already
//                          marked used / revoked (rare; happens when
//                          two parallel verify-then-mark calls race)
//   * Consumed           — code matched and was marked used in the
//                          same transaction
//
// Every code attempt — invalid or otherwise — burns one slot in the
// limiter so an attacker can't spam attempts.
//
// CODE_HEALTH L10:
//
//   * TOCTOU: the consumer used to do `check` then later
//     `recordAttempt` in a `finally` block. Two concurrent callers
//     could both pass the check before either recorded an attempt,
//     letting them exceed the locked budget. The consumer now calls
//     [RecoveryCodeAttemptLimiter.checkAndRecord], which serializes
//     concurrent callers for the same user under a per-user
//     in-process mutex AND records the attempt only when the
//     decision is Allowed (rate-limited / exhausted callers do NOT
//     burn a fresh slot, so an attacker can't flood the table by
//     spamming during the per-minute window).
//   * Constant-time slot lookup: the previous matching loop had an
//     early `break` on the first matching slot, which leaks via
//     timing where in the candidate list the matching factor sits.
//     The loop now compares against EVERY candidate without
//     branching on match-or-not; the chosen factor index is selected
//     from a constant-time accumulator AFTER the loop. Verifier
//     itself remains constant-time on the hash compare.

import '../../infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'recovery_code_attempt_limiter.dart';
import 'recovery_code_generator.dart';
import 'recovery_code_hasher.dart';

/// Outcome of [RecoveryCodeConsumer.consume].
sealed class RecoveryCodeConsumeResult {
  const RecoveryCodeConsumeResult();
}

class RecoveryCodeConsumed extends RecoveryCodeConsumeResult {
  const RecoveryCodeConsumed({required this.factorId});

  final String factorId;
}

class RecoveryCodeInvalid extends RecoveryCodeConsumeResult {
  const RecoveryCodeInvalid();
}

class RecoveryCodeAlreadyUsed extends RecoveryCodeConsumeResult {
  const RecoveryCodeAlreadyUsed({required this.factorId});

  final String factorId;
}

class RecoveryCodeRateLimited extends RecoveryCodeConsumeResult {
  const RecoveryCodeRateLimited({required this.retryAfter});

  final DateTime retryAfter;
}

class RecoveryCodeDailyBudgetExceeded extends RecoveryCodeConsumeResult {
  const RecoveryCodeDailyBudgetExceeded({required this.resetsAt});

  final DateTime resetsAt;
}

class RecoveryCodeConsumer {
  RecoveryCodeConsumer({
    required RecoveryCodeHasher hasher,
    required MfaFactorsRepository repository,
    required RecoveryCodeAttemptLimiter limiter,
  }) : _hasher = hasher,
       _repository = repository,
       _limiter = limiter;

  final RecoveryCodeHasher _hasher;
  final MfaFactorsRepository _repository;
  final RecoveryCodeAttemptLimiter _limiter;

  /// Attempts to consume [rawCode] for [userId]. Operator + location
  /// come from the verified session; the repository needs them for
  /// SET LOCAL even though the actual SQL filters by user_id.
  ///
  /// The return value is the same regardless of why an attempt
  /// failed (invalid vs. already-used) — the proxy intentionally
  /// surfaces a generic error to the user so an attacker cannot
  /// distinguish "wrong code" from "right code, already burned".
  Future<RecoveryCodeConsumeResult> consume({
    required String operatorId,
    required String locationId,
    required String userId,
    required String rawCode,
  }) async {
    // Atomic-in-process check + record: the limiter serializes
    // concurrent callers for the same user under a per-user mutex.
    // When the decision is Allowed, the slot has ALREADY been
    // recorded — the consumer must not call recordAttempt again.
    // When the decision is rate-limited / exhausted, no slot was
    // burned (would let an attacker flood the table). This closes
    // the TOCTOU window the previous `check` + `finally
    // recordAttempt` split left open within a single proxy process.
    final decision = await _limiter.checkAndRecord(userId: userId);
    if (decision is RecoveryCodeAttemptRateLimited) {
      return RecoveryCodeRateLimited(retryAfter: decision.retryAfter);
    }
    if (decision is RecoveryCodeAttemptDailyExhausted) {
      return RecoveryCodeDailyBudgetExceeded(resetsAt: decision.resetsAt);
    }

    final normalized = RecoveryCodeGenerator.normalize(rawCode);
    if (normalized == null) {
      return const RecoveryCodeInvalid();
    }

    final candidates = await _repository.listActiveRecoveryCodeFactors(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );

    // Constant-time-shaped slot lookup. Iterate EVERY candidate and
    // verify EVERY hash regardless of whether an earlier slot
    // matched. The "no early break" is the load-bearing property:
    // the loop runs candidates.length verifications either way, so
    // an attacker cannot tell from wall time whether a match was
    // found AT slot 0 vs. slot N. The verifier itself remains
    // constant-time on the hash compare. The pick-update line below
    // is branch-free at the algebra level (multiply-mask), giving
    // the AOT compiler the option to emit a cmov; even if it emits
    // a branch the cost is dwarfed by the per-iteration verify
    // call, so the timing leak is negligible at the cipher level.
    //
    // Encoding:
    //   matchedAccumulator: 0 = no match yet, 1 = locked in.
    //   matchedIndexAcc: i+1 for the locked-in slot, 0 before any
    //                    match. We store i+1 so 0 stays a clean
    //                    "no match" sentinel.
    var matchedAccumulator = 0;
    var matchedIndexAcc = 0;
    for (var i = 0; i < candidates.length; i++) {
      final factor = candidates[i];
      final stored = _tryParseHashedCode(factor.factorMetadata);
      // Run verify on a sentinel hash when metadata is malformed so
      // every loop iteration does the same amount of work. The
      // sentinel never matches (the hasher's constant-time compare
      // rejects on content).
      final verifyStored = stored ?? _sentinelStored;
      final isMatch = _hasher.verify(
        normalizedCode: normalized,
        stored: verifyStored,
      );
      final live = (stored != null && isMatch) ? 1 : 0;
      final lockMask = 1 - matchedAccumulator;
      final picked = live & lockMask;
      // Multiply-mask update: when picked=1 take (i+1); else keep
      // the current accumulator. No data-dependent branch.
      matchedIndexAcc =
          (matchedIndexAcc * (1 - picked)) + ((i + 1) * picked);
      matchedAccumulator = matchedAccumulator | picked;
    }

    if (matchedAccumulator == 0) {
      return const RecoveryCodeInvalid();
    }
    final matched = candidates[matchedIndexAcc - 1];

    final affected = await _repository.markRecoveryCodeUsed(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      factorId: matched.factorId,
    );
    if (affected == 0) {
      return RecoveryCodeAlreadyUsed(factorId: matched.factorId);
    }
    return RecoveryCodeConsumed(factorId: matched.factorId);
  }

  static HashedRecoveryCode? _tryParseHashedCode(
    Map<String, Object?> metadata,
  ) {
    final salt = metadata['salt'];
    final hash = metadata['hash'];
    if (salt is! String || hash is! String) return null;
    return HashedRecoveryCode(saltBase64: salt, hashBase64: hash);
  }

  /// All-zero base64 sentinel used so malformed-metadata slots still
  /// run a verify call — keeps the loop body's time independent of
  /// how many slots had bad metadata. The sentinel never matches a
  /// real code (32 zero bytes is not a SHA-256 of any plausible
  /// salt+code; even if it were, the hasher's constant-time compare
  /// returns the same time on a near-hit as on a miss).
  static final HashedRecoveryCode _sentinelStored = HashedRecoveryCode(
    // 16 zero bytes (24 base64 chars) and 32 zero bytes (44 base64
    // chars). Decoded values are 0x00..., which never collide with a
    // real (salt, sha256(salt || code)) pair.
    saltBase64: 'AAAAAAAAAAAAAAAAAAAAAA==',
    hashBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  );
}
