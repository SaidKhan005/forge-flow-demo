// Phase 9 live-closeout - proxy auth MFA route tests.
//
// Bucket 5d-mfa of the 2026-05-20 test-suite tightening audit:
// split out of `test/proxy_auth_operations_route_test.dart`
// (3,599 lines). This file owns the admin reset-MFA-factors flow,
// the team-side reset-MFA gate, the MFA TOTP enrollment, factor
// list/revoke/removal-cancel, recovery-codes-viewed, and MFA
// recovery-request routes — plus the MFA fresh-sign-in guard.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import 'proxy_auth_test_helpers.dart';

void main() {
  group('Phase 9 auth-operation proxy routes', () {
    test('POST admin reset-mfa-factors gates on '
        'admin.users.reset_mfa_factors and queues delayed removal', () async {
      // 11A.14 ops-debt fix - the F&F admin support path gates on the
      // new `admin.users.reset_mfa_factors` permission key (not the
      // operator-side `team.users.reset_mfa` posture).
      await withRealHttp(() async {
        final authGateway = RecordingAuthOperationsGateway();
        final mfaGateway = RecordingMfaOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
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
      await withRealHttp(() async {
        final authGateway = RecordingAuthOperationsGateway();
        final mfaGateway = RecordingMfaOperationsGateway(
          resetError: const MfaOperationRejected(
            code: 'mfa_freshness_required',
            message: 'Sign in again before removing MFA.',
            statusCode: 403,
          ),
        );
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
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
      await withRealHttp(() async {
        final authGateway = RecordingAuthOperationsGateway();
        final mfaGateway = RecordingMfaOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
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
      await withRealHttp(() async {
        final authGateway = RecordingAuthOperationsGateway();
        final mfaGateway = RecordingMfaOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
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
      await withRealHttp(() async {
        final authGateway = RecordingAuthOperationsGateway();
        final mfaGateway = RecordingMfaOperationsGateway();
        final guard = RecordingAdminGuard();
        final harness = await RouteHarness.start(
          verifier: StaticVerifier(
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

    test('POST MFA TOTP begin delegates and returns setup payload', () async {
      await withRealHttp(() async {
        final gateway = RecordingMfaOperationsGateway();
        final harness = await RouteHarness.start(
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
          expect(gateway.begins.single.actorUserId, equals(proxyAuthUserId));
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
        await withRealHttp(() async {
          final gateway = RecordingMfaOperationsGateway(
            factors: <MfaFactorSummary>[
              MfaFactorSummary(
                factorId: 'totp-db-factor',
                factorType: 'totp',
                enrolledAt: DateTime.utc(2026, 4, 30, 12),
                issuerLabel: 'Forge & Flow',
              ),
            ],
          );
          final harness = await RouteHarness.start(
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
            expect(gateway.lists.single.actorUserId, equals(proxyAuthUserId));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test(
      'POST MFA factors revoke delegates and returns delayed removal',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingMfaOperationsGateway(
            revokeResult: MfaRevokeFactorCompleted(
              revoked: false,
              requestId: 'mfa-removal-1',
              executeAfter: DateTime.utc(2026, 5, 1, 12),
            ),
          );
          final harness = await RouteHarness.start(
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
        await withRealHttp(() async {
          final gateway = RecordingMfaOperationsGateway(
            cancelResult: const MfaCancelFactorRemovalCompleted(
              cancelled: true,
            ),
          );
          final harness = await RouteHarness.start(
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

    test(
      'POST MFA recovery-codes viewed replays same key and updates fresh key',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingMfaOperationsGateway();
          final harness = await RouteHarness.start(
            mfaOperationsGateway: gateway,
          );
          try {
            final missingKey = await harness.postJson(
              authMfaRecoveryCodesViewedPath,
              const <String, Object?>{'factor_id': 'totp-db-factor'},
            );
            expect(missingKey.statusCode, equals(400));
            expect(missingKey.json['error'], equals('missing_idempotency_key'));

            final response = await harness.postJson(
              authMfaRecoveryCodesViewedPath,
              const <String, Object?>{'factor_id': 'totp-db-factor'},
              idempotencyKey: 'idem-view-codes',
            );

            expect(response.statusCode, equals(200));
            expect(
              response.json['recovery_codes_viewed_at'],
              equals('2026-05-06T12:00:00.000Z'),
            );
            final replay = await harness.postJson(
              authMfaRecoveryCodesViewedPath,
              const <String, Object?>{'factor_id': 'totp-db-factor'},
              idempotencyKey: 'idem-view-codes',
            );
            expect(replay.statusCode, equals(200));
            expect(
              replay.json['recovery_codes_viewed_at'],
              equals(response.json['recovery_codes_viewed_at']),
            );
            final fresh = await harness.postJson(
              authMfaRecoveryCodesViewedPath,
              const <String, Object?>{'factor_id': 'totp-db-factor'},
              idempotencyKey: 'idem-view-codes-2',
            );
            expect(fresh.statusCode, equals(200));
            expect(
              fresh.json['recovery_codes_viewed_at'],
              equals('2026-05-06T12:01:00.000Z'),
            );
            expect(
              gateway.recoveryCodeViews.map((command) => command.factorId),
              everyElement(equals('totp-db-factor')),
            );
            expect(
              gateway.recoveryCodeViews.map(
                (command) => command.idempotencyKey,
              ),
              equals(<String>['idem-view-codes', 'idem-view-codes-2']),
            );
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('POST MFA recovery request accepts contact-admin request', () async {
      await withRealHttp(() async {
        final gateway = RecordingMfaRecoveryRequestGateway();
        final harness = await RouteHarness.start(
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
      await withRealHttp(() async {
        final gateway = RecordingMfaOperationsGateway();
        final harness = await RouteHarness.start(
          verifier: StaticVerifier(
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
