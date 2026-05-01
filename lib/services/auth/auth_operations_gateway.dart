// Phase 9 live-closeout - proxy auth-operations gateway.
//
// This is the proxy-facing seam for Team/user-management actions. The HTTP
// router validates request shape, verifies the Firebase bearer token, checks
// permissions, and then delegates to this gateway. Production implementations
// own the multi-system write choreography: Firebase Identity Platform,
// Postgres users/auth_invites/user_roles, custom claims, and audit rows.

class TeamInviteCreateCommand {
  const TeamInviteCreateCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.email,
    required this.roleId,
    required this.scopeType,
    this.targetLocationId,
    this.targetOrgUnitId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String email;
  final String roleId;
  final String scopeType;
  final String? targetLocationId;
  final String? targetOrgUnitId;
}

class TeamInviteCreated {
  const TeamInviteCreated({
    required this.inviteId,
    required this.expiresAt,
    this.userId,
  });

  final String inviteId;
  final DateTime expiresAt;

  /// Postgres/Firebase user id created for the invite when the backing gateway
  /// owns identity creation. HTTP clients may omit it from the public response;
  /// server-side orchestration such as 11A.1 onboarding uses it to attach
  /// `operator_admins` without fabricating a second user row.
  final String? userId;
}

class TeamInviteListCommand {
  const TeamInviteListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

class TeamInviteListEntry {
  const TeamInviteListEntry({
    required this.inviteId,
    required this.email,
    required this.roleId,
    required this.roleLabel,
    required this.scopeType,
    required this.expiresAt,
    required this.createdAt,
    this.locationId,
    this.locationLabel,
    this.orgUnitId,
    this.orgUnitLabel,
  });

  final String inviteId;
  final String email;
  final String roleId;
  final String roleLabel;
  final String scopeType;
  final String? locationId;
  final String? locationLabel;
  final String? orgUnitId;
  final String? orgUnitLabel;
  final DateTime expiresAt;
  final DateTime createdAt;
}

class TeamInvitesListed {
  const TeamInvitesListed({required this.invites});

  final List<TeamInviteListEntry> invites;
}

class TeamInviteRevokeCommand {
  const TeamInviteRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.inviteId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String inviteId;
}

class TeamInviteRevoked {
  const TeamInviteRevoked({required this.revoked});

  final bool revoked;
}

class TeamUserStatusCommand {
  const TeamUserStatusCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    required this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String reason;
}

class TeamUserStatusUpdated {
  const TeamUserStatusUpdated({required this.updated});

  final bool updated;
}

class TeamUserListCommand {
  const TeamUserListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

// Phase 9.UX.grant-payload — per-grant snapshot bundled with the team-users
// projection. Mirrors the `user_roles` row shape consumed by the role-change
// dialog's inheritance hint, plus the materialized
// `user_effective_locations` set so an `org_unit` grant carries its
// reachable locations without a follow-up read. Optional / nullable fields
// stay nullable so a `location`-scoped grant (no `org_unit_id`) and an
// `operator_wide` grant (neither location nor org-unit) round-trip cleanly.
class TeamGrantSnapshot {
  const TeamGrantSnapshot({
    required this.userRoleId,
    required this.roleId,
    required this.scopeType,
    this.roleLabel,
    this.orgUnitId,
    this.locationId,
    this.sourceOrgUnitId,
    this.effectiveLocationIds = const <String>[],
    this.validFrom,
    this.validUntil,
    this.revokedAt,
  });

  final String userRoleId;
  final String roleId;

  /// `roles.display_name` for the granted role, joined into the
  /// gateway projection so the role-change dialog never needs the
  /// section's role catalog to resolve a label. Optional for
  /// backward compat with older proxies that might omit the field;
  /// when null the section falls through to its catalog/raw-id
  /// resolver.
  final String? roleLabel;

  /// One of `'operator_wide'`, `'org_unit'`, or `'location'` — matches
  /// the `user_roles.scope_type` CHECK constraint.
  final String scopeType;
  final String? orgUnitId;
  final String? locationId;
  final String? sourceOrgUnitId;
  final List<String> effectiveLocationIds;
  final DateTime? validFrom;
  final DateTime? validUntil;
  final DateTime? revokedAt;
}

class TeamUserListEntry {
  const TeamUserListEntry({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.roleId,
    required this.roleLabel,
    required this.status,
    this.locationId,
    this.locationLabel,
    this.mfaEnrolled = false,
    this.mfaRemovalPending = false,
    this.mfaRemovalRequestId,
    this.userRoleId,
    this.lastActiveAt,
    this.grants = const <TeamGrantSnapshot>[],
  });

