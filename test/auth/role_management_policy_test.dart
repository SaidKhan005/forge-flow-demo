// CODE_HEALTH C1 - operator_owner role escalation guard tests.
//
// Reference: docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md C1 -
// `lib/auth/role_management_policy.dart` granted `operator_owner`
// blanket allow on grant/revoke within their own tenant, which let
// them emit `super_admin` and `ff_support` grants - a
// privilege-escalation hole into F&F platform tiers.
//
// These tests pin the fix:
//
//   1. operator_owner attempting to grant `super_admin` is denied.
//   2. operator_owner attempting to grant `ff_support` is denied.
//   3. operator_owner granting a normal operator-scoped role
//      (e.g. `supervisor`) within their own tenant is still
//      allowed - the fix is targeted, not a regression to the
//      operator-self-management surface.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/role_management_policy.dart';

const String _ownerOperatorId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const String _ownerLocationId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const String _ownerUserId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
const String _targetUserId = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

ActorContext _operatorOwnerActor() => const ActorContext(
  actorUserId: _ownerUserId,
  actorOperatorId: _ownerOperatorId,
  actorLocationId: _ownerLocationId,
  actorRoles: <String>{'operator_owner'},
  actorAssignedOperatorIds: <String>{},
);

TargetGrant _grantOf(String roleKey) => TargetGrant(
  targetUserId: _targetUserId,
  targetOperatorId: _ownerOperatorId,
  targetLocationId: _ownerLocationId,
  targetRoleKey: roleKey,
);

void main() {
  group('operator_owner cannot escalate to F&F platform roles', () {
    test('granting super_admin within own tenant is denied', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: _operatorOwnerActor(),
        action: RoleManagementAction.grantRole,
        grant: _grantOf('super_admin'),
      );

      expect(
        decision.allowed,
        isFalse,
        reason: 'operator_owner must never grant super_admin',
      );
      expect(
        decision.reason,
        contains('platform'),
        reason: 'denial reason should explain the platform-tier guard',
      );
    });

    test('granting ff_support within own tenant is denied', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: _operatorOwnerActor(),
        action: RoleManagementAction.grantRole,
        grant: _grantOf('ff_support'),
      );

      expect(
        decision.allowed,
        isFalse,
        reason: 'operator_owner must never grant ff_support',
      );
      expect(
        decision.reason,
        contains('platform'),
        reason: 'denial reason should explain the platform-tier guard',
      );
    });

    test('revoking super_admin within own tenant is also denied', () {
      // Revoke is the inverse path of grant; the same guard MUST
      // apply, otherwise an operator_owner could revoke the only
      // super_admin in their tenant and lock platform support out.
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: _operatorOwnerActor(),
        action: RoleManagementAction.revokeRole,
        grant: _grantOf('super_admin'),
      );

      expect(decision.allowed, isFalse);
    });
  });

  group('operator_owner still manages legitimate in-tenant grants', () {
    test('granting supervisor within own tenant is allowed', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: _operatorOwnerActor(),
        action: RoleManagementAction.grantRole,
        grant: _grantOf('supervisor'),
      );

      expect(
        decision.allowed,
        isTrue,
        reason:
            'operator_owner must keep the ability to grant operator-scoped '
            'roles within their own tenant',
      );
      expect(decision.reason, contains('operator_owner'));
    });

    test('granting operator_general_manager within own tenant is allowed', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: _operatorOwnerActor(),
        action: RoleManagementAction.grantRole,
        grant: _grantOf('operator_general_manager'),
      );

      expect(decision.allowed, isTrue);
    });
  });
}
