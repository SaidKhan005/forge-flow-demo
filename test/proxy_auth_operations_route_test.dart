// Phase 9 live-closeout - proxy auth-operation route tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/services/auth/account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_confirm_gateway.dart';
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
              });

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

    test('POST team user reset-mfa queues delayed removal', () async {
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
          );

          expect(response.statusCode, equals(200));
          expect(response.json['requested_count'], equals(1));
          expect(
            response.json['request_ids'],
            equals(<Object?>['removal-request-1']),
          );
          expect(
            guard.permissionKeys,
            equals(<String>['team.users.reset_mfa']),
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

    test('POST team user cancel-mfa-removal delegates cancellation', () async {
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
          );

          expect(response.statusCode, equals(200));
          expect(response.json['cancelled'], isTrue);
          expect(
            guard.permissionKeys,
            equals(<String>['team.users.reset_mfa']),
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
          expect(gateway.commands.single.firebaseUid, equals(_firebaseUid));
          expect(gateway.commands.single.currentPassword, equals('old-secret'));
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
            final response = await harness
                .postJson(authPasswordResetConfirmPath, const <String, Object?>{
                  'oob_code': 'reset-code',
                  'new_password': 'correct horse battery staple',
                }, authorize: false);

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
    MfaOperationsGateway? mfaOperationsGateway,
    MfaRecoveryRequestGateway? mfaRecoveryRequestGateway,
    ProxyJwtVerifier? verifier,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final guard = ProxyRequestGuard(verifier: verifier ?? _StaticVerifier());
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
        mfaOperationsGateway: mfaOperationsGateway,
        mfaRecoveryRequestGateway: mfaRecoveryRequestGateway,
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
    Map<String, Object?> body, {
    bool authorize = true,
  }) async {
    final request = await client.postUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    if (authorize) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    }
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
