// Phase 11A.14 - Audited support actions admin gateway tests.
//
// Three coverage groups, mirroring the 11A.12 / 11A.13 gateway test
// shape:
//
//   * `InMemoryAuditedSupportActionsAdminGateway` - exercises the
//     demo gateway's command/response shapes, the audit-row shape,
//     the forge_admin gate, the admin_reason gate, the idempotency
//     contract, the paired-approval workflow, and the
//     `cannot_self_pair` defence.
//
//   * Permission-key + catalog consistency: the new
//     `admin.users.reset_mfa_factors` key is present in the
//     constants catalog AND in the MFA-required set AND in the
//     migration AND in the catalog markdown. The migration drift
//     scanner enforces the constants-vs-migration check at lint
//     time; this test pins the constants-vs-MFA-set + the
//     constants-vs-doc-row.
//
//   * `HttpAuditedSupportActionsAdminGateway` - pins the wire format
//     of the live gateway against a mocked `http.Client`: paths +
//     payload + idempotency-key header + bearer token + 403 mapping.
//
// Authority: docs/contracts/team_roles_hierarchy_console_parity_contract.md.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/services/audited_support_actions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_audited_support_actions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  group('InMemoryAuditedSupportActionsAdminGateway list APIs', () {
    test('listAuditLog returns operator-scoped seeded rows', () async {
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        auditLogByOperator: kDemoAuditLogByOperator(),
      );
      final dinerPage = await gateway.listAuditLog(
        operatorId: kDemoDinerOperatorId,
      );
      final sunsetPage = await gateway.listAuditLog(
        operatorId: kDemoSunsetOperatorId,
      );
      expect(dinerPage.rows, isNotEmpty);
      expect(sunsetPage.rows, isNotEmpty);
      expect(
        dinerPage.rows.every((r) => r.operatorId == kDemoDinerOperatorId),
        isTrue,
      );
      expect(
        sunsetPage.rows.every((r) => r.operatorId == kDemoSunsetOperatorId),
        isTrue,
      );
    });

    test('listAuditLog filters by actor_kind', () async {
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        auditLogByOperator: kDemoAuditLogByOperator(),
      );
      final adminOnly = await gateway.listAuditLog(
        operatorId: kDemoDinerOperatorId,
        filters: const AuditLogFilters(
          actorKinds: <AuditActorKind>[AuditActorKind.forgeAdmin],
        ),
      );
      expect(adminOnly.rows, isNotEmpty);
      expect(
        adminOnly.rows.every((r) => r.actorKind == AuditActorKind.forgeAdmin),
        isTrue,
      );
    });

    test('listAuditLog filters by action multi-select', () async {
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        auditLogByOperator: kDemoAuditLogByOperator(),
      );
      final filtered = await gateway.listAuditLog(
        operatorId: kDemoDinerOperatorId,
        filters: const AuditLogFilters(
          actions: <String>['admin.session.force_logout'],
        ),
      );
      expect(filtered.rows, hasLength(1));
      expect(filtered.rows.single.action, equals('admin.session.force_logout'));
    });

    test('listMembers returns operator-scoped fixture', () async {
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        membersByOperator: kDemoSupportActionsMembersByOperator(),
      );
      final members = await gateway.listMembers(
        operatorId: kDemoDinerOperatorId,
      );
      expect(members, isNotEmpty);
      expect(members.first.email, contains('@demo-diner.test'));
    });
  });

  group('forge_admin + admin_reason gates', () {
    test(
      'every mutation throws Forbidden when actorIsForgeAdmin is false',
      () async {
        final gateway = InMemoryAuditedSupportActionsAdminGateway(
          auditLogByOperator: kDemoAuditLogByOperator(),
          membersByOperator: kDemoSupportActionsMembersByOperator(),
        );
        await expectLater(
          gateway.exportAuditLogCsv(
            operatorId: kDemoDinerOperatorId,
            filters: AuditLogFilters.empty,
            idempotencyKey: 'k1',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<AuditedSupportActionsForbiddenException>()),
        );
        await expectLater(
          gateway.resetMemberMfa(
            operatorId: kDemoDinerOperatorId,
            targetUserId: 'demo-user-diner-owner',
            idempotencyKey: 'k2',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<AuditedSupportActionsForbiddenException>()),
        );
        await expectLater(
          gateway.initiatePasswordReset(
            operatorId: kDemoDinerOperatorId,
            targetUserId: 'demo-user-diner-owner',
            idempotencyKey: 'k3',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<AuditedSupportActionsForbiddenException>()),
        );
        await expectLater(
          gateway.issuePairedApprovalErasure(
            operatorId: kDemoDinerOperatorId,
            targetUserId: 'demo-user-diner-owner',
            idempotencyKey: 'k4',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<AuditedSupportActionsForbiddenException>()),
        );
        expect(gateway.capturedAdminActionLog, isEmpty);
      },
    );

    test('every mutation rejects empty admin_reason', () async {
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        auditLogByOperator: kDemoAuditLogByOperator(),
        membersByOperator: kDemoSupportActionsMembersByOperator(),
      );
      for (final call in <Future<void> Function()>[
        () => gateway.exportAuditLogCsv(
          operatorId: kDemoDinerOperatorId,
          filters: AuditLogFilters.empty,
          idempotencyKey: 'k1',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '   ',
        ),
        () => gateway.resetMemberMfa(
          operatorId: kDemoDinerOperatorId,
          targetUserId: 'demo-user-diner-owner',
          idempotencyKey: 'k2',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '',
        ),
        () => gateway.initiatePasswordReset(
          operatorId: kDemoDinerOperatorId,
          targetUserId: 'demo-user-diner-owner',
          idempotencyKey: 'k3',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '',
        ),
        () => gateway.issuePairedApprovalErasure(
          operatorId: kDemoDinerOperatorId,
          targetUserId: 'demo-user-diner-owner',
          idempotencyKey: 'k4',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: '',
        ),
      ]) {
        await expectLater(
          call(),
          throwsA(
            isA<AuditedSupportActionsGatewayError>().having(
              (e) => e.errorCode,
              'errorCode',
              equals('admin_reason_required'),
            ),
          ),
        );
      }
    });
  });

  group('audit-row shape (parity § Audit-row shape)', () {
    test('reset MFA writes both audit_logs row and admin_action_log row '
        'with forge_admin + admin_reason + reset_mfa_factors action', () async {
      final clock = DateTime.utc(2026, 5, 6, 12, 30);
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        membersByOperator: kDemoSupportActionsMembersByOperator(),
        clock: () => clock,
      );
      await gateway.resetMemberMfa(
        operatorId: kDemoDinerOperatorId,
        targetUserId: 'demo-user-diner-owner',
        idempotencyKey: 'k-reset',
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'walkthrough verification',
      );
      // audit_logs row.
      final audit = gateway.capturedAuditLogFor(kDemoDinerOperatorId).single;
      expect(audit.action, equals(SupportActionsAuditAction.resetMfaFactors));
      expect(audit.actorKind, equals(AuditActorKind.forgeAdmin));
      expect(audit.actorUserId, equals('demo-super-admin'));
      expect(audit.adminReason, equals('walkthrough verification'));
      expect(audit.businessDate, equals(DateTime.utc(2026, 5, 6)));
      // admin_action_log provenance row.
      final action = gateway.capturedAdminActionLog.single;
      expect(action.action, equals(SupportActionsAuditAction.resetMfaFactors));
      expect(action.readerUserId, equals('demo-super-admin'));
      expect(action.targetId, equals('demo-user-diner-owner'));
      expect(action.recordsTouched, equals(1));
      expect(action.adminReason, equals('walkthrough verification'));
    });

    test('password reset writes the reset_password action', () async {
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        membersByOperator: kDemoSupportActionsMembersByOperator(),
      );
      await gateway.initiatePasswordReset(
        operatorId: kDemoDinerOperatorId,
        targetUserId: 'demo-user-diner-owner',
        idempotencyKey: 'k-pwd',
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'support',
      );
      expect(
        gateway.capturedAdminActionLog.single.action,
        equals(SupportActionsAuditAction.resetPassword),
      );
      expect(
        gateway.capturedAuditLogFor(kDemoDinerOperatorId).single.action,
        equals(SupportActionsAuditAction.resetPassword),
      );
    });
  });

  group('paired-approval erasure', () {
    test(
      'first call returns pendingSecondApproval=true; second call confirms',
      () async {
        final gateway = InMemoryAuditedSupportActionsAdminGateway(
          membersByOperator: kDemoSupportActionsMembersByOperator(),
        );
        final first = await gateway.issuePairedApprovalErasure(
          operatorId: kDemoDinerOperatorId,
          targetUserId: 'demo-user-diner-owner',
          idempotencyKey: 'k-erase-1',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'gdpr',
        );
        expect(first.pendingSecondApproval, isTrue);
        expect(first.firstApproverUserId, equals('demo-super-admin'));
        final second = await gateway.issuePairedApprovalErasure(
          operatorId: kDemoDinerOperatorId,
          targetUserId: 'demo-user-diner-owner',
          idempotencyKey: 'k-erase-2',
          actorUserId: 'demo-second-admin',
          actorIsForgeAdmin: true,
          adminReason: 'gdpr',
          confirmRequestId: first.requestId,
        );
        expect(second.pendingSecondApproval, isFalse);
        expect(second.secondApproverUserId, equals('demo-second-admin'));
        // Two admin_action_log entries: requested + confirmed.
        expect(gateway.capturedAdminActionLog, hasLength(2));
        expect(
          gateway.capturedAdminActionLog.map((e) => e.action),
          equals(<String>[
            SupportActionsAuditAction.erasureRequested,
            SupportActionsAuditAction.erasureConfirmed,
          ]),
        );
      },
    );

    test(
      'second-leg confirmation by the same admin throws cannot_self_pair',
      () async {
        final gateway = InMemoryAuditedSupportActionsAdminGateway(
          membersByOperator: kDemoSupportActionsMembersByOperator(),
        );
        final first = await gateway.issuePairedApprovalErasure(
          operatorId: kDemoDinerOperatorId,
          targetUserId: 'demo-user-diner-owner',
          idempotencyKey: 'k-erase-1',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'gdpr',
        );
        await expectLater(
          gateway.issuePairedApprovalErasure(
            operatorId: kDemoDinerOperatorId,
            targetUserId: 'demo-user-diner-owner',
            idempotencyKey: 'k-erase-2',
            actorUserId: 'demo-super-admin',
            actorIsForgeAdmin: true,
            adminReason: 'gdpr',
            confirmRequestId: first.requestId,
          ),
          throwsA(
            isA<AuditedSupportActionsGatewayError>()
                .having(
                  (e) => e.errorCode,
                  'errorCode',
                  equals('cannot_self_pair'),
                )
                .having(
                  (e) => e.message,
                  'message',
                  equals(SupportActionsValidationCopy.cannotSelfPair),
                ),
          ),
        );
      },
    );
  });

  group('idempotency', () {
    test(
      'retried resetMemberMfa returns the same row + a single audit row',
      () async {
        final gateway = InMemoryAuditedSupportActionsAdminGateway(
          membersByOperator: kDemoSupportActionsMembersByOperator(),
        );
        const key = 'idem-reset';
        final first = await gateway.resetMemberMfa(
          operatorId: kDemoDinerOperatorId,
          targetUserId: 'demo-user-diner-owner',
          idempotencyKey: key,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        );
        final second = await gateway.resetMemberMfa(
          operatorId: kDemoDinerOperatorId,
          targetUserId: 'demo-user-diner-owner',
          idempotencyKey: key,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        );
        expect(identical(first, second), isTrue);
        expect(gateway.capturedAdminActionLog, hasLength(1));
        expect(gateway.capturedAuditLogFor(kDemoDinerOperatorId), hasLength(1));
      },
    );
  });

  group('CSV export', () {
    test(
      'export produces a CSV body and writes audit.export.requested row',
      () async {
        final gateway = InMemoryAuditedSupportActionsAdminGateway(
          auditLogByOperator: kDemoAuditLogByOperator(),
          membersByOperator: kDemoSupportActionsMembersByOperator(),
        );
        final csv = await gateway.exportAuditLogCsv(
          operatorId: kDemoDinerOperatorId,
          filters: AuditLogFilters.empty,
          idempotencyKey: 'k-export',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'compliance review',
        );
        expect(csv, isNotEmpty);
        expect(csv.contains('event_id'), isTrue);
        // The export itself wrote an audit row.
        final exportRows = gateway
            .capturedAuditLogFor(kDemoDinerOperatorId)
            .where(
              (r) => r.action == SupportActionsAuditAction.auditExportRequested,
            );
        expect(exportRows, hasLength(1));
      },
    );
  });

  group('catalog keep-in-sync (constants + MFA + migration + doc)', () {
    test('PermissionKeys.all includes admin.users.reset_mfa_factors', () {
      expect(
        PermissionKeys.all.contains(PermissionKeys.adminUsersResetMfaFactors),
        isTrue,
      );
      expect(
        PermissionKeys.adminUsersResetMfaFactors,
        equals('admin.users.reset_mfa_factors'),
      );
    });

    test('admin.users.reset_mfa_factors is in the requiresMfa set', () {
      expect(
        PermissionKeys.requiresMfa.contains(
          PermissionKeys.adminUsersResetMfaFactors,
        ),
        isTrue,
      );
    });

    test(
      'additive migration file references admin.users.reset_mfa_factors',
      () {
        final repoRoot = _repoRoot();
        final migrationPath =
            '$repoRoot/db/migrations/'
            '202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql';
        final file = File(migrationPath);
        expect(
          file.existsSync(),
          isTrue,
          reason: 'expected migration file at $migrationPath',
        );
        final body = file.readAsStringSync();
        expect(body.contains("'admin.users.reset_mfa_factors'"), isTrue);
        expect(
          body.toLowerCase().contains('on conflict'),
          isTrue,
          reason: 'migration must be additive (on conflict do nothing)',
        );
      },
    );

    test(
      'auth_permission_key_catalog.md lists the new key with MFA marker',
      () {
        final repoRoot = _repoRoot();
        final docPath =
            '$repoRoot/docs/contracts/auth_permission_key_catalog.md';
        final body = File(docPath).readAsStringSync();
        expect(body.contains('| `admin.users.reset_mfa_factors`'), isTrue);
        // The MFA marker on the same row is `| yes |` per the table
        // convention used for every other MFA-required key.
        final lineIdx = body.indexOf('| `admin.users.reset_mfa_factors`');
        expect(lineIdx, greaterThan(-1));
        final endOfLine = body.indexOf('\n', lineIdx);
        final row = body
            .substring(lineIdx, endOfLine)
            .replaceAll('\r', '')
            .trimRight();
        expect(
          row.endsWith('| yes |'),
          isTrue,
          reason: 'expected MFA marker `| yes |` on row: $row',
        );
      },
    );
  });

  group('HttpAuditedSupportActionsAdminGateway wire format', () {
    test(
      'resetMemberMfa pins POST /v1/admin/auth/users/<id>/mfa/reset + admin_reason',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'admin_action_log': <String, Object?>{
                'action_log_id': 'al-1',
                'action': 'admin.users.reset_mfa_factors',
                'occurred_at': '2026-05-06T12:30:00Z',
                'reader_user_id': 'admin-1',
                'operator_id': 'op-1',
                'target_kind': 'user',
                'target_id': 'user-1',
                'records_touched': 1,
                'admin_reason': 'walkthrough verification',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpAuditedSupportActionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        await gateway.resetMemberMfa(
          operatorId: 'op-1',
          targetUserId: 'user-1',
          idempotencyKey: 'idem-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'walkthrough verification',
        );
        expect(captured.method, equals('POST'));
        expect(
          captured.url.path,
          equals('/v1/admin/auth/users/user-1/mfa/reset'),
        );
        expect(captured.headers['Idempotency-Key'], equals('idem-1'));
        expect(captured.headers['authorization'], equals('Bearer tok'));
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(body['operator_id'], equals('op-1'));
        expect(body['admin_reason'], equals('walkthrough verification'));
      },
    );

    test(
      'listAuditLog GET sends operator_id + filter query parameters',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'rows': const <Object?>[],
              'next_cursor': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpAuditedSupportActionsAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        await gateway.listAuditLog(
          operatorId: 'op-1',
          filters: const AuditLogFilters(
            actions: <String>['admin.session.force_logout'],
            targetKind: 'user',
            timeWindow: AuditLogTimeWindow.last7d,
            actorKinds: <AuditActorKind>[
              AuditActorKind.forgeAdmin,
              AuditActorKind.servicePrincipal,
            ],
          ),
        );
        expect(captured.method, equals('GET'));
        expect(captured.url.path, equals('/v1/admin/auth/audit-log'));
        expect(captured.url.queryParameters['operator_id'], equals('op-1'));
        expect(
          captured.url.queryParameters['actions'],
          equals('admin.session.force_logout'),
        );
        expect(captured.url.queryParameters['target_kind'], equals('user'));
        expect(captured.url.queryParameters['time_window'], equals('last_7d'));
        expect(
          captured.url.queryParameters['actor_kinds'],
          equals('forge_admin,service_principal'),
        );
      },
    );

    test('listAuditLog parses actor role enrichment when supplied', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'rows': <Object?>[
              <String, Object?>{
                'event_id': 'event-1',
                'action': 'auth.password.change',
                'occurred_at': '2026-05-06T12:30:00Z',
                'actor_user_id': 'user-1',
                'actor_display_name': 'Dana Owner',
                'actor_email': 'owner@example.test',
                'actor_role': 'Owner',
                'actor_kind': 'team_member',
                'operator_id': 'op-1',
                'target_kind': 'user',
                'target_id': 'user-1',
                'payload': <String, Object?>{},
                'business_date': '2026-05-06T00:00:00Z',
              },
            ],
            'next_cursor': null,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAuditedSupportActionsAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );

      final page = await gateway.listAuditLog(operatorId: 'op-1');

      expect(page.rows.single.actorDisplayName, equals('Dana Owner'));
      expect(page.rows.single.actorEmail, equals('owner@example.test'));
      expect(page.rows.single.actorRole, equals('Owner'));
    });

    test('non-forge-admin caller never reaches the network', () async {
      var hits = 0;
      final mock = http_testing.MockClient((http.Request request) async {
        hits += 1;
        return http.Response('', 500);
      });
      final gateway = HttpAuditedSupportActionsAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );
      await expectLater(
        gateway.resetMemberMfa(
          operatorId: 'op-1',
          targetUserId: 'user-1',
          idempotencyKey: 'idem-1',
          actorUserId: 'non-admin',
          actorIsForgeAdmin: false,
          adminReason: 'r',
        ),
        throwsA(isA<AuditedSupportActionsForbiddenException>()),
      );
      expect(hits, equals(0));
    });

    test('proxy 403 maps to Forbidden', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'permission_denied',
            'message': 'forge_admin required',
          }),
          403,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAuditedSupportActionsAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );
      await expectLater(
        gateway.resetMemberMfa(
          operatorId: 'op-1',
          targetUserId: 'user-1',
          idempotencyKey: 'idem-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        ),
        throwsA(isA<AuditedSupportActionsForbiddenException>()),
      );
    });
  });

  group('locked validation copy', () {
    test('SupportActionsValidationCopy.cannotSelfPair contains no em dash', () {
      expect(
        SupportActionsValidationCopy.cannotSelfPair.contains('—'),
        isFalse,
      );
      expect(
        SupportActionsValidationCopy.adminReasonRequired.contains('—'),
        isFalse,
      );
    });
  });
}

String _repoRoot() {
  // Tests run with cwd = repo root in the existing harness; this
  // helper keeps the lookup robust if a future runner shifts cwd.
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    if (Directory('${dir.path}/db/migrations').existsSync() &&
        Directory('${dir.path}/docs/contracts').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}
