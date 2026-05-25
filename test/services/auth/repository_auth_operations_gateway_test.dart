import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_invites_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/role_permissions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/user_roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/auth/repository_auth_operations_gateway.dart';

void main() {
  group('RepositoryAuthOperationsGateway invite revoke audit', () {
    test(
      'emits invite.cancel once when revoke affects a pending invite',
      () async {
        final authInvitesRepository = _RecordingAuthInvitesRepository(<int>[
          1,
          0,
        ]);
        final auditRepository = _RecordingAuthEventsAuditRepository();
        final gateway = _gatewayWithRepositories(
          authInvitesRepository: authInvitesRepository,
          auditRepository: auditRepository,
        );

        final first = await gateway.revokeInvite(
          const TeamInviteRevokeCommand(
            actorUserId: _actorUserId,
            operatorId: _operatorId,
            locationId: _locationId,
            inviteId: _inviteId,
          ),
        );
        final second = await gateway.revokeInvite(
          const TeamInviteRevokeCommand(
            actorUserId: _actorUserId,
            operatorId: _operatorId,
            locationId: _locationId,
            inviteId: _inviteId,
          ),
        );

        expect(first.revoked, isTrue);
        expect(second.revoked, isFalse);
        expect(authInvitesRepository.requests, hasLength(2));
        expect(auditRepository.events, hasLength(1));
        expect(
          auditRepository.events.single,
          equals(
            const _RecordedAuditEvent(
              operatorId: _operatorId,
              locationId: _locationId,
              actorUserId: _actorUserId,
              actorKind: 'user',
              eventType: 'invite.cancel',
              payload: <String, Object?>{'invite_id': _inviteId},
            ),
          ),
        );
      },
    );

    test(
      'Wave 2 W-2 — fans out Firebase deleteUser + users.softDelete + '
      'audit row with reason and previous_email when shadow row exists',
      () async {
        final authInvitesRepository = _RecordingAuthInvitesRepository(
          <int>[1],
          pendingEmails: <String?>['invitee@example.com'],
        );
        final auditRepository = _RecordingAuthEventsAuditRepository();
        final firebase = _RecordingFirebaseAdminAuthClient();
        final users = _RecordingUsersRepositoryForInvite(
          shadow: const InvitedShadowUserRow(
            userId: _shadowUserId,
            firebaseUid: _shadowFirebaseUid,
            email: 'invitee@example.com',
          ),
        );
        final gateway = _gatewayWithRepositories(
          authInvitesRepository: authInvitesRepository,
          auditRepository: auditRepository,
          firebaseAdmin: firebase,
          usersRepository: users,
        );

        final result = await gateway.revokeInvite(
          const TeamInviteRevokeCommand(
            actorUserId: _actorUserId,
            operatorId: _operatorId,
            locationId: _locationId,
            inviteId: _inviteId,
            reason: '  email typo, resending  ',
          ),
        );

        expect(result.revoked, isTrue);
        expect(firebase.deletedUids, equals(<String>[_shadowFirebaseUid]));
        expect(users.softDeleteRequests, hasLength(1));
        expect(users.softDeleteRequests.single.userId, equals(_shadowUserId));
        expect(
          users.softDeleteRequests.single.operatorId,
          equals(_operatorId),
        );
        expect(auditRepository.events, hasLength(1));
        expect(
          auditRepository.events.single.payload,
          equals(<String, Object?>{
            'invite_id': _inviteId,
            'previous_email': 'invitee@example.com',
            // Trimmed by the gateway before audit-write so audit
            // never stores whitespace-only padding.
            'reason': 'email typo, resending',
          }),
        );
      },
    );

    test(
      'Wave 2 W-2 — skips Firebase + users.softDelete when invite is '
      'already revoked (pendingInviteEmail returns null)',
      () async {
        final authInvitesRepository = _RecordingAuthInvitesRepository(
          <int>[0],
          pendingEmails: <String?>[null],
        );
        final auditRepository = _RecordingAuthEventsAuditRepository();
        final firebase = _RecordingFirebaseAdminAuthClient();
        final users = _RecordingUsersRepositoryForInvite(shadow: null);
        final gateway = _gatewayWithRepositories(
          authInvitesRepository: authInvitesRepository,
          auditRepository: auditRepository,
          firebaseAdmin: firebase,
          usersRepository: users,
        );

        final result = await gateway.revokeInvite(
          const TeamInviteRevokeCommand(
            actorUserId: _actorUserId,
            operatorId: _operatorId,
            locationId: _locationId,
            inviteId: _inviteId,
          ),
        );

        expect(result.revoked, isFalse);
        expect(firebase.deletedUids, isEmpty);
        expect(users.softDeleteRequests, isEmpty);
        expect(users.findShadowRequests, isEmpty);
        expect(auditRepository.events, isEmpty);
      },
    );

    test(
      'Wave 2 W-2 — still revokes the invite when no shadow user row '
      'exists (e.g. invite predates Firebase-bound flow); audit captures '
      'the previous_email anyway',
      () async {
        final authInvitesRepository = _RecordingAuthInvitesRepository(
          <int>[1],
          pendingEmails: <String?>['legacy@example.com'],
        );
        final auditRepository = _RecordingAuthEventsAuditRepository();
        final firebase = _RecordingFirebaseAdminAuthClient();
        final users = _RecordingUsersRepositoryForInvite(shadow: null);
        final gateway = _gatewayWithRepositories(
          authInvitesRepository: authInvitesRepository,
          auditRepository: auditRepository,
          firebaseAdmin: firebase,
          usersRepository: users,
        );

        final result = await gateway.revokeInvite(
          const TeamInviteRevokeCommand(
            actorUserId: _actorUserId,
            operatorId: _operatorId,
            locationId: _locationId,
            inviteId: _inviteId,
          ),
        );

        expect(result.revoked, isTrue);
        expect(firebase.deletedUids, isEmpty);
        expect(users.softDeleteRequests, isEmpty);
        expect(auditRepository.events, hasLength(1));
        expect(
          auditRepository.events.single.payload,
          equals(<String, Object?>{
            'invite_id': _inviteId,
            'previous_email': 'legacy@example.com',
          }),
        );
      },
    );
  });

  group('RepositoryAuthOperationsGateway role permission audit', () {
    test(
      'createRole audit payload includes product for live permission writes',
      () async {
        final auditRepository = _RecordingAuthEventsAuditRepository();
        final rolePermissionsRepository = _RecordingRolePermissionsRepository();
        final gateway = _gatewayWithRepositories(
          authInvitesRepository: _RecordingAuthInvitesRepository(<int>[]),
          auditRepository: auditRepository,
          rolesRepository: _RecordingRolesRepository(roleId: _roleId),
          rolePermissionsRepository: rolePermissionsRepository,
        );

        await gateway.createRole(
          const TeamRoleCreateCommand(
            actorUserId: _actorUserId,
            operatorId: _operatorId,
            locationId: _locationId,
            roleKey: 'line_lead',
            displayName: 'Line Lead',
            permissions: <TeamRolePermissionUpdate>[
              TeamRolePermissionUpdate(
                permissionKey: 'forgeflow.shift.view',
                effect: 'allow',
              ),
              TeamRolePermissionUpdate(
                permissionKey: 'product.barrio.access',
                effect: 'allow',
              ),
            ],
            reason: 'support-onboarding',
          ),
        );

        expect(rolePermissionsRepository.upserts, hasLength(2));
        expect(auditRepository.events, hasLength(1));
        final event = auditRepository.events.single;
        expect(event.eventType, equals('auth.custom_role_created'));
        final changePayload =
            event.payload['change_payload'] as Map<String, Object?>;
        expect(changePayload['change_count'], equals(2));
        final changes = (changePayload['changes']! as List)
            .cast<Map<String, Object?>>();
        final forgeflow = changes.singleWhere(
          (entry) => entry['permission_key'] == 'forgeflow.shift.view',
        );
        final barrio = changes.singleWhere(
          (entry) => entry['permission_key'] == 'product.barrio.access',
        );
        expect(forgeflow['role_id'], equals(_roleId));
        expect(forgeflow['product'], equals('forgeflow'));
        expect(forgeflow['from'], equals('inherit'));
        expect(forgeflow['to'], equals('allow'));
        expect(barrio['role_id'], equals(_roleId));
        expect(barrio['product'], equals('barrio'));
        expect(barrio['from'], equals('inherit'));
        expect(barrio['to'], equals('allow'));
      },
    );

    test(
      'patchRole audit payload includes before/after product diff for updates and inherit',
      () async {
        final auditRepository = _RecordingAuthEventsAuditRepository();
        final rolePermissionsRepository = _RecordingRolePermissionsRepository(
          initialEffects: const <String, String>{
            'forgeflow.shift.view': 'allow',
            'product.barrio.access': 'allow',
          },
        );
        final userRolesRepository = _RecordingUserRolesRepository();
        final gateway = _gatewayWithRepositories(
          authInvitesRepository: _RecordingAuthInvitesRepository(<int>[]),
          auditRepository: auditRepository,
          rolesRepository: _RecordingRolesRepository(roleId: _roleId),
          rolePermissionsRepository: rolePermissionsRepository,
          userRolesRepository: userRolesRepository,
        );

        await gateway.patchRole(
          const TeamRolePatchCommand(
            actorUserId: _actorUserId,
            operatorId: _operatorId,
            locationId: _locationId,
            roleId: _roleId,
            permissions: <TeamRolePermissionUpdate>[
              TeamRolePermissionUpdate(
                permissionKey: 'forgeflow.shift.view',
                effect: 'deny',
              ),
              TeamRolePermissionUpdate(
                permissionKey: 'product.barrio.access',
                effect: 'inherit',
              ),
            ],
            reason: 'support-permission-change',
          ),
        );

        expect(rolePermissionsRepository.upserts, hasLength(1));
        expect(rolePermissionsRepository.deletes, hasLength(1));
        expect(userRolesRepository.bumpRequests, equals(<String>[_roleId]));
        expect(auditRepository.events, hasLength(1));
        final event = auditRepository.events.single;
        expect(event.eventType, equals('auth.custom_role_updated'));
        final changePayload =
            event.payload['change_payload'] as Map<String, Object?>;
        expect(changePayload['change_count'], equals(2));
        final changes = (changePayload['changes']! as List)
            .cast<Map<String, Object?>>();
        final forgeflow = changes.singleWhere(
          (entry) => entry['permission_key'] == 'forgeflow.shift.view',
        );
        final barrio = changes.singleWhere(
          (entry) => entry['permission_key'] == 'product.barrio.access',
        );
        expect(forgeflow['role_id'], equals(_roleId));
        expect(forgeflow['product'], equals('forgeflow'));
        expect(forgeflow['from'], equals('allow'));
        expect(forgeflow['to'], equals('deny'));
        expect(barrio['role_id'], equals(_roleId));
        expect(barrio['product'], equals('barrio'));
        expect(barrio['from'], equals('allow'));
        expect(barrio['to'], equals('inherit'));
      },
    );

    test(
      'editSeededRolePermissions protects Ecosystem admin recovery permissions',
      () async {
        final rolePermissionsRepository = _RecordingRolePermissionsRepository();
        final gateway = _gatewayWithRepositories(
          authInvitesRepository: _RecordingAuthInvitesRepository(<int>[]),
          auditRepository: _RecordingAuthEventsAuditRepository(),
          rolesRepository: _RecordingRolesRepository(
            roleId: _roleId,
            roleKey: PermissionKeys.roleSuperAdmin,
            isSeeded: true,
          ),
          rolePermissionsRepository: rolePermissionsRepository,
        );

        await expectLater(
          gateway.editSeededRolePermissions(
            const TeamSeededRolePermissionsEditCommand(
              actorUserId: _actorUserId,
              operatorId: _operatorId,
              locationId: _locationId,
              roleId: _roleId,
              permissionKeys: <String>[
                PermissionKeys.adminRolesView,
                PermissionKeys.teamRolesView,
              ],
              reason: 'defense-in-depth regression',
            ),
          ),
          throwsA(
            isA<AuthOperationRejected>()
                .having(
                  (e) => e.code,
                  'code',
                  equals('platform_role_locked_permission'),
                )
                .having((e) => e.statusCode, 'statusCode', equals(400)),
          ),
        );
        expect(rolePermissionsRepository.upserts, isEmpty);
        expect(rolePermissionsRepository.deletes, isEmpty);
      },
    );
  });
}

