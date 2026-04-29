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
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String email;
  final String roleId;
  final String scopeType;
  final String? targetLocationId;
}

class TeamInviteCreated {
  const TeamInviteCreated({required this.inviteId, required this.expiresAt});

  final String inviteId;
  final DateTime expiresAt;
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

class TeamRoleGrantCreateCommand {
  const TeamRoleGrantCreateCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    required this.roleId,
    required this.scopeType,
    this.targetLocationId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String roleId;
  final String scopeType;
  final String? targetLocationId;
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
  Future<TeamRoleCatalogListed> listRoles(TeamRoleCatalogListCommand command);

  Future<TeamRoleCreated> createRole(TeamRoleCreateCommand command);

  Future<TeamRolePatched> patchRole(TeamRolePatchCommand command);

  Future<TeamRoleDeleted> deleteRole(TeamRoleDeleteCommand command);

  Future<TeamInviteCreated> createInvite(TeamInviteCreateCommand command);

  Future<TeamInviteRevoked> revokeInvite(TeamInviteRevokeCommand command);

  Future<TeamUserStatusUpdated> suspendUser(TeamUserStatusCommand command);

  Future<TeamUserStatusUpdated> reactivateUser(TeamUserStatusCommand command);

  Future<TeamUserStatusUpdated> softDeleteUser(TeamUserStatusCommand command);

  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command,
  );

  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command,
  );

  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command,
  );
}

class ScaffoldFailingAuthOperationsGateway implements AuthOperationsGateway {
  const ScaffoldFailingAuthOperationsGateway();

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

  static const String _message =
      'Phase 9 auth-operations gateway is not wired; bind the production '
      'gateway before exposing Team/user-management proxy routes.';
}
