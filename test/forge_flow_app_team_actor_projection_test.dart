import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/forge_flow_app.dart';

void main() {
  group('projectSettingsTeamActorFromSession', () {
    test('permission-only team viewer projects current General Manager', () {
      final actor = projectSettingsTeamActorFromSession(
        session: _session(roles: const <String>['roles_version:7']),
        permissions: const <String>{PermissionKeys.teamUsersView},
      );

      expect(
        actor.actorRoles,
        contains(PermissionKeys.roleOperatorGeneralManager),
      );
      expect(actor.actorRoles, isNot(contains('operator_manager')));
      expect(actor.actorAssignedLocationIds, isEmpty);
    });

    test('location manager keeps location scope instead of becoming GM', () {
      final actor = projectSettingsTeamActorFromSession(
        session: _session(
          roles: const <String>[PermissionKeys.roleLocationManager],
        ),
        permissions: const <String>{PermissionKeys.teamUsersView},
      );

      expect(actor.actorRoles, contains(PermissionKeys.roleLocationManager));
      expect(
        actor.actorRoles,
        isNot(contains(PermissionKeys.roleOperatorGeneralManager)),
      );
      expect(actor.actorRoles, isNot(contains('operator_manager')));
      expect(actor.actorAssignedLocationIds, equals(<String>{'loc-1'}));
    });

    test('team write permissions still project owner-level scope', () {
      final actor = projectSettingsTeamActorFromSession(
        session: _session(roles: const <String>['roles_version:7']),
        permissions: const <String>{PermissionKeys.teamRolesCreateCustom},
      );

      expect(actor.actorRoles, contains(PermissionKeys.roleOperatorOwner));
      expect(actor.actorAssignedLocationIds, isEmpty);
    });
  });
}

AuthSession _session({required List<String> roles}) {
  final now = DateTime.utc(2026, 5, 19, 12);
  return AuthSession(
    userId: 'user-1',
    operatorId: 'op-1',
    locationId: 'loc-1',
    firebaseIdToken: 'token',
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: now,
    roles: roles,
    mfaEnrolled: true,
  );
}
