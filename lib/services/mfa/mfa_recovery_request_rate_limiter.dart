// Phase 9.UX.1a - lightweight MFA recovery-request abuse guard.
//
// This is intentionally small: per-email cooldown plus per-IP rolling window.
// It is suitable as the app-level guard behind Cloud Armor / ingress rate
// limits, without adding captcha plumbing to the first production slice.

class MfaRecoveryRateLimitDecision {
  const MfaRecoveryRateLimitDecision.allowed() : retryAfter = null;

  const MfaRecoveryRateLimitDecision.blocked({required this.retryAfter});

  final DateTime? retryAfter;
  bool get isAllowed => retryAfter == null;
}

abstract class MfaRecoveryRequestRateLimiter {
  Future<MfaRecoveryRateLimitDecision> checkAndRecord({
    required String normalizedEmail,
    required String clientIp,
  });
}

class InMemoryMfaRecoveryRequestRateLimiter
    implements MfaRecoveryRequestRateLimiter {
  InMemoryMfaRecoveryRequestRateLimiter({
    this.emailCooldown = const Duration(minutes: 15),
    this.ipWindow = const Duration(minutes: 10),
    this.maxRequestsPerIpWindow = 10,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration emailCooldown;
  final Duration ipWindow;
  final int maxRequestsPerIpWindow;
  final DateTime Function() _now;

  final Map<String, DateTime> _lastEmailRequest = <String, DateTime>{};
  final Map<String, List<DateTime>> _ipRequests = <String, List<DateTime>>{};

  @override
  Future<MfaRecoveryRateLimitDecision> checkAndRecord({
    required String normalizedEmail,
    required String clientIp,
  }) async {
    final now = _now().toUtc();
    final emailKey = normalizedEmail.trim().toLowerCase();
    final ipKey = clientIp.trim().isEmpty ? 'unknown' : clientIp.trim();

    final lastForEmail = _lastEmailRequest[emailKey];
    if (lastForEmail != null) {
      final retryAt = lastForEmail.add(emailCooldown);
      if (now.isBefore(retryAt)) {
        return MfaRecoveryRateLimitDecision.blocked(retryAfter: retryAt);
      }
    }

    final windowStart = now.subtract(ipWindow);
    final ipHistory = _ipRequests.putIfAbsent(ipKey, () => <DateTime>[]);
    ipHistory.removeWhere((timestamp) => timestamp.isBefore(windowStart));
    if (ipHistory.length >= maxRequestsPerIpWindow) {
      final retryAt = ipHistory.first.add(ipWindow);
      return MfaRecoveryRateLimitDecision.blocked(retryAfter: retryAt);
    }

    _lastEmailRequest[emailKey] = now;
    ipHistory.add(now);
    return const MfaRecoveryRateLimitDecision.allowed();
  }
}
