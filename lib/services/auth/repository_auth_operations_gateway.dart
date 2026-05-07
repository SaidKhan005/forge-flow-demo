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
import '../../infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/org_units_repository.dart';
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
    AuthEventsAuditRepository? auditReadRepository,
    this.orgUnitsRepository,
    this.authSessionsRepository,
    DateTime Function()? now,
    String Function()? idFactory,
    String Function()? tokenFactory,
  }) : _auditReadRepository = auditReadRepository ?? auditRepository,
       _now = now ?? DateTime.now,
       _idFactory = idFactory ?? _uuidV4,
       _tokenFactory = tokenFactory ?? _randomToken;

  final FirebaseAdminAuthClient firebaseAdmin;
  final UsersRepository usersRepository;
  final RolesRepository rolesRepository;
  final RolePermissionsRepository rolePermissionsRepository;
  final UserRolesRepository userRolesRepository;
  final AuthInvitesRepository authInvitesRepository;
  final AuthEventsAuditRepository auditRepository;

  /// Phase 9.UX.6 — separate repository binding for read-only audit
  /// projections. Production wires this to the tenant pool so the
  /// per-tenant RLS policy is engaged; the writer-side
  /// [auditRepository] keeps its existing admin-pool binding so
  /// append-only inserts from cross-tenant admin paths still land.
  /// Tests and callers that don't care can omit it; it falls back to
  /// [auditRepository].
  final AuthEventsAuditRepository _auditReadRepository;
  final OrgUnitsRepository? orgUnitsRepository;
  final AuthSessionsRepository? authSessionsRepository;
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
            mfaRemovalPending: row.mfaRemovalPending,
            mfaRemovalRequestId: row.mfaRemovalRequestId,
            userRoleId: row.userRoleId,
            lastActiveAt: row.lastActiveAt,
            grants: _teamGrantSnapshotsFromRepositoryRows(row.grants),
          ),
        ),
      ),
    );
  }

  @override
  Future<TeamUserProfilePatched> patchUserProfile(
    TeamUserProfilePatchCommand command,
  ) async {
    final displayName = _requiredTrimmed(command.displayName, 'displayName');
    final reason = _requiredTrimmed(command.reason, 'reason');
    final before = await listUsers(
      TeamUserListCommand(
        actorUserId: command.actorUserId,
        operatorId: command.operatorId,
        locationId: command.locationId,
      ),
    );
    final beforeUser = _teamUserById(before.users, command.targetUserId);
    final affected = await usersRepository.updateDisplayName(
      operatorId: command.operatorId,
      userId: command.targetUserId,
      displayName: displayName,
      adminReason: reason,
    );
    final after = await listUsers(
      TeamUserListCommand(
        actorUserId: command.actorUserId,
        operatorId: command.operatorId,
        locationId: command.locationId,
      ),
    );
    final user = _teamUserById(after.users, command.targetUserId);
    if (user == null) {
      throw const AuthOperationRejected(
        code: 'user_not_found',
        message: 'team user was not found for this operator',
        statusCode: 404,
      );
    }
    if (affected > 0 && beforeUser?.displayName != displayName) {
      await _audit(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        targetUserId: command.targetUserId,
        eventType: 'auth.user_profile_updated',
        payload: <String, Object?>{
          'field': 'display_name',
          if (beforeUser != null)
            'previous_display_name': beforeUser.displayName,
          'display_name': displayName,
          'reason': reason,
        },
      );
    }
    return TeamUserProfilePatched(user: user);
  }

  static TeamUserListEntry? _teamUserById(
    List<TeamUserListEntry> users,
    String userId,
  ) {
    for (final user in users) {
      if (user.userId == userId) return user;
    }
    return null;
  }

  static List<TeamGrantSnapshot> _teamGrantSnapshotsFromRepositoryRows(
    List<TeamUserGrantRepositoryRow> rows,
  ) {
    if (rows.isEmpty) return const <TeamGrantSnapshot>[];
    return List<TeamGrantSnapshot>.unmodifiable(
      rows.map(
        (row) => TeamGrantSnapshot(
          userRoleId: row.userRoleId,
          roleId: row.roleId,
          roleLabel: row.roleLabel,
          scopeType: row.scopeType,
          orgUnitId: row.orgUnitId,
          locationId: row.locationId,
          sourceOrgUnitId: row.sourceOrgUnitId,
          effectiveLocationIds: row.effectiveLocationIds,
          validFrom: row.validFrom,
          validUntil: row.validUntil,
          revokedAt: row.revokedAt,
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
    if (command.operatorOwnerBootstrap) {
      _validateOperatorOwnerBootstrap(scopeType: scopeType, command: command);
    }
    // Phase 9 manager contract: location-scoped actors with
    // `team.users.invite` cannot broaden invite scope past their
    // assigned location. Operator-wide / org-unit invites require
    // an operator-wide grant whose role explicitly carries
    // `team.users.invite`. The proxy permission gate alone is not
    // enough — it would pass for a mixed-scope actor whose
    // location-scoped role has the key.
    if ((scopeType == UserRoleScope.operatorWide ||
            scopeType == UserRoleScope.orgUnit) &&
        !command.operatorOwnerBootstrap) {
      await _requireOperatorWidePermission(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        requiredPermissionKey: 'team.users.invite',
      );
    }
    final roleId = await _resolveRoleId(command);
    final userId = _idFactory();
    final defaultLocationId = command.targetLocationId ?? command.locationId;
    final expiresAt = _now().toUtc().add(const Duration(days: 7));
    final claims = _baseClaimsForUser(
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
        throw AuthOperationRejected(
          code: 'invite_email_already_exists',
          message: 'an account with this email already exists',
          statusCode: 409,
          details: await _emailConflictDetails(command.email),
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
    final claimProjection = await usersRepository.firebaseCustomClaimsForUser(
      userId: userId,
      operatorId: command.operatorId,
      locationId: defaultLocationId,
      adminReason: 'team.invite_claims_refresh',
    );
    await firebaseAdmin.setCustomClaims(
      uid: claimProjection.firebaseUid,
      customClaims: claimProjection.toCustomClaims(),
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
    return TeamInviteCreated(
      inviteId: inviteId,
      expiresAt: expiresAt,
      userId: userId,
    );
  }

  Future<Map<String, Object?>> _emailConflictDetails(String email) async {
    try {
      final rows = await usersRepository.listEmailConflictUsages(
        email: email,
        adminReason: 'team.invite_email_conflict_lookup',
      );
      return <String, Object?>{
        'email': email,
        'email_conflicts': <Map<String, Object?>>[
          for (final row in rows) row.toJson(),
        ],
        if (rows.isEmpty)
          'email_conflict_note':
              'Firebase has an account for this email, but no active Forge & Flow team row was found.',
      };
    } catch (_) {
      return <String, Object?>{'email': email};
    }
  }

  void _validateOperatorOwnerBootstrap({
    required UserRoleScope scopeType,
    required TeamInviteCreateCommand command,
  }) {
    if (scopeType != UserRoleScope.operatorWide ||
        command.roleId != 'operator_owner' ||
        command.targetLocationId != null ||
        command.targetOrgUnitId != null) {
      throw ArgumentError(
        'operatorOwnerBootstrap is only valid for the first operator_owner '
        'operator-wide invite on a newly created operator',
      );
    }
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
      operatorId: command.operatorId,
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
  Future<TeamMfaResetQueued> requestMfaReset(TeamMfaResetCommand command) {
    throw const AuthOperationRejected(
      code: 'mfa_reset_gateway_not_bound',
      message: 'MFA reset is handled by the MFA operations gateway.',
      statusCode: 503,
    );
  }

  @override
  Future<TeamMfaRemovalCancelled> cancelMfaRemoval(
    TeamMfaRemovalCancelCommand command,
  ) {
    throw const AuthOperationRejected(
      code: 'mfa_removal_cancel_gateway_not_bound',
      message:
          'MFA removal cancellation is handled by the MFA operations gateway.',
      statusCode: 503,
    );
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
    // Phase 9 manager contract: location-scoped actors cannot grant
    // operator-wide or org-unit scope (those reach beyond their own
    // assigned location). Enforce server-side in addition to the
    // existing `team.roles.assign` permission gate.
    if (scopeType == UserRoleScope.operatorWide ||
        scopeType == UserRoleScope.orgUnit) {
      await _requireOperatorWidePermission(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        requiredPermissionKey: 'team.roles.assign',
      );
    }
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

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) async {
    final repo = _requireOrgUnitsRepository();
    // Determine actor scope before reading. Operator-wide actors
    // whose role explicitly carries `team.users.view` see the whole
    // tree; everyone else (including a mixed-scope user whose
    // operator-wide grant is a low-privilege role and whose
    // `team.users.view` permission comes from a location-scoped
    // role) sees only the locations they hold (via
    // `effective_location_ids`) plus the chain of org_units above
    // those locations. RLS already filters cross-tenant rows; this
    // filter trims the in-tenant view down to the actor's scope so
    // the surface matches the Phase 9 manager contract and the
    // listing path uses the same permission-aware check that the
    // mutation gate uses.
    final grants = await userRolesRepository.activeGrantsForUser(
      operatorId: command.operatorId,
      locationId: command.locationId,
      targetUserId: command.actorUserId,
      actorUserId: command.actorUserId,
    );
    final operatorWideRoleIds = <String>{
      for (final grant in grants)
        if (grant.scopeType == 'operator_wide') grant.roleId,
    };
    var hasOperatorWideView = false;
    for (final roleId in operatorWideRoleIds) {
      final permissions = await rolePermissionsRepository.listForRole(
        operatorId: command.operatorId,
        locationId: command.locationId,
        roleId: roleId,
        actorUserId: command.actorUserId,
      );
      if (permissions.any(
        (rule) =>
            rule.permissionKey == 'team.users.view' && rule.effect == 'allow',
      )) {
        hasOperatorWideView = true;
        break;
      }
    }

    final orgUnits = await repo.listForTenant(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
    );
    final locations = await repo.listLocationsForTenant(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
    );

    Iterable<OrgUnitRow> visibleOrgUnits = orgUnits;
    Iterable<OrgLocationRow> visibleLocations = locations;
    if (!hasOperatorWideView) {
      final accessibleLocationIds = <String>{
        for (final grant in grants) ...grant.effectiveLocationIds,
      };
      visibleLocations = locations.where(
        (loc) => accessibleLocationIds.contains(loc.locationId),
      );
      // Build the set of ltree path prefixes that any visible
      // location's `org_unit_path` traverses. Any org_units row
      // whose own `path` is one of those prefixes is an ancestor of
      // a visible location and stays in the tree; everything else
      // (other branches the manager doesn't reach) drops out.
      final ancestorPaths = <String>{};
      for (final loc in visibleLocations) {
        final parts = loc.orgUnitPath.split('.');
        for (var i = 1; i <= parts.length; i++) {
          ancestorPaths.add(parts.take(i).join('.'));
        }
      }
      visibleOrgUnits = orgUnits.where(
        (unit) => ancestorPaths.contains(unit.path),
      );
    }

    return TeamOrgHierarchyListed(
      orgUnits: List<TeamOrgUnitEntry>.unmodifiable(
        visibleOrgUnits.map(
          (row) => TeamOrgUnitEntry(
            orgUnitId: row.id,
            parentOrgUnitId: row.parentId,
            unitType: row.unitType,
            path: row.path,
            label: row.name,
          ),
        ),
      ),
      locations: List<TeamOrgLocationEntry>.unmodifiable(
        visibleLocations.map(
          (row) => TeamOrgLocationEntry(
            locationId: row.locationId,
            // Schema guarantees `locations.parent_org_unit_id` is NOT NULL
            // post Phase 9 hierarchy wiring; the row class keeps it
            // optional defensively, but every persisted row carries a
            // value at this seam. Fall back to empty string only if the
            // field is somehow null to avoid throwing in the read path.
            parentOrgUnitId: row.parentOrgUnitId ?? '',
            orgUnitPath: row.orgUnitPath,
            label: row.name,
          ),
        ),
      ),
    );
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command,
  ) async {
    final repo = _requireOrgUnitsRepository();
    await _requireOperatorWidePermission(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      requiredPermissionKey: 'team.roles.assign',
    );
    final unitType = _requiredTrimmed(command.unitType, 'unitType');
    if (unitType == 'corp') {
      // Roots are seeded by the migration; new children must be a
      // non-corp unit type. Reject `corp` early so the proxy returns
      // a narrow 400 instead of bouncing the DB CHECK.
      throw const AuthOperationRejected(
        code: 'invalid_unit_type',
        message: "child unit_type cannot be 'corp'",
        statusCode: 400,
      );
    }
    final label = _orgUnitLabel(command.label);
    final name = _requiredTrimmed(command.name, 'name');
    final orgUnitId = await repo.createChild(
      operatorId: command.operatorId,
      locationId: command.locationId,
      parentId: command.parentOrgUnitId,
      unitType: unitType,
      childLabel: label,
      name: name,
      userId: command.actorUserId,
    );
    await _audit(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      eventType: 'auth.org_unit_created',
      payload: <String, Object?>{
        'org_unit_id': orgUnitId,
        'parent_org_unit_id': command.parentOrgUnitId,
        'unit_type': unitType,
      },
    );
    return TeamOrgUnitCreated(orgUnitId: orgUnitId);
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command,
  ) async {
    final repo = _requireOrgUnitsRepository();
    await _requireOperatorWidePermission(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      requiredPermissionKey: 'team.roles.assign',
    );
    final affected = await repo.moveLocationToOrgUnit(
      operatorId: command.operatorId,
      locationId: command.locationId,
      targetLocationId: command.targetLocationId,
      parentOrgUnitId: command.parentOrgUnitId,
      userId: command.actorUserId,
    );
    if (affected > 0) {
      await _audit(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        eventType: 'auth.location_org_unit_moved',
        payload: <String, Object?>{
          'target_location_id': command.targetLocationId,
          'parent_org_unit_id': command.parentOrgUnitId,
        },
      );
    }
    return TeamLocationOrgUnitMoved(moved: affected > 0);
  }

  // Phase 9.UX.6 — self-service Audit Log surface. The audit
  // repository here is the same tenant-scoped binding the writer-side
  // services already use; only the new `listForUser` read path is
  // exercised. Reads stay pinned to the actor's own user_id, and the
  // per-tenant RLS policy filters cross-operator rows as a backup
  // defense.
  @override
  Future<AuthEventsListed> listAuthEventsForActor(
    AuthEventListCommand command,
  ) async {
    final patterns = command.eventKind == null
        ? const <String>[]
        : AuthEventLabels.sqlPatternsFor(command.eventKind!);
    // Fetch one extra row beyond `limit` so we can answer `has_more`
    // without a separate COUNT — cheap and consistent with the
    // newest-first ordering.
    final rows = await _auditReadRepository.listForUser(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
      limit: command.limit + 1,
      offset: command.offset,
      eventTypePatterns: patterns,
      from: command.from,
      to: command.to,
    );
    final hasMore = rows.length > command.limit;
    final visible = hasMore ? rows.take(command.limit).toList() : rows;
    final entries = <AuthEventListEntry>[
      for (final row in visible) _entryFromRow(row),
    ];
    return AuthEventsListed(
      entries: List<AuthEventListEntry>.unmodifiable(entries),
      hasMore: hasMore,
    );
  }

  AuthEventListEntry _entryFromRow(AuthEventListRow row) {
    final payload = row.payload;
    String? scope;
    final scopeType = payload['scope_type'];
    if (scopeType is String && scopeType.isNotEmpty) {
      scope = switch (scopeType) {
        'operator_wide' => 'operator-wide',
        'org_unit' => 'org unit',
        'location' => 'location',
        _ => scopeType,
      };
    }
    String? subType;
    final reason = payload['reason'];
    if (reason is String && reason.isNotEmpty) subType = reason;
    return AuthEventListEntry(
      eventId: row.eventId,
      eventKind: AuthEventLabels.kindFor(row.eventType),
      eventType: row.eventType,
      friendlyLabel: AuthEventLabels.labelFor(row.eventType),
      occurredAt: row.occurredAt,
      subType: subType,
      ip: row.ip,
      userAgent: row.userAgent,
      geoCountry: row.geoCountry,
      scope: scope,
      payload: row.payload,
    );
  }

  // Phase 9.UX.5 — self-service Active Sessions surface. Reads stay
  // bound to the actor's own user_id; the per-user RLS policy on
  // `auth_sessions` filters cross-user rows server-side as a backup
  // even though the WHERE clause already pins user_id.
  @override
  Future<AuthActiveSessionsListed> listActiveSessions(
    AuthActiveSessionsListCommand command,
  ) async {
    final repo = _requireAuthSessionsRepository();
    final rows = await repo.listActiveSessionsForUser(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
    );
    return AuthActiveSessionsListed(
      sessions: List<AuthSessionSummary>.unmodifiable(
        rows.map(_authSessionSummaryFromRow),
      ),
    );
  }

  // 11W.4 ops-debt - Team-wide Active Sessions surface. Joins
  // `auth_sessions` to `users` filtered on `users.operator_id =
  // command.operatorId` so only sessions belonging to the caller's
  // operator cross this seam. Caller (proxy) gates on
  // `team.session.force_logout`.
  @override
  Future<AuthTeamActiveSessionsListed> listTeamActiveSessions(
    AuthTeamActiveSessionsListCommand command,
  ) async {
    final repo = _requireAuthSessionsRepository();
    final rows = await repo.listActiveSessionsForOperator(
      operatorId: command.operatorId,
      adminReason:
          'team.sessions.list:operator=${command.operatorId}:'
          'actor=${command.actorUserId}',
    );
    return AuthTeamActiveSessionsListed(
      sessions: List<AuthTeamActiveSessionSummary>.unmodifiable(
        rows.map(
          (row) => AuthTeamActiveSessionSummary(
            session: _authSessionSummaryFromRow(row.session),
            targetUserId: row.userId,
            targetDisplayName: row.userDisplayName,
            targetEmail: row.userEmail,
          ),
        ),
      ),
    );
  }

  @override
  Future<AuthSessionRevoked> revokeSession(
    AuthSessionRevokeCommand command,
  ) async {
    final repo = _requireAuthSessionsRepository();
    final reason =
        _readNonBlankString(command.reason) ?? 'user_revoked_active_session';
    final affected = await repo.revokeSession(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
      sessionId: command.sessionId,
      reason: reason,
    );
    if (affected > 0) {
      await _audit(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        targetUserId: command.actorUserId,
        eventType: 'auth.session_revoked',
        payload: <String, Object?>{
          'session_id': command.sessionId,
          'reason': reason,
        },
      );
    }
    return AuthSessionRevoked(revoked: affected > 0);
  }

  @override
  Future<AuthAllSessionsRevoked> signOutAll(
    AuthAllSessionsRevokeCommand command,
  ) async {
    final repo = _requireAuthSessionsRepository();
    final reason =
        _readNonBlankString(command.reason) ?? 'user_signed_out_all_sessions';
    final targetUserId = command.targetUserId ?? command.actorUserId;
    final affected = await repo.revokeAllSessionsForUser(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: targetUserId,
      reason: reason,
    );
    if (affected > 0) {
      await _audit(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorUserId: command.actorUserId,
        targetUserId: targetUserId,
        eventType: 'auth.all_sessions_revoked',
        payload: <String, Object?>{'revoked_count': affected, 'reason': reason},
      );
    }
    return AuthAllSessionsRevoked(revokedCount: affected);
  }

  AuthSessionsRepository _requireAuthSessionsRepository() {
    final repo = authSessionsRepository;
    if (repo == null) {
      throw const AuthOperationRejected(
        code: 'auth_sessions_gateway_not_bound',
        message: 'self-service auth sessions gateway is not wired',
        statusCode: 503,
      );
    }
    return repo;
  }

  static AuthSessionSummary _authSessionSummaryFromRow(AuthSessionRow row) {
    return AuthSessionSummary(
      sessionId: row.sessionId,
      createdAt: row.createdAt,
      lastSeenAt: row.lastSeenAt,
      deviceLabel: _deviceLabelForUserAgent(row.userAgent),
      userAgent: row.userAgent,
      ip: row.ip,
      geoCountry: row.geoCountry,
      deviceFingerprint: row.deviceFingerprint,
      revokedAt: row.revokedAt,
      revokedReason: row.revokedReason,
    );
  }

  static String? _deviceLabelForUserAgent(String? userAgent) {
    if (userAgent == null) return null;
    final ua = userAgent.toLowerCase();
    String os;
    if (ua.contains('iphone') || ua.contains('ios')) {
      os = 'iOS';
    } else if (ua.contains('ipad')) {
      os = 'iPad';
    } else if (ua.contains('android')) {
      os = 'Android';
    } else if (ua.contains('mac os') || ua.contains('macintosh')) {
      os = 'macOS';
    } else if (ua.contains('windows')) {
      os = 'Windows';
    } else if (ua.contains('linux')) {
      os = 'Linux';
    } else {
      return null;
    }
    String? browser;
    if (ua.contains('forge') || ua.contains('flutter')) {
      browser = 'Forge & Flow app';
    } else if (ua.contains('chrome')) {
      browser = 'Chrome';
    } else if (ua.contains('safari')) {
      browser = 'Safari';
    } else if (ua.contains('firefox')) {
      browser = 'Firefox';
    } else if (ua.contains('edg')) {
      browser = 'Edge';
    }
    return browser == null ? os : '$browser · $os';
  }

  static String? _readNonBlankString(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Phase 9.UX.4 server-side target-scope gate. Hierarchy mutations,
  /// operator-wide / org-unit grants, and org-unit-scoped invites
  /// reach beyond a single location, so the actor must hold an active
  /// **operator-wide** grant whose role allows [requiredPermissionKey].
  ///
  /// A mixed-scope actor (e.g., `operator_staff` operator-wide PLUS
  /// `operator_manager` location-scoped) can pass a per-permission
  /// proxy gate by combining the two roles, but must not pass the
  /// hierarchy gate: only the role attached to the operator-wide
  /// grant counts. This helper looks up the role's
  /// `role_permissions` rows and refuses unless one of them carries
  /// the required key with `effect = 'allow'`.
  ///
  /// Inheritance / deny-wins from the broader permission resolver is
  /// out of scope here — the question this gate answers is narrower:
  /// "does the actor's operator-wide grant explicitly carry this
  /// permission?". Operator-wide deny rules and inheritance against
  /// the actor's other roles are intentionally not consulted, so a
  /// location-scoped role cannot be promoted via the operator-wide
  /// gate.
  Future<void> _requireOperatorWidePermission({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String requiredPermissionKey,
  }) async {
    final grants = await userRolesRepository.activeGrantsForUser(
      operatorId: operatorId,
      locationId: locationId,
      targetUserId: actorUserId,
      actorUserId: actorUserId,
    );
    final operatorWideRoleIds = <String>{
      for (final grant in grants)
        if (grant.scopeType == 'operator_wide') grant.roleId,
    };
    if (operatorWideRoleIds.isEmpty) {
      throw const AuthOperationRejected(
        code: 'target_scope_required',
        message:
            'this action requires an operator-wide grant; '
            'location-scoped actors cannot mutate operator hierarchy',
        statusCode: 403,
      );
    }
    for (final roleId in operatorWideRoleIds) {
      final permissions = await rolePermissionsRepository.listForRole(
        operatorId: operatorId,
        locationId: locationId,
        roleId: roleId,
        actorUserId: actorUserId,
      );
      final allowed = permissions.any(
        (rule) =>
            rule.permissionKey == requiredPermissionKey &&
            rule.effect == 'allow',
      );
      if (allowed) return;
    }
    throw AuthOperationRejected(
      code: 'target_scope_required',
      message:
          'this action requires an operator-wide grant whose role '
          "carries '$requiredPermissionKey'",
      statusCode: 403,
    );
  }

  OrgUnitsRepository _requireOrgUnitsRepository() {
    final repo = orgUnitsRepository;
    if (repo == null) {
      throw const AuthOperationRejected(
        code: 'org_units_gateway_not_bound',
        message: 'org hierarchy gateway is not wired',
        statusCode: 503,
      );
    }
    return repo;
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
      operatorId: command.operatorId,
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
    final claimProjection = await usersRepository.firebaseCustomClaimsForUser(
      userId: targetUserId,
      operatorId: operatorId,
      locationId: defaultLocationId,
      adminReason: 'team.role_claims_refresh',
    );
    await firebaseAdmin.setCustomClaims(
      uid: claimProjection.firebaseUid,
      customClaims: claimProjection.toCustomClaims(),
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

  Map<String, Object?> _baseClaimsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required int rolesVersion,
  }) {
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
    // User-initiated: every Team / user-management write on this
    // gateway runs behind a `/v1/auth/*` HTTP route bound to the
    // operator-admin / team-admin JWT. Tag the audit row as 'user'
    // so the actor's identity (JWT subject) carries through to the
    // hash-chained audit_logs row.
    await auditRepository.insertEvent(
      operatorId: operatorId,
      locationId: locationId,
      actorKind: 'user',
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

  static String _orgUnitLabel(String value) {
    final trimmed = _requiredTrimmed(value, 'label');
    final valid = RegExp(r'^[a-z0-9_]{1,32}$').hasMatch(trimmed);
    if (!valid) {
      throw const AuthOperationRejected(
        code: 'invalid_org_unit_label',
        message:
            'label must be lowercase letters, numbers, or underscores '
            '(1-32 chars)',
        statusCode: 400,
      );
    }
    return trimmed;
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
