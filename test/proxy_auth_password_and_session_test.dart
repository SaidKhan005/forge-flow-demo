// Phase 9 live-closeout - proxy auth password + session/audit-log
// route tests.
//
// Bucket 5d-password+session of the 2026-05-20 test-suite tightening
// audit: split out of `test/proxy_auth_operations_route_test.dart`
// (3,599 lines). This file owns the password-change /
// password-reset-request / password-reset-confirm routes, the admin
// session + force-logout aliases, the active-session and team-session
// list routes, and the GET audit log + CSV export routes.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_request_gateway.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import 'proxy_auth_test_helpers.dart';

void main() {
  group('Phase 9 auth-operation proxy routes', () {
    test('POST admin force-logout alias signs out target user', () async {
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
          expect(command.actorUserId, equals(proxyAuthUserId));
          expect(command.targetUserId, equals('target-user'));
          expect(command.reason, equals('support lockout recovery'));
        } finally {
          await harness.close();
        }
      });
    });

    test('GET admin sessions returns Access screen session rows', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          verifier: StaticVerifier(
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
          expect(row['user_id'], equals(proxyAuthUserId));
          expect(row['user_email'], equals(proxyAuthFirebaseUid));
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
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        gateway.auditLogHasMore = true;
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          verifier: StaticVerifier(
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
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final guard = RecordingAdminGuard();
          final harness = await RouteHarness.start(
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

    test('POST password change delegates and returns HIBP flag', () async {
      await withRealHttp(() async {
        final gateway = RecordingPasswordChangeGateway(
          result: const PasswordChangeCompleted(hibpUnavailable: true),
        );
        final harness = await RouteHarness.start(
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
          expect(gateway.commands.single.actorUserId, equals(proxyAuthUserId));
          expect(gateway.commands.single.firebaseUid, equals(proxyAuthFirebaseUid));
          expect(gateway.commands.single.currentPassword, equals('old-secret'));
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'POST password reset request delegates without bearer token',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingPasswordResetRequestGateway();
          final harness = await RouteHarness.start(
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
      await withRealHttp(() async {
        final gateway = RecordingPasswordResetRequestGateway();
        final harness = await RouteHarness.start(
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
      await withRealHttp(() async {
        final gateway = RecordingPasswordResetRequestGateway(
          throwOnRequest: () => const PasswordResetRequestThrottled(),
        );
        final harness = await RouteHarness.start(
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
        await withRealHttp(() async {
          final harness = await RouteHarness.start();
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
        await withRealHttp(() async {
          final gateway = RecordingPasswordResetRequestGateway();
          final harness = await RouteHarness.start(
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
        await withRealHttp(() async {
          final gateway = RecordingPasswordResetRequestGateway();
          final harness = await RouteHarness.start(
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
        await withRealHttp(() async {
          final gateway = RecordingPasswordResetRequestGateway();
          final harness = await RouteHarness.start(
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
      await withRealHttp(() async {
        final gateway = RecoveringPasswordResetRequestGateway(
          failuresBeforeSuccess: 1,
          failure: () => Exception('postgres lookup blip'),
        );
        final harness = await RouteHarness.start(
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
        await withRealHttp(() async {
          final gateway = RecordingPasswordResetConfirmGateway();
          final harness = await RouteHarness.start(
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
      await withRealHttp(() async {
        final gateway = RecordingPasswordResetConfirmGateway();
        final harness = await RouteHarness.start(
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

    test('GET active sessions delegates to AuthOperationsGateway with the '
        'verified scope and returns the projected payload', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final harness = await RouteHarness.start(
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
            equals(proxyAuthUserId),
          );
          expect(
            gateway.activeSessionsLists.single.operatorId,
            equals(proxyAuthOperatorId),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'GET active sessions returns 503 when the gateway is not configured',
      () async {
        await withRealHttp(() async {
          final harness = await RouteHarness.start();
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
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
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
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          permissionSnapshotResolver: FixedSnapshotResolver(
            ProxyPermissionSnapshot(
              userId: proxyAuthUserId,
              operatorId: proxyAuthOperatorId,
              locationId: proxyAuthLocationId,
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
            equals(proxyAuthOperatorId),
          );
        } finally {
          await harness.close();
        }
      });
    });

    test(
      'GET team sessions returns 403 without team.session.force_logout',
      () async {
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            permissionSnapshotResolver: FixedSnapshotResolver(
              ProxyPermissionSnapshot(
                userId: proxyAuthUserId,
                operatorId: proxyAuthOperatorId,
                locationId: proxyAuthLocationId,
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
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          final harness = await RouteHarness.start(
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
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
          gateway.auditLogHasMore = true;
          final harness = await RouteHarness.start(
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
            expect(gateway.auditLogLists.single.actorUserId, equals(proxyAuthUserId));
            expect(
              gateway.auditLogLists.single.operatorId,
              equals(proxyAuthOperatorId),
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
        await withRealHttp(() async {
          final harness = await RouteHarness.start();
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
      await withRealHttp(() async {
        final harness = await RouteHarness.start(
          authOperationsGateway: RecordingAuthOperationsGateway(),
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
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final harness = await RouteHarness.start(
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
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
        );
        try {
          final response = await harness.get(
            '$authAuditLogPath?user_id=spoofed-user&limit=10',
          );
          expect(response.statusCode, equals(200));
          // Even though the client sent ?user_id=..., the proxy
          // forwarded the verified bearer-token scope.
          expect(gateway.auditLogLists.single.actorUserId, equals(proxyAuthUserId));
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
        await withRealHttp(() async {
          final gateway = RecordingAuthOperationsGateway();
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
          final harness = await RouteHarness.start(
            authOperationsGateway: gateway,
            permissionSnapshotResolver: FixedSnapshotResolver(
              ProxyPermissionSnapshot(
                userId: proxyAuthUserId,
                operatorId: proxyAuthOperatorId,
                locationId: proxyAuthLocationId,
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
            expect(lines[1], contains(proxyAuthUserId));
            expect(lines[1], contains('team_member'));
            expect(lines[1], contains('"{""reason"":""totp,with comma""}"'));
            // Second body row: admin_reason promotes actor_kind.
            expect(lines[2], contains('forge_admin'));
            expect(lines[2], contains('F&F admin'));
            // Verify the proxy paged the gateway with the verified
            // scope, not a client-supplied user_id.
            expect(gateway.auditLogLists.single.actorUserId, equals(proxyAuthUserId));
          } finally {
            await harness.close();
          }
        });
      },
    );

    test('GET audit log export forwards from/to/event_kind filters into the '
        'gateway command', () async {
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          permissionSnapshotResolver: FixedSnapshotResolver(
            ProxyPermissionSnapshot(
              userId: proxyAuthUserId,
              operatorId: proxyAuthOperatorId,
              locationId: proxyAuthLocationId,
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
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          permissionSnapshotResolver: FixedSnapshotResolver(
            ProxyPermissionSnapshot(
              userId: proxyAuthUserId,
              operatorId: proxyAuthOperatorId,
              locationId: proxyAuthLocationId,
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
        await withRealHttp(() async {
          final harness = await RouteHarness.start(
            authOperationsGateway: RecordingAuthOperationsGateway(),
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
      await withRealHttp(() async {
        final gateway = RecordingAuthOperationsGateway();
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
        final harness = await RouteHarness.start(
          authOperationsGateway: gateway,
          permissionSnapshotResolver: FixedSnapshotResolver(
            ProxyPermissionSnapshot(
              userId: proxyAuthUserId,
              operatorId: proxyAuthOperatorId,
              locationId: proxyAuthLocationId,
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

  });
}