  final String userId;
  final String email;
  final String displayName;
  final String roleId;
  final String roleLabel;
  final String status;
  final String? locationId;
  final String? locationLabel;
  final bool mfaEnrolled;
  final bool mfaRemovalPending;
  final String? mfaRemovalRequestId;
  final String? userRoleId;
  final DateTime? lastActiveAt;
  final List<TeamGrantSnapshot> grants;
}

class TeamUsersListed {
  const TeamUsersListed({required this.users});

  final List<TeamUserListEntry> users;
}

class TeamPasswordResetCommand {
  const TeamPasswordResetCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
}

class TeamPasswordResetQueued {
  const TeamPasswordResetQueued();
}

class TeamMfaResetCommand {
  const TeamMfaResetCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    this.stepUpProofId = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String stepUpProofId;
}

class TeamMfaResetQueued {
  const TeamMfaResetQueued({
    required this.requestedCount,
    this.requestIds = const <String>[],
    this.executeAfter,
  });

  final int requestedCount;
  final List<String> requestIds;
  final DateTime? executeAfter;
}

class TeamMfaRemovalCancelCommand {
  const TeamMfaRemovalCancelCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    required this.requestId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String requestId;
}

class TeamMfaRemovalCancelled {
  const TeamMfaRemovalCancelled({required this.cancelled});

  final bool cancelled;
}

class TeamRoleGrantCreateCommand {
  const TeamRoleGrantCreateCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    required this.roleId,
    required this.scopeType,
    this.targetLocationId,
    this.targetOrgUnitId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String roleId;
  final String scopeType;
  final String? targetLocationId;
  final String? targetOrgUnitId;
  final String? reason;
}

class TeamRoleGrantCreated {
  const TeamRoleGrantCreated({required this.userRoleId});

  final String userRoleId;
}

class TeamRoleGrantRevokeCommand {
  const TeamRoleGrantRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.userRoleId,
    required this.targetUserId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String userRoleId;
  final String targetUserId;
  final String? reason;
}

class TeamRoleGrantRevoked {
  const TeamRoleGrantRevoked({required this.revoked});

  final bool revoked;
}

// Phase 9.UX.4 — operator org hierarchy.
//
// `org_units` is the per-operator corp/region/district/location_group
// hierarchy stored as a Postgres `ltree` (item 1 / Q2 from
// `phase_9_scalability_decisions_2026-04-27.md`). The Settings → Team →
// Org Hierarchy surface uses these commands to render the tree, add
// child units, and move locations between units. Permission grants at
// any node inherit to descendants; the `user_effective_locations`
// materialized cache from the `202604290101_phase_9_hierarchy_access_wiring`
// migration handles the lookup.
class TeamOrgUnitEntry {
  const TeamOrgUnitEntry({
    required this.orgUnitId,
    required this.parentOrgUnitId,
    required this.unitType,
    required this.path,
    required this.label,
  });

  final String orgUnitId;
  final String? parentOrgUnitId;
  final String unitType;
  final String path;
  final String label;
}

class TeamOrgLocationEntry {
  const TeamOrgLocationEntry({
    required this.locationId,
    required this.parentOrgUnitId,
    required this.orgUnitPath,
    required this.label,
  });

  final String locationId;
  final String parentOrgUnitId;
  final String orgUnitPath;
  final String label;
}

class TeamOrgHierarchyListCommand {
  const TeamOrgHierarchyListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

class TeamOrgHierarchyListed {
  const TeamOrgHierarchyListed({
    required this.orgUnits,
    required this.locations,
  });

  final List<TeamOrgUnitEntry> orgUnits;
  final List<TeamOrgLocationEntry> locations;
}

class TeamOrgUnitCreateCommand {
  const TeamOrgUnitCreateCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.parentOrgUnitId,
    required this.unitType,
    required this.label,
    required this.name,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String parentOrgUnitId;
  final String unitType;
  final String label;
  final String name;
}

class TeamOrgUnitCreated {
  const TeamOrgUnitCreated({required this.orgUnitId});

  final String orgUnitId;
}

class TeamLocationOrgUnitMoveCommand {
  const TeamLocationOrgUnitMoveCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetLocationId,
    required this.parentOrgUnitId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetLocationId;
  final String parentOrgUnitId;
}

class TeamLocationOrgUnitMoved {
  const TeamLocationOrgUnitMoved({required this.moved});

  final bool moved;
}

class TeamRolePermissionRule {
  const TeamRolePermissionRule({
    required this.permissionKey,
    required this.effect,
  });

  final String permissionKey;

