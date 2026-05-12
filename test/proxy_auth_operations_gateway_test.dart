// Phase 9 live-closeout - ProxyAuthOperationsGateway tests.
//
// Covers the app-side client for `/v1/admin/auth/*` Team/user-management
// routes. No live HTTP; every test injects a fake transport.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';

import '../tool/advisor_proxy/advisor_proxy.dart' as proxy;

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('ProxyAuthOperationsGateway', () {
    test(
      'createInvite POSTs narrow payload and parses invite response',
      () async {
        final fake = _FakeAuthOpsHttpClient(
          postResponse: ProxyAuthOperationsResponse(
            statusCode: 201,
            body: <String, Object?>{
              'invite_id': 'invite-1',
              'expires_at': DateTime.utc(2026, 5, 5, 12).toIso8601String(),
            },
          ),
        );
        final gateway = ProxyAuthOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
          idempotencyKeyFactory: () => 'idem-1',
        );

        final created = await gateway.createInvite(
          const TeamInviteCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            email: 'new.user@example.test',
            roleId: 'operator_staff',
            scopeType: 'operator_wide',
          ),
        );

        expect(created.inviteId, equals('invite-1'));
        final call = fake.posts.single;
        expect(call.url.path, equals(proxy.adminAuthInvitesPath));
        expect(
          call.headers[HttpHeaders.authorizationHeader],
          equals('Bearer id-token'),
        );
        expect(call.headers['Idempotency-Key'], equals('idem-1'));
        expect(
          call.body,
          equals(<String, Object?>{
            'email': 'new.user@example.test',
            'role_id': 'operator_staff',
            'scope_type': 'operator_wide',
          }),
        );
      },
    );

    test('createInvite can POST org-unit scope', () async {
      final fake = _FakeAuthOpsHttpClient(
        postResponse: ProxyAuthOperationsResponse(
          statusCode: 201,
          body: <String, Object?>{
            'invite_id': 'invite-org-1',
            'expires_at': DateTime.utc(2026, 5, 5, 12).toIso8601String(),
          },
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      await gateway.createInvite(
        const TeamInviteCreateCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          email: 'regional.user@example.test',
          roleId: 'role-1',
          scopeType: 'org_unit',
          targetOrgUnitId: 'org-unit-1',
        ),
      );

      expect(fake.posts.single.body, containsPair('org_unit_id', 'org-unit-1'));
      expect(fake.posts.single.body.containsKey('location_id'), isFalse);
    });

    test('lists team users and pending invites from GET routes', () async {
      final fake = _FakeAuthOpsHttpClient(
        getResponses: <ProxyAuthOperationsResponse>[
          ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{
              'users': <Object?>[
                <String, Object?>{
                  'user_id': 'user-1',
                  'email': 'jane@example.test',
                  'display_name': 'Jane Owner',
                  'role_id': 'role-1',
                  'role_label': 'Owner',
                  'status': 'active',
                  'location_id': null,
                  'location_label': null,
                  'mfa_enrolled': true,
                  'user_role_id': 'grant-1',
                  'last_active_at': DateTime.utc(
                    2026,
                    4,
                    29,
                    12,
                  ).toIso8601String(),
                },
              ],
            },
          ),
          ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{
              'invites': <Object?>[
                <String, Object?>{
                  'invite_id': 'invite-1',
                  'email': 'new@example.test',
                  'role_id': 'role-2',
                  'role_label': 'Staff',
                  'scope_type': 'operator_wide',
                  'expires_at': DateTime.utc(2026, 5, 6).toIso8601String(),
                  'created_at': DateTime.utc(2026, 4, 29).toIso8601String(),
                },
              ],
            },
          ),
        ],
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final users = await gateway.listUsers(
        const TeamUserListCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );
      final invites = await gateway.listInvites(
        const TeamInviteListCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );

      expect(users.users.single.userRoleId, equals('grant-1'));
      expect(users.users.single.mfaEnrolled, isTrue);
      expect(invites.invites.single.inviteId, equals('invite-1'));
      expect(fake.gets.first.url.path, equals(proxy.adminAuthUsersPath));
      expect(fake.gets.last.url.path, equals(proxy.adminAuthInvitesPath));
    });

    test('patchUserProfile PATCHes display name with idempotency', () async {
      final fake = _FakeAuthOpsHttpClient(
        patchResponse: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'user': <String, Object?>{
              'user_id': 'target-user',
              'email': 'target@example.test',
              'display_name': 'Target Person',
              'role_id': 'role-1',
              'role_label': 'Owner',
              'status': 'active',
              'mfa_enrolled': false,
            },
          },
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
        idempotencyKeyFactory: () => 'idem-profile-1',
      );

      final patched = await gateway.patchUserProfile(
        const TeamUserProfilePatchCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          targetUserId: 'target-user',
          displayName: 'Target Person',
          reason: 'operator requested correction',
        ),
      );

      expect(patched.user.displayName, equals('Target Person'));
      final call = fake.patches.single;
      expect(call.url.path, equals('${proxy.adminAuthUsersPrefix}target-user'));
      expect(call.headers['Idempotency-Key'], equals('idem-profile-1'));
      expect(
        call.body,
        equals(<String, Object?>{
          'display_name': 'Target Person',
          'reason': 'operator requested correction',
        }),
      );
    });

    test('createInvite maps proxy rejection to narrow error code', () async {
      final fake = _FakeAuthOpsHttpClient(
        postResponse: const ProxyAuthOperationsResponse(
          statusCode: 403,
          body: <String, Object?>{
            'error': 'permission_denied',
            'message': 'permission denied',
          },
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final thrown = await _captureError(
        gateway.createInvite(
          const TeamInviteCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            email: 'new.user@example.test',
            roleId: 'operator_staff',
            scopeType: 'operator_wide',
          ),
        ),
      );

      expect(thrown, isA<ProxyAuthOperationsError>());
      final error = thrown! as ProxyAuthOperationsError;
      expect(error.code, equals('permission_denied'));
      expect(error.statusCode, equals(403));
    });

    test('missing ID token fails before network', () async {
      final fake = _FakeAuthOpsHttpClient();
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => null,
        httpClient: fake,
      );

      final thrown = await _captureError(
        gateway.requestPasswordReset(
          const TeamPasswordResetCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            targetUserId: 'target',
          ),
        ),
      );

      expect(thrown, isA<ProxyAuthOperationsError>());
      expect((thrown! as ProxyAuthOperationsError).code, equals('no_id_token'));
      expect(fake.posts, isEmpty);
      expect(fake.deletes, isEmpty);
    });

    test('requestPasswordReset targets the admin user reset route', () async {
      final fake = _FakeAuthOpsHttpClient(
        postResponse: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true},
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      await gateway.requestPasswordReset(
        const TeamPasswordResetCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          targetUserId: 'target-user',
        ),
      );

      final call = fake.posts.single;
      expect(
        call.url.path,
        equals('${proxy.adminAuthUsersPrefix}target-user/reset-password'),
      );
      expect(call.body, isEmpty);
    });

    test('requestMfaReset targets the admin user MFA reset route', () async {
      final fake = _FakeAuthOpsHttpClient(
        postResponse: ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'ok': true,
            'requested_count': 1,
            'request_ids': <Object?>['removal-request-1'],
            'execute_after': DateTime.utc(2026, 5, 1, 12).toIso8601String(),
          },
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final queued = await gateway.requestMfaReset(
        const TeamMfaResetCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          targetUserId: 'target-user',
          stepUpProofId: 'fresh-token',
        ),
      );

      final call = fake.posts.single;
      expect(
        call.url.path,
        equals('${proxy.adminAuthUsersPrefix}target-user/reset-mfa'),
      );
      expect(call.body['step_up_proof_id'], equals('fresh-token'));
      expect(queued.requestedCount, equals(1));
      expect(queued.requestIds, equals(<String>['removal-request-1']));
    });

    test('cancelMfaRemoval targets the admin user MFA cancel route', () async {
      final fake = _FakeAuthOpsHttpClient(
        postResponse: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true, 'cancelled': true},
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final cancelled = await gateway.cancelMfaRemoval(
        const TeamMfaRemovalCancelCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          targetUserId: 'target-user',
          requestId: 'removal-request-1',
        ),
      );

      final call = fake.posts.single;
      expect(
        call.url.path,
        equals('${proxy.adminAuthUsersPrefix}target-user/cancel-mfa-removal'),
      );
      expect(call.body['request_id'], equals('removal-request-1'));
      expect(cancelled.cancelled, isTrue);
    });

    test(
      'createRoleGrant and revokeRoleGrant use the route contract',
      () async {
        final fake = _FakeAuthOpsHttpClient(
          postResponse: const ProxyAuthOperationsResponse(
            statusCode: 201,
            body: <String, Object?>{'user_role_id': 'grant-1'},
          ),
          deleteResponse: const ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{'ok': true, 'revoked': true},
          ),
        );
        final gateway = ProxyAuthOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final created = await gateway.createRoleGrant(
          const TeamRoleGrantCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            targetUserId: 'target-user',
            roleId: 'role-1',
            scopeType: 'location',
            targetLocationId: 'loc-a',
            reason: 'promotion',
          ),
        );
        final revoked = await gateway.revokeRoleGrant(
          const TeamRoleGrantRevokeCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            userRoleId: 'grant-1',
            targetUserId: 'target-user',
            reason: 'changed role',
          ),
        );

        expect(created.userRoleId, equals('grant-1'));
        expect(revoked.revoked, isTrue);
        expect(
          fake.posts.single.url.path,
          equals(proxy.adminAuthRoleGrantsPath),
        );
        expect(fake.posts.single.body['location_id'], equals('loc-a'));
        expect(
          fake.deletes.single.url.path,
          equals('${proxy.adminAuthRoleGrantPrefix}grant-1'),
        );
        expect(fake.deletes.single.body['user_id'], equals('target-user'));
      },
    );

    test('createRoleGrant can POST org-unit scope', () async {
      final fake = _FakeAuthOpsHttpClient(
        postResponse: const ProxyAuthOperationsResponse(
          statusCode: 201,
          body: <String, Object?>{'user_role_id': 'grant-org-1'},
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      await gateway.createRoleGrant(
        const TeamRoleGrantCreateCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          targetUserId: 'target-user',
          roleId: 'role-1',
          scopeType: 'org_unit',
          targetOrgUnitId: 'org-unit-1',
        ),
      );

      expect(fake.posts.single.body['scope_type'], equals('org_unit'));
      expect(fake.posts.single.body['org_unit_id'], equals('org-unit-1'));
      expect(fake.posts.single.body.containsKey('location_id'), isFalse);
    });

    test('role catalog CRUD uses the custom role route contract', () async {
      final roleJson = <String, Object?>{
        'role_id': 'role-1',
        'role_key': 'kitchen_lead',
        'display_name': 'Kitchen Lead',
        'description': '',
        'is_seeded': false,
        'is_editable': true,
        'operator_id': 'op',
        'permissions': <Object?>[
          <String, Object?>{
            'permission_key': 'team.users.view',
            'effect': 'allow',
          },
        ],
      };
      final fake = _FakeAuthOpsHttpClient(
        getResponse: ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'roles': <Object?>[roleJson],
          },
        ),
        postResponse: ProxyAuthOperationsResponse(
          statusCode: 201,
          body: <String, Object?>{'role': roleJson},
        ),
        patchResponse: ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'role': roleJson, 'bumped_users': 1},
        ),
        deleteResponse: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true, 'deleted': true},
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final listed = await gateway.listRoles(
        const TeamRoleCatalogListCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          scope: 'custom',
        ),
      );
      final created = await gateway.createRole(
        const TeamRoleCreateCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          roleKey: 'kitchen_lead',
          displayName: 'Kitchen Lead',
          permissions: <TeamRolePermissionUpdate>[
            TeamRolePermissionUpdate(
              permissionKey: 'team.users.view',
              effect: 'allow',
            ),
          ],
        ),
      );
      final patched = await gateway.patchRole(
        const TeamRolePatchCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          roleId: 'role-1',
          permissions: <TeamRolePermissionUpdate>[
            TeamRolePermissionUpdate(
              permissionKey: 'team.users.invite',
              effect: null,
            ),
          ],
        ),
      );
      final deleted = await gateway.deleteRole(
        const TeamRoleDeleteCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          roleId: 'role-1',
        ),
      );

      expect(listed.roles.single.roleId, equals('role-1'));
      expect(created.role.roleKey, equals('kitchen_lead'));
      expect(patched.bumpedUsers, equals(1));
      expect(deleted.deleted, isTrue);
      expect(fake.gets.single.url.path, equals(proxy.adminAuthRolesPath));
      expect(fake.gets.single.url.query, equals('scope=custom'));
      expect(fake.posts.last.url.path, equals(proxy.adminAuthRolesPath));
      expect(
        fake.patches.single.url.path,
        equals('${proxy.adminAuthRolePrefix}role-1'),
      );
      expect(
        fake.patches.single.body['permissions'],
        equals(<Object?>[
          <String, Object?>{
            'permission_key': 'team.users.invite',
            'effect': 'inherit',
          },
        ]),
      );
      expect(
        fake.deletes.last.url.path,
        equals('${proxy.adminAuthRolePrefix}role-1'),
      );
    });

    test('org hierarchy CRUD targets the org-units routes', () async {
      final fake = _FakeAuthOpsHttpClient(
        getResponse: ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'org_units': <Object?>[
              <String, Object?>{
                'org_unit_id': 'unit-1',
                'parent_org_unit_id': null,
                'unit_type': 'corp',
                'path': 'acme',
                'label': 'ACME',
              },
            ],
            'locations': <Object?>[
              <String, Object?>{
                'location_id': 'loc-1',
                'parent_org_unit_id': 'unit-1',
                'org_unit_path': 'acme',
                'label': 'Downtown',
              },
            ],
          },
        ),
        postResponse: const ProxyAuthOperationsResponse(
          statusCode: 201,
          body: <String, Object?>{'org_unit_id': 'unit-2'},
        ),
        patchResponse: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'ok': true,
            'moved': true,
            'org_unit_id': 'unit-east',
            'parent_org_unit_id': 'unit-2',
            'unit_type': 'region',
            'path': 'acme.east',
            'label': 'East Region',
          },
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final listed = await gateway.listOrgHierarchy(
        const TeamOrgHierarchyListCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );
      final created = await gateway.createOrgUnit(
        const TeamOrgUnitCreateCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          parentOrgUnitId: 'unit-1',
          unitType: 'region',
          label: 'east',
          name: 'East Region',
          adminReason: 'admin hierarchy setup',
        ),
      );
      final movedOrgUnit = await gateway.moveOrgUnit(
        const TeamOrgUnitMoveCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          orgUnitId: 'unit-east',
          parentOrgUnitId: 'unit-2',
          adminReason: 'admin branch realignment',
        ),
      );
      final moved = await gateway.moveLocationToOrgUnit(
        const TeamLocationOrgUnitMoveCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          targetLocationId: 'loc-1',
          parentOrgUnitId: 'unit-2',
          adminReason: 'admin location realignment',
        ),
      );

      expect(listed.orgUnits.single.orgUnitId, equals('unit-1'));
      expect(listed.locations.single.locationId, equals('loc-1'));
      expect(created.orgUnitId, equals('unit-2'));
      expect(movedOrgUnit.orgUnit.orgUnitId, equals('unit-east'));
      expect(moved.moved, isTrue);
      expect(fake.gets.single.url.path, equals(proxy.adminAuthOrgUnitsPath));
      expect(fake.posts.single.url.path, equals(proxy.adminAuthOrgUnitsPath));
      expect(
        fake.posts.single.body,
        equals(<String, Object?>{
          'parent_org_unit_id': 'unit-1',
          'unit_type': 'region',
          'label': 'east',
          'name': 'East Region',
          'admin_reason': 'admin hierarchy setup',
        }),
      );
      expect(
        fake.patches[0].url.path,
        equals('/v1/admin/auth/org-units/unit-east/parent'),
      );
      expect(
        fake.patches[0].body,
        equals(<String, Object?>{
          'parent_org_unit_id': 'unit-2',
          'admin_reason': 'admin branch realignment',
        }),
      );
      expect(
        fake.patches[1].url.path,
        equals('/v1/admin/auth/locations/loc-1/org-unit'),
      );
      expect(
        fake.patches[1].body,
        equals(<String, Object?>{
          'parent_org_unit_id': 'unit-2',
          'admin_reason': 'admin location realignment',
        }),
      );
    });

    test('hierarchy lifecycle routes carry admin reason', () async {
      final fake = _FakeAuthOpsHttpClient(
        patchResponse: ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'ok': true,
            'org_unit': <String, Object?>{
              'org_unit_id': 'unit-east',
              'parent_org_unit_id': 'unit-root',
              'unit_type': 'region',
              'path': 'acme.east',
              'label': 'East Region',
              'suspended_at': '2026-05-08T12:00:00.000Z',
            },
          },
        ),
        postResponse: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true, 'deleted': true},
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final suspended = await gateway.suspendOrgUnit(
        const TeamOrgUnitLifecycleCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          orgUnitId: 'unit-east',
          adminReason: 'pause branch',
        ),
      );
      final deleted = await gateway.deleteLocation(
        const TeamLocationLifecycleCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          targetLocationId: 'loc-1',
          adminReason: 'duplicate location',
        ),
      );

      expect(suspended.orgUnit.suspendedAt, isNotNull);
      expect(deleted.deleted, isTrue);
      expect(
        fake.patches.single.url.path,
        equals('/v1/admin/auth/org-units/unit-east/suspend'),
      );
      expect(
        fake.patches.single.body,
        equals(<String, Object?>{'admin_reason': 'pause branch'}),
      );
      expect(
        fake.posts.single.url.path,
        equals('/v1/admin/auth/locations/loc-1/delete'),
      );
      expect(
        fake.posts.single.body,
        equals(<String, Object?>{'admin_reason': 'duplicate location'}),
      );
    });

    test(
      'listActiveSessions GETs /v1/auth/sessions and parses payload',
      () async {
        final fake = _FakeAuthOpsHttpClient(
          getResponse: ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{
              'sessions': <Object?>[
                <String, Object?>{
                  'session_id': 'session-1',
                  'device_label': 'Forge & Flow app · iOS',
                  'user_agent': 'Forge&Flow/1.0',
                  'ip': '203.0.113.10',
                  'geo_country': 'CA',
                  'created_at': DateTime.utc(2026, 4, 28).toIso8601String(),
                  'last_seen_at': DateTime.utc(2026, 4, 30).toIso8601String(),
                },
                <String, Object?>{
                  'session_id': 'session-2',
                  'device_label': 'Safari · iPad',
                  'user_agent': 'Mozilla/5.0',
                  'created_at': DateTime.utc(2026, 4, 27).toIso8601String(),
                  'last_seen_at': DateTime.utc(2026, 4, 29).toIso8601String(),
                },
              ],
            },
          ),
        );
        final gateway = ProxyAuthOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final listed = await gateway.listActiveSessions(
          const AuthActiveSessionsListCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
          ),
        );

        expect(listed.sessions, hasLength(2));
        expect(listed.sessions.first.sessionId, equals('session-1'));
        expect(
          listed.sessions.first.deviceLabel,
          equals('Forge & Flow app · iOS'),
        );
        expect(fake.gets.single.url.path, equals('/v1/auth/sessions'));
      },
    );

    // 11W.4 ops-debt - listTeamActiveSessions GETs the new
    // /v1/auth/team/sessions route and projects per-row user identity.
    test('listTeamActiveSessions GETs /v1/auth/team/sessions and parses '
        'target user identity', () async {
      final fake = _FakeAuthOpsHttpClient(
        getResponse: ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'sessions': <Object?>[
              <String, Object?>{
                'session_id': 'session-1',
                'created_at': DateTime.utc(2026, 5, 5).toIso8601String(),
                'last_seen_at': DateTime.utc(2026, 5, 5, 14).toIso8601String(),
                'device_label': 'Forge & Flow on iPhone',
                'user_id': 'u-jordan',
                'display_name': 'Jordan Lee',
                'email': 'jordan.lee@demo.test',
              },
            ],
          },
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final listed = await gateway.listTeamActiveSessions(
        const AuthTeamActiveSessionsListCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );

      expect(listed.sessions, hasLength(1));
      expect(listed.sessions.single.targetUserId, equals('u-jordan'));
      expect(listed.sessions.single.targetDisplayName, equals('Jordan Lee'));
      expect(listed.sessions.single.session.sessionId, equals('session-1'));
      expect(fake.gets.single.url.path, equals('/v1/auth/team/sessions'));
    });

    test('revokeSession POSTs the existing session/revoke route', () async {
      final fake = _FakeAuthOpsHttpClient(
        postResponse: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true, 'revoked': true},
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final result = await gateway.revokeSession(
        const AuthSessionRevokeCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          sessionId: 'session-2',
          reason: 'user_revoked_active_session',
        ),
      );

      expect(result.revoked, isTrue);
      expect(fake.posts.single.url.path, equals('/v1/auth/session/revoke'));
      expect(
        fake.posts.single.body,
        equals(<String, Object?>{
          'session_id': 'session-2',
          'reason': 'user_revoked_active_session',
        }),
      );
    });

    test('signOutAll POSTs the existing session/revoke-all route', () async {
      final fake = _FakeAuthOpsHttpClient(
        postResponse: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true, 'revoked_count': 3},
        ),
      );
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final result = await gateway.signOutAll(
        const AuthAllSessionsRevokeCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );

      expect(result.revokedCount, equals(3));
      expect(fake.posts.single.url.path, equals('/v1/auth/session/revoke-all'));
    });

    test(
      'listAuthEventsForActor GETs /v1/auth/audit-log and parses entries',
      () async {
        final fake = _FakeAuthOpsHttpClient(
          getResponse: ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{
              'entries': <Object?>[
                <String, Object?>{
                  'event_id': 'audit-1',
                  'event_kind': 'sign_in',
                  'event_type': 'auth.user.signed_in',
                  'friendly_label': 'Sign-in',
                  'occurred_at': DateTime.utc(2026, 4, 30).toIso8601String(),
                  'ip': '203.0.113.10',
                  'user_agent': 'Forge&Flow/1.0',
                  'geo_country': 'CA',
                  'payload': <String, Object?>{'reason': 'normal'},
                },
                <String, Object?>{
                  'event_id': 'audit-2',
                  'event_type': 'auth.password_changed',
                  'occurred_at': DateTime.utc(2026, 4, 29).toIso8601String(),
                  'payload': <String, Object?>{},
                },
              ],
              'has_more': true,
            },
          ),
        );
        final gateway = ProxyAuthOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final from = DateTime.utc(2026, 4, 1);
        final to = DateTime.utc(2026, 4, 30, 23, 59, 59);
        final listed = await gateway.listAuthEventsForActor(
          AuthEventListCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            limit: 50,
            offset: 0,
            eventKind: AuthEventKind.signIn,
            from: from,
            to: to,
          ),
        );

        expect(listed.entries, hasLength(2));
        expect(listed.hasMore, isTrue);
        expect(listed.entries.first.eventId, equals('audit-1'));
        expect(listed.entries.first.friendlyLabel, equals('Sign-in'));
        expect(listed.entries.first.eventKind, equals(AuthEventKind.signIn));
        // Falls back to derived label/kind when the wire payload omits them.
        expect(listed.entries[1].eventKind, equals(AuthEventKind.password));
        expect(listed.entries[1].friendlyLabel, equals('Password changed'));
        expect(fake.gets.single.url.path, equals('/v1/auth/audit-log'));
        expect(
          fake.gets.single.url.queryParameters['event_kind'],
          equals('sign_in'),
        );
        expect(fake.gets.single.url.queryParameters['limit'], equals('50'));
        expect(fake.gets.single.url.queryParameters['offset'], equals('0'));
        expect(
          fake.gets.single.url.queryParameters['from'],
          equals(from.toIso8601String()),
        );
        expect(
          fake.gets.single.url.queryParameters['to'],
          equals(to.toIso8601String()),
        );
      },
    );

    test('transport failures collapse to transport_error', () async {
      final fake = _FakeAuthOpsHttpClient.throws(StateError('secret://dsn'));
      final gateway = ProxyAuthOperationsGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final thrown = await _captureError(
        gateway.requestPasswordReset(
          const TeamPasswordResetCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            targetUserId: 'target',
          ),
        ),
      );

      expect(thrown, isA<ProxyAuthOperationsError>());
      final error = thrown! as ProxyAuthOperationsError;
      expect(error.code, equals('transport_error'));
      expect(error.message.contains('secret://dsn'), isFalse);
      expect(error.toString(), contains('transport'));
      expect(error.toString().contains('secret://dsn'), isFalse);
    });
  });
}

