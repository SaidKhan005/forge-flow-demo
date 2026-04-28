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
    final decision = await _limiter.check(userId: userId);
    if (decision is RecoveryCodeAttemptRateLimited) {
      return RecoveryCodeRateLimited(retryAfter: decision.retryAfter);
    }
    if (decision is RecoveryCodeAttemptDailyExhausted) {
      return RecoveryCodeDailyBudgetExceeded(resetsAt: decision.resetsAt);
    }

    // From here on, EVERY exit path records the attempt — even
    // malformed input — so an attacker cannot burn-then-bypass.
    try {
      final normalized = RecoveryCodeGenerator.normalize(rawCode);
      if (normalized == null) {
        return const RecoveryCodeInvalid();
      }

      final candidates = await _repository.listActiveRecoveryCodeFactors(
        operatorId: operatorId,
        locationId: locationId,
        userId: userId,
      );

      MfaFactorRecord? matched;
      for (final factor in candidates) {
        final stored = _tryParseHashedCode(factor.factorMetadata);
        if (stored == null) continue;
        if (_hasher.verify(normalizedCode: normalized, stored: stored)) {
          matched = factor;
          break;
        }
      }
      if (matched == null) {
        return const RecoveryCodeInvalid();
      }

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
    } finally {
      await _limiter.recordAttempt(userId: userId);
    }
  }

  static HashedRecoveryCode? _tryParseHashedCode(
    Map<String, Object?> metadata,
  ) {
    final salt = metadata['salt'];
    final hash = metadata['hash'];
    if (salt is! String || hash is! String) return null;
    return HashedRecoveryCode(saltBase64: salt, hashBase64: hash);
  }
}