  /// Either `'allow'` or `'deny'`.
  final String effect;
}

class TeamRolePermissionUpdate {
  const TeamRolePermissionUpdate({
    required this.permissionKey,
    required this.effect,
  });

  final String permissionKey;

  /// `'allow'` / `'deny'` upserts a rule. `null` removes the explicit
  /// rule so the permission falls back to inherited/default behavior.
  final String? effect;
}

class TeamRoleCatalogEntry {
  const TeamRoleCatalogEntry({
    required this.roleId,
    required this.roleKey,
    required this.displayName,
    required this.description,
    required this.isSeeded,
    required this.isEditable,
    required this.permissions,
    this.operatorId,
  });

  final String roleId;
  final String roleKey;
  final String displayName;
  final String description;
  final bool isSeeded;
  final bool isEditable;
  final String? operatorId;
  final List<TeamRolePermissionRule> permissions;
}

class TeamRoleCatalogListCommand {
  const TeamRoleCatalogListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.scope,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;

  /// `all` (default), `global` / `seeded`, or `operator` / `custom`.
  final String? scope;
}

class TeamRoleCatalogListed {
  const TeamRoleCatalogListed({required this.roles});

  final List<TeamRoleCatalogEntry> roles;
}

class TeamRoleCreateCommand {
  const TeamRoleCreateCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.roleKey,
    required this.displayName,
    this.description = '',
    this.permissions = const <TeamRolePermissionUpdate>[],
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String roleKey;
  final String displayName;
  final String description;
  final List<TeamRolePermissionUpdate> permissions;
  final String? reason;
}

class TeamRoleCreated {
  const TeamRoleCreated({required this.role});

  final TeamRoleCatalogEntry role;
}

class TeamRolePatchCommand {
  const TeamRolePatchCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.roleId,
    this.displayName,
    this.description,
    this.permissions = const <TeamRolePermissionUpdate>[],
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String roleId;
  final String? displayName;
  final String? description;
  final List<TeamRolePermissionUpdate> permissions;
  final String? reason;
}

class TeamRolePatched {
  const TeamRolePatched({required this.role, required this.bumpedUsers});

  final TeamRoleCatalogEntry role;
  final int bumpedUsers;
}

class TeamRoleDeleteCommand {
  const TeamRoleDeleteCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.roleId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String roleId;
  final String? reason;
}

class TeamRoleDeleted {
  const TeamRoleDeleted({required this.deleted});

  final bool deleted;
}

// Phase 9.UX.1 - self-service MFA factor contract declarations.
//
// The live Settings MFA surface is wired through MfaOperationsGateway. These
// additive value types reserve the auth-operations contract shape for clients
// that need to project a user's own factor inventory through the broader auth
// operations seam without disturbing the Team/role/org methods below.
class MfaSelfFactorSummary {
  const MfaSelfFactorSummary({
    required this.factorId,
    required this.factorType,
    required this.enrolledAt,
    required this.issuerLabel,
    this.lastUsedAt,
    this.canRevoke = true,
  });

  final String factorId;
  final String factorType;
  final DateTime enrolledAt;
  final DateTime? lastUsedAt;
  final String issuerLabel;
  final bool canRevoke;
}

class MfaSelfFactorListCommand {
  const MfaSelfFactorListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.authorizationIdToken = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String authorizationIdToken;
}

class MfaSelfFactorListed {
  const MfaSelfFactorListed({required this.factors});

  final List<MfaSelfFactorSummary> factors;
}

class MfaSelfFactorRevokeCommand {
  const MfaSelfFactorRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.factorId,
    this.stepUpProofId = '',
    this.authorizationIdToken = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String factorId;
  final String stepUpProofId;
  final String authorizationIdToken;
}

class MfaSelfFactorRevoked {
  const MfaSelfFactorRevoked({
    required this.revoked,
    this.requestId,
    this.executeAfter,
  });

  final bool revoked;
  final String? requestId;
  final DateTime? executeAfter;
}

// Phase 9.UX.5 — self-service Active Sessions viewer.
//
// Operators inspect and revoke their own auth_sessions ledger rows
// from Settings → Account → Active Sessions. The DTOs intentionally
// stay thin — only metadata that helps a person recognise their own
// device (UA / approximate location / last-seen time) is surfaced;
// raw token material never crosses this seam.

class AuthSessionSummary {
  const AuthSessionSummary({
    required this.sessionId,
    required this.createdAt,
    required this.lastSeenAt,
    this.deviceLabel,
    this.userAgent,
    this.ip,
    this.geoCountry,
    this.deviceFingerprint,
    this.revokedAt,
    this.revokedReason,
  });

