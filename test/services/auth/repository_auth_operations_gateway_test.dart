import 'package:flutter_test/flutter_test.dart';
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
  });
}

const String _actorUserId = '10000000-0000-4000-8000-000000000001';
const String _operatorId = '20000000-0000-4000-8000-000000000001';
const String _locationId = '30000000-0000-4000-8000-000000000001';
const String _inviteId = '40000000-0000-4000-8000-000000000001';
const String _roleId = '60000000-0000-4000-8000-000000000001';

RepositoryAuthOperationsGateway _gatewayWithRepositories({
  required AuthInvitesRepository authInvitesRepository,
  required AuthEventsAuditRepository auditRepository,
  RolesRepository? rolesRepository,
  RolePermissionsRepository? rolePermissionsRepository,
  UserRolesRepository? userRolesRepository,
}) {
  final wrapper = TenantTransactionWrapper(_UnexpectedPostgresPool());
  return RepositoryAuthOperationsGateway(
    firebaseAdmin: const ScaffoldFailingFirebaseAdminAuthClient(),
    usersRepository: UsersRepository(wrapper),
    rolesRepository: rolesRepository ?? RolesRepository(wrapper),
    rolePermissionsRepository:
        rolePermissionsRepository ?? RolePermissionsRepository(wrapper),
    userRolesRepository: userRolesRepository ?? UserRolesRepository(wrapper),
    authInvitesRepository: authInvitesRepository,
    auditRepository: auditRepository,
  );
}

class _RecordingRolesRepository extends RolesRepository {
  _RecordingRolesRepository({required this.roleId})
    : super(TenantTransactionWrapper(_UnexpectedPostgresPool()));

  final String roleId;

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
      operatorId: operatorId,
      roleKey: 'custom.line_lead',
      displayName: 'Line Lead',
      description: '',
      isSeeded: false,
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
  _RecordingAuthInvitesRepository(List<int> affectedRows)
    : _affectedRows = List<int>.of(affectedRows),
      super(TenantTransactionWrapper(_UnexpectedPostgresPool()));

  final List<int> _affectedRows;
  final List<_RevokeInviteRequest> requests = <_RevokeInviteRequest>[];

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