const String _actorUserId = '10000000-0000-4000-8000-000000000001';
const String _operatorId = '20000000-0000-4000-8000-000000000001';
const String _locationId = '30000000-0000-4000-8000-000000000001';
const String _inviteId = '40000000-0000-4000-8000-000000000001';
const String _roleId = '60000000-0000-4000-8000-000000000001';
const String _shadowUserId = '70000000-0000-4000-8000-000000000001';
const String _shadowFirebaseUid = '70000000-0000-4000-8000-000000000001';

RepositoryAuthOperationsGateway _gatewayWithRepositories({
  required AuthInvitesRepository authInvitesRepository,
  required AuthEventsAuditRepository auditRepository,
  RolesRepository? rolesRepository,
  RolePermissionsRepository? rolePermissionsRepository,
  UserRolesRepository? userRolesRepository,
  FirebaseAdminAuthClient? firebaseAdmin,
  UsersRepository? usersRepository,
}) {
  final wrapper = TenantTransactionWrapper(_UnexpectedPostgresPool());
  return RepositoryAuthOperationsGateway(
    firebaseAdmin: firebaseAdmin ?? const ScaffoldFailingFirebaseAdminAuthClient(),
    usersRepository: usersRepository ?? UsersRepository(wrapper),
    rolesRepository: rolesRepository ?? RolesRepository(wrapper),
    rolePermissionsRepository:
        rolePermissionsRepository ?? RolePermissionsRepository(wrapper),
    userRolesRepository: userRolesRepository ?? UserRolesRepository(wrapper),
    authInvitesRepository: authInvitesRepository,
    auditRepository: auditRepository,
  );
}

