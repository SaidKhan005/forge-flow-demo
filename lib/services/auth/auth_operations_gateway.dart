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

abstract class AuthOperationsGateway {
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
