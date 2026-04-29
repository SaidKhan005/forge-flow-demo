// Phase 9 live-closeout - proxy auth-operation route tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/mfa/mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';

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
                });

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
          );
          final delete = await harness.deleteJson(
            '$adminAuthRolePrefix${Uri.encodeComponent(_roleId)}',
            const <String, Object?>{'reason': 'cleanup'},
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
          expect(gateway.commands.single.currentPassword, equals('old-secret'));
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

    test('POST recovery-code consume maps rate limit details', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingMfaOperationsGateway(
          consumeError: MfaOperationRejected(
            code: 'recovery_code_rate_limited',
            message: 'Too many attempts.',
            statusCode: 429,
            retryAfter: DateTime.utc(2026, 4, 28, 12, 1),
          ),
        );
        final harness = await _RouteHarness.start(
          mfaOperationsGateway: gateway,
        );
        try {
          final response = await harness.postJson(
            authMfaRecoveryConsumePath,
            const <String, Object?>{'recovery_code': 'ABCD-EFGH-JKMN'},
          );

          expect(response.statusCode, equals(429));
          expect(response.json['error'], equals('recovery_code_rate_limited'));
          expect(
            response.json['retry_after'],
            equals(DateTime.utc(2026, 4, 28, 12, 1).toIso8601String()),
          );
        } finally {
          await harness.close();
        }
      });
    });
  });
}

const _userId = '11111111-1111-4111-8111-111111111111';
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
    ProxyPermissionSnapshotResolver? permissionSnapshotResolver,
    AuthOperationsGateway? authOperationsGateway,
    ProxyAdminPermissionGuard? adminPermissionGuard,
    PasswordChangeGateway? passwordChangeGateway,
    MfaOperationsGateway? mfaOperationsGateway,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final guard = ProxyRequestGuard(verifier: const _StaticVerifier());
    server.listen((request) async {
      await routeRequest(
        request,
        guard,
        permissionSnapshotResolver: permissionSnapshotResolver,
        authOperationsGateway: authOperationsGateway,
        adminPermissionGuard: adminPermissionGuard,
        passwordChangeGateway: passwordChangeGateway,
        mfaOperationsGateway: mfaOperationsGateway,
        now: () => DateTime.utc(2026, 4, 28, 12),
      );
    });
    return _RouteHarness._(
      server: server,
      client: HttpClient(),
      baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
    );
  }

  Future<_HttpJsonResponse> get(String path) async {
    final request = await client.getUrl(baseUri.resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    final response = await request.close();
    return _HttpJsonResponse.from(response);
  }

  Future<_HttpJsonResponse> postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final request = await client.postUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    return _HttpJsonResponse.from(response);
  }

  Future<_HttpJsonResponse> patchJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final request = await client.patchUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    return _HttpJsonResponse.from(response);
  }

  Future<_HttpJsonResponse> deleteJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final request = await client.deleteUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
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

class _StaticVerifier implements ProxyJwtVerifier {
  const _StaticVerifier();

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    return ProxyJwtClaims(
      userId: _userId,
      operatorId: _operatorId,
      locationId: _locationId,
      roles: const <String>['roles_version:7'],
      rolesVersion: 7,
      lastFreshAuthAt: DateTime.utc(2026, 4, 28, 11, 59),
    );
  }
}

class _FixedSnapshotResolver implements ProxyPermissionSnapshotResolver {
  const _FixedSnapshotResolver(this.snapshot);

  final ProxyPermissionSnapshot snapshot;

  @override
  Future<ProxyPermissionSnapshot> load(OperatorContext scope) async => snapshot;
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

class _RecordingMfaOperationsGateway implements MfaOperationsGateway {
  _RecordingMfaOperationsGateway({this.consumeError});

  final MfaOperationRejected? consumeError;
  final begins = <MfaTotpBeginCommand>[];

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
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) async {
    return const MfaTotpConfirmCompleted(
      factorId: 'factor-db-1',
      recoveryCodesPlaintext: <String>['ABCD-EFGH-JKMN'],
    );
  }

  @override
  Future<RecoveryCodeConsumeCompleted> consumeRecoveryCode(
    RecoveryCodeConsumeCommand command,
  ) async {
    final error = consumeError;
    if (error != null) throw error;
    return const RecoveryCodeConsumeCompleted(factorId: 'factor-db-1');
  }
}

class _RecordingAuthOperationsGateway implements AuthOperationsGateway {
  final roleLists = <TeamRoleCatalogListCommand>[];
  final roleCreates = <TeamRoleCreateCommand>[];
  final rolePatches = <TeamRolePatchCommand>[];
  final roleDeletes = <TeamRoleDeleteCommand>[];
  final inviteCreates = <TeamInviteCreateCommand>[];

  @override
  Future<TeamRoleCatalogListed> listRoles(
    TeamRoleCatalogListCommand command,
  ) async {
    roleLists.add(command);
    return TeamRoleCatalogListed(roles: <TeamRoleCatalogEntry>[_teamRole]);
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
