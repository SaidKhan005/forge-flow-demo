// Phase 9.UX.grant-payload — `/v1/admin/auth/users` route response
// includes per-grant payload.
//
// Asserts the proxy's team-users JSON shape gains the additive `grants`
// array. Runs an in-process HttpServer against the production
// `routeRequest` so the response shape is exercised end-to-end (no
// shortcut around the route handler).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';

const String _userId = '11111111-1111-4111-8111-111111111111';
const String _firebaseUid = 'firebase-auth-uid';
const String _operatorId = '22222222-2222-4222-8222-222222222222';
const String _locationId = '33333333-3333-4333-8333-333333333333';
const String _roleId = '44444444-4444-4444-8444-444444444444';

void main() {
  group('GET /v1/admin/auth/users grants payload', () {
    test(
      'serializes the additive grants array alongside existing fields',
      () async {
        await _withRealHttp(() async {
          final gateway = _GrantsRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness.get(adminAuthUsersPath);

            expect(response.statusCode, equals(200));
            final users = response.json['users'] as List<Object?>;
            expect(users, hasLength(1));
            final user = Map<String, Object?>.from(users.single as Map);
            // Backward-compat: existing fields are unchanged.
            expect(user['user_role_id'], equals('grant-1'));
            expect(user['mfa_enrolled'], isTrue);
            // New additive field: grants array carries the per-grant
            // scope payload the inheritance hint consumes.
            final grants = user['grants'] as List<Object?>;
            expect(grants, hasLength(3));
            final byScope = <String, Map<String, Object?>>{
              for (final entry in grants)
                Map<String, Object?>.from(entry as Map)['scope_type'] as String:
                    Map<String, Object?>.from(entry),
            };
            expect(byScope.keys.toSet(), <String>{
              'operator_wide',
              'org_unit',
              'location',
            });
            expect(
              byScope['operator_wide']!['user_role_id'],
              equals('grant-op-wide'),
            );
            // Authoritative role labels travel with the payload so the
            // client never freezes to raw role UUIDs while the role
            // catalog loads asynchronously.
            expect(byScope['operator_wide']!['role_label'], equals('Owner'));
            expect(byScope['org_unit']!['org_unit_id'], equals('unit-east'));
            expect(byScope['org_unit']!['role_label'], equals('Manager'));
            expect(
              byScope['org_unit']!['effective_location_ids'],
              equals(<Object?>['loc-vancouver', 'loc-burnaby']),
            );
            expect(
              byScope['location']!['location_id'],
              equals('loc-vancouver'),
            );
            expect(byScope['location']!['role_label'], equals('Supervisor'));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('backward-compat: zero-grant users still serialize without breaking '
        'existing callers', () async {
      await _withRealHttp(() async {
        final gateway = _GrantsRecordingAuthOperationsGateway(
          emitGrants: false,
        );
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.get(adminAuthUsersPath);

          expect(response.statusCode, equals(200));
          final users = response.json['users'] as List<Object?>;
          final user = Map<String, Object?>.from(users.single as Map);
          // The grants key is always present (additive field) but
          // the array is empty so existing callers see a no-op shape.
          expect(user['grants'], equals(const <Object?>[]));
          // Existing fields untouched.
          expect(user['user_id'], equals('zero-grant-user'));
          expect(user['user_role_id'], isNull);
        } finally {
          await harness.close();
        }
      });
    });

    test('self-service alias serializes the same grants payload', () async {
      await _withRealHttp(() async {
        final gateway = _GrantsRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.get(authTeamUsersPath);

          expect(response.statusCode, equals(200));
          final users = response.json['users'] as List<Object?>;
          expect(users, hasLength(1));
          final user = Map<String, Object?>.from(users.single as Map);
          expect(user['user_id'], equals('multi-grant-user'));
          expect(user['grants'], isA<List<Object?>>());
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'self-service role and hierarchy aliases route to auth operations',
      () async {
        await _withRealHttp(() async {
          final gateway = _GrantsRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final rolesResponse = await harness.get(authTeamRolesPath);
            expect(rolesResponse.statusCode, equals(200));
            final roles = rolesResponse.json['roles'] as List<Object?>;
            expect(
              Map<String, Object?>.from(roles.single as Map)['display_name'],
              equals('Owner'),
            );

            final hierarchyResponse = await harness.get(authTeamOrgUnitsPath);
            expect(hierarchyResponse.statusCode, equals(200));
            expect(hierarchyResponse.json['org_units'], isA<List<Object?>>());
            expect(hierarchyResponse.json['locations'], isA<List<Object?>>());
          } finally {
            await harness.close();
          }
        });
      },
    );
  });

  // Phase 11A.10 / Hard Promise #7 — every proxy write is idempotent.
  // The 9 self-service auth-operations write branches must reject
  // requests without an `Idempotency-Key` header (400) and replay
  // a cached response when the same key arrives a second time so a
  // retry does not double-mutate.
  group('self-service auth write branches enforce Idempotency-Key', () {
    test('POST /v1/admin/auth/roles rejects missing Idempotency-Key', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.postJson(
            adminAuthRolesPath,
            const <String, Object?>{
              'role_key': 'kitchen_lead',
              'display_name': 'Kitchen Lead',
            },
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.roleCreates, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'POST /v1/admin/auth/roles replays cached response on key reuse',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final first = await harness.postJson(
              adminAuthRolesPath,
              const <String, Object?>{
                'role_key': 'kitchen_lead',
                'display_name': 'Kitchen Lead',
              },
              idempotencyKey: 'idem-role-create-1',
            );
            final second = await harness.postJson(
              adminAuthRolesPath,
              const <String, Object?>{
                'role_key': 'kitchen_lead',
                'display_name': 'Kitchen Lead',
              },
              idempotencyKey: 'idem-role-create-1',
            );
            expect(first.statusCode, equals(201));
            expect(second.statusCode, equals(201));
            // Gateway only invoked once even though the client sent
            // the request twice — the second call replayed the cached
            // 201 body without re-running the multi-system write.
            expect(gateway.roleCreates, hasLength(1));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'PATCH /v1/admin/auth/roles/{id} rejects missing Idempotency-Key',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness.patchJson(
              '$adminAuthRolePrefix$_roleId',
              const <String, Object?>{'display_name': 'Updated'},
            );
            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('missing_idempotency_key'));
            expect(gateway.rolePatches, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('POST /v1/admin/auth/roles/{id}/permissions edits seeded role '
        'with admin key, reason, and idempotency', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final first = await harness.postJson(
            '$adminAuthRolePrefix$_roleId/permissions',
            const <String, Object?>{
              'permission_keys': <String>['team.users.view'],
              'admin_reason': 'Quarterly seeded-role review',
            },
            idempotencyKey: 'idem-edit-seeded-1',
          );
          final second = await harness.postJson(
            '$adminAuthRolePrefix$_roleId/permissions',
            const <String, Object?>{
              'permission_keys': <String>['team.users.view'],
              'admin_reason': 'Quarterly seeded-role review',
            },
            idempotencyKey: 'idem-edit-seeded-1',
          );

          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          expect(gateway.seededRoleEdits, hasLength(1));
          expect(
            gateway.seededRoleEdits.single.permissionKeys,
            equals(<String>['team.users.view']),
          );
          expect(
            gateway.seededRoleEdits.single.reason,
            equals('Quarterly seeded-role review'),
          );
          expect(
            guard.requestedPermissionKeys,
            contains('admin.roles.edit_seeded'),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test('POST /v1/admin/auth/roles/{id}/permissions rejects missing '
        'admin_reason before gateway write', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.postJson(
            '$adminAuthRolePrefix$_roleId/permissions',
            const <String, Object?>{
              'permission_keys': <String>['team.users.view'],
            },
            idempotencyKey: 'idem-edit-seeded-missing-reason',
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_admin_reason'));
          expect(gateway.seededRoleEdits, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'PATCH /v1/admin/auth/users/{id} rejects missing Idempotency-Key',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness.patchJson(
              '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}',
              const <String, Object?>{
                'display_name': 'Target Person',
                'admin_reason': 'operator requested correction',
              },
            );
            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('missing_idempotency_key'));
            expect(gateway.profilePatches, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'PATCH /v1/admin/auth/users/{id} replays cached response on key reuse',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final first = await harness.patchJson(
              '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}',
              const <String, Object?>{
                'display_name': 'Target Person',
                'admin_reason': 'operator requested correction',
              },
              idempotencyKey: 'idem-profile-patch-1',
            );
            final second = await harness.patchJson(
              '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}',
              const <String, Object?>{
                'display_name': 'Target Person',
                'admin_reason': 'operator requested correction',
              },
              idempotencyKey: 'idem-profile-patch-1',
            );
            expect(first.statusCode, equals(200));
            expect(second.statusCode, equals(200));
            expect(first.json, equals(second.json));
            expect(gateway.profilePatches, hasLength(1));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'DELETE /v1/admin/auth/roles/{id} rejects missing Idempotency-Key',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness.deleteJson(
              '$adminAuthRolePrefix$_roleId',
              const <String, Object?>{'reason': 'cleanup'},
            );
            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('missing_idempotency_key'));
            expect(gateway.roleDeletes, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST /v1/admin/auth/invites rejects missing Idempotency-Key',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness
                .postJson(adminAuthInvitesPath, const <String, Object?>{
                  'email': 'new@example.test',
                  'role_id': _roleId,
                  'scope_type': 'operator_wide',
                });
            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('missing_idempotency_key'));
            expect(gateway.inviteCreates, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST /v1/admin/auth/invites replays cached response on key reuse',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final first = await harness
                .postJson(adminAuthInvitesPath, const <String, Object?>{
                  'email': 'new@example.test',
                  'role_id': _roleId,
                  'scope_type': 'operator_wide',
                }, idempotencyKey: 'idem-invite-1');
            final second = await harness
                .postJson(adminAuthInvitesPath, const <String, Object?>{
                  'email': 'new@example.test',
                  'role_id': _roleId,
                  'scope_type': 'operator_wide',
                }, idempotencyKey: 'idem-invite-1');
            expect(first.statusCode, equals(201));
            expect(second.statusCode, equals(201));
            // Gateway invoked exactly once across the two retries.
            expect(gateway.inviteCreates, hasLength(1));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'DELETE /v1/admin/auth/invites/{id} rejects missing Idempotency-Key',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness.deleteJson(
              '$adminAuthInvitePrefix${Uri.encodeComponent('invite-1')}',
              const <String, Object?>{},
            );
            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('missing_idempotency_key'));
            expect(gateway.inviteRevokes, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('Wave 2 W-2 — DELETE /v1/admin/auth/invites/{id} happy path forwards '
        'the trimmed `reason` field onto TeamInviteRevokeCommand.reason and '
        'returns the gateway revoked bool', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.deleteJson(
            '$adminAuthInvitePrefix${Uri.encodeComponent('invite-9')}',
            const <String, Object?>{'reason': '  wrong email, resending  '},
            idempotencyKey: 'idemp-cancel-1',
          );
          expect(response.statusCode, equals(200));
          expect(response.json['revoked'], isTrue);
          expect(gateway.inviteRevokes, hasLength(1));
          final command = gateway.inviteRevokes.single;
          expect(command.inviteId, equals('invite-9'));
          // Proxy trims operator-supplied reason before handing to
          // the gateway so audit never stores whitespace padding.
          expect(command.reason, equals('wrong email, resending'));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'Wave 2 W-2 — DELETE /v1/admin/auth/invites/{id} accepts a body '
      'without a `reason` field and lands a null reason on the command',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness.deleteJson(
              '$adminAuthInvitePrefix${Uri.encodeComponent('invite-noreason')}',
              const <String, Object?>{},
              idempotencyKey: 'idemp-cancel-noreason',
            );
            expect(response.statusCode, equals(200));
            expect(gateway.inviteRevokes, hasLength(1));
            expect(gateway.inviteRevokes.single.reason, isNull);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('Wave 2 W-2 — DELETE /v1/admin/auth/invites/{id} idempotent replay '
        '(same Idempotency-Key) invokes the gateway exactly once', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final first = await harness.deleteJson(
            '$adminAuthInvitePrefix${Uri.encodeComponent('invite-replay')}',
            const <String, Object?>{'reason': 'cleanup'},
            idempotencyKey: 'idemp-cancel-replay',
          );
          final second = await harness.deleteJson(
            '$adminAuthInvitePrefix${Uri.encodeComponent('invite-replay')}',
            const <String, Object?>{'reason': 'cleanup'},
            idempotencyKey: 'idemp-cancel-replay',
          );
          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          // Gateway invoked exactly once across the two retries.
          expect(gateway.inviteRevokes, hasLength(1));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'POST /v1/admin/auth/role-grants rejects missing Idempotency-Key',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness
                .postJson(adminAuthRoleGrantsPath, const <String, Object?>{
                  'user_id': 'target-user',
                  'role_id': _roleId,
                  'scope_type': 'operator_wide',
                });
            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('missing_idempotency_key'));
            expect(gateway.roleGrantCreates, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST /v1/admin/auth/role-grants rejects role_key without role_id',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness
                .postJson(adminAuthRoleGrantsPath, const <String, Object?>{
                  'user_id': 'target-user',
                  'role_key': 'custom.floor_captain',
                  'scope_type': 'operator_wide',
                }, idempotencyKey: 'idem-role-grant-role-key');
            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('role_id_required'));
            expect(gateway.roleGrantCreates, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST /v1/admin/auth/role-grants rejects role_key even with role_id',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness.postJson(
              adminAuthRoleGrantsPath,
              const <String, Object?>{
                'user_id': 'target-user',
                'role_id': _roleId,
                'role_key': 'custom.floor_captain',
                'scope_type': 'operator_wide',
              },
              idempotencyKey: 'idem-role-grant-role-key-with-id',
            );
            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('role_id_required'));
            expect(gateway.roleGrantCreates, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('DELETE /v1/admin/auth/role-grants/{id} rejects missing '
        'Idempotency-Key', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.deleteJson(
            '$adminAuthRoleGrantPrefix${Uri.encodeComponent('grant-1')}',
            const <String, Object?>{'user_id': 'target-user'},
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.roleGrantRevokes, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'POST /v1/admin/auth/org-units rejects missing Idempotency-Key',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness
                .postJson(adminAuthOrgUnitsPath, const <String, Object?>{
                  'parent_org_unit_id': 'unit-root',
                  'unit_type': 'region',
                  'label': 'east',
                  'name': 'East Region',
                });
            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('missing_idempotency_key'));
            expect(gateway.orgUnitCreates, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('PATCH /v1/admin/auth/locations/{id}/org-unit rejects missing '
        'Idempotency-Key', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.patchJson(
            '/v1/admin/auth/locations/$_locationId/org-unit',
            const <String, Object?>{
              'parent_org_unit_id': 'unit-east',
              'admin_reason': 'admin hierarchy setup',
            },
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.locationOrgUnitMoves, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'rejects empty Idempotency-Key (whitespace-only) the same as missing',
      () async {
        await _withRealHttp(() async {
          final gateway = _IdempotencyRecordingAuthOperationsGateway();
          final harness = await _RouteHarness.start(
            authOperationsGateway: gateway,
            adminPermissionGuard: _RecordingAdminGuard(),
          );
          try {
            final response = await harness.postJson(
              adminAuthRolesPath,
              const <String, Object?>{
                'role_key': 'kitchen_lead',
                'display_name': 'Kitchen Lead',
              },
              idempotencyKey: '   ',
            );
            expect(response.statusCode, equals(400));
            expect(response.json['error'], equals('missing_idempotency_key'));
            expect(gateway.roleCreates, isEmpty);
          } finally {
            await harness.close();
          }
        });
      },
    );
  });

  // Audit follow-up to commit 76021d28 — the user-actions sub-route
  // (POST /v1/admin/auth/users/{id}/{action}) is the parallel write
  // surface that escaped the original 9-branch sweep. Same Hard Promise
  // applies: every proxy write must be idempotent, so each of the six
  // actions (suspend, reactivate, soft-delete, reset-password,
  // reset-mfa, cancel-mfa-removal) must reject requests without an
  // `Idempotency-Key` header and replay a cached response on key reuse.
  group('user-actions sub-route enforces Idempotency-Key', () {
    test('POST suspend rejects missing Idempotency-Key', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}/suspend',
            const <String, Object?>{'reason': 'no-show'},
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.userSuspends, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test('POST reactivate rejects missing Idempotency-Key', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}'
            '/reactivate',
            const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.userReactivates, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test('POST soft-delete rejects missing Idempotency-Key', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}'
            '/soft-delete',
            const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.userSoftDeletes, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test('POST reset-password rejects missing Idempotency-Key', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}'
            '/reset-password',
            const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.passwordResetRequests, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test('POST reset-mfa rejects missing Idempotency-Key', () async {
      await _withRealHttp(() async {
        final authGateway = _IdempotencyRecordingAuthOperationsGateway();
        final mfaGateway = _IdempotencyRecordingMfaOperationsGateway();
        // Pin clock + verifier so freshAuth passes (1-min difference,
        // well within the 5-min window) and the request reaches the
        // idempotency check.
        final harness = await _RouteHarness.start(
          authOperationsGateway: authGateway,
          mfaOperationsGateway: mfaGateway,
          adminPermissionGuard: _RecordingAdminGuard(),
          verifier: _StaticVerifier(
            lastFreshAuthAt: DateTime.utc(2026, 4, 28, 11, 59),
          ),
          now: () => DateTime.utc(2026, 4, 28, 12),
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}'
            '/reset-mfa',
            const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(mfaGateway.resetUserFactors, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test('POST cancel-mfa-removal rejects missing Idempotency-Key', () async {
      await _withRealHttp(() async {
        final authGateway = _IdempotencyRecordingAuthOperationsGateway();
        final mfaGateway = _IdempotencyRecordingMfaOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: authGateway,
          mfaOperationsGateway: mfaGateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}'
            '/cancel-mfa-removal',
            const <String, Object?>{'request_id': 'removal-request-1'},
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(mfaGateway.cancels, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test('POST suspend replays cached response on key reuse', () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final first = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}/suspend',
            const <String, Object?>{'reason': 'no-show'},
            idempotencyKey: 'idem-user-suspend-1',
          );
          final second = await harness.postJson(
            '$adminAuthUsersPrefix${Uri.encodeComponent('target-user')}/suspend',
            const <String, Object?>{'reason': 'no-show'},
            idempotencyKey: 'idem-user-suspend-1',
          );
          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          expect(first.json, equals(second.json));
          // Gateway invoked exactly once across the two retries — the
          // second call replayed the cached body without re-firing
          // the suspend write.
          expect(gateway.userSuspends, hasLength(1));
        } finally {
          await harness.close();
        }
      });
    });
  });
}

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
    AuthOperationsGateway? authOperationsGateway,
    ProxyAdminPermissionGuard? adminPermissionGuard,
    MfaOperationsGateway? mfaOperationsGateway,
    ProxyJwtVerifier? verifier,
    DateTime Function()? now,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final guard = ProxyRequestGuard(verifier: verifier ?? _StaticVerifier());
    server.listen((request) async {
      await routeRequest(
        request,
        guard,
        authOperationsGateway: authOperationsGateway,
        adminPermissionGuard: adminPermissionGuard,
        mfaOperationsGateway: mfaOperationsGateway,
        now: now,
      );
    });
    final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
    final client = HttpClient();
    return _RouteHarness._(server: server, client: client, baseUri: baseUri);
  }

  Future<_HarnessResponse> get(String path) async {
    final request = await client.openUrl('GET', baseUri.resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake-token');
    final response = await request.close();
    final body = await utf8.decodeStream(response.cast<List<int>>());
    final decoded = body.isEmpty
        ? const <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(body) as Map);
    return _HarnessResponse(statusCode: response.statusCode, json: decoded);
  }

  Future<_HarnessResponse> postJson(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
  }) async {
    return _sendJson('POST', path, body, idempotencyKey: idempotencyKey);
  }

  Future<_HarnessResponse> patchJson(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
  }) async {
    return _sendJson('PATCH', path, body, idempotencyKey: idempotencyKey);
  }

  Future<_HarnessResponse> deleteJson(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
  }) async {
    return _sendJson('DELETE', path, body, idempotencyKey: idempotencyKey);
  }

  Future<_HarnessResponse> _sendJson(
    String method,
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
  }) async {
    final request = await client.openUrl(method, baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake-token');
    if (idempotencyKey != null) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    final raw = await utf8.decodeStream(response.cast<List<int>>());
    final decoded = raw.isEmpty
        ? const <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(raw) as Map);
    return _HarnessResponse(statusCode: response.statusCode, json: decoded);
  }

  Future<void> close() async {
    client.close(force: true);
    await server.close(force: true);
  }
}

class _HarnessResponse {
  const _HarnessResponse({required this.statusCode, required this.json});
  final int statusCode;
  final Map<String, Object?> json;
}

class _StaticVerifier implements ProxyJwtVerifier {
  _StaticVerifier({DateTime? lastFreshAuthAt})
    : lastFreshAuthAt = lastFreshAuthAt ?? DateTime.utc(2026, 4, 28, 11, 59);

  final DateTime lastFreshAuthAt;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    return ProxyJwtClaims(
      userId: _userId,
      firebaseUid: _firebaseUid,
      operatorId: _operatorId,
      locationId: _locationId,
      roles: const <String>['roles_version:7'],
      rolesVersion: 7,
      lastFreshAuthAt: lastFreshAuthAt,
    );
  }
}

class _RecordingAdminGuard implements ProxyAdminPermissionGuard {
  final requestedPermissionKeys = <String>[];

  @override
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  ) async {
    requestedPermissionKeys.add(context.requestedPermissionKey);
    return const ProxyAdminAllowed();
  }
}

class _GrantsRecordingAuthOperationsGateway implements AuthOperationsGateway {
  _GrantsRecordingAuthOperationsGateway({this.emitGrants = true});

  final bool emitGrants;

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) async {
    if (!emitGrants) {
      return const TeamUsersListed(
        users: <TeamUserListEntry>[
          TeamUserListEntry(
            userId: 'zero-grant-user',
            email: 'zero@example.test',
            displayName: 'Zero Grants',
            roleId: _roleId,
            roleLabel: 'Staff',
            status: 'active',
          ),
        ],
      );
    }
    return const TeamUsersListed(
      users: <TeamUserListEntry>[
        TeamUserListEntry(
          userId: 'multi-grant-user',
          email: 'multi@example.test',
          displayName: 'Multi Grant',
          roleId: _roleId,
          roleLabel: 'Owner',
          status: 'active',
          mfaEnrolled: true,
          userRoleId: 'grant-1',
          grants: <TeamGrantSnapshot>[
            TeamGrantSnapshot(
              userRoleId: 'grant-op-wide',
              roleId: _roleId,
              roleLabel: 'Owner',
              scopeType: 'operator_wide',
            ),
            TeamGrantSnapshot(
              userRoleId: 'grant-org-east',
              roleId: _roleId,
              roleLabel: 'Manager',
              scopeType: 'org_unit',
              orgUnitId: 'unit-east',
              sourceOrgUnitId: 'unit-east',
              effectiveLocationIds: <String>['loc-vancouver', 'loc-burnaby'],
            ),
            TeamGrantSnapshot(
              userRoleId: 'grant-loc-1',
              roleId: _roleId,
              roleLabel: 'Supervisor',
              scopeType: 'location',
              locationId: 'loc-vancouver',
              effectiveLocationIds: <String>['loc-vancouver'],
            ),
          ],
        ),
      ],
    );
  }

  // ── Other AuthOperationsGateway methods are not exercised here ──

  @override
  Future<TeamRoleCatalogListed> listRoles(
    TeamRoleCatalogListCommand command,
  ) async {
    return const TeamRoleCatalogListed(
      roles: <TeamRoleCatalogEntry>[
        TeamRoleCatalogEntry(
          roleId: _roleId,
          roleKey: 'operator_owner',
          displayName: 'Owner',
          description: 'Can manage the operator account.',
          isSeeded: true,
          isEditable: false,
          permissions: <TeamRolePermissionRule>[
            TeamRolePermissionRule(
              permissionKey: 'team.users.view',
              effect: 'allow',
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) async {
    return const TeamOrgHierarchyListed(
      orgUnits: <TeamOrgUnitEntry>[
        TeamOrgUnitEntry(
          orgUnitId: 'unit-root',
          parentOrgUnitId: null,
          unitType: 'operator',
          path: 'root',
          label: 'Operator root',
        ),
      ],
      locations: <TeamOrgLocationEntry>[
        TeamOrgLocationEntry(
          locationId: _locationId,
          parentOrgUnitId: 'unit-root',
          orgUnitPath: 'root',
          label: 'Primary location',
        ),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'method ${invocation.memberName} is not exercised by the grants route '
      'test',
    );
  }
}

/// Records every auth-operations write so the idempotency-key tests
/// can assert the gateway was (or was not) invoked across retries.
/// Returns deterministic success bodies from each write so a same-key
/// replay can be compared byte-for-byte against the first response.
class _IdempotencyRecordingAuthOperationsGateway
    implements AuthOperationsGateway {
  final roleCreates = <TeamRoleCreateCommand>[];
  final rolePatches = <TeamRolePatchCommand>[];
  final seededRoleEdits = <TeamSeededRolePermissionsEditCommand>[];
  final roleDeletes = <TeamRoleDeleteCommand>[];
  final inviteCreates = <TeamInviteCreateCommand>[];
  final inviteRevokes = <TeamInviteRevokeCommand>[];
  final roleGrantCreates = <TeamRoleGrantCreateCommand>[];
  final roleGrantRevokes = <TeamRoleGrantRevokeCommand>[];
  final orgUnitCreates = <TeamOrgUnitCreateCommand>[];
  final orgUnitMoves = <TeamOrgUnitMoveCommand>[];
  final locationOrgUnitMoves = <TeamLocationOrgUnitMoveCommand>[];
  final profilePatches = <TeamUserProfilePatchCommand>[];
  final userSuspends = <TeamUserStatusCommand>[];
  final userReactivates = <TeamUserStatusCommand>[];
  final userSoftDeletes = <TeamUserStatusCommand>[];
  final passwordResetRequests = <TeamPasswordResetCommand>[];

  static const TeamRoleCatalogEntry _role = TeamRoleCatalogEntry(
    roleId: _roleId,
    roleKey: 'kitchen_lead',
    displayName: 'Kitchen Lead',
    description: 'Recorded role',
    isSeeded: false,
    isEditable: true,
    operatorId: _operatorId,
    permissions: <TeamRolePermissionRule>[],
  );

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) async {
    return const TeamUsersListed(
      users: <TeamUserListEntry>[
        TeamUserListEntry(
          userId: 'target-user',
          email: 'target@example.test',
          displayName: 'Target User',
          roleId: _roleId,
          roleLabel: 'Staff',
          status: 'active',
        ),
      ],
    );
  }

  @override
  Future<TeamRoleCreated> createRole(TeamRoleCreateCommand command) async {
    roleCreates.add(command);
    return const TeamRoleCreated(role: _role);
  }

  @override
  Future<TeamRolePatched> patchRole(TeamRolePatchCommand command) async {
    rolePatches.add(command);
    return const TeamRolePatched(role: _role, bumpedUsers: 0);
  }

  @override
  Future<TeamRolePatched> editSeededRolePermissions(
    TeamSeededRolePermissionsEditCommand command,
  ) async {
    seededRoleEdits.add(command);
    return const TeamRolePatched(role: _role, bumpedUsers: 0);
  }

  @override
  Future<TeamRoleDeleted> deleteRole(TeamRoleDeleteCommand command) async {
    roleDeletes.add(command);
    return const TeamRoleDeleted(deleted: true);
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
    inviteRevokes.add(command);
    return const TeamInviteRevoked(revoked: true);
  }

  @override
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command,
  ) async {
    roleGrantCreates.add(command);
    return const TeamRoleGrantCreated(userRoleId: 'grant-1');
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command,
  ) async {
    roleGrantRevokes.add(command);
    return const TeamRoleGrantRevoked(revoked: true);
  }

  @override
  Future<TeamUserProfilePatched> patchUserProfile(
    TeamUserProfilePatchCommand command,
  ) async {
    profilePatches.add(command);
    return TeamUserProfilePatched(
      user: TeamUserListEntry(
        userId: command.targetUserId,
        // W-1 — Members edit-user write path. Both `displayName` and
        // `email` are optional on the command; the recording stub
        // surfaces whichever value was supplied, falling back to the
        // existing fixture so route grant test assertions keep
        // working.
        email: command.email ?? 'target@example.test',
        displayName: command.displayName ?? 'Target User',
        roleId: _roleId,
        roleLabel: 'Staff',
        status: 'active',
      ),
    );
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command,
  ) async {
    orgUnitCreates.add(command);
    return const TeamOrgUnitCreated(orgUnitId: 'unit-east');
  }

  @override
  Future<TeamOrgUnitMoved> moveOrgUnit(TeamOrgUnitMoveCommand command) async {
    orgUnitMoves.add(command);
    return TeamOrgUnitMoved(
      orgUnit: TeamOrgUnitEntry(
        orgUnitId: command.orgUnitId,
        parentOrgUnitId: command.parentOrgUnitId,
        unitType: 'region',
        path: 'root.east',
        label: 'East',
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

  @override
  Future<TeamUserStatusUpdated> suspendUser(
    TeamUserStatusCommand command,
  ) async {
    userSuspends.add(command);
    return const TeamUserStatusUpdated(updated: true);
  }

  @override
  Future<TeamUserStatusUpdated> reactivateUser(
    TeamUserStatusCommand command,
  ) async {
    userReactivates.add(command);
    return const TeamUserStatusUpdated(updated: true);
  }

  @override
  Future<TeamUserStatusUpdated> softDeleteUser(
    TeamUserStatusCommand command,
  ) async {
    userSoftDeletes.add(command);
    return const TeamUserStatusUpdated(updated: true);
  }

  @override
  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command,
  ) async {
    passwordResetRequests.add(command);
    return const TeamPasswordResetQueued();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'method ${invocation.memberName} is not exercised by the idempotency '
      'tests',
    );
  }
}

/// Minimal MFA recording gateway for the user-actions idempotency
/// tests. Enough to let `reset-mfa` and `cancel-mfa-removal` reach the
/// idempotency check and (on the replay test) the gateway itself.
class _IdempotencyRecordingMfaOperationsGateway
    implements MfaOperationsGateway {
  final resetUserFactors = <MfaRevokeUserFactorsCommand>[];
  final cancels = <MfaCancelFactorRemovalCommand>[];

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) async {
    resetUserFactors.add(command);
    return MfaRevokeUserFactorsCompleted(
      requestedCount: 1,
      requestIds: const <String>['removal-request-1'],
      executeAfter: DateTime.utc(2026, 4, 28, 12, 30),
    );
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) async {
    cancels.add(command);
    return const MfaCancelFactorRemovalCompleted(cancelled: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'method ${invocation.memberName} is not exercised by the idempotency '
      'tests',
    );
  }
}
