// Phase 9.5 - Password change orchestration.
//
// Composes the three independent password-change checks:
//
//   1. NIST SP 800-63B-4 shape rules ([PasswordPolicy.validate]).
//   2. HIBP k-anonymity pwned-password screening
//      ([HibpPwnedPasswordScreener.screen]).
//   3. Last-5 reuse rejection ([PasswordHistoryCheck.isReusedPassword]).
//
// Default policy when HIBP is unavailable is "fail-open + audit"
// per the plan; high-security operator profiles can flip this via
// [PasswordChangeService.failClosedOnHibpUnavailable].

import '../../auth/password_policy.dart';
import 'hibp_pwned_password_screener.dart';
import 'password_history_check.dart';

enum PasswordChangeRejection {
  /// One or more NIST shape rules failed; see [PasswordChangeOutcome.violations].
  violatesPolicy,

  /// Candidate appears in HIBP-known breaches.
  pwnedInBreach,

  /// HIBP reported "screener unavailable" and the operator profile
  /// is set to fail closed.
  hibpUnavailable,

  /// Candidate matches one of the user's last-5 stored hashes.
  reusedFromHistory,

  /// History check itself failed (DB outage etc.). Default is to
  /// refuse the change rather than risk silently allowing reuse.
  historyCheckUnavailable,
}

class PasswordChangeOutcome {
  PasswordChangeOutcome({
    required this.allowed,
    required this.rejections,
    required this.violations,
    required this.hibpResult,
  });

  final bool allowed;
  final Set<PasswordChangeRejection> rejections;

  /// NIST shape rule violations (only populated when [PasswordChangeRejection.violatesPolicy]
  /// is in [rejections]).
  final Set<PasswordViolation> violations;

  /// Underlying HIBP verdict so the proxy can emit the right
  /// `auth.hibp_*` audit event.
  final PwnedPasswordResult hibpResult;
}

class PasswordChangeService {
  PasswordChangeService({
    required HibpPwnedPasswordScreener hibpScreener,
    required PasswordHistoryCheck historyCheck,
    this.failClosedOnHibpUnavailable = false,
  }) : _hibpScreener = hibpScreener,
       _historyCheck = historyCheck;

  final HibpPwnedPasswordScreener _hibpScreener;
  final PasswordHistoryCheck _historyCheck;

  /// When true, an unavailable HIBP backend refuses the change. The
  /// default (false) follows the plan's UX-friendly stance: a HIBP
  /// outage should not block a legitimate password change. The
  /// proxy emits an `auth.hibp_unavailable` audit event either way.
  final bool failClosedOnHibpUnavailable;

  Future<PasswordChangeOutcome> evaluate({
    required String userId,
    required String candidate,
  }) async {
    final rejections = <PasswordChangeRejection>{};

    final shape = PasswordPolicy.validate(candidate);
    if (!shape.isValid) {
      rejections.add(PasswordChangeRejection.violatesPolicy);
    }

    final hibpResult = await _hibpScreener.screen(candidate);
    switch (hibpResult) {
      case PwnedPasswordResult.pwned:
        rejections.add(PasswordChangeRejection.pwnedInBreach);
      case PwnedPasswordResult.screenerUnavailable:
        if (failClosedOnHibpUnavailable) {
          rejections.add(PasswordChangeRejection.hibpUnavailable);
        }
      case PwnedPasswordResult.notPwned:
        break;
    }

    bool reused;
    try {
      reused = await _historyCheck.isReusedPassword(
        userId: userId,
        candidate: candidate,
      );
    } catch (_) {
      rejections.add(PasswordChangeRejection.historyCheckUnavailable);
      reused = false;
    }
    if (reused) {
      rejections.add(PasswordChangeRejection.reusedFromHistory);
    }

    return PasswordChangeOutcome(
      allowed: rejections.isEmpty,
      rejections: rejections,
      violations: shape.violations,
      hibpResult: hibpResult,
    );
  }
}
