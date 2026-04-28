// Phase 9.8 - User lifecycle + invite + GDPR erasure tests.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/user_lifecycle.dart';
import 'package:forge_and_flow/services/auth/gdpr_erasure_service.dart';
import 'package:forge_and_flow/services/auth/user_invite_service.dart';

void main() {
  group('UserStatus.fromKey + toSchemaKey', () {
    test('roundtrips every status', () {
      for (final status in UserStatus.values) {
        expect(
          UserStatus.fromKey(status.toSchemaKey()),
          equals(status),
        );
      }
    });

    test('unknown key returns null', () {
      expect(UserStatus.fromKey('unknown'), isNull);
      expect(UserStatus.fromKey(null), isNull);
    });
  });

  group('UserLifecycleStateMachine', () {
    test('invited -> acceptInvite -> active', () {
      final t = UserLifecycleStateMachine.apply(
        from: UserStatus.invited,
        action: UserLifecycleAction.acceptInvite,
      );
      expect(t.to, equals(UserStatus.active));
    });

    test('active -> suspend -> suspended', () {
      final t = UserLifecycleStateMachine.apply(
        from: UserStatus.active,
        action: UserLifecycleAction.suspend,
      );
      expect(t.to, equals(UserStatus.suspended));
    });

    test('suspended -> reactivate -> active', () {
      final t = UserLifecycleStateMachine.apply(
        from: UserStatus.suspended,
        action: UserLifecycleAction.reactivate,
      );
      expect(t.to, equals(UserStatus.active));
    });

    test('dormancy advance: 30 -> 60 -> 90', () {
      expect(
        UserLifecycleStateMachine.apply(
          from: UserStatus.active,
          action: UserLifecycleAction.advanceDormancy30,
        ).to,
        equals(UserStatus.dormant30),
      );
      expect(
        UserLifecycleStateMachine.apply(
          from: UserStatus.dormant30,
          action: UserLifecycleAction.advanceDormancy60,
        ).to,
        equals(UserStatus.dormant60),
      );
      expect(
        UserLifecycleStateMachine.apply(
          from: UserStatus.dormant60,
          action: UserLifecycleAction.advanceDormancy90,
        ).to,
        equals(UserStatus.dormant90),
      );
    });

    test('dormant_90 -> suspend (HP locked rule)', () {
      final t = UserLifecycleStateMachine.apply(
        from: UserStatus.dormant90,
        action: UserLifecycleAction.suspend,
      );
      expect(t.to, equals(UserStatus.suspended));
    });

    test('any dormant tier can recover to active', () {
      for (final from in const <UserStatus>[
        UserStatus.dormant30,
        UserStatus.dormant60,
        UserStatus.dormant90,
      ]) {
        expect(
          UserLifecycleStateMachine.apply(
            from: from,
            action: UserLifecycleAction.recoverFromDormancy,
          ).to,
          equals(UserStatus.active),
        );
      }
    });

    test('softDelete is allowed from any non-deleted state', () {
      for (final from in const <UserStatus>[
        UserStatus.invited,
        UserStatus.active,
        UserStatus.suspended,
        UserStatus.dormant30,
        UserStatus.dormant60,
        UserStatus.dormant90,
      ]) {
        expect(
          UserLifecycleStateMachine.apply(
            from: from,
            action: UserLifecycleAction.softDelete,
          ).to,
          equals(UserStatus.deleted),
        );
      }
    });

    test('deleted is absorbing — no further transitions allowed', () {
      for (final action in UserLifecycleAction.values) {
        expect(
          () => UserLifecycleStateMachine.apply(
            from: UserStatus.deleted,
            action: action,
          ),
          throwsA(isA<UserLifecycleError>()),
        );
      }
    });

    test('suspend on already-suspended is illegal (no double-suspend)', () {
      expect(
        () => UserLifecycleStateMachine.apply(
          from: UserStatus.suspended,
          action: UserLifecycleAction.suspend,
        ),
        throwsA(isA<UserLifecycleError>()),
      );
    });

    test('canApply mirrors apply success/failure', () {
      expect(
        UserLifecycleStateMachine.canApply(
          from: UserStatus.active,
          action: UserLifecycleAction.suspend,
        ),
        isTrue,
      );
      expect(
        UserLifecycleStateMachine.canApply(
          from: UserStatus.deleted,
          action: UserLifecycleAction.reactivate,
        ),
        isFalse,
      );
    });
  });

  group('UserInviteService', () {
    InviteRecord createInvite(UserInviteService svc, {DateTime? at}) {
      return svc.createInvite(
        inviteId: 'inv-1',
        request: const InviteRequest(
          email: 'invited@example.test',
          operatorId: 'op-a',
          roleId: 'role-staff',
          locationId: 'loc-a',
        ),
        invitedByUserId: 'admin-x',
        tokenHash: 'hash-xyz',
      );
    }

    test('createInvite sets expiresAt = now + 7 days by default', () {
      final clock = DateTime.utc(2026, 4, 26, 12);
      final svc = UserInviteService(now: () => clock);
      final inv = createInvite(svc);
      expect(inv.createdAt, equals(clock));
      expect(inv.expiresAt, equals(clock.add(const Duration(days: 7))));
      expect(inv.isPending, isTrue);
    });

    test('isAcceptableAt: pending + not expired', () {
      var clock = DateTime.utc(2026, 4, 26, 12);
      final svc = UserInviteService(now: () => clock);
      final inv = createInvite(svc);
      expect(inv.isAcceptableAt(clock), isTrue);

      clock = clock.add(const Duration(days: 7, seconds: 1));
      expect(inv.isAcceptableAt(clock), isFalse);
    });

    test('acceptInvite happy path sets acceptedAt', () {
      final clock = DateTime.utc(2026, 4, 26, 12);
      final svc = UserInviteService(now: () => clock);
      final inv = createInvite(svc);
      svc.acceptInvite(inv);
      expect(inv.acceptedAt, equals(clock));
      expect(inv.isPending, isFalse);
    });

    test('acceptInvite refuses already-accepted invite', () {
      final svc = UserInviteService(now: () => DateTime.utc(2026, 4, 26, 12));
      final inv = createInvite(svc);
      svc.acceptInvite(inv);
      expect(() => svc.acceptInvite(inv), throwsA(isA<InviteError>()));
    });

    test('acceptInvite refuses revoked invite', () {
      final svc = UserInviteService(now: () => DateTime.utc(2026, 4, 26, 12));
      final inv = createInvite(svc);
      svc.revokeInvite(inv);
      expect(() => svc.acceptInvite(inv), throwsA(isA<InviteError>()));
    });

    test('acceptInvite refuses expired invite (past 7d)', () {
      var clock = DateTime.utc(2026, 4, 26, 12);
      final svc = UserInviteService(now: () => clock);
      final inv = createInvite(svc);
      clock = clock.add(const Duration(days: 8));
      expect(() => svc.acceptInvite(inv), throwsA(isA<InviteError>()));
    });

    test('revokeInvite is idempotent on already-revoked / accepted', () {
      final svc = UserInviteService(now: () => DateTime.utc(2026, 4, 26, 12));
      final inv = createInvite(svc);
      expect(svc.revokeInvite(inv), isTrue);
      expect(svc.revokeInvite(inv), isFalse);

      final inv2 = createInvite(svc);
      svc.acceptInvite(inv2);
      expect(svc.revokeInvite(inv2), isFalse);
    });
  });

  group('TrustedUserCreationPolicy', () {
    test('super_admin allowed', () {
      expect(
        TrustedUserCreationPolicy.isAllowedFor(const <String>['super_admin']),
        isTrue,
      );
    });

    test('case-insensitive', () {
      expect(
        TrustedUserCreationPolicy.isAllowedFor(const <String>['SUPER_ADMIN']),
        isTrue,
      );
    });

    test('operator_owner / ff_support / staff DENIED', () {
      for (final role in const <String>[
        'operator_owner',
        'ff_support',
        'operator_manager',
        'operator_supervisor',
        'operator_staff',
      ]) {
        expect(
          TrustedUserCreationPolicy.isAllowedFor(<String>[role]),
          isFalse,
          reason: role,
        );
      }
    });

    test('empty roles -> false', () {
      expect(
        TrustedUserCreationPolicy.isAllowedFor(const <String>[]),
        isFalse,
      );
    });
  });

  group('GdprErasureService (paired-approval)', () {
    ErasureRequest buildRequest({
      String requestedBy = 'super-1',
      Set<String> requestedByRoles = const <String>{'super_admin'},
    }) {
      return ErasureRequest(
        requestId: 'req-1',
        targetUserId: 'target-user',
        targetOperatorId: 'op-a',
        requestedBy: requestedBy,
        requestedByRoles: requestedByRoles,
        reason: 'GDPR DSR ticket #42',
        requestedAt: DateTime.utc(2026, 4, 26, 12),
      );
    }

    test('requires paired approval before execute', () {
      final svc = GdprErasureService(
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      final req = buildRequest();
      svc.recordApproval(
        req,
        approverUserId: 'super-2',
        approverRoles: const <String>['super_admin'],
      );
      expect(req.firstApprovalBy, equals('super-2'));
      expect(req.isApprovedByPair, isFalse);
      expect(
        () => svc.executeErasure(
          req,
          currentTargetStatus: UserStatus.deleted,
          erasureRunbookVersion: 'v1',
        ),
        throwsA(isA<ErasureError>()),
      );
    });

    test('approver must hold super_admin', () {
      final svc = GdprErasureService();
      final req = buildRequest();
      expect(
        () => svc.recordApproval(
          req,
          approverUserId: 'owner-1',
          approverRoles: const <String>['operator_owner'],
        ),
        throwsA(isA<ErasureError>()),
      );
    });

    test('requester cannot self-approve', () {
      final svc = GdprErasureService();
      final req = buildRequest(requestedBy: 'super-1');
      expect(
        () => svc.recordApproval(
          req,
          approverUserId: 'super-1',
          approverRoles: const <String>['super_admin'],
        ),
        throwsA(isA<ErasureError>()),
      );
    });

    test('same approver cannot count twice', () {
      final svc = GdprErasureService();
      final req = buildRequest();
      svc.recordApproval(
        req,
        approverUserId: 'super-2',
        approverRoles: const <String>['super_admin'],
      );
      expect(
        () => svc.recordApproval(
          req,
          approverUserId: 'super-2',
          approverRoles: const <String>['super_admin'],
        ),
        throwsA(isA<ErasureError>()),
      );
    });

    test('execute requires the user to be soft-deleted first', () {
      final svc = GdprErasureService();
      final req = buildRequest();
      svc.recordApproval(
        req,
        approverUserId: 'super-2',
        approverRoles: const <String>['super_admin'],
      );
      svc.recordApproval(
        req,
        approverUserId: 'super-3',
        approverRoles: const <String>['super_admin'],
      );
      expect(
        () => svc.executeErasure(
          req,
          currentTargetStatus: UserStatus.active,
          erasureRunbookVersion: 'v1',
        ),
        throwsA(isA<ErasureError>()),
      );
    });

    test('happy path: paired approval + soft-deleted -> execute returns '
        'redaction payload preserving Art. 17(3) operational records', () {
      final svc = GdprErasureService(
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      final req = buildRequest();
      svc.recordApproval(
        req,
        approverUserId: 'super-2',
        approverRoles: const <String>['super_admin'],
      );
      svc.recordApproval(
        req,
        approverUserId: 'super-3',
        approverRoles: const <String>['super_admin'],
      );
      final outcome = svc.executeErasure(
        req,
        currentTargetStatus: UserStatus.deleted,
        erasureRunbookVersion: 'v1',
      );
      expect(outcome.targetUserId, equals('target-user'));
      expect(outcome.priorStatus, equals(UserStatus.deleted));
      expect(outcome.newStatus, equals(UserStatus.deleted));
      final payload = outcome.redactionPayload;
      expect(payload['runbook_version'], equals('v1'));
      final redactions = payload['redactions']! as Map<String, Object?>;
      expect(
        redactions['users.email'],
        equals('redacted-target-user@deleted.local'),
      );
      expect(redactions['users.firebase_uid_retain'], equals(true));
      // Operational record carve-out preserved.
      final preserved = payload['preserved_under_art_17_3']! as List;
      expect(preserved, contains('auth_events_audit.event_id'));
      expect(preserved, contains('auth_events_audit.event_type'));
      expect(preserved, contains('auth_events_audit.occurred_at'));
      expect(req.isExecuted, isTrue);
    });

    test('executed request is no longer pending — repeat execute fails',
        () {
      final svc = GdprErasureService();
      final req = buildRequest();
      svc.recordApproval(
        req,
        approverUserId: 'super-2',
        approverRoles: const <String>['super_admin'],
      );
      svc.recordApproval(
        req,
        approverUserId: 'super-3',
        approverRoles: const <String>['super_admin'],
      );
      svc.executeErasure(
        req,
        currentTargetStatus: UserStatus.deleted,
        erasureRunbookVersion: 'v1',
      );
      expect(
        () => svc.executeErasure(
          req,
          currentTargetStatus: UserStatus.deleted,
          erasureRunbookVersion: 'v1',
        ),
        throwsA(isA<ErasureError>()),
      );
    });

    test('cancel flips state and blocks subsequent approval / execute', () {
      final svc = GdprErasureService();
      final req = buildRequest();
      expect(svc.cancel(req, cancelledBy: 'super-2'), isTrue);
      expect(svc.cancel(req, cancelledBy: 'super-2'), isFalse);
      expect(
        () => svc.recordApproval(
          req,
          approverUserId: 'super-2',
          approverRoles: const <String>['super_admin'],
        ),
        throwsA(isA<ErasureError>()),
      );
    });
  });
}