Future<Object?> _captureError(Future<void> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

class _FakeAuthOpsHttpClient implements ProxyAuthOperationsHttpClient {
  _FakeAuthOpsHttpClient({
    ProxyAuthOperationsResponse? getResponse,
    List<ProxyAuthOperationsResponse>? getResponses,
    ProxyAuthOperationsResponse? postResponse,
    ProxyAuthOperationsResponse? patchResponse,
    ProxyAuthOperationsResponse? deleteResponse,
  }) : _getResponse =
           getResponse ??
           const ProxyAuthOperationsResponse(
             statusCode: 200,
             body: <String, Object?>{'roles': <Object?>[]},
           ),
       _getResponses = getResponses == null
           ? null
           : List<ProxyAuthOperationsResponse>.of(getResponses),
       _postResponse =
           postResponse ??
           const ProxyAuthOperationsResponse(
             statusCode: 200,
             body: <String, Object?>{'ok': true},
           ),
       _patchResponse =
           patchResponse ??
           const ProxyAuthOperationsResponse(
             statusCode: 200,
             body: <String, Object?>{'ok': true},
           ),
       _deleteResponse =
           deleteResponse ??
           const ProxyAuthOperationsResponse(
             statusCode: 200,
             body: <String, Object?>{'ok': true, 'revoked': true},
           );

  _FakeAuthOpsHttpClient.throws(Object error)
    : _getResponse = null,
      _getResponses = null,
      _postResponse = null,
      _patchResponse = null,
      _deleteResponse = null,
      _error = error;

  final ProxyAuthOperationsResponse? _getResponse;
  final List<ProxyAuthOperationsResponse>? _getResponses;
  final ProxyAuthOperationsResponse? _postResponse;
  final ProxyAuthOperationsResponse? _patchResponse;
  final ProxyAuthOperationsResponse? _deleteResponse;
  Object? _error;

  final List<_CapturedAuthOpsCall> gets = <_CapturedAuthOpsCall>[];
  final List<_CapturedAuthOpsCall> posts = <_CapturedAuthOpsCall>[];
  final List<_CapturedAuthOpsCall> patches = <_CapturedAuthOpsCall>[];
  final List<_CapturedAuthOpsCall> deletes = <_CapturedAuthOpsCall>[];

  @override
  Future<ProxyAuthOperationsResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  }) async {
    if (_error != null) throw _error!;
    gets.add(
      _CapturedAuthOpsCall(
        url: url,
        headers: headers,
        body: const <String, Object?>{},
      ),
    );
    final queued = _getResponses;
    if (queued != null && queued.isNotEmpty) {
      return queued.removeAt(0);
    }
    return _getResponse!;
  }

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    if (_error != null) throw _error!;
    posts.add(_CapturedAuthOpsCall(url: url, headers: headers, body: body));
    return _postResponse!;
  }

  @override
  Future<ProxyAuthOperationsResponse> patchJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    if (_error != null) throw _error!;
    patches.add(_CapturedAuthOpsCall(url: url, headers: headers, body: body));
    return _patchResponse!;
  }

  @override
  Future<ProxyAuthOperationsResponse> deleteJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    if (_error != null) throw _error!;
    deletes.add(_CapturedAuthOpsCall(url: url, headers: headers, body: body));
    return _deleteResponse!;
  }
}

class _CapturedAuthOpsCall {
  const _CapturedAuthOpsCall({
    required this.url,
    required this.headers,
    required this.body,
  });

  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}
