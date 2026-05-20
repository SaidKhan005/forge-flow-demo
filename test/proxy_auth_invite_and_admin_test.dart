// Phase 9 live-closeout - proxy auth invite + admin-scoping route
// tests.
//
// Bucket 5d-invite+admin of the 2026-05-20 test-suite tightening
// audit: split out of `test/proxy_auth_operations_route_test.dart`
// (3,599 lines). This file owns invite creation (operator-wide,
// location-scoped, org-unit scoped, admin-console role_key path,
// admin target operator/location), org-unit + location hierarchy
// CRUD + lifecycle, admin role list/create/patch/delete, admin
// users list (with explicit admin scoping) + PATCH profile +
// deactivate alias, and the self-profile editor (`/v1/auth/self/profile`).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import 'proxy_auth_test_helpers.dart';

void main() {
  group('Phase 9 auth-operation proxy routes', () {
    test(
      'POST invite create verifies permission and delegates command',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness
                .postJson(adminAuthInvitesPath, <String, Object?>{
                  'email': 'new.user@example.test',
                  'role_id': 'supervisor',
                  'scope_type': 'location',
                  'location_id': proxyAuthLocationId,
                }, idempotencyKey: 'idem-invite-create-1');

            expect(response.statusCode, equals(201));
            expect(response.json['invite_id'], equals('invite-1'));
            expect(guard.permissionKeys, equals(<String>['team.users.invite']));
            expect(
              gateway.inviteCreates.single.email,
              equals('new.user@example.test'),
            );
            expect(gateway.inviteCreates.single.actorUserId, equals(proxyAuthUserId));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST invite create accepts admin console role_key and primary_location_id',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: RecordingAdminGuard(),
          );
          try {
            final response = await harness.postJson(
              adminAuthInvitesPath,
              <String, Object?>{
                'email': 'manager@example.test',
                'display_name': 'Manager User',
                'role_key': 'operator_general_manager',
                'primary_location_id': proxyAuthLocationId,
              },
              idempotencyKey: 'idem-invite-create-admin-console',
            );

            expect(response.statusCode, equals(201));
            final command = gateway.inviteCreates.single;
            expect(command.roleId, equals('operator_general_manager'));
            expect(command.scopeType, equals('location'));
            expect(command.targetLocationId, equals(proxyAuthLocationId));
            expect(response.json['invite'], isA<Map<String, Object?>>());
            final invite = response.json['invite'] as Map<String, Object?>;
            expect(invite['email'], equals('manager@example.test'));
            expect(invite['role_key'], equals('operator_general_manager'));
            expect(invite['primary_location_id'], equals(proxyAuthLocationId));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST invite create honors explicit admin target operator/location',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
            verifier: StaticVerifier(
              roles: const <String>['super_admin', 'roles_version:7'],
            ),
          );
          try {
            const targetOperatorId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
            const targetLocationId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
            final response = await harness.postJson(
              adminAuthInvitesPath,
              <String, Object?>{
                'operator_id': targetOperatorId,
                'email': 'manager@example.test',
                'display_name': 'Manager User',
                'role_key': 'operator_general_manager',
                'primary_location_id': targetLocationId,
              },
              idempotencyKey: 'idem-invite-create-admin-target',
            );

            expect(response.statusCode, equals(201));
            expect(guard.permissionKeys, isEmpty);
            final command = gateway.inviteCreates.single;
            expect(command.operatorId, equals(targetOperatorId));
            expect(command.locationId, equals(targetLocationId));
            expect(command.targetLocationId, equals(targetLocationId));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('POST invite create forwards org-unit scope payload', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: RecordingAdminGuard(),
        );
        try {
          final response = await harness
              .postJson(adminAuthInvitesPath, <String, Object?>{
                'email': 'regional.user@example.test',
                'role_id': proxyAuthRoleId,
                'scope_type': 'org_unit',
                'org_unit_id': '55555555-5555-4555-8555-555555555555',
              }, idempotencyKey: 'idem-invite-create-2');

          expect(response.statusCode, equals(201));
          final command = gateway.inviteCreates.single;
          expect(command.scopeType, equals('org_unit'));
          expect(
            command.targetOrgUnitId,
            equals('55555555-5555-4555-8555-555555555555'),
          );
          expect(command.targetLocationId, isNull);
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'GET org-units lists hierarchy and gates on team.users.view',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness.get(adminAuthOrgUnitsPath);

            expect(response.statusCode, equals(200));
            expect(guard.permissionKeys, equals(<String>['team.users.view']));
            expect(gateway.orgHierarchyLists, hasLength(1));
            expect(
              gateway.orgHierarchyLists.single.actorUserId,
              equals(proxyAuthUserId),
            );
            expect(
              gateway.orgHierarchyLists.single.operatorId,
              equals(proxyAuthOperatorId),
            );
            expect(
              gateway.orgHierarchyLists.single.locationId,
              equals(proxyAuthLocationId),
            );
            final units = response.json['org_units'] as List<Object?>;
            final firstUnit = Map<String, Object?>.from(units.single as Map);
            expect(firstUnit['unit_type'], equals('corp'));
            expect(firstUnit['path'], equals('acme'));
            final locations = response.json['locations'] as List<Object?>;
            final firstLoc = Map<String, Object?>.from(locations.single as Map);
            expect(firstLoc['parent_org_unit_id'], firstUnit['org_unit_id']);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST org-units creates a child unit and gates on team.roles.assign',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness
                .postJson(adminAuthOrgUnitsPath, const <String, Object?>{
                  'parent_org_unit_id': '66666666-6666-4666-8666-666666666666',
                  'unit_type': 'region',
                  'label': 'east',
                  'name': 'East Region',
                  'admin_reason': 'admin hierarchy setup',
                }, idempotencyKey: 'idem-org-unit-create-1');

            expect(response.statusCode, equals(201));
            expect(guard.permissionKeys, equals(<String>['team.roles.assign']));
            final command = gateway.orgUnitCreates.single;
            expect(command.actorUserId, equals(proxyAuthUserId));
            expect(command.operatorId, equals(proxyAuthOperatorId));
            expect(command.locationId, equals(proxyAuthLocationId));
            expect(
              command.parentOrgUnitId,
              equals('66666666-6666-4666-8666-666666666666'),
            );
            expect(command.unitType, equals('region'));
            expect(command.label, equals('east'));
            expect(command.name, equals('East Region'));
            expect(command.adminReason, equals('admin hierarchy setup'));
            expect(
              response.json['org_unit_id'],
              equals('77777777-7777-4777-8777-777777777777'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'PATCH org-unit parent moves the branch and gates on team.roles.assign',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            const targetOrgUnit = '88888888-8888-4888-8888-888888888888';
            final response = await harness.patchJson(
              '$adminAuthOrgUnitsPath/$targetOrgUnit/parent',
              const <String, Object?>{
                'parent_org_unit_id': '77777777-7777-4777-8777-777777777777',
                'admin_reason': 'admin branch realignment',
              },
              idempotencyKey: 'idem-org-unit-move-1',
            );

            expect(response.statusCode, equals(200));
            expect(guard.permissionKeys, equals(<String>['team.roles.assign']));
            final command = gateway.orgUnitMoves.single;
            expect(command.actorUserId, equals(proxyAuthUserId));
            expect(command.operatorId, equals(proxyAuthOperatorId));
            expect(command.locationId, equals(proxyAuthLocationId));
            expect(command.orgUnitId, equals(targetOrgUnit));
            expect(
              command.parentOrgUnitId,
              equals('77777777-7777-4777-8777-777777777777'),
            );
            expect(command.adminReason, equals('admin branch realignment'));
            final orgUnit = Map<String, Object?>.from(
              response.json['org_unit'] as Map,
            );
            expect(orgUnit['org_unit_id'], equals(targetOrgUnit));
            expect(
              orgUnit['parent_org_unit_id'],
              equals('77777777-7777-4777-8777-777777777777'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'PATCH admin org-unit name renames and gates on team.roles.assign',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            const targetOrgUnit = '88888888-8888-4888-8888-888888888888';
            final response = await harness.patchJson(
              '$adminAuthOrgUnitsPath/$targetOrgUnit/name',
              const <String, Object?>{
                'name': 'Pacific Region',
                'admin_reason': 'operator requested label cleanup',
              },
              idempotencyKey: 'idem-org-unit-rename-admin-1',
            );

            expect(response.statusCode, equals(200));
            expect(guard.permissionKeys, equals(<String>['team.roles.assign']));
            final command = gateway.orgUnitRenames.single;
            expect(command.actorUserId, equals(proxyAuthUserId));
            expect(command.operatorId, equals(proxyAuthOperatorId));
            expect(command.locationId, equals(proxyAuthLocationId));
            expect(command.orgUnitId, equals(targetOrgUnit));
            expect(command.name, equals('Pacific Region'));
            // Admin path carries the reason through.
            expect(
              command.adminReason,
              equals('operator requested label cleanup'),
            );
            final orgUnit = Map<String, Object?>.from(
              response.json['org_unit'] as Map,
            );
            expect(orgUnit['org_unit_id'], equals(targetOrgUnit));
            expect(orgUnit['label'], equals('Pacific Region'));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'PATCH self-service org-unit name renames with NO admin_reason',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            const targetOrgUnit = '88888888-8888-4888-8888-888888888888';
            final response = await harness.patchJson(
              '$authTeamOrgUnitsPath/$targetOrgUnit/name',
              const <String, Object?>{'name': 'My New Region'},
              idempotencyKey: 'idem-org-unit-rename-self-1',
            );

            expect(response.statusCode, equals(200));
            expect(guard.permissionKeys, equals(<String>['team.roles.assign']));
            final command = gateway.orgUnitRenames.single;
            expect(command.orgUnitId, equals(targetOrgUnit));
            expect(command.name, equals('My New Region'));
            // Self-service path forces adminReason null even if absent.
            expect(command.adminReason, isNull);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('PATCH admin org-unit name requires admin_reason', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          const targetOrgUnit = '88888888-8888-4888-8888-888888888888';
          final response = await harness.patchJson(
            '$adminAuthOrgUnitsPath/$targetOrgUnit/name',
            const <String, Object?>{'name': 'No Reason Region'},
            idempotencyKey: 'idem-org-unit-rename-missing-reason',
          );

          expect(response.statusCode, equals(400));
          expect(
            response.json['error'],
            equals('missing_org_unit_rename_fields'),
          );
          expect(gateway.orgUnitRenames, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'PATCH org-unit name replays the original 2xx on idempotency reuse',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            const targetOrgUnit = '88888888-8888-4888-8888-888888888888';
            const key = 'idem-org-unit-rename-replay-1';
            final first = await harness.patchJson(
              '$adminAuthOrgUnitsPath/$targetOrgUnit/name',
              const <String, Object?>{
                'name': 'Replay Region',
                'admin_reason': 'first call',
              },
              idempotencyKey: key,
            );
            final second = await harness.patchJson(
              '$adminAuthOrgUnitsPath/$targetOrgUnit/name',
              const <String, Object?>{
                'name': 'Replay Region',
                'admin_reason': 'first call',
              },
              idempotencyKey: key,
            );

            expect(first.statusCode, equals(200));
            expect(second.statusCode, equals(200));
            expect(second.json, equals(first.json));
            // Replay collapses to a single backend mutation.
            expect(gateway.orgUnitRenames.length, equals(1));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'PATCH location org-unit moves the location and gates on team.roles.assign',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            const targetLocation = '33333333-3333-4333-8333-333333333333';
            final response = await harness.patchJson(
              '/v1/admin/auth/locations/$targetLocation/org-unit',
              const <String, Object?>{
                'parent_org_unit_id': '77777777-7777-4777-8777-777777777777',
                'admin_reason': 'operator requested location move',
              },
              idempotencyKey: 'idem-location-move-1',
            );

            expect(response.statusCode, equals(200));
            expect(guard.permissionKeys, equals(<String>['team.roles.assign']));
            final command = gateway.locationOrgUnitMoves.single;
            expect(command.actorUserId, equals(proxyAuthUserId));
            expect(command.operatorId, equals(proxyAuthOperatorId));
            expect(command.locationId, equals(proxyAuthLocationId));
            expect(command.targetLocationId, equals(targetLocation));
            expect(
              command.parentOrgUnitId,
              equals('77777777-7777-4777-8777-777777777777'),
            );
            expect(
              command.adminReason,
              equals('operator requested location move'),
            );
            expect(response.json['moved'], isTrue);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('PATCH location org-unit requires admin_reason', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          const targetLocation = '33333333-3333-4333-8333-333333333333';
          final response = await harness.patchJson(
            '/v1/admin/auth/locations/$targetLocation/org-unit',
            const <String, Object?>{
              'parent_org_unit_id': '77777777-7777-4777-8777-777777777777',
            },
            idempotencyKey: 'idem-location-move-missing-reason',
          );

          expect(response.statusCode, equals(400));
          expect(
            response.json['error'],
            equals('missing_location_org_unit_fields'),
          );
          expect(gateway.locationOrgUnitMoves, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test('PATCH org-unit suspend gates on team.hierarchy.suspend', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          const orgUnit = '66666666-6666-4666-8666-666666666666';
          final response = await harness.patchJson(
            '/v1/admin/auth/org-units/$orgUnit/suspend',
            const <String, Object?>{'admin_reason': 'pause this district'},
            idempotencyKey: 'idem-org-unit-suspend-1',
          );

          expect(response.statusCode, equals(200));
          expect(
            guard.permissionKeys,
            equals(<String>['team.hierarchy.suspend']),
          );
          final command = gateway.orgUnitLifecycle.single;
          expect(command.orgUnitId, equals(orgUnit));
          expect(command.adminReason, equals('pause this district'));
          expect(response.json['org_unit'], isA<Map<String, Object?>>());
        } finally {
          await harness.close();
        }
      });
    });

    test('POST org-unit delete gates on team.hierarchy.delete', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          const orgUnit = '66666666-6666-4666-8666-666666666666';
          final response = await harness.postJson(
            '/v1/admin/auth/org-units/$orgUnit/delete',
            const <String, Object?>{'admin_reason': 'empty hierarchy cleanup'},
            idempotencyKey: 'idem-org-unit-delete-1',
          );

          expect(response.statusCode, equals(200));
          expect(
            guard.permissionKeys,
            equals(<String>['team.hierarchy.delete']),
          );
          final command = gateway.orgUnitDeletes.single;
          expect(command.orgUnitId, equals(orgUnit));
          expect(command.adminReason, equals('empty hierarchy cleanup'));
          expect(response.json['deleted'], isTrue);
        } finally {
          await harness.close();
        }
      });
    });

    test('PATCH location suspend gates on team.hierarchy.suspend', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          const targetLocation = '33333333-3333-4333-8333-333333333333';
          final response = await harness.patchJson(
            '/v1/admin/auth/locations/$targetLocation/suspend',
            const <String, Object?>{'admin_reason': 'temporary closure'},
            idempotencyKey: 'idem-location-suspend-1',
          );

          expect(response.statusCode, equals(200));
          expect(
            guard.permissionKeys,
            equals(<String>['team.hierarchy.suspend']),
          );
          final command = gateway.locationLifecycle.single;
          expect(command.targetLocationId, equals(targetLocation));
          expect(command.adminReason, equals('temporary closure'));
          expect(response.json['location'], isA<Map<String, Object?>>());
        } finally {
          await harness.close();
        }
      });
    });

    test('admin guard denial stops auth operation before gateway', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: RecordingAdminGuard(
            decision: const ProxyAdminDeniedDefault(),
          ),
        );
        try {
          final response = await harness
              .postJson(adminAuthInvitesPath, <String, Object?>{
                'email': 'new.user@example.test',
                'role_id': 'supervisor',
                'scope_type': 'operator_wide',
              });

          expect(response.statusCode, equals(403));
          expect(response.json['error'], equals('permission_denied'));
          expect(gateway.inviteCreates, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'GET roles lists by scope and verifies team role view permission',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness.get(
              '$adminAuthRolesPath?scope=custom',
            );

            expect(response.statusCode, equals(200));
            expect(guard.permissionKeys, equals(<String>['team.roles.view']));
            expect(gateway.roleLists.single.scope, equals('custom'));
            final roles = response.json['roles'] as List<Object?>;
            final role = Map<String, Object?>.from(roles.single as Map);
            expect(role['role_id'], equals(proxyAuthRoleId));
            expect(role['permissions'], isA<List<Object?>>());
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('GET users and invites list Team data for Settings', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final users = await harness.get(adminAuthUsersPath);
          final invites = await harness.get(adminAuthInvitesPath);

          expect(users.statusCode, equals(200));
          expect(invites.statusCode, equals(200));
          expect(
            guard.permissionKeys,
            equals(<String>['team.users.view', 'team.users.view']),
          );
          expect(gateway.userLists.single.actorUserId, equals(proxyAuthUserId));
          expect(gateway.inviteLists.single.operatorId, equals(proxyAuthOperatorId));
          final userBody = users.json['users'] as List<Object?>;
          final inviteBody = invites.json['invites'] as List<Object?>;
          expect(
            Map<String, Object?>.from(userBody.single as Map)['user_role_id'],
            equals('grant-1'),
          );
          expect(
            Map<String, Object?>.from(inviteBody.single as Map)['invite_id'],
            equals('invite-1'),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test('GET users honors explicit admin target operator/location', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
          verifier: StaticVerifier(
            roles: const <String>['super_admin', 'roles_version:7'],
          ),
        );
        try {
          const targetOperatorId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
          const targetLocationId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
          final users = await harness.get(
            '$adminAuthUsersPath?operator_id=$targetOperatorId'
            '&location_id=$targetLocationId',
          );

          expect(users.statusCode, equals(200));
          expect(guard.permissionKeys, isEmpty);
          final command = gateway.userLists.single;
          expect(command.operatorId, equals(targetOperatorId));
          expect(command.locationId, equals(targetLocationId));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'PATCH admin user display name delegates idempotent profile update',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness.patchJson(
              '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}',
              const <String, Object?>{
                'display_name': 'Target Person',
                'admin_reason': 'operator requested correction',
              },
              idempotencyKey: 'idem-user-profile-patch-1',
            );

            expect(response.statusCode, equals(200));
            expect(guard.permissionKeys, equals(<String>['team.users.invite']));
            final command = gateway.profilePatches.single;
            expect(command.targetUserId, equals('target-user'));
            expect(command.displayName, equals('Target Person'));
            expect(command.email, isNull);
            expect(command.reason, equals('operator requested correction'));
            final user = response.json['user'] as Map<String, Object?>;
            expect(user['display_name'], equals('Target Person'));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'W-1 — PATCH admin user accepts combined email + display_name patch',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness.patchJson(
              '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}',
              const <String, Object?>{
                'display_name': 'Pat Lee',
                'email': 'pat.lee@example.test',
                'admin_reason': 'operator typo fix',
              },
              idempotencyKey: 'idem-user-edit-1',
            );

            expect(response.statusCode, equals(200));
            expect(guard.permissionKeys, equals(<String>['team.users.invite']));
            final command = gateway.profilePatches.single;
            expect(command.targetUserId, equals('target-user'));
            expect(command.displayName, equals('Pat Lee'));
            expect(command.email, equals('pat.lee@example.test'));
            expect(command.reason, equals('operator typo fix'));
            final user = response.json['user'] as Map<String, Object?>;
            expect(user['display_name'], equals('Pat Lee'));
            expect(user['email'], equals('pat.lee@example.test'));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'W-1 — PATCH admin user rejects all-null body shape with 400',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness.patchJson(
              '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}',
              const <String, Object?>{
                'admin_reason': 'operator requested correction',
              },
              idempotencyKey: 'idem-user-edit-no-fields',
            );

            expect(response.statusCode, equals(400));
            expect(
              response.json['error'],
              equals('missing_user_profile_fields'),
            );
            expect(gateway.profilePatches, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('W-1 — PATCH admin user rejects malformed email with 400', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.patchJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}',
            const <String, Object?>{
              'email': 'not-an-email',
              'admin_reason': 'operator typo fix',
            },
            idempotencyKey: 'idem-user-edit-bad-email',
          );

          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('invalid_email'));
          expect(gateway.profilePatches, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'W-3 — PATCH /v1/auth/self/profile patches display name + email',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness
                .patchJson('/v1/auth/self/profile', const <String, Object?>{
                  'display_name': 'Alex Morrison-Davies',
                  'email': 'alex@new-domain.com',
                }, idempotencyKey: 'idem-self-profile-1');

            expect(response.statusCode, equals(200));
            // The route MUST gate on the self-edit key, NOT on
            // team.users.invite (which gates admin-editing-someone-else).
            expect(
              guard.permissionKeys,
              equals(<String>['team.users.self_update']),
            );
            final command = gateway.selfProfilePatches.single;
            // Actor == target: the proxy resolves the actor from the
            // verified bearer token; no client-supplied target id.
            expect(command.actorUserId, equals(proxyAuthUserId));
            expect(command.displayName, equals('Alex Morrison-Davies'));
            expect(command.email, equals('alex@new-domain.com'));
            final user = response.json['user'] as Map<String, Object?>;
            expect(user['display_name'], equals('Alex Morrison-Davies'));
            expect(user['email'], equals('alex@new-domain.com'));
            expect(user['email_changed'], isTrue);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'W-3 — PATCH /v1/auth/self/profile rejects all-null body with 400',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness.patchJson(
              '/v1/auth/self/profile',
              const <String, Object?>{},
              idempotencyKey: 'idem-self-profile-no-fields',
            );

            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('no_profile_fields'));
            expect(gateway.selfProfilePatches, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'W-3 — PATCH /v1/auth/self/profile rejects malformed email with 400',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness.patchJson(
              '/v1/auth/self/profile',
              const <String, Object?>{'email': 'not-an-email'},
              idempotencyKey: 'idem-self-profile-bad-email',
            );

            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('invalid_email'));
            expect(gateway.selfProfilePatches, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('POST admin deactivate alias returns updated user payload', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}'
            '/deactivate',
            const <String, Object?>{
              'admin_reason': 'operator requested suspension',
            },
            idempotencyKey: 'idem-user-deactivate-1',
          );

          expect(response.statusCode, equals(200));
          expect(response.json['updated'], isTrue);
          expect(response.json['user'], isA<Map<String, Object?>>());
          expect(
            guard.permissionKeys,
            equals(<String>['team.users.deactivate']),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test('POST role create delegates custom role command', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.postJson(
            adminAuthRolesPath,
            const <String, Object?>{
              'role_key': 'kitchen_lead',
              'display_name': 'Kitchen Lead',
              'description': 'Can coach kitchen handoffs',
              'permissions': <Object?>[
                <String, Object?>{
                  'permission_key': 'team.users.view',
                  'effect': 'allow',
                },
              ],
            },
            idempotencyKey: 'idem-role-create-1',
          );

          expect(response.statusCode, equals(201));
          expect(
            guard.permissionKeys,
            equals(<String>['team.roles.create_custom']),
          );
          expect(gateway.roleCreates.single.roleKey, equals('kitchen_lead'));
          expect(gateway.roleCreates.single.permissions.single.effect, 'allow');
          expect(response.json['role'], isA<Map<String, Object?>>());
        } finally {
          await harness.close();
        }
      });
    });

    test('PATCH and DELETE roles delegate custom role commands', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final patch = await harness.patchJson(
            '$adminAuthRolePrefix${Uri.encodeComponent(proxyAuthRoleId)}',
            const <String, Object?>{
              'display_name': 'Kitchen Captain',
              'permissions': <Object?>[
                <String, Object?>{
                  'permission_key': 'team.users.invite',
                  'effect': 'inherit',
                },
              ],
            },
            idempotencyKey: 'idem-role-patch-1',
          );
          final delete = await harness.deleteJson(
            '$adminAuthRolePrefix${Uri.encodeComponent(proxyAuthRoleId)}',
            const <String, Object?>{'reason': 'cleanup'},
            idempotencyKey: 'idem-role-delete-1',
          );

          expect(patch.statusCode, equals(200));
          expect(delete.statusCode, equals(200));
          expect(
            guard.permissionKeys,
            equals(<String>[
              'team.roles.create_custom',
              'team.roles.create_custom',
            ]),
          );
          expect(gateway.rolePatches.single.roleId, equals(proxyAuthRoleId));
          expect(gateway.rolePatches.single.permissions.single.effect, isNull);
          expect(gateway.roleDeletes.single.reason, equals('cleanup'));
        } finally {
          await harness.close();
        }
      });
    });

  });
}