  final String sessionId;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  /// Friendly label the proxy/repository can derive (e.g. parsed
  /// browser / OS pairing). Optional — UI falls back to the raw UA.
  final String? deviceLabel;
  final String? userAgent;
  final String? ip;

  /// ISO-3166 alpha-2 country code captured at login time.
  final String? geoCountry;
  final String? deviceFingerprint;
  final DateTime? revokedAt;
  final String? revokedReason;
}

class AuthActiveSessionsListCommand {
  const AuthActiveSessionsListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

class AuthActiveSessionsListed {
  const AuthActiveSessionsListed({required this.sessions});

  final List<AuthSessionSummary> sessions;
}

class AuthSessionRevokeCommand {
  const AuthSessionRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.sessionId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String sessionId;
  final String? reason;
}

class AuthSessionRevoked {
  const AuthSessionRevoked({required this.revoked});

  final bool revoked;
}

class AuthAllSessionsRevokeCommand {
  const AuthAllSessionsRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String? reason;
}

class AuthAllSessionsRevoked {
  const AuthAllSessionsRevoked({required this.revokedCount});

  final int revokedCount;
}

class AuthOperationRejected implements Exception {
  const AuthOperationRejected({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  final String code;
  final String message;
  final int statusCode;

  @override
  String toString() => 'AuthOperationRejected(code: $code)';
}

abstract class AuthOperationsGateway {
  Future<TeamUsersListed> listUsers(TeamUserListCommand command);

  Future<TeamRoleCatalogListed> listRoles(TeamRoleCatalogListCommand command);

  Future<TeamRoleCreated> createRole(TeamRoleCreateCommand command);

  Future<TeamRolePatched> patchRole(TeamRolePatchCommand command);

  Future<TeamRoleDeleted> deleteRole(TeamRoleDeleteCommand command);

  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command);

  Future<TeamInviteCreated> createInvite(TeamInviteCreateCommand command);

  Future<TeamInviteRevoked> revokeInvite(TeamInviteRevokeCommand command);

  Future<TeamUserStatusUpdated> suspendUser(TeamUserStatusCommand command);

  Future<TeamUserStatusUpdated> reactivateUser(TeamUserStatusCommand command);

  Future<TeamUserStatusUpdated> softDeleteUser(TeamUserStatusCommand command);

  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command,
  );

  Future<TeamMfaResetQueued> requestMfaReset(TeamMfaResetCommand command);

  Future<TeamMfaRemovalCancelled> cancelMfaRemoval(
    TeamMfaRemovalCancelCommand command,
  );

  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command,
  );

  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command,
  );

  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  );

  Future<TeamOrgUnitCreated> createOrgUnit(TeamOrgUnitCreateCommand command);

  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command,
  );

  // Phase 9.UX.5 — self-service Active Sessions surface.
  Future<AuthActiveSessionsListed> listActiveSessions(
    AuthActiveSessionsListCommand command,
  );

  Future<AuthSessionRevoked> revokeSession(AuthSessionRevokeCommand command);

  Future<AuthAllSessionsRevoked> signOutAll(
    AuthAllSessionsRevokeCommand command,
  );
}

class ScaffoldFailingAuthOperationsGateway implements AuthOperationsGateway {
  const ScaffoldFailingAuthOperationsGateway();

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamRoleCatalogListed> listRoles(TeamRoleCatalogListCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamRoleCreated> createRole(TeamRoleCreateCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamRolePatched> patchRole(TeamRolePatchCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamRoleDeleted> deleteRole(TeamRoleDeleteCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamInviteCreated> createInvite(TeamInviteCreateCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamInviteRevoked> revokeInvite(TeamInviteRevokeCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamUserStatusUpdated> suspendUser(TeamUserStatusCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamUserStatusUpdated> reactivateUser(TeamUserStatusCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamUserStatusUpdated> softDeleteUser(TeamUserStatusCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamMfaResetQueued> requestMfaReset(TeamMfaResetCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamMfaRemovalCancelled> cancelMfaRemoval(
    TeamMfaRemovalCancelCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(TeamOrgUnitCreateCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<AuthActiveSessionsListed> listActiveSessions(
    AuthActiveSessionsListCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<AuthSessionRevoked> revokeSession(AuthSessionRevokeCommand command) {
    throw StateError(_message);
  }

  @override
  Future<AuthAllSessionsRevoked> signOutAll(
    AuthAllSessionsRevokeCommand command,
  ) {
    throw StateError(_message);
  }

  static const String _message =
      'Phase 9 auth-operations gateway is not wired; bind the production '
      'gateway before exposing Team/user-management proxy routes.';
}
