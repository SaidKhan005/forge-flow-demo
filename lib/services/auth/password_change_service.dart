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
//
// CODE_HEALTH L10 (HIBP order): the HIBP roundtrip is the only
// network call on this path. Shape validation runs FIRST so an
// obviously-invalid candidate (too short, control chars, leading
// whitespace, etc.) never burns a HIBP request. Beyond saving the
// outbound HTTP cost, the early return also defends the HIBP rate
// budget against a brute-force attacker who fires malformed
// candidates. The history check still runs after HIBP so an
// otherwise-valid candidate that matches a stored hash also burns
// the HIBP slot — that's intentional: HIBP results are cached at
// the proxy edge and represent risk signal regardless of reuse.

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

    // CODE_HEALTH L10: shape validation is the cheapest, most
    // deterministic check + the only one that can prove the
    // candidate is malformed without consulting any external
    // dependency. Running it first means an obviously-invalid
    // password (empty, too short, control chars, edge whitespace)
    // returns immediately without burning a HIBP roundtrip or a
    // history-check DB call.
    final shape = PasswordPolicy.validate(candidate);
    if (!shape.isValid) {
      rejections.add(PasswordChangeRejection.violatesPolicy);
      // Skip HIBP + history when the shape itself failed. The
      // outcome carries an empty `screenerUnavailable` to signal
      // "HIBP not consulted"; the proxy's audit emitter logs
      // `auth.password_change_rejected_shape` rather than the
      // HIBP-specific events.
      return PasswordChangeOutcome(
        allowed: false,
        rejections: rejections,
        violations: shape.violations,
        hibpResult: PwnedPasswordResult.screenerUnavailable,
      );
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