class _RecordingRolesRepository extends RolesRepository {
  _RecordingRolesRepository({
    required this.roleId,
    this.roleKey = 'custom.line_lead',
    this.isSeeded = false,
  }) : super(TenantTransactionWrapper(_UnexpectedPostgresPool()));

  final String roleId;
  final String roleKey;
  final bool isSeeded;

  @override
  Future<String> insertOperatorRole({
    required String operatorId,
    required String locationId,
    required String createdByUserId,
    required String roleKey,
    required String displayName,
    String description = '',
    bool isEditable = true,
  }) async {
    return roleId;
  }

  @override
  Future<RoleRecord> visibleRoleById({
    required String operatorId,
    required String locationId,
    required String roleId,
    String? actorUserId,
  }) async {
    return RoleRecord(
      roleId: roleId,
      operatorId: isSeeded ? null : operatorId,
      roleKey: roleKey,
      displayName: 'Line Lead',
      description: '',
      isSeeded: isSeeded,
      isEditable: true,
      createdAt: DateTime.utc(2026, 5, 12),
      updatedAt: DateTime.utc(2026, 5, 12),
    );
  }
}

class _RecordingRolePermissionsRepository extends RolePermissionsRepository {
  _RecordingRolePermissionsRepository({
    Map<String, String> initialEffects = const <String, String>{},
  }) : _effects = Map<String, String>.of(initialEffects),
       super(TenantTransactionWrapper(_UnexpectedPostgresPool()));

