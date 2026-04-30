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
