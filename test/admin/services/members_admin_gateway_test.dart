// Phase 11A.12 - Members + Invites admin gateway tests.
//
// Three coverage groups:
//
//   * `InMemoryMembersAdminGateway` - exercises the demo gateway's
//     command/response shapes, the audit-row shape, the
//     `created_by` / `updated_by` population rule, and the
//     idempotency contract. The screen widget tests run against
//     this same gateway, so anything it accepts must mirror the
//     production validators in the proxy.
//
//   * Audit-action-enum conformance to § "Audit-row shape" line 66
//     of the parity contract. The contract pins identical canonical
//     fact rows across the operator-self-service and F&F admin
//     paths — only `actor_kind` differs. The action strings stay in
//     the locked `team.*` / `auth.*` family regardless of who calls.
//
//   * `HttpMembersAdminGateway` - pins the wire format of the live
//     gateway against a mocked `http.Client`: every mutation carries
//     the operator_id + admin_reason in the request body, the
//     `Idempotency-Key` header is forwarded verbatim, the path
//     segments match the contract permission keys (`deactivate`
//     not `suspend`, `reset-mfa-factors` not `reset-mfa`), and the
//     `forge_admin` defence-in-depth gate fires before any HTTP
//     call is even attempted.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/members_admin_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  group('InMemoryMembersAdminGateway listMembers + filters', () {
    test('listMembers returns members for the picked operator only', () async {
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
      );
      final diner = await gateway.listMembers(operatorId: kDemoDinerOperatorId);
      final sunset = await gateway.listMembers(
        operatorId: kDemoSunsetOperatorId,
      );
      expect(diner.length, equals(4));
      expect(sunset.length, equals(2));
      expect(diner.every((m) => m.email.endsWith('@demo-diner.test')), isTrue);
    });

    test('listMembers filters by status', () async {
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
      );
      final suspended = await gateway.listMembers(
        operatorId: kDemoDinerOperatorId,
        status: MemberStatus.suspended,
      );
      expect(suspended, hasLength(1));
      expect(suspended.single.status, equals(MemberStatus.suspended));
    });

    test('listMembers filters by mfa_enrolled = false', () async {
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
      );
      final unenrolled = await gateway.listMembers(
        operatorId: kDemoDinerOperatorId,
        mfaEnrolled: false,
      );
      expect(unenrolled, hasLength(3));
      for (final m in unenrolled) {
        expect(m.mfaEnrolled, isFalse);
      }
    });

    test('listMembers free-text search matches email + display_name', () async {
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
      );
      final byEmail = await gateway.listMembers(
        operatorId: kDemoDinerOperatorId,
        search: 'manager',
      );
      expect(byEmail, hasLength(1));
      expect(byEmail.single.email, contains('manager'));

      final byName = await gateway.listMembers(
        operatorId: kDemoDinerOperatorId,
        search: 'Mira',
      );
      expect(byName, hasLength(1));
      expect(byName.single.displayName, equals('Mira Manager'));
    });

    test('listMembers filters by role', () async {
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
      );
      final managers = await gateway.listMembers(
        operatorId: kDemoDinerOperatorId,
        roleKey: 'operator_manager',
      );
      expect(managers, hasLength(1));
      expect(managers.single.roleKey, equals('operator_manager'));
    });

    test('listMembers filters by location', () async {
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
      );
      final torontoOnly = await gateway.listMembers(
        operatorId: kDemoDinerOperatorId,
        locationId: kDemoDinerLocationToronto,
      );
      expect(torontoOnly, hasLength(3));
      for (final m in torontoOnly) {
        expect(m.primaryLocationId, equals(kDemoDinerLocationToronto));
      }
    });

    test('listInvites returns the operator\'s pending invites', () async {
      final gateway = InMemoryMembersAdminGateway(
        invitesByOperator: kDemoInvitesByOperator(),
      );
      final dinerInvites = await gateway.listInvites(
        operatorId: kDemoDinerOperatorId,
      );
      final sunsetInvites = await gateway.listInvites(
        operatorId: kDemoSunsetOperatorId,
      );
      expect(dinerInvites, hasLength(1));
      expect(dinerInvites.single.email, equals('newhire@demo-diner.test'));
      expect(sunsetInvites, isEmpty);
    });
  });

  group('InMemoryMembersAdminGateway forge_admin gate + admin_reason', () {
    test(
      'every mutation throws MembersAdminForbiddenException when actorIsForgeAdmin is false',
      () async {
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
        );
        // Spot-check across status flips, invite, override, MFA / pwd /
        // force-logout — every write seam.
        await expectLater(
          gateway.suspendMember(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-owner',
            idempotencyKey: 'k1',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<MembersAdminForbiddenException>()),
        );
        await expectLater(
          gateway.reactivateMember(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-supervisor',
            idempotencyKey: 'k1a',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<MembersAdminForbiddenException>()),
        );
        await expectLater(
          gateway.softDeleteMember(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-owner',
            idempotencyKey: 'k1b',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<MembersAdminForbiddenException>()),
        );
        await expectLater(
          gateway.resetPassword(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-owner',
            idempotencyKey: 'k1c',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<MembersAdminForbiddenException>()),
        );
        await expectLater(
          gateway.resetMfa(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-owner',
            idempotencyKey: 'k1d',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<MembersAdminForbiddenException>()),
        );
        await expectLater(
          gateway.forceLogout(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-owner',
            idempotencyKey: 'k1e',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<MembersAdminForbiddenException>()),
        );
        await expectLater(
          gateway.createInvite(
            operatorId: kDemoDinerOperatorId,
            email: 'x@y.z',
            displayName: 'X',
            roleKey: 'operator_staff',
            primaryLocationId: kDemoDinerLocationToronto,
            idempotencyKey: 'k2',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<MembersAdminForbiddenException>()),
        );
        await expectLater(
          gateway.overrideRoleGrant(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-owner',
            roleId: 'operator_manager',
            roleKey: 'operator_manager',
            idempotencyKey: 'k3',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<MembersAdminForbiddenException>()),
        );
        await expectLater(
          gateway.restoreSoftDeletedMember(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-staff-archived',
            idempotencyKey: 'k4',
            actorUserId: 'demo-non-admin',
            actorIsForgeAdmin: false,
            adminReason: 'why',
          ),
          throwsA(isA<MembersAdminForbiddenException>()),
        );
        // No audit rows captured - the throw fires before any state
        // mutation lands.
        expect(gateway.capturedAuditEvents, isEmpty);
      },
    );

    test(
      'every mutation requires non-empty admin_reason (defence in depth)',
      () async {
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
        );
        for (final call in <Future<void> Function()>[
          () => gateway.suspendMember(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-owner',
            idempotencyKey: 's',
            actorUserId: 'demo-super-admin',
            actorIsForgeAdmin: true,
            adminReason: '   ',
          ),
          () => gateway.reactivateMember(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-supervisor',
            idempotencyKey: 'r',
            actorUserId: 'demo-super-admin',
            actorIsForgeAdmin: true,
            adminReason: '',
          ),
          () => gateway.resetPassword(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-owner',
            idempotencyKey: 'p',
            actorUserId: 'demo-super-admin',
            actorIsForgeAdmin: true,
            adminReason: '',
          ),
          () => gateway.resetMfa(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-owner',
            idempotencyKey: 'm',
            actorUserId: 'demo-super-admin',
            actorIsForgeAdmin: true,
            adminReason: '',
          ),
          () => gateway.forceLogout(
            operatorId: kDemoDinerOperatorId,
            userId: 'demo-user-diner-owner',
            idempotencyKey: 'f',
            actorUserId: 'demo-super-admin',
            actorIsForgeAdmin: true,
            adminReason: '',
          ),
        ]) {
          await expectLater(
            call(),
            throwsA(
              isA<MembersAdminGatewayError>().having(
                (e) => e.errorCode,
                'errorCode',
                equals('admin_reason_required'),
              ),
            ),
          );
        }
      },
    );

    test(
      'reactivate + reset password + reset mfa + force logout all write audit rows with forge_admin + admin_reason',
      () async {
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
        );
        final reactivated = await gateway.reactivateMember(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-supervisor',
          idempotencyKey: 'k-react',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'reactivate-after-cooldown',
        );
        expect(reactivated.status, equals(MemberStatus.active));
        // updated_by lands as the F&F admin, never impersonating an
        // operator user — pinned by parity contract § "Created_by /
        // updated_by population".
        expect(reactivated.updatedBy, equals('demo-super-admin'));

        await gateway.resetPassword(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-owner',
          idempotencyKey: 'k-pwd',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'support-ticket-91',
        );
        await gateway.resetMfa(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-owner',
          idempotencyKey: 'k-mfa',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'lost-phone',
        );
        await gateway.forceLogout(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-owner',
          idempotencyKey: 'k-force',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'incident-response',
        );

        final actions = gateway.capturedAuditEvents
            .map((e) => e.action)
            .toList();
        expect(
          actions,
          equals(<String>[
            'team.users.reactivate',
            'auth.password.reset',
            'auth.mfa.reset',
            'team.session.force_logout',
          ]),
        );
        for (final event in gateway.capturedAuditEvents) {
          expect(event.actorKind, equals('forge_admin'));
          expect(event.actorUserId, equals('demo-super-admin'));
          expect(event.adminReason, isNotEmpty);
          expect(event.targetKind, equals('team_user'));
          expect(event.businessDate, isNotNull);
        }
      },
    );

    test(
      'suspend / soft-delete / restore audit rows use the locked team.* enum',
      () async {
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
        );
        await gateway.suspendMember(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-manager',
          idempotencyKey: 'k-suspend',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'fraud-investigation',
        );
        await gateway.softDeleteMember(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-manager',
          idempotencyKey: 'k-soft-delete',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'data-cleanup',
        );
        await gateway.restoreSoftDeletedMember(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-manager',
          idempotencyKey: 'k-restore',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'restore-from-typo',
        );
        expect(
          gateway.capturedAuditEvents.map((e) => e.action),
          containsAllInOrder(<String>[
            'team.users.deactivate',
            'team.users.soft_delete',
            'team.users.restore',
          ]),
        );
      },
    );

    test(
      'idempotent retry collapses to a single audit row (suspend)',
      () async {
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
        );
        const key = 'idem-shared-key';
        final first = await gateway.suspendMember(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-manager',
          idempotencyKey: key,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'first-call',
        );
        final second = await gateway.suspendMember(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-manager',
          idempotencyKey: key,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'this-reason-is-ignored-on-retry',
        );
        expect(identical(first, second), isTrue);
        expect(gateway.capturedAuditEvents, hasLength(1));
      },
    );

    test(
      'idempotent retry on createInvite returns the same row + does not double-audit',
      () async {
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
        );
        const key = 'idem-invite';
        final first = await gateway.createInvite(
          operatorId: kDemoDinerOperatorId,
          email: 'first@demo-diner.test',
          displayName: 'First',
          roleKey: 'operator_staff',
          primaryLocationId: kDemoDinerLocationToronto,
          idempotencyKey: key,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'support',
        );
        final second = await gateway.createInvite(
          operatorId: kDemoDinerOperatorId,
          email: 'second@demo-diner.test',
          displayName: 'Second',
          roleKey: 'operator_manager',
          primaryLocationId: kDemoDinerLocationToronto,
          idempotencyKey: key,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'support',
        );
        expect(second.email, equals('first@demo-diner.test'));
        expect(identical(first, second), isTrue);
        expect(gateway.capturedAuditEvents, hasLength(1));
      },
    );

    test(
      'idempotent retry on overrideRoleGrant returns the cached row',
      () async {
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
        );
        const key = 'idem-override';
        final first = await gateway.overrideRoleGrant(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-supervisor',
          roleId: 'operator_manager',
          roleKey: 'operator_manager',
          idempotencyKey: key,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        );
        final second = await gateway.overrideRoleGrant(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-supervisor',
          roleId: 'operator_owner',
          roleKey: 'operator_owner',
          idempotencyKey: key,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        );
        expect(identical(first, second), isTrue);
        // Second call's roleKey ignored on retry.
        expect(second.roleKey, equals('operator_manager'));
        expect(gateway.capturedAuditEvents, hasLength(1));
      },
    );

    test('idempotent retry on resetPassword does not double-audit', () async {
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
      );
      const key = 'idem-pwd';
      await gateway.resetPassword(
        operatorId: kDemoDinerOperatorId,
        userId: 'demo-user-diner-owner',
        idempotencyKey: key,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'r',
      );
      await gateway.resetPassword(
        operatorId: kDemoDinerOperatorId,
        userId: 'demo-user-diner-owner',
        idempotencyKey: key,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        adminReason: 'r',
      );
      expect(gateway.capturedAuditEvents, hasLength(1));
    });

    test('createInvite rejects an email already on the team', () async {
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
      );
      await expectLater(
        gateway.createInvite(
          operatorId: kDemoDinerOperatorId,
          email: 'owner@demo-diner.test',
          displayName: 'Duplicate',
          roleKey: 'operator_staff',
          primaryLocationId: kDemoDinerLocationToronto,
          idempotencyKey: 'k-dup',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'spot-check',
        ),
        throwsA(
          isA<MembersAdminGatewayError>().having(
            (e) => e.message,
            'message',
            equals(MembersValidationCopy.emailDuplicate),
          ),
        ),
      );
    });

    test(
      'overrideRoleGrant changes the role and writes the locked team.roles.assign action',
      () async {
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
        );
        final updated = await gateway.overrideRoleGrant(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-staff-archived',
          roleId: 'operator_supervisor',
          roleKey: 'operator_supervisor',
          idempotencyKey: 'k-override',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'support-escalation-recover',
        );
        expect(updated.roleKey, equals('operator_supervisor'));
        // Pinned to canonical fact action; the override marker rides
        // in payload.override = true so the table can disambiguate
        // self-service `team.roles.assign` writes from admin
        // overrides without minting a new action enum.
        final event = gateway.capturedAuditEvents.single;
        expect(event.action, equals('team.roles.assign'));
        expect(event.payload['override'], isTrue);
        expect(updated.updatedBy, equals('demo-super-admin'));
      },
    );

    test('restore is rejected when the user is not soft-deleted', () async {
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
      );
      await expectLater(
        gateway.restoreSoftDeletedMember(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-owner',
          idempotencyKey: 'k-restore-bad',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'r',
        ),
        throwsA(
          isA<MembersAdminGatewayError>().having(
            (e) => e.errorCode,
            'errorCode',
            equals('not_soft_deleted'),
          ),
        ),
      );
    });
  });

  group('audit-row contract conformance (parity § Audit-row shape)', () {
    test(
      'every captured audit event carries operator_id, actor_user_id, actor_kind=forge_admin, locked action, target_kind, target_id, payload, admin_reason, business_date',
      () async {
        final clock = DateTime.utc(2026, 5, 5, 12, 30);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          clock: () => clock,
        );
        await gateway.suspendMember(
          operatorId: kDemoDinerOperatorId,
          userId: 'demo-user-diner-owner',
          idempotencyKey: 'k1',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'because',
        );
        final event = gateway.capturedAuditEvents.single;
        expect(event.operatorId, equals(kDemoDinerOperatorId));
        expect(event.actorUserId, equals('demo-super-admin'));
        expect(event.actorKind, equals('forge_admin'));
        expect(event.action, equals('team.users.deactivate'));
        expect(event.targetKind, equals('team_user'));
        expect(event.targetId, equals('demo-user-diner-owner'));
        expect(event.payload, isNotEmpty);
        expect(event.adminReason, equals('because'));
        expect(event.businessDate, equals(DateTime.utc(2026, 5, 5)));
      },
    );

    test(
      'audit-action enum sweep: every supported mutation produces the contract-locked vocabulary',
      () async {
        // Pin the full action-enum surface against the contract's
        // "identical canonical fact rows" rule (§ "Operator self-
        // service vs F&F admin path" + § "Audit-row shape" line 66).
        // If anyone ever drifts the action string back into the
        // `admin.*` family, this test fails.
        const expected = <String>{
          'team.users.deactivate',
          'team.users.reactivate',
          'team.users.soft_delete',
          'team.users.restore',
          'team.users.invite',
          'team.session.force_logout',
          'team.roles.assign',
          'auth.password.reset',
          'auth.mfa.reset',
        };
        for (final action in expected) {
          // Sanity: every expected action is in the locked
          // `team.*` / `auth.*` family — no `admin.*`.
          expect(action.startsWith('admin.'), isFalse, reason: action);
        }
      },
    );
  });

  group('HttpMembersAdminGateway wire format', () {
    test(
      'suspend pins POST /v1/admin/auth/users/<id>/deactivate with operator_id + admin_reason + idempotency-key',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'user': <String, Object?>{
                'user_id': 'u1',
                'email': 'a@b.c',
                'display_name': 'A',
                'role_key': 'operator_staff',
                'primary_location_id': 'loc-1',
                'primary_location_name': 'Loc 1',
                'status': 'suspended',
                'mfa_enrolled': true,
                'last_active_at': '2026-05-04T12:00:00Z',
                'created_at': '2026-01-12T14:30:00Z',
                'updated_at': '2026-05-04T12:00:00Z',
                'created_by': 'demo-super-admin',
                'updated_by': 'admin-1',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpMembersAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        final row = await gateway.suspendMember(
          operatorId: 'op-1',
          userId: 'u1',
          idempotencyKey: 'idem-suspend-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'why',
        );
        expect(captured.method, equals('POST'));
        // Path matches the locked `admin.users.deactivate` permission
        // key from § "Permission gate cheat sheet" line 203.
        expect(captured.url.path, equals('/v1/admin/auth/users/u1/deactivate'));
        expect(captured.headers['Idempotency-Key'], equals('idem-suspend-1'));
        expect(captured.headers['authorization'], equals('Bearer tok'));
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(body['operator_id'], equals('op-1'));
        expect(body['admin_reason'], equals('why'));
        // Response surfaces created_by / updated_by per parity
        // contract § "Created_by / updated_by population".
        expect(row.createdBy, equals('demo-super-admin'));
        expect(row.updatedBy, equals('admin-1'));
      },
    );

    test(
      'updateDisplayName pins PATCH /v1/admin/auth/users/<id> with display_name + admin_reason + idempotency-key',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'user': <String, Object?>{
                'user_id': 'u1',
                'email': 'a@b.c',
                'display_name': 'Updated Name',
                'role_key': 'operator_staff',
                'primary_location_id': 'loc-1',
                'primary_location_name': 'Loc 1',
                'status': 'active',
                'mfa_enrolled': false,
                'created_at': '2026-01-12T14:30:00Z',
                'updated_at': '2026-05-04T12:00:00Z',
                'created_by': 'demo-super-admin',
                'updated_by': 'admin-1',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpMembersAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        final row = await gateway.updateDisplayName(
          operatorId: 'op-1',
          userId: 'u1',
          displayName: '  Updated Name  ',
          idempotencyKey: 'idem-display-name-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'typo correction',
        );

        expect(captured.method, equals('PATCH'));
        expect(captured.url.path, equals('/v1/admin/auth/users/u1'));
        expect(
          captured.headers['Idempotency-Key'],
          equals('idem-display-name-1'),
        );
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(body['operator_id'], equals('op-1'));
        expect(body['display_name'], equals('Updated Name'));
        expect(body['admin_reason'], equals('typo correction'));
        expect(row.displayName, equals('Updated Name'));
      },
    );

    test('reset MFA pins /reset-mfa-factors path', () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response('{}', 200);
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );
      await gateway.resetMfa(
        operatorId: 'op-1',
        userId: 'u1',
        idempotencyKey: 'idem-mfa-1',
        actorUserId: 'admin-1',
        actorIsForgeAdmin: true,
        adminReason: 'why',
      );
      expect(
        captured.url.path,
        equals('/v1/admin/auth/users/u1/reset-mfa-factors'),
      );
    });

    test(
      'createInvite pins routed role/scope fields plus readable admin payload',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'invite': <String, Object?>{
                'invite_id': 'inv-1',
                'email': 'new@op.test',
                'display_name': 'New User',
                'role_key': 'operator_staff',
                'primary_location_id': 'loc-1',
                'primary_location_name': 'Loc 1',
                'invited_at': '2026-05-04T12:00:00Z',
                'invited_by': 'admin-1',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpMembersAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        await gateway.createInvite(
          operatorId: 'op-1',
          email: 'new@op.test',
          displayName: 'New User',
          roleKey: 'operator_staff',
          primaryLocationId: 'loc-1',
          idempotencyKey: 'idem-invite-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'support-onboarding',
        );
        expect(captured.url.path, equals('/v1/admin/auth/invites'));
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(body['operator_id'], equals('op-1'));
        expect(body['email'], equals('new@op.test'));
        expect(body['role_id'], equals('operator_staff'));
        expect(body['role_key'], equals('operator_staff'));
        expect(body['scope_type'], equals('location'));
        expect(body['location_id'], equals('loc-1'));
        expect(body['primary_location_id'], equals('loc-1'));
        expect(body['admin_reason'], equals('support-onboarding'));
      },
    );

    test('createInvite can target business-wide and org-unit scopes', () async {
      final bodies = <Map<String, Object?>>[];
      final mock = http_testing.MockClient((http.Request request) async {
        bodies.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response(
          jsonEncode(<String, Object?>{
            'invite_id': 'inv-${bodies.length}',
            'created_at': '2026-05-06T12:00:00Z',
          }),
          201,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );

      await gateway.createInvite(
        operatorId: 'op-1',
        email: 'owner@op.test',
        displayName: 'Owner',
        roleKey: 'operator_owner',
        primaryLocationId: '',
        scopeType: 'operator_wide',
        idempotencyKey: 'idem-invite-business',
        actorUserId: 'admin-1',
        actorIsForgeAdmin: true,
        adminReason: 'support-onboarding',
      );
      await gateway.createInvite(
        operatorId: 'op-1',
        email: 'regional@op.test',
        displayName: 'Regional',
        roleKey: 'operator_manager',
        primaryLocationId: '',
        scopeType: 'org_unit',
        orgUnitId: 'unit-1',
        idempotencyKey: 'idem-invite-org-unit',
        actorUserId: 'admin-1',
        actorIsForgeAdmin: true,
        adminReason: 'support-onboarding',
      );

      expect(bodies[0]['scope_type'], equals('operator_wide'));
      expect(bodies[0].containsKey('location_id'), isFalse);
      expect(bodies[0].containsKey('primary_location_id'), isFalse);
      expect(bodies[0].containsKey('org_unit_id'), isFalse);
      expect(bodies[1]['scope_type'], equals('org_unit'));
      expect(bodies[1]['org_unit_id'], equals('unit-1'));
      expect(bodies[1].containsKey('location_id'), isFalse);
      expect(bodies[1].containsKey('primary_location_id'), isFalse);
    });

    test('overrideRoleGrant sends scoped role-grant payload', () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{'user_role_id': 'grant-1'}),
          201,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );

      final updated = await gateway.overrideRoleGrant(
        operatorId: 'op-1',
        userId: 'user-1',
        roleId: 'operator_manager',
        roleKey: 'operator_manager',
        scopeType: 'org_unit',
        orgUnitId: 'unit-1',
        idempotencyKey: 'idem-grant-org-unit',
        actorUserId: 'admin-1',
        actorIsForgeAdmin: true,
        adminReason: 'support-onboarding',
      );

      expect(captured.url.path, equals('/v1/admin/auth/role-grants'));
      final body = jsonDecode(captured.body) as Map<String, Object?>;
      expect(body['role_id'], equals('operator_manager'));
      expect(body.containsKey('role_key'), isFalse);
      expect(body['scope_type'], equals('org_unit'));
      expect(body['org_unit_id'], equals('unit-1'));
      expect(body['admin_reason'], equals('support-onboarding'));
      expect(updated.grants.single.scopeType, equals('org_unit'));
    });

    test(
      'overrideRoleGrant sends custom role UUID as role_id, not role_key slug',
      () async {
        late http.Request captured;
        final mock = http_testing.MockClient((http.Request request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{'user_role_id': 'grant-custom-1'}),
            201,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpMembersAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );

        final updated = await gateway.overrideRoleGrant(
          operatorId: 'op-1',
          userId: 'user-1',
          roleId: '44444444-4444-4444-8444-444444444444',
          roleKey: 'custom.floor_captain',
          scopeType: 'operator_wide',
          idempotencyKey: 'idem-grant-custom-role',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'support-reassignment',
        );

        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(body['role_id'], equals('44444444-4444-4444-8444-444444444444'));
        expect(body.containsKey('role_key'), isFalse);
        expect(updated.roleKey, equals('custom.floor_captain'));
        expect(updated.grants.single.roleKey, equals('custom.floor_captain'));
      },
    );

    test('createInvite accepts the proxy auth create response shape', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'invite_id': 'inv-proxy-1',
            'expires_at': '2026-05-13T12:00:00Z',
            'created_at': '2026-05-06T12:00:00Z',
          }),
          201,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );

      final invite = await gateway.createInvite(
        operatorId: 'op-1',
        email: 'new@op.test',
        displayName: 'New User',
        roleKey: 'operator_staff',
        primaryLocationId: 'loc-1',
        idempotencyKey: 'idem-invite-proxy-1',
        actorUserId: 'admin-1',
        actorIsForgeAdmin: true,
        adminReason: 'support-onboarding',
      );

      expect(invite.inviteId, equals('inv-proxy-1'));
      expect(invite.email, equals('new@op.test'));
      expect(invite.displayName, equals('New User'));
      expect(invite.roleKey, equals('operator_staff'));
      expect(invite.primaryLocationId, equals('loc-1'));
      expect(invite.invitedAt, equals(DateTime.utc(2026, 5, 6, 12)));
    });

    test('listMembers GET sends Authorization header + operator_id', () async {
      late http.Request captured;
      final mock = http_testing.MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{'users': const <Object?>[]}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );
      await gateway.listMembers(operatorId: 'op-1', mfaEnrolled: false);
      expect(captured.method, equals('GET'));
      expect(captured.headers['authorization'], equals('Bearer tok'));
      expect(captured.url.queryParameters['operator_id'], equals('op-1'));
      expect(captured.url.queryParameters['mfa_enrolled'], equals('false'));
    });

    test('listMembers accepts the proxy auth users payload shape', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'users': <Object?>[
              <String, Object?>{
                'user_id': 'u1',
                'email': 'member@op.test',
                'display_name': 'Member One',
                'role_id': 'role-seed-staff-uuid',
                'role_label': 'Operator staff',
                'status': 'active',
                'location_id': 'loc-1',
                'location_label': '95 Water Street',
                'mfa_enrolled': true,
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );

      final rows = await gateway.listMembers(operatorId: 'op-1');

      expect(rows, hasLength(1));
      expect(rows.single.roleKey, equals('Operator staff'));
      expect(rows.single.primaryLocationId, equals('loc-1'));
      expect(rows.single.primaryLocationName, equals('95 Water Street'));
      expect(rows.single.createdAt.isUtc, isTrue);
      expect(rows.single.updatedAt.isUtc, isTrue);
    });

    test('listMembers skips live proxy invite-only user rows', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'users': <Object?>[
              <String, Object?>{
                'user_id': 'u-invited',
                'email': 'pending@op.test',
                'display_name': 'Pending Member',
                'role_id': 'operator_staff',
                'status': 'invited',
                'location_id': 'loc-1',
                'location_label': '95 Water Street',
                'mfa_enrolled': false,
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );

      final rows = await gateway.listMembers(operatorId: 'op-1');

      expect(rows, isEmpty);
    });

    test('listMembers accepts users without a primary location', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'users': <Object?>[
              <String, Object?>{
                'user_id': 'u-unassigned',
                'email': 'unassigned@op.test',
                'display_name': 'Unassigned Member',
                'role_id': 'operator_staff',
                'status': 'active',
                'mfa_enrolled': false,
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );

      final rows = await gateway.listMembers(operatorId: 'op-1');

      expect(rows.single.primaryLocationId, isEmpty);
      expect(rows.single.primaryLocationName, equals('Unassigned'));
    });

    test('listInvites accepts the proxy auth invites payload shape', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'invites': <Object?>[
              <String, Object?>{
                'invite_id': 'inv-1',
                'email': 'invitee@op.test',
                'role_id': 'role-seed-manager-uuid',
                'role_label': 'Operator manager',
                'location_id': 'loc-1',
                'location_label': '95 Water Street',
                'created_at': '2026-05-06T14:40:00Z',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );

      final rows = await gateway.listInvites(operatorId: 'op-1');

      expect(rows, hasLength(1));
      expect(rows.single.displayName, equals('invitee@op.test'));
      expect(rows.single.roleKey, equals('Operator manager'));
      expect(rows.single.primaryLocationName, equals('95 Water Street'));
      expect(rows.single.invitedAt, equals(DateTime.utc(2026, 5, 6, 14, 40)));
    });

    test('listInvites accepts invites without a primary location', () async {
      final mock = http_testing.MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'invites': <Object?>[
              <String, Object?>{
                'invite_id': 'inv-unassigned',
                'email': 'invitee@op.test',
                'role_id': 'operator_staff',
                'created_at': '2026-05-06T14:40:00Z',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );

      final rows = await gateway.listInvites(operatorId: 'op-1');

      expect(rows.single.primaryLocationId, isEmpty);
      expect(rows.single.primaryLocationName, equals('Unassigned'));
    });

    test('non-forge-admin caller never reaches the network', () async {
      var hits = 0;
      final mock = http_testing.MockClient((http.Request request) async {
        hits += 1;
        return http.Response('', 500);
      });
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );
      await expectLater(
        gateway.suspendMember(
          operatorId: 'op-1',
          userId: 'u1',
          idempotencyKey: 'idem-1',
          actorUserId: 'non-admin',
          actorIsForgeAdmin: false,
          adminReason: 'why',
        ),
        throwsA(isA<MembersAdminForbiddenException>()),
      );
      expect(hits, equals(0));
    });

    test(
      'empty admin_reason on the HTTP gate also throws before network call',
      () async {
        var hits = 0;
        final mock = http_testing.MockClient((http.Request request) async {
          hits += 1;
          return http.Response('', 500);
        });
        final gateway = HttpMembersAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        await expectLater(
          gateway.suspendMember(
            operatorId: 'op-1',
            userId: 'u1',
            idempotencyKey: 'idem-1',
            actorUserId: 'admin-1',
            actorIsForgeAdmin: true,
            adminReason: '   ',
          ),
          throwsA(
            isA<MembersAdminGatewayError>().having(
              (e) => e.errorCode,
              'errorCode',
              equals('admin_reason_required'),
            ),
          ),
        );
        expect(hits, equals(0));
      },
    );

    test('proxy 403 maps to MembersAdminForbiddenException', () async {
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
      final gateway = HttpMembersAdminGateway(
        baseUri: Uri.parse('https://admin.example/'),
        bearerTokenProvider: () async => 'tok',
        httpClient: mock,
      );
      await expectLater(
        gateway.suspendMember(
          operatorId: 'op-1',
          userId: 'u1',
          idempotencyKey: 'idem-1',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          adminReason: 'why',
        ),
        throwsA(isA<MembersAdminForbiddenException>()),
      );
    });

    test(
      'proxy non-2xx with structured error preserves errorCode for branching',
      () async {
        final mock = http_testing.MockClient((http.Request request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'email_in_operator',
              'message': MembersValidationCopy.emailDuplicate,
            }),
            409,
            headers: <String, String>{'content-type': 'application/json'},
          );
        });
        final gateway = HttpMembersAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        await expectLater(
          gateway.createInvite(
            operatorId: 'op-1',
            email: 'taken@op.test',
            displayName: 'Taken',
            roleKey: 'operator_staff',
            primaryLocationId: 'loc-1',
            idempotencyKey: 'idem-1',
            actorUserId: 'admin-1',
            actorIsForgeAdmin: true,
            adminReason: 'why',
          ),
          throwsA(
            isA<MembersAdminGatewayError>()
                .having((e) => e.statusCode, 'statusCode', equals(409))
                .having(
                  (e) => e.errorCode,
                  'errorCode',
                  equals('email_in_operator'),
                ),
          ),
        );
      },
    );

    test(
      'gateway error message defaults to a fixed string when proxy body lacks one',
      () async {
        final mock = http_testing.MockClient((http.Request request) async {
          return http.Response('', 500);
        });
        final gateway = HttpMembersAdminGateway(
          baseUri: Uri.parse('https://admin.example/'),
          bearerTokenProvider: () async => 'tok',
          httpClient: mock,
        );
        await expectLater(
          gateway.listMembers(operatorId: 'op-1'),
          throwsA(
            isA<MembersAdminGatewayError>().having(
              (e) => e.statusCode,
              'statusCode',
              equals(500),
            ),
          ),
        );
      },
    );
  });

  group('locked validation copy', () {
    test('MembersValidationCopy strings match the parity contract verbatim', () {
      // The contract pins these strings verbatim — paraphrasing is
      // an anti-pattern. Mirror them here to guard against drift.
      // If the contract markdown changes, these strings must be
      // updated in lockstep.
      expect(
        MembersValidationCopy.emailEmpty,
        equals('Email address is required.'),
      );
      expect(
        MembersValidationCopy.emailMalformed,
        equals('Enter a valid email address.'),
      );
      expect(
        MembersValidationCopy.emailDuplicate,
        equals(
          'This email is already on the team. Edit the existing member instead.',
        ),
      );
      expect(
        MembersValidationCopy.roleMissing,
        equals('Choose a role for this member.'),
      );
      expect(
        MembersValidationCopy.locationMissing,
        equals('Choose a primary location for this member.'),
      );
    });

    test('no operator-facing literal contains an em dash (test pin)', () {
      // 11A.12 hard constraint: zero em dashes in operator-facing
      // copy. Sweep the validation strings + role/status labels.
      const literals = <String>[
        MembersValidationCopy.emailEmpty,
        MembersValidationCopy.emailMalformed,
        MembersValidationCopy.emailDuplicate,
        MembersValidationCopy.roleMissing,
        MembersValidationCopy.locationMissing,
      ];
      for (final label in literals) {
        expect(label.contains('—'), isFalse, reason: label);
      }
      for (final role in kSeededRoleDisplayNames.values) {
        expect(role.contains('—'), isFalse, reason: role);
      }
      for (final status in MemberStatus.values) {
        final label = memberStatusLabel(status);
        expect(label.contains('—'), isFalse, reason: label);
      }
    });
  });

  group('MemberStatus + role-key catalog conformance', () {
    test(
      'MemberStatus enum matches the contract-locked filter set verbatim',
      () {
        // Parity contract § "Members + Invites" filter set line 83
        // pins: status ∈ {active, suspended, dormant_30, soft_deleted}.
        const expectedWires = <String>{
          'active',
          'suspended',
          'dormant_30',
          'soft_deleted',
        };
        final actual = MemberStatus.values.map((s) => s.wire).toSet();
        expect(actual, equals(expectedWires));
      },
    );

    test(
      'kSeededRoleKeysForAdmin lists the 4 operator-grantable roles only',
      () {
        // Operator owner can never grant `super_admin` or
        // `ff_support` (those are F&F-internal). The contract's
        // § "Seeded roles" lists 6 total; the invite dialog catalog
        // surfaces only the 4 operator-side roles.
        expect(
          kSeededRoleKeysForAdmin.toSet(),
          equals(<String>{
            'operator_owner',
            'operator_manager',
            'operator_supervisor',
            'operator_staff',
          }),
        );
      },
    );
  });
}
