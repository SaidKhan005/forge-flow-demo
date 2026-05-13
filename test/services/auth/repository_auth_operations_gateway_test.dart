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
}

const String _actorUserId = '10000000-0000-4000-8000-000000000001';
const String _operatorId = '20000000-0000-4000-8000-000000000001';
const String _locationId = '30000000-0000-4000-8000-000000000001';
const String _inviteId = '40000000-0000-4000-8000-000000000001';

RepositoryAuthOperationsGateway _gatewayWithRepositories({
  required AuthInvitesRepository authInvitesRepository,
  required AuthEventsAuditRepository auditRepository,
}) {
  final wrapper = TenantTransactionWrapper(_UnexpectedPostgresPool());
  return RepositoryAuthOperationsGateway(
    firebaseAdmin: const ScaffoldFailingFirebaseAdminAuthClient(),
    usersRepository: UsersRepository(wrapper),
    rolesRepository: RolesRepository(wrapper),
    rolePermissionsRepository: RolePermissionsRepository(wrapper),
    userRolesRepository: UserRolesRepository(wrapper),
    authInvitesRepository: authInvitesRepository,
    auditRepository: auditRepository,
  );
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