  final List<_RolePermissionUpsertRequest> upserts =
      <_RolePermissionUpsertRequest>[];
  final List<_RolePermissionDeleteRequest> deletes =
      <_RolePermissionDeleteRequest>[];
  final Map<String, String> _effects;

  @override
  Future<int> upsertCell({
    required String operatorId,
    required String locationId,
    required String updatedByUserId,
    required String roleId,
    required String permissionKey,
    required String effect,
  }) async {
    upserts.add(
      _RolePermissionUpsertRequest(
        roleId: roleId,
        permissionKey: permissionKey,
        effect: effect,
      ),
    );
    _effects[permissionKey] = effect;
    return 1;
  }

  @override
  Future<int> deleteCell({
    required String operatorId,
    required String locationId,
    required String updatedByUserId,
    required String roleId,
    required String permissionKey,
  }) async {
    deletes.add(
      _RolePermissionDeleteRequest(
        roleId: roleId,
        permissionKey: permissionKey,
      ),
    );
    return _effects.remove(permissionKey) == null ? 0 : 1;
  }

  @override
  Future<List<RolePermissionRow>> listForRole({
    required String operatorId,
    required String locationId,
    required String roleId,
    String? actorUserId,
  }) async {
    return <RolePermissionRow>[
      for (final entry in _effects.entries)
        RolePermissionRow(
          roleId: roleId,
          permissionKey: entry.key,
          effect: entry.value,
          createdAt: DateTime.utc(2026, 5, 12),
          updatedAt: DateTime.utc(2026, 5, 12),
        ),
    ];
  }
}

