// Phase 9 live-closeout - proxy auth-operation route tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/services/auth/account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_confirm_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_request_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/mfa/mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_gateway.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('Phase 9 auth-operation proxy routes', () {
    test('GET permission snapshot returns resolver payload', () async {
      await _withRealHttp(() async {
        final harness = await _RouteHarness.start(
          permissionSnapshotResolver: _FixedSnapshotResolver(
            ProxyPermissionSnapshot(
              userId: _userId,
              operatorId: _operatorId,
              locationId: _locationId,
              rolesVersion: 7,
              evaluatedAt: DateTime.utc(2026, 4, 28, 12),
              permissions: const <String, PermissionEffect>{
                'team.users.view': PermissionEffect.allow,
                'team.users.invite': PermissionEffect.deny,
              },
              requiresMfaKeys: const <String>{'billing.manage'},
            ),
          ),
        );
        try {
          final response = await harness.get(authPermissionsSnapshotPath);
          final body = response.json;

          expect(response.statusCode, equals(200));
          expect(body['user_id'], equals(_userId));
          expect(body['roles_version'], equals(7));
          expect(
            body['permissions'],
            equals(<String, Object?>{
              'team.users.view': 'allow',
              'team.users.invite': 'deny',
            }),
          );
          expect(body['requires_mfa'], equals(<Object?>['billing.manage']));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'GET account info is self-scoped and returns friendly payload',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingAccountInfoGateway();
          final harness = await _RouteHarness.start(
            accountInfoGateway: gateway,
          );
          try {
            final response = await harness.get(
              '$authAccountInfoPath?user_id=someone-else',
            );
            final body = response.json;

            expect(response.statusCode, equals(200));
            expect(gateway.requests.single.actorUserId, equals(_userId));
            expect(gateway.requests.single.operatorId, equals(_operatorId));
            expect(body['display_name'], equals('Jane Operator'));
            expect(body['location_label'], equals('Downtown'));
            expect(body['role_labels'], equals(<Object?>['Kitchen Lead']));
            expect(body['mfa_enabled'], isTrue);
            expect(body.containsKey('user_id'), isFalse);
            expect(body.containsKey('operator_id'), isFalse);
            expect(body.containsKey('location_id'), isFalse);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('GET account info does not require Team permission', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAccountInfoGateway();
        final guard = _RecordingAdminGuard(
          decision: const ProxyAdminDeniedDefault(),
        );
        final harness = await _RouteHarness.start(
          accountInfoGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.get(authAccountInfoPath);

          expect(response.statusCode, equals(200));
          expect(guard.permissionKeys, isEmpty);
          expect(gateway.requests, hasLength(1));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'POST invite create verifies permission and delegates command',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final guard = _RecordingAdminGuard();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness
                .postJson(adminAuthInvitesPath, <String, Object?>{
                  'email': 'new.user@example.test',
                  'role_id': 'operator_staff',
                  'scope_type': 'location',
                  'location_id': _locationId,
                }, idempotencyKey: 'idem-invite-create-1');

            expect(response.statusCode, equals(201));
            expect(response.json['invite_id'], equals('invite-1'));
            expect(guard.permissionKeys, equals(<String>['team.users.invite']));
            expect(
              gateway.inviteCreates.single.email,
              equals('new.user@example.test'),
            );
            expect(gateway.inviteCreates.single.actorUserId, equals(_userId));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST invite create accepts admin console role_key and primary_location_id',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness.postJson(
              adminAuthInvitesPath,
              <String, Object?>{
                'email': 'manager@example.test',
                'display_name': 'Manager User',
                'role_key': 'operator_manager',
                'primary_location_id': _locationId,
              },
              idempotencyKey: 'idem-invite-create-admin-console',
            );

            expect(response.statusCode, equals(201));
            final command = gateway.inviteCreates.single;
            expect(command.roleId, equals('operator_manager'));
            expect(command.scopeType, equals('location'));
            expect(command.targetLocationId, equals(_locationId));
            expect(response.json['invite'], isA<Map<String, Object?>>());
            final invite = response.json['invite'] as Map<String, Object?>;
            expect(invite['email'], equals('manager@example.test'));
            expect(invite['role_key'], equals('operator_manager'));
            expect(invite['primary_location_id'], equals(_locationId));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST invite create honors explicit admin target operator/location',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final guard = _RecordingAdminGuard();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
            verifier: _StaticVerifier(
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
                'role_key': 'operator_manager',
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
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness
              .postJson(adminAuthInvitesPath, <String, Object?>{
                'email': 'regional.user@example.test',
                'role_id': _roleId,
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
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final guard = _RecordingAdminGuard();
          final harness = await _RouteHarness.start(
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
              equals(_userId),
            );
            expect(
              gateway.orgHierarchyLists.single.operatorId,
              equals(_operatorId),
            );
            expect(
              gateway.orgHierarchyLists.single.locationId,
              equals(_locationId),
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
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final guard = _RecordingAdminGuard();
          final harness = await _RouteHarness.start(
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
            expect(command.actorUserId, equals(_userId));
            expect(command.operatorId, equals(_operatorId));
            expect(command.locationId, equals(_locationId));
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
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final guard = _RecordingAdminGuard();
          final harness = await _RouteHarness.start(
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
            expect(command.actorUserId, equals(_userId));
            expect(command.operatorId, equals(_operatorId));
            expect(command.locationId, equals(_locationId));
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
      'PATCH location org-unit moves the location and gates on team.roles.assign',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final guard = _RecordingAdminGuard();
          final harness = await _RouteHarness.start(
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
            expect(command.actorUserId, equals(_userId));
            expect(command.operatorId, equals(_operatorId));
            expect(command.locationId, equals(_locationId));
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
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
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

    test('admin guard denial stops auth operation before gateway', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(
            decision: const ProxyAdminDeniedDefault(),
          ),
        );
        try {
          final response = await harness
              .postJson(adminAuthInvitesPath, <String, Object?>{
                'email': 'new.user@example.test',
                'role_id': 'operator_staff',
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
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final guard = _RecordingAdminGuard();
          final harness = await _RouteHarness.start(
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
            expect(role['role_id'], equals(_roleId));
            expect(role['permissions'], isA<List<Object?>>());
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('GET users and invites list Team data for Settings', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
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
          expect(gateway.userLists.single.actorUserId, equals(_userId));
          expect(gateway.inviteLists.single.operatorId, equals(_operatorId));
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
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
          verifier: _StaticVerifier(
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
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final guard = _RecordingAdminGuard();
          final harness = await _RouteHarness.start(
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
            expect(command.reason, equals('operator requested correction'));
            final user = response.json['user'] as Map<String, Object?>;
            expect(user['display_name'], equals('Target Person'));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('POST admin deactivate alias returns updated user payload', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
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

    test('POST admin force-logout alias signs out target user', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}'
            '/force-logout',
            const <String, Object?>{'admin_reason': 'support lockout recovery'},
            idempotencyKey: 'idem-user-force-logout-1',
          );

          expect(response.statusCode, equals(200));
          expect(response.json['revoked_count'], equals(2));
          expect(
            guard.permissionKeys,
            equals(<String>['team.session.force_logout']),
          );
          final command = gateway.allSessionsRevokes.single;
          expect(command.actorUserId, equals(_userId));
          expect(command.targetUserId, equals('target-user'));
          expect(command.reason, equals('support lockout recovery'));
        } finally {
          await harness.close();
        }
      });
    });

    test('GET admin sessions returns Access screen session rows', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          verifier: _StaticVerifier(
            roles: const <String>['super_admin', 'roles_version:7'],
          ),
        );
        try {
          const targetOperatorId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
          const targetLocationId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
          final response = await harness.get(
            '$adminAuthSessionsPath?operator_id=$targetOperatorId'
            '&location_id=$targetLocationId',
          );

          expect(response.statusCode, equals(200));
          final sessions = response.json['sessions'] as List<Object?>;
          final row = Map<String, Object?>.from(sessions.single as Map);
          expect(
            row['session_id'],
            equals('88888888-8888-4888-8888-888888888888'),
          );
          expect(row['user_id'], equals(_userId));
          expect(row['user_email'], equals(_firebaseUid));
          expect(row['last_active_at'], equals('2026-04-28T12:00:00.000Z'));
          expect(
            gateway.activeSessionsLists.single.operatorId,
            targetOperatorId,
          );
          expect(
            gateway.activeSessionsLists.single.locationId,
            targetLocationId,
          );
        } finally {
          await harness.close();
        }
      });
    });

    test('GET admin audit-log returns audited-support row envelope', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        gateway.auditLogHasMore = true;
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          verifier: _StaticVerifier(
            roles: const <String>['super_admin', 'roles_version:7'],
          ),
        );
        try {
          const targetOperatorId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
          const targetLocationId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
          final response = await harness.get(
            '$adminAuthAuditLogPath?operator_id=$targetOperatorId'
            '&location_id=$targetLocationId&actions=sign_in&limit=25'
            '&cursor=5',
          );

          expect(response.statusCode, equals(200));
          final rows = response.json['rows'] as List<Object?>;
          final row = Map<String, Object?>.from(rows.single as Map);
          expect(row['action'], equals('auth.user.signed_in'));
          expect(row['actor_kind'], equals('team_member'));
          expect(row['operator_id'], equals(targetOperatorId));
          expect(response.json['next_cursor'], equals('30'));
          final command = gateway.auditLogLists.single;
          expect(command.operatorId, equals(targetOperatorId));
          expect(command.locationId, equals(targetLocationId));
          expect(command.eventKind, equals(AuthEventKind.signIn));
          expect(command.limit, equals(25));
          expect(command.offset, equals(5));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'POST admin session revoke delegates idempotent force logout',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final guard = _RecordingAdminGuard();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: guard,
          );
          try {
            final response = await harness.postJson(
              '$adminAuthSessionsPrefix${Uri.encodeComponent('sess-1')}/revoke',
              const <String, Object?>{
                'user_id': 'target-user',
                'admin_reason': 'operator requested forced sign-out',
              },
              idempotencyKey: 'idem-admin-session-revoke-1',
            );

            expect(response.statusCode, equals(200));
            expect(response.json['revoked'], isTrue);
            expect(
              guard.permissionKeys,
              equals(<String>['team.session.force_logout']),
            );
            final command = gateway.sessionRevokes.single;
            expect(command.sessionId, equals('sess-1'));
            expect(command.actorUserId, equals('target-user'));
            expect(
              command.reason,
              equals('operator requested forced sign-out'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('POST admin reset-mfa-factors gates on '
        'admin.users.reset_mfa_factors and queues delayed removal', () async {
      // 11A.14 ops-debt fix - the F&F admin support path gates on the
      // new `admin.users.reset_mfa_factors` permission key (not the
      // operator-side `team.users.reset_mfa` posture).
      await _withRealHttp(() async {
        final authGateway = _RecordingAuthOperationsGateway();
        final mfaGateway = _RecordingMfaOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
          authOperationsGateway: authGateway,
          mfaOperationsGateway: mfaGateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}/reset-mfa',
            const <String, Object?>{},
            idempotencyKey: 'idem-reset-mfa-1',
          );

          expect(response.statusCode, equals(200));
          expect(response.json['requested_count'], equals(1));
          expect(
            response.json['request_ids'],
            equals(<Object?>['removal-request-1']),
          );
          expect(
            guard.permissionKeys,
            equals(<String>['admin.users.reset_mfa_factors']),
          );
          expect(
            mfaGateway.resetUserFactors.single.targetUserId,
            'target-user',
          );
          expect(
            mfaGateway.resetUserFactors.single.stepUpProofId,
            startsWith('fresh-auth:'),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test('POST team user reset-mfa surfaces MFA gateway rejections', () async {
      await _withRealHttp(() async {
        final authGateway = _RecordingAuthOperationsGateway();
        final mfaGateway = _RecordingMfaOperationsGateway(
          resetError: const MfaOperationRejected(
            code: 'mfa_freshness_required',
            message: 'Sign in again before removing MFA.',
            statusCode: 403,
          ),
        );
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
          authOperationsGateway: authGateway,
          mfaOperationsGateway: mfaGateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}/reset-mfa',
            const <String, Object?>{},
            idempotencyKey: 'idem-reset-mfa-reject-1',
          );

          expect(response.statusCode, equals(403));
          expect(response.json['error'], equals('mfa_freshness_required'));
          expect(
            mfaGateway.resetUserFactors.single.targetUserId,
            'target-user',
          );
        } finally {
          await harness.close();
        }
      });
    });

    test('POST admin cancel-mfa-removal delegates cancellation gated on '
        'admin.users.reset_mfa_factors', () async {
      // 11A.14 ops-debt fix - admin path gates on the new admin key.
      await _withRealHttp(() async {
        final authGateway = _RecordingAuthOperationsGateway();
        final mfaGateway = _RecordingMfaOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
          authOperationsGateway: authGateway,
          mfaOperationsGateway: mfaGateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}/cancel-mfa-removal',
            const <String, Object?>{'request_id': 'removal-request-1'},
            idempotencyKey: 'idem-cancel-mfa-removal-1',
          );

          expect(response.statusCode, equals(200));
          expect(response.json['cancelled'], isTrue);
          expect(
            guard.permissionKeys,
            equals(<String>['admin.users.reset_mfa_factors']),
          );
          expect(mfaGateway.cancels.single.targetUserId, equals('target-user'));
          expect(
            mfaGateway.cancels.single.requestId,
            equals('removal-request-1'),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test('POST team-side reset-mfa keeps the operator-side gate '
        'team.users.reset_mfa', () async {
      // 11A.14 ops-debt fix - operator self-service paths
      // (`/v1/auth/team/users/...`) keep `team.users.reset_mfa` for
      // delayed authenticator removal. Only the admin support path
      // is upgraded to the new `admin.users.reset_mfa_factors` key.
      await _withRealHttp(() async {
        final authGateway = _RecordingAuthOperationsGateway();
        final mfaGateway = _RecordingMfaOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
          authOperationsGateway: authGateway,
          mfaOperationsGateway: mfaGateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.postJson(
            '/v1/auth/team/users/${Uri.encodeComponent('target-user')}/'
            'reset-mfa',
            const <String, Object?>{},
            idempotencyKey: 'idem-team-reset-mfa-1',
          );

          expect(response.statusCode, equals(200));
          expect(
            guard.permissionKeys,
            equals(<String>['team.users.reset_mfa']),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test('POST team user reset-mfa requires fresh admin sign-in', () async {
      await _withRealHttp(() async {
        final authGateway = _RecordingAuthOperationsGateway();
        final mfaGateway = _RecordingMfaOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
          verifier: _StaticVerifier(
            lastFreshAuthAt: DateTime.utc(2026, 4, 28, 11, 40),
          ),
          authOperationsGateway: authGateway,
          mfaOperationsGateway: mfaGateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}/reset-mfa',
            const <String, Object?>{},
          );

          expect(response.statusCode, equals(403));
          expect(response.json['error'], equals('mfa_freshness_required'));
          expect(mfaGateway.resetUserFactors, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test('POST role create delegates custom role command', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
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
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final patch = await harness.patchJson(
            '$adminAuthRolePrefix${Uri.encodeComponent(_roleId)}',
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
            '$adminAuthRolePrefix${Uri.encodeComponent(_roleId)}',
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
          expect(gateway.rolePatches.single.roleId, equals(_roleId));
          expect(gateway.rolePatches.single.permissions.single.effect, isNull);
          expect(gateway.roleDeletes.single.reason, equals('cleanup'));
        } finally {
          await harness.close();
        }
      });
    });

    test('POST password change delegates and returns HIBP flag', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingPasswordChangeGateway(
          result: const PasswordChangeCompleted(hibpUnavailable: true),
        );
        final harness = await _RouteHarness.start(
          passwordChangeGateway: gateway,
        );
        try {
          final response = await harness.postJson(
            authPasswordChangePath,
            const <String, Object?>{
              'current_password': 'old-secret',
              'new_password': 'new-secret',
            },
          );

          expect(response.statusCode, equals(200));
          expect(response.json['hibp_unavailable'], isTrue);
          expect(gateway.commands.single.actorUserId, equals(_userId));
          expect(gateway.commands.single.firebaseUid, equals(_firebaseUid));
          expect(gateway.commands.single.currentPassword, equals('old-secret'));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'POST password reset request delegates without bearer token',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingPasswordResetRequestGateway();
          final harness = await _RouteHarness.start(
            passwordResetRequestGateway: gateway,
          );
          try {
            final response = await harness.postJson(
              authPasswordResetRequestPath,
              const <String, Object?>{'email': 'demo.operator@forgeflow.test'},
              authorize: false,
              idempotencyKey: 'idem-req-1',
            );

            expect(response.statusCode, equals(200));
            expect(response.json['ok'], isTrue);
            expect(
              gateway.commands.single.email,
              equals('demo.operator@forgeflow.test'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('POST password reset request returns 200 even when email is unknown '
        '(privacy-preserving)', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingPasswordResetRequestGateway();
        final harness = await _RouteHarness.start(
          passwordResetRequestGateway: gateway,
        );
        try {
          final response = await harness.postJson(
            authPasswordResetRequestPath,
            const <String, Object?>{'email': 'unknown@example.test'},
            authorize: false,
            idempotencyKey: 'idem-req-unknown',
          );

          // Same body shape regardless of presence/absence so the
          // proxy never leaks whether the email matches an account.
          expect(response.statusCode, equals(200));
          expect(response.json['ok'], isTrue);
        } finally {
          await harness.close();
        }
      });
    });

    test('POST password reset request maps throttle to 429', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingPasswordResetRequestGateway(
          throwOnRequest: () => const PasswordResetRequestThrottled(),
        );
        final harness = await _RouteHarness.start(
          passwordResetRequestGateway: gateway,
        );
        try {
          final response = await harness.postJson(
            authPasswordResetRequestPath,
            const <String, Object?>{'email': 'demo.operator@forgeflow.test'},
            authorize: false,
            idempotencyKey: 'idem-req-throttled',
          );

          expect(response.statusCode, equals(429));
          expect(response.json['error'], equals('rate_limited'));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'POST password reset request returns 503 when gateway is not configured',
      () async {
        await _withRealHttp(() async {
          final harness = await _RouteHarness.start();
          try {
            final response = await harness.postJson(
              authPasswordResetRequestPath,
              const <String, Object?>{'email': 'demo.operator@forgeflow.test'},
              authorize: false,
              idempotencyKey: 'idem-req-unconfigured',
            );

            expect(response.statusCode, equals(503));
            expect(
              response.json['error'],
              equals('password_reset_request_not_configured'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST password reset request rejects missing email with 400',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingPasswordResetRequestGateway();
          final harness = await _RouteHarness.start(
            passwordResetRequestGateway: gateway,
          );
          try {
            final response = await harness.postJson(
              authPasswordResetRequestPath,
              const <String, Object?>{},
              authorize: false,
              idempotencyKey: 'idem-req-missing-email',
            );

            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('missing_email'));
            expect(gateway.commands, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST password reset request rejects missing Idempotency-Key with 400',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingPasswordResetRequestGateway();
          final harness = await _RouteHarness.start(
            passwordResetRequestGateway: gateway,
          );
          try {
            final response = await harness.postJson(
              authPasswordResetRequestPath,
              const <String, Object?>{'email': 'demo.operator@forgeflow.test'},
              authorize: false,
            );

            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('missing_idempotency_key'));
            expect(gateway.commands, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST password reset request replays cached response on retry with same key',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingPasswordResetRequestGateway();
          final harness = await _RouteHarness.start(
            passwordResetRequestGateway: gateway,
          );
          try {
            final first = await harness.postJson(
              authPasswordResetRequestPath,
              const <String, Object?>{'email': 'demo.operator@forgeflow.test'},
              authorize: false,
              idempotencyKey: 'idem-req-replay',
            );
            final second = await harness.postJson(
              authPasswordResetRequestPath,
              const <String, Object?>{'email': 'demo.operator@forgeflow.test'},
              authorize: false,
              idempotencyKey: 'idem-req-replay',
            );

            expect(first.statusCode, equals(200));
            expect(second.statusCode, equals(200));
            // Gateway only invoked once even though the client sent
            // the request twice — the second call replayed the cached
            // {200, ok:true} body without re-firing Firebase.
            expect(gateway.commands, hasLength(1));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('POST password reset request does NOT cache 5xx — a transient lookup '
        'blip can recover on the operator retry with the same key', () async {
      await _withRealHttp(() async {
        final gateway = _RecoveringPasswordResetRequestGateway(
          failuresBeforeSuccess: 1,
          failure: () => Exception('postgres lookup blip'),
        );
        final harness = await _RouteHarness.start(
          passwordResetRequestGateway: gateway,
        );
        try {
          final first = await harness.postJson(
            authPasswordResetRequestPath,
            const <String, Object?>{'email': 'demo.operator@forgeflow.test'},
            authorize: false,
            idempotencyKey: 'idem-req-recoverable',
          );
          expect(first.statusCode, equals(503));

          // Operator retries with the same key. If 5xx were cached,
          // they would replay the 503 forever. With 5xx-not-cached
          // semantics, the gateway is invoked again and (in this
          // test) succeeds.
          final second = await harness.postJson(
            authPasswordResetRequestPath,
            const <String, Object?>{'email': 'demo.operator@forgeflow.test'},
            authorize: false,
            idempotencyKey: 'idem-req-recoverable',
          );
          expect(second.statusCode, equals(200));
          expect(gateway.commands, hasLength(2));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'POST password reset confirm delegates without bearer token',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingPasswordResetConfirmGateway();
          final harness = await _RouteHarness.start(
            passwordResetConfirmGateway: gateway,
          );
          try {
            final response = await harness.postJson(
              authPasswordResetConfirmPath,
              const <String, Object?>{
                'oob_code': 'reset-code',
                'new_password': 'correct horse battery staple',
              },
              authorize: false,
              idempotencyKey: 'idem-confirm-1',
            );

            expect(response.statusCode, equals(200));
            expect(gateway.commands.single.oobCode, equals('reset-code'));
            expect(
              gateway.commands.single.newPassword,
              equals('correct horse battery staple'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('POST password reset confirm replays prior success on retry with same '
        'Idempotency-Key (oobCode is single-use, so retry without dedupe '
        'would surface password_reset_expired)', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingPasswordResetConfirmGateway();
        final harness = await _RouteHarness.start(
          passwordResetConfirmGateway: gateway,
        );
        try {
          final first = await harness.postJson(
            authPasswordResetConfirmPath,
            const <String, Object?>{
              'oob_code': 'reset-code',
              'new_password': 'correct horse battery staple',
            },
            authorize: false,
            idempotencyKey: 'idem-confirm-replay',
          );
          final second = await harness.postJson(
            authPasswordResetConfirmPath,
            const <String, Object?>{
              'oob_code': 'reset-code',
              'new_password': 'correct horse battery staple',
            },
            authorize: false,
            idempotencyKey: 'idem-confirm-replay',
          );

          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          expect(gateway.commands, hasLength(1));
        } finally {
          await harness.close();
        }
      });
    });

    test('POST MFA TOTP begin delegates and returns setup payload', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingMfaOperationsGateway();
        final harness = await _RouteHarness.start(
          mfaOperationsGateway: gateway,
        );
        try {
          final response = await harness.postJson(
            authMfaTotpBeginPath,
            const <String, Object?>{
              'user_email': 'owner@example.test',
              'issuer_name': 'Forge & Flow',
            },
          );

          expect(response.statusCode, equals(200));
          expect(response.json['factor_id'], equals('factor-session-1'));
          expect(gateway.begins.single.actorUserId, equals(_userId));
          expect(
            gateway.begins.single.authorizationIdToken,
            equals('test-token'),
          );
          expect(gateway.begins.single.userEmail, equals('owner@example.test'));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'POST MFA factors list delegates and returns factor summaries',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingMfaOperationsGateway(
            factors: <MfaFactorSummary>[
              MfaFactorSummary(
                factorId: 'totp-db-factor',
                factorType: 'totp',
                enrolledAt: DateTime.utc(2026, 4, 30, 12),
                issuerLabel: 'Forge & Flow',
              ),
            ],
          );
          final harness = await _RouteHarness.start(
            mfaOperationsGateway: gateway,
          );
          try {
            final response = await harness.postJson(
              authMfaFactorsListPath,
              const <String, Object?>{},
            );

            expect(response.statusCode, equals(200));
            final factors = response.json['factors']! as List<Object?>;
            final factor = Map<String, Object?>.from(factors.single! as Map);
            expect(factor['factor_id'], equals('totp-db-factor'));
            expect(gateway.lists.single.actorUserId, equals(_userId));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST MFA factors revoke delegates and returns delayed removal',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingMfaOperationsGateway(
            revokeResult: MfaRevokeFactorCompleted(
              revoked: false,
              requestId: 'mfa-removal-1',
              executeAfter: DateTime.utc(2026, 5, 1, 12),
            ),
          );
          final harness = await _RouteHarness.start(
            mfaOperationsGateway: gateway,
          );
          try {
            final response = await harness.postJson(
              authMfaFactorsRevokePath,
              const <String, Object?>{'factor_id': 'totp-db-factor'},
            );

            expect(response.statusCode, equals(200));
            expect(response.json['revoked'], isFalse);
            expect(response.json['request_id'], equals('mfa-removal-1'));
            expect(gateway.revokes.single.factorId, equals('totp-db-factor'));
            expect(
              gateway.revokes.single.stepUpProofId,
              startsWith('fresh-auth:'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST MFA factor removal cancel delegates and returns status',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingMfaOperationsGateway(
            cancelResult: const MfaCancelFactorRemovalCompleted(
              cancelled: true,
            ),
          );
          final harness = await _RouteHarness.start(
            mfaOperationsGateway: gateway,
          );
          try {
            final response = await harness.postJson(
              authMfaFactorsRemovalCancelPath,
              const <String, Object?>{'request_id': 'mfa-removal-1'},
            );

            expect(response.statusCode, equals(200));
            expect(response.json['cancelled'], isTrue);
            expect(gateway.cancels.single.requestId, equals('mfa-removal-1'));
            expect(
              gateway.cancels.single.authorizationIdToken,
              equals('test-token'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('POST MFA recovery request accepts contact-admin request', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingMfaRecoveryRequestGateway();
        final harness = await _RouteHarness.start(
          mfaRecoveryRequestGateway: gateway,
        );
        try {
          final response = await harness.postJson(
            authMfaRecoveryRequestPath,
            const <String, Object?>{
              'email': 'locked@example.test',
              'reason': 'no_factor_access',
            },
            authorize: false,
          );

          expect(response.statusCode, equals(202));
          expect(response.json['queued'], isTrue);
          expect(gateway.commands.single.email, equals('locked@example.test'));
          expect(gateway.commands.single.reason, equals('no_factor_access'));
        } finally {
          await harness.close();
        }
      });
    });

    test('GET active sessions delegates to AuthOperationsGateway with the '
        'verified scope and returns the projected payload', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
        );
        try {
          final response = await harness.get(authSessionsListPath);

          expect(response.statusCode, equals(200));
          final sessions = response.json['sessions'] as List<Object?>;
          expect(sessions, hasLength(1));
          final entry = sessions.single as Map<Object?, Object?>;
          expect(
            entry['session_id'],
            equals('88888888-8888-4888-8888-888888888888'),
          );
          expect(entry['device_label'], equals('Forge & Flow app · iOS'));
          expect(
            gateway.activeSessionsLists.single.actorUserId,
            equals(_userId),
          );
          expect(
            gateway.activeSessionsLists.single.operatorId,
            equals(_operatorId),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'GET active sessions returns 503 when the gateway is not configured',
      () async {
        await _withRealHttp(() async {
          final harness = await _RouteHarness.start();
          try {
            final response = await harness.get(authSessionsListPath);

            expect(response.statusCode, equals(503));
            expect(
              response.json['error'],
              equals('auth_operations_not_configured'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    // 11W.4 ops-debt - GET /v1/auth/team/sessions tests. The route
    // gates on `team.session.force_logout` and joins on
    // `users.operator_id` so cross-tenant rows never cross the seam.
    test('GET team sessions returns the projected payload with target user '
        'identity when the caller has team.session.force_logout', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        gateway.teamActiveSessions = <AuthTeamActiveSessionSummary>[
          AuthTeamActiveSessionSummary(
            session: AuthSessionSummary(
              sessionId: 'aaaaaaaa-1111-4111-8111-111111111111',
              deviceLabel: 'Forge & Flow on iPhone',
              createdAt: DateTime.utc(2026, 5, 5, 14),
              lastSeenAt: DateTime.utc(2026, 5, 5, 14, 30),
              geoCountry: 'CA',
            ),
            targetUserId: 'u-jordan',
            targetDisplayName: 'Jordan Lee',
            targetEmail: 'jordan.lee@demo.test',
          ),
        ];
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          permissionSnapshotResolver: _FixedSnapshotResolver(
            ProxyPermissionSnapshot(
              userId: _userId,
              operatorId: _operatorId,
              locationId: _locationId,
              rolesVersion: 7,
              evaluatedAt: DateTime.utc(2026, 5, 5),
              permissions: const <String, PermissionEffect>{
                'team.session.force_logout': PermissionEffect.allow,
              },
            ),
          ),
        );
        try {
          final response = await harness.get(authTeamSessionsListPath);
          expect(response.statusCode, equals(200));
          final sessions = response.json['sessions'] as List<Object?>;
          expect(sessions, hasLength(1));
          final entry = Map<String, Object?>.from(
            sessions.single as Map<Object?, Object?>,
          );
          expect(entry['user_id'], equals('u-jordan'));
          expect(entry['display_name'], equals('Jordan Lee'));
          expect(entry['email'], equals('jordan.lee@demo.test'));
          expect(
            entry['session_id'],
            equals('aaaaaaaa-1111-4111-8111-111111111111'),
          );
          expect(
            gateway.teamActiveSessionsLists.single.operatorId,
            equals(_operatorId),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'GET team sessions returns 403 without team.session.force_logout',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            permissionSnapshotResolver: _FixedSnapshotResolver(
              ProxyPermissionSnapshot(
                userId: _userId,
                operatorId: _operatorId,
                locationId: _locationId,
                rolesVersion: 7,
                evaluatedAt: DateTime.utc(2026, 5, 5),
                permissions: const <String, PermissionEffect>{
                  'team.session.force_logout': PermissionEffect.deny,
                },
              ),
            ),
          );
          try {
            final response = await harness.get(authTeamSessionsListPath);
            expect(response.statusCode, equals(403));
            expect(response.json['error'], equals('forbidden'));
            expect(gateway.teamActiveSessionsLists, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'GET team sessions returns 503 without permissionSnapshotResolver',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
          );
          try {
            final response = await harness.get(authTeamSessionsListPath);
            expect(response.statusCode, equals(503));
            expect(
              response.json['error'],
              equals('permission_snapshot_not_configured'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'GET audit log delegates with verified scope and returns the projected '
      'payload',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          gateway.auditLogHasMore = true;
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
          );
          try {
            final response = await harness.get(
              '$authAuditLogPath?event_kind=sign_in&limit=25&offset=0',
            );

            expect(response.statusCode, equals(200));
            final entries = response.json['entries'] as List<Object?>;
            expect(entries, hasLength(1));
            final entry = entries.single as Map<Object?, Object?>;
            expect(entry['event_type'], equals('auth.user.signed_in'));
            expect(entry['event_kind'], equals('sign_in'));
            expect(entry['friendly_label'], equals('Sign-in'));
            expect(response.json['has_more'], isTrue);
            expect(response.json['limit'], equals(25));
            expect(response.json['offset'], equals(0));
            expect(gateway.auditLogLists.single.actorUserId, equals(_userId));
            expect(
              gateway.auditLogLists.single.operatorId,
              equals(_operatorId),
            );
            expect(
              gateway.auditLogLists.single.eventKind,
              equals(AuthEventKind.signIn),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'GET audit log returns 503 when the gateway is not configured',
      () async {
        await _withRealHttp(() async {
          final harness = await _RouteHarness.start();
          try {
            final response = await harness.get(authAuditLogPath);
            expect(response.statusCode, equals(503));
            expect(
              response.json['error'],
              equals('auth_operations_not_configured'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('GET audit log without a bearer token returns 401, not 404', () async {
      await _withRealHttp(() async {
        final harness = await _RouteHarness.start(
          authOperationsGateway: _RecordingAuthOperationsGateway(),
        );
        try {
          final response = await harness.get(
            authAuditLogPath,
            authorize: false,
          );
          expect(response.statusCode, equals(401));
        } finally {
          await harness.close();
        }
      });
    });

    test('GET audit log forwards from/to ISO date params into the gateway '
        'command', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
        );
        try {
          final from = DateTime.utc(2026, 4, 1);
          final to = DateTime.utc(2026, 4, 30, 23, 59, 59);
          final response = await harness.get(
            '$authAuditLogPath'
            '?from=${Uri.encodeQueryComponent(from.toIso8601String())}'
            '&to=${Uri.encodeQueryComponent(to.toIso8601String())}',
          );
          expect(response.statusCode, equals(200));
          expect(gateway.auditLogLists.single.from, equals(from));
          expect(gateway.auditLogLists.single.to, equals(to));
        } finally {
          await harness.close();
        }
      });
    });

    test('GET audit log ignores client-supplied user_id and pins scope to the '
        'verified bearer token', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
        );
        try {
          final response = await harness.get(
            '$authAuditLogPath?user_id=spoofed-user&limit=10',
          );
          expect(response.statusCode, equals(200));
          // Even though the client sent ?user_id=..., the proxy
          // forwarded the verified bearer-token scope.
          expect(gateway.auditLogLists.single.actorUserId, equals(_userId));
        } finally {
          await harness.close();
        }
      });
    });

    // Theme B#5 N3 - server-side streaming CSV export.
    test(
      'GET audit log export streams RFC 4180 CSV with the export filename + '
      'attachment headers when the caller has team.audit_log.export',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingAuthOperationsGateway();
          gateway.auditLogEntries = <AuthEventListEntry>[
            AuthEventListEntry(
              eventId: 'aaaaaaaa-1111-4111-8111-111111111111',
              eventKind: AuthEventKind.signIn,
              eventType: 'auth.user.signed_in',
              friendlyLabel: 'Sign-in',
              occurredAt: DateTime.utc(2026, 4, 28, 12, 5),
              ip: '203.0.113.10',
              geoCountry: 'CA',
              payload: const <String, Object?>{'reason': 'totp,with comma'},
            ),
            AuthEventListEntry(
              eventId: 'bbbbbbbb-2222-4222-8222-222222222222',
              eventKind: AuthEventKind.password,
              eventType: 'auth.user.password_changed',
              friendlyLabel: 'Password changed',
              occurredAt: DateTime.utc(2026, 4, 28, 12, 10),
              payload: const <String, Object?>{
                'admin_reason': 'support: "rotated by F&F"',
              },
            ),
          ];
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            permissionSnapshotResolver: _FixedSnapshotResolver(
              ProxyPermissionSnapshot(
                userId: _userId,
                operatorId: _operatorId,
                locationId: _locationId,
                rolesVersion: 7,
                evaluatedAt: DateTime.utc(2026, 4, 28, 12),
                permissions: const <String, PermissionEffect>{
                  'team.audit_log.export': PermissionEffect.allow,
                },
              ),
            ),
          );
          try {
            final response = await harness.getRaw(authAuditLogExportPath);
            expect(response.statusCode, equals(200));
            expect(response.contentType?.toLowerCase(), startsWith('text/csv'));
            expect(
              response.headers['content-disposition']?.first,
              contains('attachment; filename="forge_flow_audit_log_'),
            );
            // RFC 4180 header row.
            final lines = response.body.split('\r\n');
            expect(
              lines.first,
              equals(
                'created_at,action,actor_user_id,actor_display_name,'
                'actor_email,actor_kind,target_kind,target_id,admin_reason,'
                'payload',
              ),
            );
            // Two body rows + a trailing empty entry from the final
            // \r\n line terminator.
            expect(lines.length, equals(4));
            // First body row: comma in payload forces RFC 4180 quoting
            // and the JSON-encoded payload's internal `"` doubles
            // ("" per RFC 4180 quoting).
            expect(lines[1], contains('auth.user.signed_in'));
            expect(lines[1], contains(_userId));
            expect(lines[1], contains('team_member'));
            expect(lines[1], contains('"{""reason"":""totp,with comma""}"'));
            // Second body row: admin_reason promotes actor_kind.
            expect(lines[2], contains('forge_admin'));
            expect(lines[2], contains('F&F admin'));
            // Verify the proxy paged the gateway with the verified
            // scope, not a client-supplied user_id.
            expect(gateway.auditLogLists.single.actorUserId, equals(_userId));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('GET audit log export forwards from/to/event_kind filters into the '
        'gateway command', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          permissionSnapshotResolver: _FixedSnapshotResolver(
            ProxyPermissionSnapshot(
              userId: _userId,
              operatorId: _operatorId,
              locationId: _locationId,
              rolesVersion: 7,
              evaluatedAt: DateTime.utc(2026, 4, 28, 12),
              permissions: const <String, PermissionEffect>{
                'team.audit_log.export': PermissionEffect.allow,
              },
            ),
          ),
        );
        try {
          final from = DateTime.utc(2026, 4, 1);
          final to = DateTime.utc(2026, 4, 30, 23, 59, 59);
          final response = await harness.getRaw(
            '$authAuditLogExportPath'
            '?event_kind=password'
            '&from=${Uri.encodeQueryComponent(from.toIso8601String())}'
            '&to=${Uri.encodeQueryComponent(to.toIso8601String())}',
          );
          expect(response.statusCode, equals(200));
          expect(gateway.auditLogLists.single.from, equals(from));
          expect(gateway.auditLogLists.single.to, equals(to));
          expect(
            gateway.auditLogLists.single.eventKind,
            equals(AuthEventKind.password),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test('GET audit log export returns 403 when the snapshot denies '
        'team.audit_log.export', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          permissionSnapshotResolver: _FixedSnapshotResolver(
            ProxyPermissionSnapshot(
              userId: _userId,
              operatorId: _operatorId,
              locationId: _locationId,
              rolesVersion: 7,
              evaluatedAt: DateTime.utc(2026, 4, 28, 12),
              permissions: const <String, PermissionEffect>{
                'team.audit_log.export': PermissionEffect.deny,
              },
            ),
          ),
        );
        try {
          final response = await harness.get(authAuditLogExportPath);
          expect(response.statusCode, equals(403));
          expect(response.json['error'], equals('permission_denied'));
          expect(
            response.json['permission_key'],
            equals('team.audit_log.export'),
          );
          expect(gateway.auditLogLists, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'GET audit log export returns 503 without a snapshot resolver',
      () async {
        await _withRealHttp(() async {
          final harness = await _RouteHarness.start(
            authOperationsGateway: _RecordingAuthOperationsGateway(),
          );
          try {
            final response = await harness.get(authAuditLogExportPath);
            expect(response.statusCode, equals(503));
            expect(
              response.json['error'],
              equals('permission_snapshot_not_configured'),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('GET audit log export pages the underlying gateway and emits a row '
        'per audit entry', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingAuthOperationsGateway();
        // Fill one full page + one partial page so the route has to
        // page through twice. The recording gateway's
        // listAuthEventsForActor honors the offset, so the second
        // page returns the trailing entries.
        gateway.auditLogEntries = <AuthEventListEntry>[
          for (var i = 0; i < 7; i += 1)
            AuthEventListEntry(
              eventId:
                  '${i.toString().padLeft(8, '0')}-1111-4111-8111-111111111111',
              eventKind: AuthEventKind.signIn,
              eventType: 'auth.user.signed_in',
              friendlyLabel: 'Sign-in',
              occurredAt: DateTime.utc(
                2026,
                4,
                28,
                12,
              ).add(Duration(minutes: i)),
            ),
        ];
        gateway.auditLogPagedMode = true;
        gateway.auditLogPagedPageSize = 5;
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          permissionSnapshotResolver: _FixedSnapshotResolver(
            ProxyPermissionSnapshot(
              userId: _userId,
              operatorId: _operatorId,
              locationId: _locationId,
              rolesVersion: 7,
              evaluatedAt: DateTime.utc(2026, 4, 28, 12),
              permissions: const <String, PermissionEffect>{
                'team.audit_log.export': PermissionEffect.allow,
              },
            ),
          ),
        );
        try {
          final response = await harness.getRaw(authAuditLogExportPath);
          expect(response.statusCode, equals(200));
          final lines = response.body.split('\r\n');
          // 1 header + 7 body rows + trailing empty.
          expect(lines.length, equals(9));
          expect(gateway.auditLogLists.length, greaterThanOrEqualTo(2));
          // Offsets advance across calls.
          expect(gateway.auditLogLists[0].offset, equals(0));
          expect(gateway.auditLogLists[1].offset, equals(5));
        } finally {
          await harness.close();
        }
      });
    });

    test('POST MFA factors revoke requires a fresh sign-in', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingMfaOperationsGateway();
        final harness = await _RouteHarness.start(
          verifier: _StaticVerifier(
            lastFreshAuthAt: DateTime.utc(2026, 4, 28, 11, 40),
          ),
          mfaOperationsGateway: gateway,
        );
        try {
          final response = await harness.postJson(
            authMfaFactorsRevokePath,
            const <String, Object?>{'factor_id': 'totp-db-factor'},
          );

          expect(response.statusCode, equals(403));
          expect(response.json['error'], equals('mfa_freshness_required'));
          expect(gateway.revokes, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });
  });
}

const _userId = '11111111-1111-4111-8111-111111111111';
const _firebaseUid = 'firebase-auth-uid';
const _operatorId = '22222222-2222-4222-8222-222222222222';
const _locationId = '33333333-3333-4333-8333-333333333333';
const _roleId = '44444444-4444-4444-8444-444444444444';

Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

class _RouteHarness {
  _RouteHarness._({
    required this.server,
    required this.client,
    required this.baseUri,
  });

  final HttpServer server;
  final HttpClient client;
  final Uri baseUri;

  static Future<_RouteHarness> start({
    AccountInfoGateway? accountInfoGateway,
    ProxyPermissionSnapshotResolver? permissionSnapshotResolver,
    AuthOperationsGateway? authOperationsGateway,
    ProxyAdminPermissionGuard? adminPermissionGuard,
    PasswordChangeGateway? passwordChangeGateway,
    PasswordResetConfirmGateway? passwordResetConfirmGateway,
    PasswordResetRequestGateway? passwordResetRequestGateway,
    MfaOperationsGateway? mfaOperationsGateway,
    MfaRecoveryRequestGateway? mfaRecoveryRequestGateway,
    ProxyJwtVerifier? verifier,
    ProxyAuthIdempotencyCache? authIdempotencyCache,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final guard = ProxyRequestGuard(verifier: verifier ?? _StaticVerifier());
    // Per-test cache so the global default doesn't carry replays
    // across test cases.
    final perTestCache = authIdempotencyCache ?? ProxyAuthIdempotencyCache();
    server.listen((request) async {
      await routeRequest(
        request,
        guard,
        accountInfoGateway: accountInfoGateway,
        permissionSnapshotResolver: permissionSnapshotResolver,
        authOperationsGateway: authOperationsGateway,
        adminPermissionGuard: adminPermissionGuard,
        passwordChangeGateway: passwordChangeGateway,
        passwordResetConfirmGateway: passwordResetConfirmGateway,
        passwordResetRequestGateway: passwordResetRequestGateway,
        mfaOperationsGateway: mfaOperationsGateway,
        mfaRecoveryRequestGateway: mfaRecoveryRequestGateway,
        authIdempotencyCache: perTestCache,
        now: () => DateTime.utc(2026, 4, 28, 12),
      );
    });
    return _RouteHarness._(
      server: server,
      client: HttpClient(),
      baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
    );
  }

  Future<_HttpJsonResponse> get(String path, {bool authorize = true}) async {
    final request = await client.getUrl(baseUri.resolve(path));
    if (authorize) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    }
    final response = await request.close();
    return _HttpJsonResponse.from(response);
  }

  /// Streaming-friendly variant of [get] that surfaces the raw body
  /// + headers (rather than forcing a JSON decode). Used by the CSV
  /// export tests so they can assert on the streamed bytes + the
  /// `text/csv` + `Content-Disposition` headers.
  Future<_HttpRawResponse> getRaw(String path, {bool authorize = true}) async {
    final request = await client.getUrl(baseUri.resolve(path));
    if (authorize) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    }
    final response = await request.close();
    return _HttpRawResponse.from(response);
  }

  Future<_HttpJsonResponse> postJson(
    String path,
    Map<String, Object?> body, {
    bool authorize = true,
    String? idempotencyKey,
  }) async {
    final request = await client.postUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    if (authorize) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    }
    if (idempotencyKey != null) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    return _HttpJsonResponse.from(response);
  }

  Future<_HttpJsonResponse> patchJson(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
  }) async {
    final request = await client.patchUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    if (idempotencyKey != null) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    return _HttpJsonResponse.from(response);
  }

  Future<_HttpJsonResponse> deleteJson(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
  }) async {
    final request = await client.deleteUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    if (idempotencyKey != null) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    return _HttpJsonResponse.from(response);
  }

  Future<void> close() async {
    client.close(force: true);
    await server.close(force: true);
  }
}

class _HttpJsonResponse {
  const _HttpJsonResponse({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, Object?> json;

  static Future<_HttpJsonResponse> from(HttpClientResponse response) async {
    final raw = await utf8.decodeStream(response.cast<List<int>>());
    return _HttpJsonResponse(
      statusCode: response.statusCode,
      json: raw.isEmpty
          ? const <String, Object?>{}
          : Map<String, Object?>.from(jsonDecode(raw) as Map),
    );
  }
}

class _HttpRawResponse {
  const _HttpRawResponse({
    required this.statusCode,
    required this.body,
    required this.contentType,
    required this.headers,
  });

  final int statusCode;
  final String body;
  final String? contentType;
  final Map<String, List<String>> headers;

  static Future<_HttpRawResponse> from(HttpClientResponse response) async {
    final raw = await utf8.decodeStream(response.cast<List<int>>());
    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = List<String>.from(values);
    });
    return _HttpRawResponse(
      statusCode: response.statusCode,
      body: raw,
      contentType: response.headers.contentType?.toString(),
      headers: headers,
    );
  }
}

class _StaticVerifier implements ProxyJwtVerifier {
  _StaticVerifier({
    DateTime? lastFreshAuthAt,
    this.roles = const <String>['roles_version:7'],
  }) : lastFreshAuthAt = lastFreshAuthAt ?? DateTime.utc(2026, 4, 28, 11, 59);

  final DateTime lastFreshAuthAt;
  final List<String> roles;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    return ProxyJwtClaims(
      userId: _userId,
      firebaseUid: _firebaseUid,
      operatorId: _operatorId,
      locationId: _locationId,
      roles: roles,
      rolesVersion: 7,
      lastFreshAuthAt: lastFreshAuthAt,
    );
  }
}

class _FixedSnapshotResolver implements ProxyPermissionSnapshotResolver {
  const _FixedSnapshotResolver(this.snapshot);

  final ProxyPermissionSnapshot snapshot;

  @override
  Future<ProxyPermissionSnapshot> load(OperatorContext scope) async => snapshot;
}

class _RecordingAccountInfoGateway implements AccountInfoGateway {
  final requests = <AccountInfoRequest>[];

  @override
  Future<AccountInfo> load(AccountInfoRequest request) async {
    requests.add(request);
    return AccountInfo(
      displayName: 'Jane Operator',
      email: 'jane@example.test',
      statusLabel: 'Active',
      locationLabel: 'Downtown',
      roleLabels: const <String>['Kitchen Lead'],
      mfaEnabled: true,
      lastLoginAt: DateTime.utc(2026, 4, 28, 11),
      lastActiveAt: DateTime.utc(2026, 4, 28, 12),
      passwordUpdatedAt: DateTime.utc(2026, 4, 20, 9),
    );
  }
}

class _RecordingAdminGuard implements ProxyAdminPermissionGuard {
  _RecordingAdminGuard({this.decision = const ProxyAdminAllowed()});

  final ProxyAdminGuardDecision decision;
  final permissionKeys = <String>[];

  @override
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  ) async {
    permissionKeys.add(context.requestedPermissionKey);
    return decision;
  }
}

class _RecordingPasswordChangeGateway implements PasswordChangeGateway {
  _RecordingPasswordChangeGateway({
    this.result = const PasswordChangeCompleted(),
  });

  final PasswordChangeCompleted result;
  final commands = <PasswordChangeCommand>[];

  @override
  Future<PasswordChangeCompleted> changePassword(
    PasswordChangeCommand command,
  ) async {
    commands.add(command);
    return result;
  }
}

class _RecordingPasswordResetConfirmGateway
    implements PasswordResetConfirmGateway {
  final commands = <PasswordResetConfirmCommand>[];

  @override
  Future<PasswordResetConfirmCompleted> confirmPasswordReset(
    PasswordResetConfirmCommand command,
  ) async {
    commands.add(command);
    return const PasswordResetConfirmCompleted();
  }
}

class _RecordingPasswordResetRequestGateway
    implements PasswordResetRequestGateway {
  _RecordingPasswordResetRequestGateway({this.throwOnRequest});

  final Object Function()? throwOnRequest;
  final commands = <PasswordResetRequestCommand>[];

  @override
  Future<PasswordResetRequestAccepted> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    commands.add(command);
    if (throwOnRequest != null) {
      throw throwOnRequest!();
    }
    return const PasswordResetRequestAccepted();
  }
}

/// Recording gateway that throws [failure] for the first
/// [failuresBeforeSuccess] calls and then succeeds. Used to assert
/// the proxy idempotency cache lets a same-key retry hit a fresh
/// gateway invocation after a 5xx (so transient infrastructure
/// blips can recover without a key rotation).
class _RecoveringPasswordResetRequestGateway
    implements PasswordResetRequestGateway {
  _RecoveringPasswordResetRequestGateway({
    required this.failuresBeforeSuccess,
    required this.failure,
  });

  final int failuresBeforeSuccess;
  final Object Function() failure;
  final commands = <PasswordResetRequestCommand>[];

  @override
  Future<PasswordResetRequestAccepted> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    commands.add(command);
    if (commands.length <= failuresBeforeSuccess) {
      throw failure();
    }
    return const PasswordResetRequestAccepted();
  }
}

class _RecordingMfaOperationsGateway implements MfaOperationsGateway {
  _RecordingMfaOperationsGateway({
    this.resetError,
    this.factors = const <MfaFactorSummary>[],
    this.revokeResult = const MfaRevokeFactorCompleted(revoked: false),
    this.cancelResult = const MfaCancelFactorRemovalCompleted(cancelled: true),
  });

  final MfaOperationRejected? resetError;
  final List<MfaFactorSummary> factors;
  final MfaRevokeFactorCompleted revokeResult;
  final MfaCancelFactorRemovalCompleted cancelResult;
  final resetUserFactors = <MfaRevokeUserFactorsCommand>[];
  final begins = <MfaTotpBeginCommand>[];
  final lists = <MfaListFactorsCommand>[];
  final revokes = <MfaRevokeFactorCommand>[];
  final cancels = <MfaCancelFactorRemovalCommand>[];

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(
    MfaTotpBeginCommand command,
  ) async {
    begins.add(command);
    return const TotpEnrollmentSetup(
      factorId: 'factor-session-1',
      secretBase32: 'JBSWY3DPEHPK3PXP',
      otpAuthUrl: 'otpauth://totp/Forge%20%26%20Flow:owner@example.test',
    );
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(
    MfaListFactorsCommand command,
  ) async {
    lists.add(command);
    return MfaListFactorsCompleted(factors: factors);
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) async {
    revokes.add(command);
    return revokeResult;
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) async {
    cancels.add(command);
    return cancelResult;
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) async {
    resetUserFactors.add(command);
    final error = resetError;
    if (error != null) throw error;
    return MfaRevokeUserFactorsCompleted(
      requestedCount: 1,
      requestIds: const <String>['removal-request-1'],
      executeAfter: DateTime.utc(2026, 5, 1, 12),
    );
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) async {
    return const MfaTotpConfirmCompleted(factorId: 'factor-db-1');
  }
}

class _RecordingMfaRecoveryRequestGateway implements MfaRecoveryRequestGateway {
  final commands = <MfaRecoveryRequestCommand>[];

  @override
  Future<MfaRecoveryRequestAccepted> requestRecovery(
    MfaRecoveryRequestCommand command,
  ) async {
    commands.add(command);
    return const MfaRecoveryRequestAccepted(
      queued: true,
      requestId: 'recovery-request-1',
    );
  }
}

class _RecordingAuthOperationsGateway implements AuthOperationsGateway {
  final userLists = <TeamUserListCommand>[];
  final roleLists = <TeamRoleCatalogListCommand>[];
  final roleCreates = <TeamRoleCreateCommand>[];
  final rolePatches = <TeamRolePatchCommand>[];
  final roleDeletes = <TeamRoleDeleteCommand>[];
  final inviteLists = <TeamInviteListCommand>[];
  final inviteCreates = <TeamInviteCreateCommand>[];
  final profilePatches = <TeamUserProfilePatchCommand>[];

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) async {
    userLists.add(command);
    return const TeamUsersListed(
      users: <TeamUserListEntry>[
        TeamUserListEntry(
          userId: 'target-user',
          email: 'target@example.test',
          displayName: 'Target User',
          roleId: _roleId,
          roleLabel: 'Kitchen Lead',
          status: 'active',
          mfaEnrolled: true,
          userRoleId: 'grant-1',
          // Phase 9.UX.grant-payload — surface a representative
          // multi-scope grant set so the route serializer's `grants`
          // field is exercised end-to-end.
          grants: <TeamGrantSnapshot>[
            TeamGrantSnapshot(
              userRoleId: 'grant-1',
              roleId: _roleId,
              scopeType: 'operator_wide',
            ),
            TeamGrantSnapshot(
              userRoleId: 'grant-2',
              roleId: _roleId,
              scopeType: 'org_unit',
              orgUnitId: 'unit-east',
              sourceOrgUnitId: 'unit-east',
              effectiveLocationIds: <String>['loc-vancouver', 'loc-burnaby'],
            ),
            TeamGrantSnapshot(
              userRoleId: 'grant-3',
              roleId: _roleId,
              scopeType: 'location',
              locationId: 'loc-vancouver',
              effectiveLocationIds: <String>['loc-vancouver'],
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<TeamRoleCatalogListed> listRoles(
    TeamRoleCatalogListCommand command,
  ) async {
    roleLists.add(command);
    return TeamRoleCatalogListed(roles: <TeamRoleCatalogEntry>[_teamRole]);
  }

  @override
  Future<TeamUserProfilePatched> patchUserProfile(
    TeamUserProfilePatchCommand command,
  ) async {
    profilePatches.add(command);
    return TeamUserProfilePatched(
      user: TeamUserListEntry(
        userId: command.targetUserId,
        email: 'target@example.test',
        displayName: command.displayName,
        roleId: _roleId,
        roleLabel: 'Kitchen Lead',
        status: 'active',
        mfaEnrolled: true,
      ),
    );
  }

  @override
  Future<TeamRoleCreated> createRole(TeamRoleCreateCommand command) async {
    roleCreates.add(command);
    return const TeamRoleCreated(role: _teamRole);
  }

  @override
  Future<TeamRolePatched> patchRole(TeamRolePatchCommand command) async {
    rolePatches.add(command);
    return const TeamRolePatched(role: _teamRole, bumpedUsers: 2);
  }

  @override
  Future<TeamRoleDeleted> deleteRole(TeamRoleDeleteCommand command) async {
    roleDeletes.add(command);
    return const TeamRoleDeleted(deleted: true);
  }

  @override
  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command) async {
    inviteLists.add(command);
    return TeamInvitesListed(
      invites: <TeamInviteListEntry>[
        TeamInviteListEntry(
          inviteId: 'invite-1',
          email: 'new@example.test',
          roleId: _roleId,
          roleLabel: 'Kitchen Lead',
          scopeType: 'operator_wide',
          expiresAt: DateTime.utc(2026, 5, 5, 12),
          createdAt: DateTime.utc(2026, 4, 29, 12),
        ),
      ],
    );
  }

  @override
  Future<TeamInviteCreated> createInvite(
    TeamInviteCreateCommand command,
  ) async {
    inviteCreates.add(command);
    return TeamInviteCreated(
      inviteId: 'invite-1',
      expiresAt: DateTime.utc(2026, 5, 5, 12),
    );
  }

  @override
  Future<TeamInviteRevoked> revokeInvite(
    TeamInviteRevokeCommand command,
  ) async {
    return const TeamInviteRevoked(revoked: true);
  }

  @override
  Future<TeamUserStatusUpdated> suspendUser(
    TeamUserStatusCommand command,
  ) async {
    return const TeamUserStatusUpdated(updated: true);
  }

  @override
  Future<TeamUserStatusUpdated> reactivateUser(
    TeamUserStatusCommand command,
  ) async {
    return const TeamUserStatusUpdated(updated: true);
  }

  @override
  Future<TeamUserStatusUpdated> softDeleteUser(
    TeamUserStatusCommand command,
  ) async {
    return const TeamUserStatusUpdated(updated: true);
  }

  @override
  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command,
  ) async {
    return const TeamPasswordResetQueued();
  }

  @override
  Future<TeamMfaResetQueued> requestMfaReset(
    TeamMfaResetCommand command,
  ) async {
    return const TeamMfaResetQueued(requestedCount: 1);
  }

  @override
  Future<TeamMfaRemovalCancelled> cancelMfaRemoval(
    TeamMfaRemovalCancelCommand command,
  ) async {
    return const TeamMfaRemovalCancelled(cancelled: true);
  }

  @override
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command,
  ) async {
    return const TeamRoleGrantCreated(userRoleId: 'grant-1');
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command,
  ) async {
    return const TeamRoleGrantRevoked(revoked: true);
  }

  final orgHierarchyLists = <TeamOrgHierarchyListCommand>[];
  final orgUnitCreates = <TeamOrgUnitCreateCommand>[];
  final orgUnitMoves = <TeamOrgUnitMoveCommand>[];
  final locationOrgUnitMoves = <TeamLocationOrgUnitMoveCommand>[];

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) async {
    orgHierarchyLists.add(command);
    return const TeamOrgHierarchyListed(
      orgUnits: <TeamOrgUnitEntry>[
        TeamOrgUnitEntry(
          orgUnitId: '66666666-6666-4666-8666-666666666666',
          parentOrgUnitId: null,
          unitType: 'corp',
          path: 'acme',
          label: 'ACME',
        ),
      ],
      locations: <TeamOrgLocationEntry>[
        TeamOrgLocationEntry(
          locationId: '33333333-3333-4333-8333-333333333333',
          parentOrgUnitId: '66666666-6666-4666-8666-666666666666',
          orgUnitPath: 'acme',
          label: 'Downtown',
        ),
      ],
    );
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command,
  ) async {
    orgUnitCreates.add(command);
    return const TeamOrgUnitCreated(
      orgUnitId: '77777777-7777-4777-8777-777777777777',
    );
  }

  @override
  Future<TeamOrgUnitMoved> moveOrgUnit(TeamOrgUnitMoveCommand command) async {
    orgUnitMoves.add(command);
    return TeamOrgUnitMoved(
      orgUnit: TeamOrgUnitEntry(
        orgUnitId: command.orgUnitId,
        parentOrgUnitId: command.parentOrgUnitId,
        unitType: 'region',
        path: 'acme.east',
        label: 'East Region',
      ),
    );
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command,
  ) async {
    locationOrgUnitMoves.add(command);
    return const TeamLocationOrgUnitMoved(moved: true);
  }

  final activeSessionsLists = <AuthActiveSessionsListCommand>[];
  final sessionRevokes = <AuthSessionRevokeCommand>[];
  final allSessionsRevokes = <AuthAllSessionsRevokeCommand>[];

  List<AuthSessionSummary> activeSessions = <AuthSessionSummary>[
    AuthSessionSummary(
      sessionId: '88888888-8888-4888-8888-888888888888',
      deviceLabel: 'Forge & Flow app · iOS',
      userAgent: 'Forge&Flow/1.0',
      ip: '203.0.113.10',
      geoCountry: 'CA',
      createdAt: DateTime.utc(2026, 4, 28, 12),
      lastSeenAt: DateTime.utc(2026, 4, 28, 12),
    ),
  ];

  @override
  Future<AuthActiveSessionsListed> listActiveSessions(
    AuthActiveSessionsListCommand command,
  ) async {
    activeSessionsLists.add(command);
    return AuthActiveSessionsListed(
      sessions: List<AuthSessionSummary>.unmodifiable(activeSessions),
    );
  }

  final teamActiveSessionsLists = <AuthTeamActiveSessionsListCommand>[];
  List<AuthTeamActiveSessionSummary> teamActiveSessions =
      <AuthTeamActiveSessionSummary>[];

  @override
  Future<AuthTeamActiveSessionsListed> listTeamActiveSessions(
    AuthTeamActiveSessionsListCommand command,
  ) async {
    teamActiveSessionsLists.add(command);
    return AuthTeamActiveSessionsListed(
      sessions: List<AuthTeamActiveSessionSummary>.unmodifiable(
        teamActiveSessions,
      ),
    );
  }

  @override
  Future<AuthSessionRevoked> revokeSession(
    AuthSessionRevokeCommand command,
  ) async {
    sessionRevokes.add(command);
    return const AuthSessionRevoked(revoked: true);
  }

  @override
  Future<AuthAllSessionsRevoked> signOutAll(
    AuthAllSessionsRevokeCommand command,
  ) async {
    allSessionsRevokes.add(command);
    return const AuthAllSessionsRevoked(revokedCount: 2);
  }

  final auditLogLists = <AuthEventListCommand>[];

  List<AuthEventListEntry> auditLogEntries = <AuthEventListEntry>[
    AuthEventListEntry(
      eventId: '99999999-9999-4999-8999-999999999999',
      eventKind: AuthEventKind.signIn,
      eventType: 'auth.user.signed_in',
      friendlyLabel: 'Sign-in',
      occurredAt: DateTime.utc(2026, 4, 28, 12),
      ip: '203.0.113.10',
      geoCountry: 'CA',
    ),
  ];
  bool auditLogHasMore = false;

  /// When true, the recording gateway honors offset + slices
  /// [auditLogEntries] using [auditLogPagedPageSize] (not the
  /// command's limit, so the export route's larger inner page size
  /// can still be forced into multiple roundtrips). `hasMore` is set
  /// based on whether the slice covers the tail. The export route
  /// relies on this so the paging loop exercises the seam.
  bool auditLogPagedMode = false;
  int auditLogPagedPageSize = 100;

  @override
  Future<AuthEventsListed> listAuthEventsForActor(
    AuthEventListCommand command,
  ) async {
    auditLogLists.add(command);
    if (auditLogPagedMode) {
      final offset = command.offset < 0 ? 0 : command.offset;
      final pageSize = auditLogPagedPageSize < 1 ? 1 : auditLogPagedPageSize;
      final start = offset.clamp(0, auditLogEntries.length);
      final end = (start + pageSize).clamp(0, auditLogEntries.length);
      final slice = auditLogEntries.sublist(start, end);
      return AuthEventsListed(
        entries: List<AuthEventListEntry>.unmodifiable(slice),
        hasMore: end < auditLogEntries.length,
      );
    }
    return AuthEventsListed(
      entries: List<AuthEventListEntry>.unmodifiable(auditLogEntries),
      hasMore: auditLogHasMore,
    );
  }
}

const _teamRole = TeamRoleCatalogEntry(
  roleId: _roleId,
  roleKey: 'kitchen_lead',
  displayName: 'Kitchen Lead',
  description: 'Can coach kitchen handoffs',
  isSeeded: false,
  isEditable: true,
  operatorId: _operatorId,
  permissions: <TeamRolePermissionRule>[
    TeamRolePermissionRule(permissionKey: 'team.users.view', effect: 'allow'),
  ],
);
