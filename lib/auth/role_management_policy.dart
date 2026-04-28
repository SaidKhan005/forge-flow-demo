// Phase 9.6 - Role management policy.
//
// "Who can do what to roles + grants?" This is pure logic — the
// proxy uses it to decide whether to even open a transaction for a
// `/v1/admin/auth/roles/*` request before touching Postgres.
//
// Locked rules from the plan:
//
//   * super_admin can grant/revoke any role.
//   * ff_support can grant/revoke only for operators in their scope
//     (`operator_admins.scope_location_id` filter).
//   * operator_owner can grant/revoke operator-scoped roles within
//     their own operator. They CAN edit their own custom roles;
//     they CANNOT edit seeded roles (super_admin / ff_support /
//     operator_owner / operator_manager / operator_supervisor /
//     operator_staff are `is_seeded = true` + `is_editable` flagged
//     per `auth_permission_key_catalog.md`).
//   * operator_manager can grant operator_supervisor + operator_staff
//     within their operator + location only.
//
// The policy returns a [RoleManagementDecision] with reason text so
// audit can record why something was rejected.

class ActorContext {
  const ActorContext({
    required this.actorUserId,
    required this.actorOperatorId,
    required this.actorLocationId,
    required this.actorRoles,
    required this.actorAssignedOperatorIds,
  });

  final String actorUserId;
  final String actorOperatorId;
  final String actorLocationId;

  /// Role keys held by the actor (e.g. `super_admin`, `ff_support`,
  /// `operator_owner`).
  final Set<String> actorRoles;

  /// For ff_support actors: the operator IDs they have read scope
  /// on (via `operator_admins.scope_location_id` resolution). For
  /// other actors: ignored.
  final Set<String> actorAssignedOperatorIds;
}

class TargetRole {
  const TargetRole({
    required this.roleId,
    required this.roleKey,
    required this.operatorId,
    required this.isSeeded,
    required this.isEditable,
  });

  final String roleId;
  final String roleKey;

  /// Null for global / seeded roles, non-null for operator-scoped
  /// custom roles.
  final String? operatorId;

  final bool isSeeded;

  /// `is_editable` flag from `roles`. Even seeded roles can be
  /// `is_editable = true` (e.g. `operator_owner`); the protection
  /// is a per-role boolean, not a "all seeded are frozen" rule.
  final bool isEditable;
}

class TargetGrant {
  const TargetGrant({
    required this.targetUserId,
    required this.targetOperatorId,
    required this.targetLocationId,
    required this.targetRoleKey,
  });

  final String targetUserId;
  final String targetOperatorId;
  final String? targetLocationId;
  final String targetRoleKey;
}

enum RoleManagementAction {
  createRole,
  editRole,
  deleteRole,
  grantRole,
  revokeRole,
}

class RoleManagementDecision {
  const RoleManagementDecision({required this.allowed, required this.reason});

  final bool allowed;
  final String reason;

  factory RoleManagementDecision.allow(String reason) =>
      RoleManagementDecision(allowed: true, reason: reason);
  factory RoleManagementDecision.deny(String reason) =>
      RoleManagementDecision(allowed: false, reason: reason);
}

abstract class RoleManagementPolicy {
  RoleManagementPolicy._();

  /// Decides whether [actor] may perform [action] on [role] (used
  /// for createRole / editRole / deleteRole).
  static RoleManagementDecision evaluateRoleAction({
    required ActorContext actor,
    required RoleManagementAction action,
    required TargetRole role,
  }) {
    if (actor.actorRoles.contains('super_admin')) {
      return RoleManagementDecision.allow('actor is super_admin');
    }
    if (action == RoleManagementAction.createRole ||
        action == RoleManagementAction.editRole ||
        action == RoleManagementAction.deleteRole) {
      // Seeded roles are protected — only super_admin may edit
      // (handled above). The `is_editable` flag is a per-role
      // override; non-super_admin actors must respect it.
      if (role.isSeeded && !role.isEditable) {
        return RoleManagementDecision.deny(
          'role is seeded + locked from edit (is_editable = false)',
        );
      }
      if (role.operatorId == null) {
        // Global / non-operator-scoped role. Only super_admin can
        // touch globals (allow path above).
        return RoleManagementDecision.deny(
          'global roles require super_admin',
        );
      }
      if (actor.actorRoles.contains('operator_owner')) {
        if (role.operatorId == actor.actorOperatorId) {
          return RoleManagementDecision.allow(
            'operator_owner managing own operator-scoped role',
          );
        }
        return RoleManagementDecision.deny(
          'operator_owner cannot manage roles for another operator',
        );
      }
      return RoleManagementDecision.deny(
        'actor lacks role management privilege',
      );
    }
    return RoleManagementDecision.deny(
      'action does not match a role-action path',
    );
  }

  /// Decides whether [actor] may grant or revoke [grant] for the
  /// given target user (used for grantRole / revokeRole).
  static RoleManagementDecision evaluateGrantAction({
    required ActorContext actor,
    required RoleManagementAction action,
    required TargetGrant grant,
  }) {
    if (action != RoleManagementAction.grantRole &&
        action != RoleManagementAction.revokeRole) {
      return RoleManagementDecision.deny(
        'action does not match a grant-action path',
      );
    }
    if (actor.actorRoles.contains('super_admin')) {
      return RoleManagementDecision.allow('actor is super_admin');
    }
    if (actor.actorRoles.contains('ff_support')) {
      if (!actor.actorAssignedOperatorIds.contains(grant.targetOperatorId)) {
        return RoleManagementDecision.deny(
          'ff_support has no scope on the target operator',
        );
      }
      return RoleManagementDecision.allow(
        'ff_support managing assigned operator',
      );
    }
    if (actor.actorRoles.contains('operator_owner')) {
      if (grant.targetOperatorId != actor.actorOperatorId) {
        return RoleManagementDecision.deny(
          'operator_owner cannot manage grants for another operator',
        );
      }
      // Owners may grant any operator-scoped role within their
      // operator (the seeded-role-protection is on EDIT, not on
      // GRANT — granting an existing seeded role like
      // operator_supervisor to a user is fine).
      return RoleManagementDecision.allow(
        'operator_owner managing own operator',
      );
    }
    if (actor.actorRoles.contains('operator_manager')) {
      if (grant.targetOperatorId != actor.actorOperatorId) {
        return RoleManagementDecision.deny(
          'operator_manager cannot manage grants for another operator',
        );
      }
      if (grant.targetLocationId != null &&
          grant.targetLocationId != actor.actorLocationId) {
        return RoleManagementDecision.deny(
          'operator_manager cannot manage grants outside own location',
        );
      }
      const allowed = <String>{'operator_supervisor', 'operator_staff'};
      if (!allowed.contains(grant.targetRoleKey)) {
        return RoleManagementDecision.deny(
          'operator_manager limited to operator_supervisor + operator_staff',
        );
      }
      return RoleManagementDecision.allow(
        'operator_manager granting allowed sub-role',
      );
    }
    return RoleManagementDecision.deny('actor lacks grant privilege');
  }
}
