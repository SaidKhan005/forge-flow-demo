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
