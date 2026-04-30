// Phase 9.4 - MFA enrollment policy.
//
// Reopened on 2026-04-30: TOTP MFA enrollment is available at launch, but
// mandatory MFA enforcement for admin-tier accounts is deferred until
// post-launch stability and explicit approval. Sensitive actions can still
// require fresh auth.

/// Operator subscription tier the policy reads from.
enum OperatorSubscriptionTier {
  pilot,
  starter,
  premium,
  pro,
  enterprise;

  static OperatorSubscriptionTier? fromKey(String? raw) {
    final normalized = raw?.trim().toLowerCase();
    switch (normalized) {
      case 'pilot':
        return pilot;
      case 'starter':
        return starter;
      case 'premium':
        return premium;
      case 'pro':
        return pro;
      case 'enterprise':
        return enterprise;
      default:
        return null;
    }
  }

  bool get requiresStaffMfa {
    return false;
  }
}

/// Outcome of [MfaPolicy.evaluate].
enum MfaRequirement {
  /// User must enroll MFA before proceeding. Reserved for the post-launch
  /// enforcement rollout; not returned by the launch policy.
  requiredAndNotEnrolled,

  /// User is required to have MFA and has enrolled. Reserved for the
  /// post-launch enforcement rollout.
  requiredAndEnrolled,

  /// MFA is optional for this user / operator-tier combo. Users may still
  /// self-enroll via the account surface but the gate does not force it.
  optional,
}

abstract class MfaPolicy {
  MfaPolicy._();

  /// Evaluates the launch MFA policy for a single user.
  ///
  /// [authRoles], [subscriptionTier], and [mfaEnrolled] stay in the signature
  /// so the post-launch enforcement rollout can reuse the seam without
  /// touching every caller. For launch, no role/tier combination forces
  /// enrollment.
  static MfaRequirement evaluate({
    required Iterable<String> authRoles,
    required OperatorSubscriptionTier? subscriptionTier,
    required bool mfaEnrolled,
  }) {
    return MfaRequirement.optional;
  }
}
