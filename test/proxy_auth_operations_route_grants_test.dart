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

    test('POST /v1/admin/auth/roles replays cached response on key reuse',
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
    });

    test('PATCH /v1/admin/auth/roles/{id} rejects missing Idempotency-Key',
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
    });

    test('DELETE /v1/admin/auth/roles/{id} rejects missing Idempotency-Key',
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
    });

    test('POST /v1/admin/auth/invites rejects missing Idempotency-Key',
        () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.postJson(
            adminAuthInvitesPath,
            const <String, Object?>{
              'email': 'new@example.test',
              'role_id': _roleId,
              'scope_type': 'operator_wide',
            },
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.inviteCreates, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test('POST /v1/admin/auth/invites replays cached response on key reuse',
        () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final first = await harness.postJson(
            adminAuthInvitesPath,
            const <String, Object?>{
              'email': 'new@example.test',
              'role_id': _roleId,
              'scope_type': 'operator_wide',
            },
            idempotencyKey: 'idem-invite-1',
          );
          final second = await harness.postJson(
            adminAuthInvitesPath,
            const <String, Object?>{
              'email': 'new@example.test',
              'role_id': _roleId,
              'scope_type': 'operator_wide',
            },
            idempotencyKey: 'idem-invite-1',
          );
          expect(first.statusCode, equals(201));
          expect(second.statusCode, equals(201));
          // Gateway invoked exactly once across the two retries.
          expect(gateway.inviteCreates, hasLength(1));
        } finally {
          await harness.close();
        }
      });
    });

    test('DELETE /v1/admin/auth/invites/{id} rejects missing Idempotency-Key',
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
    });

    test('POST /v1/admin/auth/role-grants rejects missing Idempotency-Key',
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
              'scope_type': 'operator_wide',
            },
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.roleGrantCreates, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

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

    test('POST /v1/admin/auth/org-units rejects missing Idempotency-Key',
        () async {
      await _withRealHttp(() async {
        final gateway = _IdempotencyRecordingAuthOperationsGateway();
        final harness = await _RouteHarness.start(
          authOperationsGateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.postJson(
            adminAuthOrgUnitsPath,
            const <String, Object?>{
              'parent_org_unit_id': 'unit-root',
              'unit_type': 'region',
              'label': 'east',
              'name': 'East Region',
            },
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.orgUnitCreates, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

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
            const <String, Object?>{'parent_org_unit_id': 'unit-east'},
          );
          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.locationOrgUnitMoves, isEmpty);
        } finally {
          await harness.close();
        }
      });
    });

    test('rejects empty Idempotency-Key (whitespace-only) the same as missing',
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
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final guard = ProxyRequestGuard(verifier: _StaticVerifier());
    server.listen((request) async {
      await routeRequest(
        request,
        guard,
        authOperationsGateway: authOperationsGateway,
        adminPermissionGuard: adminPermissionGuard,
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
  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    return ProxyJwtClaims(
      userId: _userId,
      firebaseUid: _firebaseUid,
      operatorId: _operatorId,
      locationId: _locationId,
      roles: const <String>['roles_version:7'],
      rolesVersion: 7,
      lastFreshAuthAt: DateTime.utc(2026, 4, 28, 11, 59),
    );
  }
}

class _RecordingAdminGuard implements ProxyAdminPermissionGuard {
  @override
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  ) async {
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
  final roleDeletes = <TeamRoleDeleteCommand>[];
  final inviteCreates = <TeamInviteCreateCommand>[];
  final inviteRevokes = <TeamInviteRevokeCommand>[];
  final roleGrantCreates = <TeamRoleGrantCreateCommand>[];
  final roleGrantRevokes = <TeamRoleGrantRevokeCommand>[];
  final orgUnitCreates = <TeamOrgUnitCreateCommand>[];
  final locationOrgUnitMoves = <TeamLocationOrgUnitMoveCommand>[];

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
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command,
  ) async {
    orgUnitCreates.add(command);
    return const TeamOrgUnitCreated(orgUnitId: 'unit-east');
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command,
  ) async {
    locationOrgUnitMoves.add(command);
    return const TeamLocationOrgUnitMoved(moved: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'method ${invocation.memberName} is not exercised by the idempotency '
      'tests',
    );
  }
}
