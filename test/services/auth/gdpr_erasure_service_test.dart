// CODE_HEALTH L11 - GdprErasureService approval-expiry tests.
//
// Focuses on the 14-day pending-erasure approval expiry. A pair that
// approved but never executed cannot run the erasure on stale consent —
// they must re-approve. Per-deployment override via
// `GDPR_APPROVAL_MAX_AGE_DAYS` is exercised via the `approvalMaxAge`
// constructor parameter so the tests stay env-independent.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/user_lifecycle.dart';
import 'package:forge_and_flow/services/auth/gdpr_erasure_service.dart';

void main() {
  group('GdprErasureService approval expiry (CODE_HEALTH L11)', () {
    test('approval dated 13 days ago passes the freshness gate', () {
      final clock = _FixedClock(DateTime.utc(2026, 5, 1, 12));
      final service = GdprErasureService(now: clock.now);

      final request = _pairApproved(clock: clock);
      // Roll the clock forward to 13 days after the approvals.
      clock.value = DateTime.utc(2026, 5, 14, 12);

      final outcome = service.executeErasure(
        request,
        currentTargetStatus: UserStatus.deleted,
        erasureRunbookVersion: 'gdpr-erasure-v1',
      );

      expect(outcome.targetUserId, equals('target-user'));
      expect(request.executedAt, isNotNull);
    });

    test('approval dated 15 days ago fails with a stale-approval error', () {
      final clock = _FixedClock(DateTime.utc(2026, 5, 1, 12));
      final service = GdprErasureService(now: clock.now);

      final request = _pairApproved(clock: clock);
      // Roll forward 15 days — past the 14-day default.
      clock.value = DateTime.utc(2026, 5, 16, 12);

      expect(
        () => service.executeErasure(
          request,
          currentTargetStatus: UserStatus.deleted,
          erasureRunbookVersion: 'gdpr-erasure-v1',
        ),
        throwsA(
          isA<ErasureError>().having(
            (error) => error.message,
            'message',
            contains('stale'),
          ),
        ),
      );
      expect(request.executedAt, isNull);
    });

    test(
      'second approval stale alone fails (per-approval freshness, not pair)',
      () {
        final clock = _FixedClock(DateTime.utc(2026, 5, 1, 12));
        final service = GdprErasureService(now: clock.now);

        final request = ErasureRequest(
          requestId: 'req-1',
          targetUserId: 'target-user',
          targetOperatorId: 'op-1',
          requestedBy: 'requester',
          requestedByRoles: <String>{'super_admin'},
          reason: 'subject access request',
          requestedAt: clock.now(),
        );
        // First approval is recent.
        service.recordApproval(
          request,
          approverUserId: 'approver-1',
          approverRoles: const <String>['super_admin'],
        );
        // Second approval recorded right now, but we will roll forward.
        service.recordApproval(
          request,
          approverUserId: 'approver-2',
          approverRoles: const <String>['super_admin'],
        );

        // Manually backdate the second approval to be stale; first stays fresh.
        request.firstApprovalAt = DateTime.utc(2026, 5, 1, 12); // recent
        request.secondApprovalAt = DateTime.utc(2026, 4, 10, 12); // 21d ago
        clock.value = DateTime.utc(2026, 5, 1, 12);

        expect(
          () => service.executeErasure(
            request,
            currentTargetStatus: UserStatus.deleted,
            erasureRunbookVersion: 'gdpr-erasure-v1',
          ),
          throwsA(
            isA<ErasureError>().having(
              (error) => error.message,
              'message',
              contains('second approval is stale'),
            ),
          ),
        );
      },
    );

    test('configurable window honors approvalMaxAge override', () {
      final clock = _FixedClock(DateTime.utc(2026, 5, 1, 12));
      // Tighter 7-day window from a per-deployment env override.
      final service = GdprErasureService(
        now: clock.now,
        approvalMaxAge: const Duration(days: 7),
      );

      final request = _pairApproved(clock: clock);
      // 8 days later — past the tightened window.
      clock.value = DateTime.utc(2026, 5, 9, 12);

      expect(
        () => service.executeErasure(
          request,
          currentTargetStatus: UserStatus.deleted,
          erasureRunbookVersion: 'gdpr-erasure-v1',
        ),
        throwsA(isA<ErasureError>()),
      );
      expect(service.approvalMaxAge, equals(const Duration(days: 7)));
    });

    test('default window is 14 days', () {
      expect(
        GdprErasureService.defaultApprovalMaxAge,
        equals(const Duration(days: 14)),
      );
      expect(
        GdprErasureService.approvalMaxAgeEnvVar,
        equals('GDPR_APPROVAL_MAX_AGE_DAYS'),
      );
    });

    test(
      'expiry check runs after pair completeness and before status check',
      () {
        // A request with only one approval still surfaces the existing
        // "paired approval is not complete" error (expiry does not mask it).
        final clock = _FixedClock(DateTime.utc(2026, 5, 1, 12));
        final service = GdprErasureService(now: clock.now);

        final request = ErasureRequest(
          requestId: 'req-2',
          targetUserId: 'target-user',
          targetOperatorId: 'op-1',
          requestedBy: 'requester',
          requestedByRoles: <String>{'super_admin'},
          reason: 'subject access request',
          requestedAt: clock.now(),
        );
        service.recordApproval(
          request,
          approverUserId: 'approver-1',
          approverRoles: const <String>['super_admin'],
        );

        expect(
          () => service.executeErasure(
            request,
            currentTargetStatus: UserStatus.deleted,
            erasureRunbookVersion: 'gdpr-erasure-v1',
          ),
          throwsA(
            isA<ErasureError>().having(
              (error) => error.message,
              'message',
              equals('paired approval is not complete'),
            ),
          ),
        );
      },
    );
  });
}

/// Builds an [ErasureRequest] with a fresh paired approval at [clock].now().
ErasureRequest _pairApproved({required _FixedClock clock}) {
  final service = GdprErasureService(now: clock.now);
  final request = ErasureRequest(
    requestId: 'req-1',
    targetUserId: 'target-user',
    targetOperatorId: 'op-1',
    requestedBy: 'requester',
    requestedByRoles: <String>{'super_admin'},
    reason: 'subject access request',
    requestedAt: clock.now(),
  );
  service.recordApproval(
    request,
    approverUserId: 'approver-1',
    approverRoles: const <String>['super_admin'],
  );
  service.recordApproval(
    request,
    approverUserId: 'approver-2',
    approverRoles: const <String>['super_admin'],
  );
  return request;
}

class _FixedClock {
  _FixedClock(this.value);

  DateTime value;

  DateTime now() => value;
}