class _RecordingUserRolesRepository extends UserRolesRepository {
  _RecordingUserRolesRepository()
    : super(TenantTransactionWrapper(_UnexpectedPostgresPool()));

  final List<String> bumpRequests = <String>[];

  @override
  Future<int> bumpActiveGrantHoldersForRole({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String roleId,
  }) async {
    bumpRequests.add(roleId);
    return 2;
  }
}

class _RecordingAuthInvitesRepository extends AuthInvitesRepository {
  _RecordingAuthInvitesRepository(
    List<int> affectedRows, {
    List<String?>? pendingEmails,
  }) : _affectedRows = List<int>.of(affectedRows),
       _pendingEmails = pendingEmails == null
           ? null
           : List<String?>.of(pendingEmails),
       super(TenantTransactionWrapper(_UnexpectedPostgresPool()));

  final List<int> _affectedRows;
  // Wave 2 W-2 — optional script for `pendingInviteEmail` so tests
  // that care can pin the lookup result. When null, the stub returns
  // null (no pending email found) so existing tests stay green.
  final List<String?>? _pendingEmails;
  final List<_RevokeInviteRequest> requests = <_RevokeInviteRequest>[];
  final List<String> pendingInviteEmailRequests = <String>[];

  @override
  Future<int> revokeInvite({
    required String operatorId,
    required String locationId,
    required String inviteId,
    required String actorUserId,
  }) async {
    requests.add(
      _RevokeInviteRequest(
        operatorId: operatorId,
        locationId: locationId,
        inviteId: inviteId,
        actorUserId: actorUserId,
      ),
    );
    if (_affectedRows.isEmpty) {
      throw StateError('unexpected revokeInvite call');
    }
    return _affectedRows.removeAt(0);
  }

  @override
  Future<String?> pendingInviteEmail({
    required String operatorId,
    required String locationId,
    required String inviteId,
    required String actorUserId,
  }) async {
    pendingInviteEmailRequests.add(inviteId);
    final scripted = _pendingEmails;
    if (scripted == null) return null;
    if (scripted.isEmpty) {
      throw StateError('unexpected pendingInviteEmail call');
    }
    return scripted.removeAt(0);
  }
}

class _RecordingAuthEventsAuditRepository extends AuthEventsAuditRepository {
  _RecordingAuthEventsAuditRepository()
    : super(TenantTransactionWrapper(_UnexpectedPostgresPool()));

  final List<_RecordedAuditEvent> events = <_RecordedAuditEvent>[];

  @override
  Future<String> insertEvent({
    required String operatorId,
    required String locationId,
    required String eventType,
    required String actorKind,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    String? adminReason,
  }) async {
    events.add(
      _RecordedAuditEvent(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        eventType: eventType,
        payload: payload,
      ),
    );
    return '50000000-0000-4000-8000-000000000001';
  }
}

class _RevokeInviteRequest {
  const _RevokeInviteRequest({
    required this.operatorId,
    required this.locationId,
    required this.inviteId,
    required this.actorUserId,
  });

  final String operatorId;
  final String locationId;
  final String inviteId;
  final String actorUserId;
}

class _RolePermissionUpsertRequest {
  const _RolePermissionUpsertRequest({
    required this.roleId,
    required this.permissionKey,
    required this.effect,
  });

  final String roleId;
  final String permissionKey;
  final String effect;
}

class _RolePermissionDeleteRequest {
  const _RolePermissionDeleteRequest({
    required this.roleId,
    required this.permissionKey,
  });

  final String roleId;
  final String permissionKey;
}

/// Wave 2 W-2 — Firebase client stub that records every
/// `deleteUser` invocation so the cancel-invite test can assert
/// the gateway fanned out to Firebase Identity Platform with the
/// shadow account's uid. Other surfaces throw to fail fast if the
/// test exercises a path the stub does not script.
class _RecordingFirebaseAdminAuthClient implements FirebaseAdminAuthClient {
  final List<String> deletedUids = <String>[];

