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
  final UserRolesRepository userRolesRepository;
  final AuthInvitesRepository authInvitesRepository;
  final AuthEventsAuditRepository auditRepository;
  final DateTime Function() _now;
  final String Function() _idFactory;
  final String Function() _tokenFactory;

  @override
  Future<TeamInviteCreated> createInvite(
    TeamInviteCreateCommand command,
  ) async {
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

    await firebaseAdmin.createUser(
      uid: userId,
      email: command.email,
      customClaims: claims,
    );
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
      scopeType: _scopeFromCommand(command.scopeType),
      grantLocationId: command.targetLocationId,
      reason: 'team.invite_create',
    );
    final inviteId = await authInvitesRepository.insertInvite(
      operatorId: command.operatorId,
      locationId: command.locationId,
      email: command.email,
      roleId: roleId,
      invitedByUserId: command.actorUserId,
      expiresAt: expiresAt,
      tokenHash: _sha256(_tokenFactory()),
      targetLocationId: command.targetLocationId,
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
        'scope_type': command.scopeType,
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
    final roleId = await _resolveRoleGrantRoleId(command);
    final id = await userRolesRepository.insertGrant(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      targetUserId: command.targetUserId,
      roleId: roleId,
      scopeType: _scopeFromCommand(command.scopeType),
      grantLocationId: command.targetLocationId,
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
        'scope_type': command.scopeType,
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
      'location' => UserRoleScope.location,
      _ => throw ArgumentError.value(
        scopeType,
        'scopeType',
        "must be 'operator_wide' or 'location'",
      ),
    };
  }

  static String _sha256(String value) {
    return sha256.convert(value.codeUnits).toString();
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
