// Phase 9 live-closeout - repository-backed auth operations gateway.
//
// Runs behind the advisor proxy. Owns the server-side choreography for
// Team/user-management writes: Firebase Identity Platform, Postgres auth
// repositories, role-version claims, and append-only audit rows.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/auth_invites_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/role_permissions_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/roles_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/user_roles_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'auth_operations_gateway.dart';
import 'firebase_admin_auth_client.dart';

class RepositoryAuthOperationsGateway implements AuthOperationsGateway {
  RepositoryAuthOperationsGateway({
    required this.firebaseAdmin,
    required this.usersRepository,
    required this.rolesRepository,
    required this.rolePermissionsRepository,
    required this.userRolesRepository,
    required this.authInvitesRepository,
    required this.auditRepository,
    DateTime Function()? now,
    String Function()? idFactory,
    String Function()? tokenFactory,
  }) : _now = now ?? DateTime.now,
       _idFactory = idFactory ?? _uuidV4,
       _tokenFactory = tokenFactory ?? _randomToken;

  final FirebaseAdminAuthClient firebaseAdmin;
  final UsersRepository usersRepository;
  final RolesRepository rolesRepository;
  final RolePermissionsRepository rolePermissionsRepository;
  final UserRolesRepository userRolesRepository;
  final AuthInvitesRepository authInvitesRepository;
  final AuthEventsAuditRepository auditRepository;
  final DateTime Function() _now;
  final String Function() _idFactory;
  final String Function() _tokenFactory;

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) async {
    final rows = await usersRepository.listTeamUsers(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
    );
    return TeamUsersListed(
      users: List<TeamUserListEntry>.unmodifiable(
        rows.map(
          (row) => TeamUserListEntry(
            userId: row.userId,
            email: row.email,
            displayName: row.displayName,
            roleId: row.roleId,
            roleLabel: row.roleLabel,
            status: row.status,
            locationId: row.locationId,
            locationLabel: row.locationLabel,
            mfaEnrolled: row.mfaEnrolled,
            userRoleId: row.userRoleId,
            lastActiveAt: row.lastActiveAt,
          ),
        ),
      ),
    );
  }

  @override
  Future<TeamRoleCatalogListed> listRoles(
    TeamRoleCatalogListCommand command,
  ) async {
    final roles = await rolesRepository.listVisibleRoles(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
    );
    final entries = <TeamRoleCatalogEntry>[];
    for (final role in roles) {
      if (!_scopeIncludesRole(command.scope, command.operatorId, role)) {
        continue;
      }
      entries.add(await _roleEntry(command, role));
    }
    return TeamRoleCatalogListed(
      roles: List<TeamRoleCatalogEntry>.unmodifiable(entries),
    );
  }

  @override
  Future<TeamRoleCreated> createRole(TeamRoleCreateCommand command) async {
    final roleKey = _roleKey(command.roleKey);
    final displayName = _requiredTrimmed(command.displayName, 'displayName');
    final description = command.description.trim();
    final roleId = await rolesRepository.insertOperatorRole(
      operatorId: command.operatorId,
      locationId: command.locationId,
      createdByUserId: command.actorUserId,
      roleKey: roleKey,
      displayName: displayName,
      description: description,
    );
    await _applyRolePermissionUpdates(
      command: command,
      roleId: roleId,
      updates: command.permissions,
    );
    await _audit(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      eventType: 'auth.custom_role_created',
      payload: <String, Object?>{
        'role_id': roleId,
        'role_key': roleKey,
        if (command.reason != null) 'reason': command.reason,
      },
    );
    final role = await rolesRepository.visibleRoleById(
      operatorId: command.operatorId,
      locationId: command.locationId,
      roleId: roleId,
      actorUserId: command.actorUserId,
    );
    return TeamRoleCreated(role: await _roleEntry(command, role));
  }

  @override
  Future<TeamRolePatched> patchRole(TeamRolePatchCommand command) async {
    await _customRoleForMutation(command);
    final displayName = _optionalTrimmed(command.displayName, 'displayName');
    final description = command.description?.trim();
    var metadataChanged = false;
    if (displayName != null || description != null) {
      metadataChanged =
          await rolesRepository.updateOperatorRole(
            operatorId: command.operatorId,
            locationId: command.locationId,
            updatedByUserId: command.actorUserId,
            roleId: command.roleId,
            displayName: displayName,
            description: description,
          ) >
          0;
    }
    final permissionChanges = await _applyRolePermissionUpdates(
      command: command,
      roleId: command.roleId,
      updates: command.permissions,
    );
    var bumpedUsers = 0;
    if (metadataChanged || permissionChanges > 0) {
      bumpedUsers = await userRolesRepository.bumpActiveGrantHoldersForRole(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        roleId: command.roleId,
      );
      await _audit(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        eventType: 'auth.custom_role_updated',
        payload: <String, Object?>{
          'role_id': command.roleId,
          'permission_changes': permissionChanges,
          'metadata_changed': metadataChanged,
          'bumped_users': bumpedUsers,
          if (command.reason != null) 'reason': command.reason,
        },
      );
    }
    final role = await rolesRepository.visibleRoleById(
      operatorId: command.operatorId,
      locationId: command.locationId,
      roleId: command.roleId,
      actorUserId: command.actorUserId,
    );
    return TeamRolePatched(
      role: await _roleEntry(command, role),
      bumpedUsers: bumpedUsers,
    );
  }

  @override
  Future<TeamRoleDeleted> deleteRole(TeamRoleDeleteCommand command) async {
    await _customRoleForMutation(command);
    int affected;
    try {
      affected = await rolesRepository.softDeleteOperatorRole(
        operatorId: command.operatorId,
        locationId: command.locationId,
        updatedByUserId: command.actorUserId,
        roleId: command.roleId,
      );
    } on StateError catch (error) {
      if (error.message.contains('active user_roles grants')) {
        throw const AuthOperationRejected(
          code: 'role_has_active_grants',
          message: 'custom role still has active grants',
          statusCode: 409,
        );
      }
      rethrow;
    }
    if (affected > 0) {
      await _audit(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        eventType: 'auth.custom_role_deleted',
        payload: <String, Object?>{
          'role_id': command.roleId,
          if (command.reason != null) 'reason': command.reason,
        },
      );
    }
    return TeamRoleDeleted(deleted: affected > 0);
  }

  @override
  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command) async {
    final rows = await authInvitesRepository.listPendingInvites(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
    );
    return TeamInvitesListed(
      invites: List<TeamInviteListEntry>.unmodifiable(
        rows.map(
          (row) => TeamInviteListEntry(
            inviteId: row.inviteId,
            email: row.email,
            roleId: row.roleId,
            roleLabel: row.roleLabel,
            scopeType: row.scopeType,
            locationId: row.locationId,
            locationLabel: row.locationLabel,
            orgUnitId: row.orgUnitId,
            orgUnitLabel: row.orgUnitLabel,
            expiresAt: row.expiresAt,
            createdAt: row.createdAt,
          ),
        ),
      ),
    );
  }

  @override
  Future<TeamInviteCreated> createInvite(
    TeamInviteCreateCommand command,
  ) async {
    final scopeType = _scopeFromCommand(command.scopeType);
    _validateScopePayload(
      scopeType: scopeType,
      targetLocationId: command.targetLocationId,
      targetOrgUnitId: command.targetOrgUnitId,
    );
    final roleId = await _resolveRoleId(command);
    final userId = _idFactory();
    final defaultLocationId = command.targetLocationId ?? command.locationId;
    final expiresAt = _now().toUtc().add(const Duration(days: 7));
    final claims = await _claimsForUser(
      userId: userId,
      operatorId: command.operatorId,
      locationId: defaultLocationId,
      rolesVersion: 1,
    );

    try {
      await firebaseAdmin.createUser(
        uid: userId,
        email: command.email,
        customClaims: claims,
      );
    } on FirebaseAdminAuthError catch (error) {
      if (error.code == 'email_exists') {
        throw const AuthOperationRejected(
          code: 'invite_email_already_exists',
          message: 'an account with this email already exists',
          statusCode: 409,
        );
      }
      rethrow;
    }
    await usersRepository.insertInvitedUser(
      userId: userId,
      firebaseUid: userId,
      operatorId: command.operatorId,
      email: command.email,
      primaryRoleId: roleId,
      primaryLocationId: defaultLocationId,
      adminReason: 'team.invite_create',
    );
    final userRoleId = await userRolesRepository.insertGrant(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      targetUserId: userId,
      roleId: roleId,
      scopeType: scopeType,
      grantLocationId: command.targetLocationId,
      grantOrgUnitId: command.targetOrgUnitId,
      reason: 'team.invite_create',
    );
    final inviteId = await authInvitesRepository.insertInvite(
      operatorId: command.operatorId,
      locationId: command.locationId,
      email: command.email,
      roleId: roleId,
      scopeType: scopeType.sqlKey,
      invitedByUserId: command.actorUserId,
      expiresAt: expiresAt,
      tokenHash: _sha256(_tokenFactory()),
      targetLocationId: command.targetLocationId,
      targetOrgUnitId: command.targetOrgUnitId,
    );
    final rolesVersion = await usersRepository.rolesVersionForUser(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: userId,
      actorUserId: command.actorUserId,
    );
    await firebaseAdmin.setCustomClaims(
      uid: userId,
      customClaims: await _claimsForUser(
        userId: userId,
        operatorId: command.operatorId,
        locationId: defaultLocationId,
        rolesVersion: rolesVersion,
      ),
    );
    await firebaseAdmin.sendPasswordResetEmail(email: command.email);
    await _audit(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      targetUserId: userId,
      eventType: 'auth.invite_created',
      payload: <String, Object?>{
        'invite_id': inviteId,
        'user_role_id': userRoleId,
        'scope_type': scopeType.sqlKey,
        if (command.targetLocationId != null)
          'location_id': command.targetLocationId,
        if (command.targetOrgUnitId != null)
          'org_unit_id': command.targetOrgUnitId,
      },
    );
    return TeamInviteCreated(inviteId: inviteId, expiresAt: expiresAt);
  }

  @override
  Future<TeamInviteRevoked> revokeInvite(
    TeamInviteRevokeCommand command,
  ) async {
    final affected = await authInvitesRepository.revokeInvite(
      operatorId: command.operatorId,
      locationId: command.locationId,
      inviteId: command.inviteId,
      actorUserId: command.actorUserId,
    );
    if (affected > 0) {
      await _audit(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        eventType: 'auth.invite_revoked',
        payload: <String, Object?>{'invite_id': command.inviteId},
      );
    }
    return TeamInviteRevoked(revoked: affected > 0);
  }

  @override
  Future<TeamUserStatusUpdated> suspendUser(
    TeamUserStatusCommand command,
  ) async {
    return _updateUserStatus(command, 'suspended', true, 'auth.user_suspended');
  }

  @override
  Future<TeamUserStatusUpdated> reactivateUser(
    TeamUserStatusCommand command,
  ) async {
    return _updateUserStatus(command, 'active', false, 'auth.user_reactivated');
  }

  @override
  Future<TeamUserStatusUpdated> softDeleteUser(
    TeamUserStatusCommand command,
  ) async {
    final firebaseUid = await _firebaseUid(command);
    await firebaseAdmin.setDisabled(uid: firebaseUid, disabled: true);
    final affected = await usersRepository.softDelete(
      userId: command.targetUserId,
      adminReason: command.reason,
    );
    if (affected > 0) {
      await _audit(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        targetUserId: command.targetUserId,
        eventType: 'auth.user_soft_deleted',
        payload: <String, Object?>{'reason': command.reason},
      );
    }
    return TeamUserStatusUpdated(updated: affected > 0);
  }

  @override
  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command,
  ) async {
    final email = await usersRepository.emailForUser(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.targetUserId,
      actorUserId: command.actorUserId,
    );
    await firebaseAdmin.sendPasswordResetEmail(email: email);
    await _audit(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      targetUserId: command.targetUserId,
      eventType: 'auth.password_reset_requested',
    );
    return const TeamPasswordResetQueued();
  }

  @override
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command,
  ) async {
    final scopeType = _scopeFromCommand(command.scopeType);
    _validateScopePayload(
      scopeType: scopeType,
      targetLocationId: command.targetLocationId,
      targetOrgUnitId: command.targetOrgUnitId,
    );
    final roleId = await _resolveRoleGrantRoleId(command);
    final id = await userRolesRepository.insertGrant(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      targetUserId: command.targetUserId,
      roleId: roleId,
      scopeType: scopeType,
      grantLocationId: command.targetLocationId,
      grantOrgUnitId: command.targetOrgUnitId,
      reason: command.reason,
    );
    await _refreshTargetClaims(command);
    await _audit(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      targetUserId: command.targetUserId,
      eventType: 'auth.role_grant_created',
      payload: <String, Object?>{
        'user_role_id': id,
        'scope_type': scopeType.sqlKey,
        if (command.targetLocationId != null)
          'location_id': command.targetLocationId,
        if (command.targetOrgUnitId != null)
          'org_unit_id': command.targetOrgUnitId,
      },
    );
    return TeamRoleGrantCreated(userRoleId: id);
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command,
  ) async {
    final affected = await userRolesRepository.revokeGrant(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      userRoleId: command.userRoleId,
      targetUserId: command.targetUserId,
      reason: command.reason,
    );
    await _refreshTargetClaims(command);
    if (affected > 0) {
      await _audit(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        targetUserId: command.targetUserId,
        eventType: 'auth.role_grant_revoked',
        payload: <String, Object?>{'user_role_id': command.userRoleId},
      );
    }
    return TeamRoleGrantRevoked(revoked: affected > 0);
  }

  Future<TeamUserStatusUpdated> _updateUserStatus(
    TeamUserStatusCommand command,
    String status,
    bool disabled,
    String eventType,
  ) async {
    final firebaseUid = await _firebaseUid(command);
    await firebaseAdmin.setDisabled(uid: firebaseUid, disabled: disabled);
    final affected = await usersRepository.updateStatus(
      userId: command.targetUserId,
      newStatus: status,
      adminReason: command.reason,
    );
    if (affected > 0) {
      await _audit(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        targetUserId: command.targetUserId,
        eventType: eventType,
        payload: <String, Object?>{'reason': command.reason},
      );
    }
    return TeamUserStatusUpdated(updated: affected > 0);
  }

  Future<String> _firebaseUid(TeamUserStatusCommand command) {
    return usersRepository.firebaseUidForUser(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.targetUserId,
      actorUserId: command.actorUserId,
    );
  }

  Future<void> _refreshTargetClaims(Object command) async {
    final actorUserId = switch (command) {
      TeamRoleGrantCreateCommand(:final actorUserId) => actorUserId,
      TeamRoleGrantRevokeCommand(:final actorUserId) => actorUserId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final operatorId = switch (command) {
      TeamRoleGrantCreateCommand(:final operatorId) => operatorId,
      TeamRoleGrantRevokeCommand(:final operatorId) => operatorId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final locationId = switch (command) {
      TeamRoleGrantCreateCommand(:final locationId) => locationId,
      TeamRoleGrantRevokeCommand(:final locationId) => locationId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final targetUserId = switch (command) {
      TeamRoleGrantCreateCommand(:final targetUserId) => targetUserId,
      TeamRoleGrantRevokeCommand(:final targetUserId) => targetUserId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final defaultLocationId = switch (command) {
      TeamRoleGrantCreateCommand(:final targetLocationId) =>
        targetLocationId ?? locationId,
      TeamRoleGrantRevokeCommand() => locationId,
      _ => locationId,
    };
    final firebaseUid = await usersRepository.firebaseUidForUser(
      operatorId: operatorId,
      locationId: locationId,
      userId: targetUserId,
      actorUserId: actorUserId,
    );
    final rolesVersion = await usersRepository.rolesVersionForUser(
      operatorId: operatorId,
      locationId: locationId,
      userId: targetUserId,
      actorUserId: actorUserId,
    );
    await firebaseAdmin.setCustomClaims(
      uid: firebaseUid,
      customClaims: await _claimsForUser(
        userId: targetUserId,
        operatorId: operatorId,
        locationId: defaultLocationId,
        rolesVersion: rolesVersion,
      ),
    );
  }

  Future<String> _resolveRoleId(TeamInviteCreateCommand command) {
    if (_looksLikeUuid(command.roleId)) return Future.value(command.roleId);
    return rolesRepository.roleIdForVisibleKey(
      operatorId: command.operatorId,
      locationId: command.locationId,
      roleKey: command.roleId,
      actorUserId: command.actorUserId,
    );
  }

  Future<String> _resolveRoleGrantRoleId(TeamRoleGrantCreateCommand command) {
    if (_looksLikeUuid(command.roleId)) return Future.value(command.roleId);
    return rolesRepository.roleIdForVisibleKey(
      operatorId: command.operatorId,
      locationId: command.locationId,
      roleKey: command.roleId,
      actorUserId: command.actorUserId,
    );
  }

  Future<TeamRoleCatalogEntry> _roleEntry(
    Object command,
    RoleRecord role,
  ) async {
    final operatorId = switch (command) {
      TeamRoleCatalogListCommand(:final operatorId) => operatorId,
      TeamRoleCreateCommand(:final operatorId) => operatorId,
      TeamRolePatchCommand(:final operatorId) => operatorId,
      TeamRoleDeleteCommand(:final operatorId) => operatorId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final locationId = switch (command) {
      TeamRoleCatalogListCommand(:final locationId) => locationId,
      TeamRoleCreateCommand(:final locationId) => locationId,
      TeamRolePatchCommand(:final locationId) => locationId,
      TeamRoleDeleteCommand(:final locationId) => locationId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final actorUserId = switch (command) {
      TeamRoleCatalogListCommand(:final actorUserId) => actorUserId,
      TeamRoleCreateCommand(:final actorUserId) => actorUserId,
      TeamRolePatchCommand(:final actorUserId) => actorUserId,
      TeamRoleDeleteCommand(:final actorUserId) => actorUserId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final permissionRows = await rolePermissionsRepository.listForRole(
      operatorId: operatorId,
      locationId: locationId,
      roleId: role.roleId,
      actorUserId: actorUserId,
    );
    return TeamRoleCatalogEntry(
      roleId: role.roleId,
      roleKey: role.roleKey,
      displayName: role.displayName,
      description: role.description,
      isSeeded: role.isSeeded,
      isEditable: role.isEditable,
      operatorId: role.operatorId,
      permissions: List<TeamRolePermissionRule>.unmodifiable(
        permissionRows.map(
          (row) => TeamRolePermissionRule(
            permissionKey: row.permissionKey,
            effect: row.effect,
          ),
        ),
      ),
    );
  }

  Future<RoleRecord> _customRoleForMutation(Object command) async {
    final operatorId = switch (command) {
      TeamRolePatchCommand(:final operatorId) => operatorId,
      TeamRoleDeleteCommand(:final operatorId) => operatorId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final locationId = switch (command) {
      TeamRolePatchCommand(:final locationId) => locationId,
      TeamRoleDeleteCommand(:final locationId) => locationId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final actorUserId = switch (command) {
      TeamRolePatchCommand(:final actorUserId) => actorUserId,
      TeamRoleDeleteCommand(:final actorUserId) => actorUserId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final roleId = switch (command) {
      TeamRolePatchCommand(:final roleId) => roleId,
      TeamRoleDeleteCommand(:final roleId) => roleId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final role = await rolesRepository.visibleRoleById(
      operatorId: operatorId,
      locationId: locationId,
      roleId: roleId,
      actorUserId: actorUserId,
    );
    if (role.operatorId != operatorId || role.isSeeded || !role.isEditable) {
      throw const AuthOperationRejected(
        code: 'role_not_editable',
        message: 'only editable operator-scoped custom roles can be changed',
        statusCode: 403,
      );
    }
    return role;
  }

  Future<int> _applyRolePermissionUpdates({
    required Object command,
    required String roleId,
    required List<TeamRolePermissionUpdate> updates,
  }) async {
    final operatorId = switch (command) {
      TeamRoleCreateCommand(:final operatorId) => operatorId,
      TeamRolePatchCommand(:final operatorId) => operatorId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final locationId = switch (command) {
      TeamRoleCreateCommand(:final locationId) => locationId,
      TeamRolePatchCommand(:final locationId) => locationId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final actorUserId = switch (command) {
      TeamRoleCreateCommand(:final actorUserId) => actorUserId,
      TeamRolePatchCommand(:final actorUserId) => actorUserId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    var changed = 0;
    final seen = <String>{};
    for (final update in updates) {
      final key = _requiredTrimmed(update.permissionKey, 'permissionKey');
      if (!seen.add(key)) {
        throw AuthOperationRejected(
          code: 'duplicate_permission_update',
          message: 'permission update for $key appears more than once',
          statusCode: 400,
        );
      }
      final effect = update.effect?.trim();
      if (effect == null || effect == 'inherit') {
        changed += await rolePermissionsRepository.deleteCell(
          operatorId: operatorId,
          locationId: locationId,
          updatedByUserId: actorUserId,
          roleId: roleId,
          permissionKey: key,
        );
        continue;
      }
      if (effect != 'allow' && effect != 'deny') {
        throw const AuthOperationRejected(
          code: 'invalid_permission_effect',
          message: "permission effect must be 'allow', 'deny', or 'inherit'",
          statusCode: 400,
        );
      }
      changed += await rolePermissionsRepository.upsertCell(
        operatorId: operatorId,
        locationId: locationId,
        updatedByUserId: actorUserId,
        roleId: roleId,
        permissionKey: key,
        effect: effect,
      );
    }
    return changed;
  }

  Future<Map<String, Object?>> _claimsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required int rolesVersion,
  }) async {
    return <String, Object?>{
      'postgres_user_id': userId,
      'operator_id': operatorId,
      'location_id': locationId,
      'roles_version': rolesVersion,
    };
  }

  Future<void> _audit({
    required String operatorId,
    required String locationId,
    required String eventType,
    String? actorUserId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
  }) async {
    await auditRepository.insertEvent(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      targetUserId: targetUserId,
      eventType: eventType,
      payload: payload,
    );
  }

  static UserRoleScope _scopeFromCommand(String scopeType) {
    return switch (scopeType) {
      'operator_wide' => UserRoleScope.operatorWide,
      'org_unit' => UserRoleScope.orgUnit,
      'location' => UserRoleScope.location,
      _ => throw const AuthOperationRejected(
        code: 'invalid_scope_type',
        message:
            "scope_type must be 'operator_wide', 'org_unit', or 'location'",
        statusCode: 400,
      ),
    };
  }

  static void _validateScopePayload({
    required UserRoleScope scopeType,
    required String? targetLocationId,
    required String? targetOrgUnitId,
  }) {
    final hasLocation = targetLocationId != null && targetLocationId.isNotEmpty;
    final hasOrgUnit = targetOrgUnitId != null && targetOrgUnitId.isNotEmpty;
    switch (scopeType) {
      case UserRoleScope.operatorWide:
        if (hasLocation || hasOrgUnit) {
          throw const AuthOperationRejected(
            code: 'invalid_scope_payload',
            message:
                'operator-wide scope cannot include a location or org unit',
            statusCode: 400,
          );
        }
      case UserRoleScope.location:
        if (!hasLocation || hasOrgUnit) {
          throw const AuthOperationRejected(
            code: 'invalid_scope_payload',
            message: 'location scope requires exactly one location',
            statusCode: 400,
          );
        }
      case UserRoleScope.orgUnit:
        if (!hasOrgUnit || hasLocation) {
          throw const AuthOperationRejected(
            code: 'invalid_scope_payload',
            message: 'org-unit scope requires exactly one org unit',
            statusCode: 400,
          );
        }
    }
  }

  static String _sha256(String value) {
    return sha256.convert(value.codeUnits).toString();
  }

  static bool _scopeIncludesRole(
    String? rawScope,
    String operatorId,
    RoleRecord role,
  ) {
    final scope = (rawScope ?? 'all').trim();
    switch (scope) {
      case '':
      case 'all':
        return true;
      case 'global':
      case 'seeded':
        return role.operatorId == null;
      case 'operator':
      case 'custom':
        return role.operatorId == operatorId;
      default:
        throw const AuthOperationRejected(
          code: 'invalid_role_scope',
          message: "role scope must be 'all', 'global', or 'operator'",
          statusCode: 400,
        );
    }
  }

  static String _roleKey(String value) {
    final trimmed = _requiredTrimmed(value, 'roleKey');
    final valid = RegExp(r'^[a-z][a-z0-9_]{2,63}$').hasMatch(trimmed);
    if (!valid) {
      throw const AuthOperationRejected(
        code: 'invalid_role_key',
        message:
            'role_key must start with a lowercase letter and contain only '
            'lowercase letters, numbers, and underscores',
        statusCode: 400,
      );
    }
    return trimmed;
  }

  static String _requiredTrimmed(String value, String fieldName) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw AuthOperationRejected(
        code: 'missing_$fieldName',
        message: '$fieldName is required',
        statusCode: 400,
      );
    }
    return trimmed;
  }

  static String? _optionalTrimmed(String? value, String fieldName) {
    if (value == null) return null;
    return _requiredTrimmed(value, fieldName);
  }

  static bool _looksLikeUuid(String value) {
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);
  }

  static String _uuidV4() {
    final random = math.Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-'
        '${hex(8, 10)}-${hex(10, 16)}';
  }

  static String _randomToken() => _uuidV4();
}