  @override
  Future<void> deleteUser({required String uid}) async {
    deletedUids.add(uid);
  }

  @override
  Future<void> createUser({
    required String uid,
    required String email,
    required Map<String, Object?> customClaims,
  }) async => throw UnimplementedError();

  @override
  Future<void> setCustomClaims({
    required String uid,
    required Map<String, Object?> customClaims,
  }) async => throw UnimplementedError();

  @override
  Future<void> setDisabled({
    required String uid,
    required bool disabled,
  }) async => throw UnimplementedError();

  @override
  Future<void> updateUser({
    required String uid,
    String? email,
    String? displayName,
  }) async => throw UnimplementedError();

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    String? continueUrl,
  }) async => throw UnimplementedError();

  @override
  Future<FirebasePasswordResetCodeInfo> verifyPasswordResetCode({
    required String oobCode,
  }) async => throw UnimplementedError();

  @override
  Future<void> confirmPasswordReset({
    required String oobCode,
    required String newPassword,
  }) async => throw UnimplementedError();

  @override
  Future<bool> verifyPassword({
    required String email,
    required String password,
    required String expectedUid,
  }) async => throw UnimplementedError();

  @override
  Future<void> updatePassword({
    required String uid,
    required String password,
  }) async => throw UnimplementedError();

  @override
  Future<void> revokeRefreshTokens({required String uid}) async =>
      throw UnimplementedError();

  @override
  Future<void> clearMfaEnrollments({required String uid}) async =>
      throw UnimplementedError();
}

/// Wave 2 W-2 — UsersRepository stub that returns a scripted
/// [InvitedShadowUserRow] for `findInvitedShadowUserByEmail` and
/// records `softDelete` invocations so the cancel-invite test can
/// assert the shadow row was torn down. Falls through to the
/// `_UnexpectedPostgresPool` for everything else so any unscripted
/// repository call fails loudly.
class _RecordingUsersRepositoryForInvite extends UsersRepository {
  _RecordingUsersRepositoryForInvite({required this.shadow})
    : super(TenantTransactionWrapper(_UnexpectedPostgresPool()));

  final InvitedShadowUserRow? shadow;
  final List<String> findShadowRequests = <String>[];
  final List<_RecordedSoftDelete> softDeleteRequests = <_RecordedSoftDelete>[];

  @override
  Future<InvitedShadowUserRow?> findInvitedShadowUserByEmail({
    required String operatorId,
    required String email,
    required String adminReason,
  }) async {
    findShadowRequests.add(email);
    return shadow;
  }

  @override
  Future<int> softDelete({
    required String userId,
    required String operatorId,
    required String adminReason,
  }) async {
    softDeleteRequests.add(
      _RecordedSoftDelete(userId: userId, operatorId: operatorId),
    );
    return 1;
  }
}

class _RecordedSoftDelete {
  const _RecordedSoftDelete({
    required this.userId,
    required this.operatorId,
  });

  final String userId;
  final String operatorId;
}

class _RecordedAuditEvent {
  const _RecordedAuditEvent({
    required this.operatorId,
    required this.locationId,
    required this.actorUserId,
    required this.actorKind,
    required this.eventType,
    required this.payload,
  });

  final String operatorId;
  final String locationId;
  final String? actorUserId;
  final String actorKind;
  final String eventType;
  final Map<String, Object?> payload;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _RecordedAuditEvent &&
          runtimeType == other.runtimeType &&
          operatorId == other.operatorId &&
          locationId == other.locationId &&
          actorUserId == other.actorUserId &&
          actorKind == other.actorKind &&
          eventType == other.eventType &&
          _mapEquals(payload, other.payload);

  @override
  int get hashCode => Object.hash(
    operatorId,
    locationId,
    actorUserId,
    actorKind,
    eventType,
    Object.hashAll(payload.entries.map((entry) => (entry.key, entry.value))),
  );
}

class _UnexpectedPostgresPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw StateError('unexpected Postgres access in repository gateway test');
  }
}

bool _mapEquals(Map<String, Object?> left, Map<String, Object?> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (!right.containsKey(entry.key) || right[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}
