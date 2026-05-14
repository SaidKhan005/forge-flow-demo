// Phase 9.8 - User invite service.
//
// 7-day expiry per the locked decision. Invites are single-use:
// once accepted, the underlying `auth_invites` row is marked
// `accepted_at` and never reused. Revoke flips `revoked_at` and
// fail-closes any subsequent acceptance.
//
// Trusted programmatic creation (no invite email) is a separate
// path — F&F super_admin only per the decision lock — and lives
// under `TrustedUserCreationPolicy` below.
//
// BC-1 invite-path resolution (Q-3 scaffold audit lane,
// 2026-05-13): This service owns the durable `auth_invites`
// bookkeeping — token mint, expiry, accept/revoke state machine.
// It does NOT mint or send the invite email itself. The production
// invite EMAIL goes through Firebase Identity Platform's
// password-reset action-link template, dispatched from
// `lib/services/auth/repository_auth_operations_gateway.dart`'s
// `firebaseAdmin.sendPasswordResetEmail` calls at the
// invite-completion site and the admin-initiated reset site.
// Rationale: Firebase already owns the canonical action-link
// flow (oobCode mint, branded action page, deep-link bounce
// through `web/auth/action/index.html`); duplicating that with a
// SendGrid-owned invite template would force F&F to re-implement
// the token-exchange + UI surface for no functional gain.
//
// The repo-owned `operator_admin_invite.md` template was deleted
// in A2.2 (PR #540); `operator_invite_first_admin.md` is
// preserved as the admin SendGrid connectivity-test fixture only
// (see `EmailTemplateIds.operatorInviteFirstAdmin` doc string and
// `tool/advisor_proxy/admin_email_routes.dart`). C-2 Draft A and
// addendum B4 path 1 both ratified Firebase as the production
// invite email; Q-3 promotes that ratification from
// decision-doc-only to source-of-truth comment so future readers
// see the split without grepping decision docs.
//
// Source: `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md`
// Draft A; addendum B4 path 1; `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md`
// row BC-1.

class InviteRequest {
  const InviteRequest({
    required this.email,
    required this.operatorId,
    required this.roleId,
    this.locationId,
  });

  final String email;
  final String operatorId;
  final String roleId;
  final String? locationId;
}

class InviteRecord {
  InviteRecord({
    required this.inviteId,
    required this.email,
    required this.operatorId,
    required this.roleId,
    required this.locationId,
    required this.invitedBy,
    required this.createdAt,
    required this.expiresAt,
    required this.tokenHash,
    this.acceptedAt,
    this.revokedAt,
  });

  final String inviteId;
  final String email;
  final String operatorId;
  final String roleId;
  final String? locationId;
  final String invitedBy;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String tokenHash;
  DateTime? acceptedAt;
  DateTime? revokedAt;

  bool get isPending =>
      acceptedAt == null && revokedAt == null;

  bool isExpiredAt(DateTime now) =>
      !now.isBefore(expiresAt);

  bool isAcceptableAt(DateTime now) =>
      isPending && !isExpiredAt(now);
}

class UserInviteService {
  UserInviteService({
    DateTime Function()? now,
    Duration ttl = defaultInviteTtl,
  }) : _now = now ?? DateTime.now,
       _ttl = ttl;

  /// Locked decision: invites expire after 7 days.
  static const Duration defaultInviteTtl = Duration(days: 7);

  final DateTime Function() _now;
  final Duration _ttl;

  /// Builds an [InviteRecord] with `expiresAt = now + 7d`. The
  /// proxy persists the record in `auth_invites` (Phase 9.0
  /// schema) and dispatches a Firebase magic-link email to the
  /// branded action page.
  InviteRecord createInvite({
    required String inviteId,
    required InviteRequest request,
    required String invitedByUserId,
    required String tokenHash,
  }) {
    final created = _now();
    return InviteRecord(
      inviteId: inviteId,
      email: request.email,
      operatorId: request.operatorId,
      roleId: request.roleId,
      locationId: request.locationId,
      invitedBy: invitedByUserId,
      createdAt: created,
      expiresAt: created.add(_ttl),
      tokenHash: tokenHash,
    );
  }

  /// Accepts a pending invite. Throws [InviteError] when:
  ///   - already accepted
  ///   - already revoked
  ///   - expired
  /// Mutates the record so the caller can persist the
  /// `accepted_at` value.
  void acceptInvite(InviteRecord record) {
    final now = _now();
    if (record.acceptedAt != null) {
      throw InviteError('invite was already accepted');
    }
    if (record.revokedAt != null) {
      throw InviteError('invite was revoked');
    }
    if (record.isExpiredAt(now)) {
      throw InviteError('invite expired');
    }
    record.acceptedAt = now;
  }

  /// Revokes a pending invite. Idempotent — calling revoke on an
  /// already-revoked / accepted invite is a no-op (returns false to
  /// signal that the caller should NOT emit a duplicate audit row).
  bool revokeInvite(InviteRecord record) {
    if (record.acceptedAt != null) return false;
    if (record.revokedAt != null) return false;
    record.revokedAt = _now();
    return true;
  }
}

class InviteError implements Exception {
  InviteError(this.message);

  final String message;

  @override
  String toString() => 'InviteError: $message';
}

/// Trusted user creation (no invite email) — F&F super_admin only
/// per the decision lock. The proxy calls [evaluate] BEFORE invoking
/// `firebase_auth.Admin.createUser` so an unauthorized actor cannot
/// even reach Firebase.
abstract class TrustedUserCreationPolicy {
  TrustedUserCreationPolicy._();

  /// Returns true iff [actorRoles] include `super_admin`.
  /// Operator owners + ff_support cannot use this path; they must
  /// go through the invite flow.
  static bool isAllowedFor(Iterable<String> actorRoles) {
    for (final role in actorRoles) {
      if (role.trim().toLowerCase() == 'super_admin') return true;
    }
    return false;
  }
}
