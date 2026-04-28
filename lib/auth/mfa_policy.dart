// Phase 9.4 - MFA enforcement policy.
//
// Encodes the locked enforcement decision from
// `phase_9_decision_lock_2026-04-26.md`:
//
//   * All admin users (super_admin, ff_support, operator_owner,
//     operator_manager) require MFA at every tier.
//   * Staff-level users do not have mandatory MFA by subscription
//     tier; they may opt in, and sensitive actions can still require
//     fresh auth.
//
// Inputs come from the verified JWT custom claims + the operator's
// subscription tier (read at session-build time from
// `operators.subscription_tier`). Output drives:
//
//   - the AuthGate (route the user to the enrollment surface when
//     MFA is required and not yet enrolled);
//   - the proxy (refuse sensitive ops until enrollment completes);
//   - the admin console (Phase 9.9 displays the per-tier policy).

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
  /// User must enroll MFA before proceeding. AuthGate routes to the
  /// enrollment surface; sensitive ops refused.
  requiredAndNotEnrolled,

  /// User is required to have MFA and has enrolled. Login flow
  /// proceeds normally; sensitive ops still demand step-up freshness
  /// (5-minute window from the decision lock — see
  /// `AuthSession.isAuthFresh`).
  requiredAndEnrolled,

  /// MFA is optional for this user / operator-tier combo. Users may
  /// still self-enroll via the account surface but the gate does
  /// not force it.
  optional,
}

/// Roles the policy treats as "admin tier" (required-everywhere).
/// Mirrors the catalog in `auth_permission_key_catalog.md`.
const Set<String> _adminTierRoles = <String>{
  'super_admin',
  'ff_support',
  'operator_owner',
  'operator_manager',
};

abstract class MfaPolicy {
  MfaPolicy._();

  /// Evaluates the decision-lock MFA policy for a single user.
  ///
  /// [authRoles] are the role keys carried by the verified session
  /// (see `BarrioPreviewRole.fromAuthRoles` for the canonical list).
  /// Unknown roles are ignored — they cannot upgrade a user to the
  /// admin tier.
  static MfaRequirement evaluate({
    required Iterable<String> authRoles,
    required OperatorSubscriptionTier? subscriptionTier,
    required bool mfaEnrolled,
  }) {
    if (_isAdminTier(authRoles)) {
      return mfaEnrolled
          ? MfaRequirement.requiredAndEnrolled
          : MfaRequirement.requiredAndNotEnrolled;
    }
    return MfaRequirement.optional;
  }

  static bool _isAdminTier(Iterable<String> authRoles) {
    for (final role in authRoles) {
      if (_adminTierRoles.contains(role.trim().toLowerCase())) {
        return true;
      }
    }
    return false;
  }
}
