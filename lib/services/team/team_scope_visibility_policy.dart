// Phase 9.10 - Operator Settings -> Team scope visibility policy.
//
// Pure logic backing the "who can see Team nav" + "what can each
// actor manage" question. Runtime gates (PermissionGate widget,
// proxy-side ProxyAdminPermissionGuard) consume this policy so the
// surface stays consistent across mobile + desktop + proxy.
//
// Locked decisions from the slice prompt:
//
//   * operator_owner: manage own operator across all locations.
//   * operator_general_manager: current v2 GM role; business-scope
//     staff admin and audit access when granted team.* perms.
//   * location_manager: see/manage assigned locations only when
//     granted team.* perms.
//   * retired v1 roles (operator_manager / operator_supervisor /
//     operator_staff): cannot see Team nav.

/// Per-actor scope context the policy consumes. Built from the
/// verified session + the actor's `user_roles` rows.
class TeamScopeActor {
  const TeamScopeActor({
    required this.actorRoles,
    required this.actorOperatorId,
    required this.actorAssignedLocationIds,
    required this.actorPermissions,
  });

  /// Role keys held by the actor (e.g. `super_admin`, `operator_owner`,
  /// `operator_general_manager`).
  final Set<String> actorRoles;
  final String actorOperatorId;

  /// Location_ids this actor is granted on (location-scope grants
  /// from `user_roles`). Empty for operator_owner and
  /// operator_general_manager (business-scope roles that manage every
  /// location).
  final Set<String> actorAssignedLocationIds;

  /// Resolved permission keys the actor holds (allow effects). The
  /// caller has already applied deny-wins / default-deny via the
  /// 9.6 resolver.
  final Set<String> actorPermissions;
}

/// Target user the actor wants to view / mutate. Carries the
/// minimum context the policy needs.
class TeamScopeTarget {
  const TeamScopeTarget({
    required this.targetOperatorId,
    this.targetLocationId,
  });

  final String targetOperatorId;

  /// Null when the target row is operator-wide; non-null when
  /// location-scoped.
  final String? targetLocationId;
}

abstract class TeamScopeVisibilityPolicy {
  TeamScopeVisibilityPolicy._();

  /// True iff the actor should see the Team nav entrypoint at all.
  /// Gated by `team.users.view` AND a valid v2 role/scope. Business
  /// roles (operator_owner / operator_general_manager) cover the
  /// operator. location_manager needs at least one assigned location.
  /// Retired v1 roles are refused even if they hold the permission key
  /// for some reason.
  static bool canSeeTeamNav(TeamScopeActor actor) {
    if (!actor.actorPermissions.contains('team.users.view')) return false;
    if (_isAdminTier(actor)) return true;
    if (actor.actorRoles.contains('operator_owner')) return true;
    if (actor.actorRoles.contains('operator_general_manager')) return true;
    if (actor.actorRoles.contains('location_manager')) {
      // Location manager needs at least one assigned location to have
      // anything to manage.
      return actor.actorAssignedLocationIds.isNotEmpty;
    }
    return false;
  }

  /// True iff the actor can view [target]. Cross-tenant always
  /// refused. Location-scoped target requires the actor to hold
  /// the location.
  static bool canViewTarget({
    required TeamScopeActor actor,
    required TeamScopeTarget target,
  }) {
    if (target.targetOperatorId != actor.actorOperatorId &&
        !_isAdminTier(actor)) {
      return false;
    }
    if (_isAdminTier(actor)) return true;
    if (actor.actorRoles.contains('operator_owner')) return true;
    if (actor.actorRoles.contains('operator_general_manager')) return true;
    if (!actor.actorRoles.contains('location_manager')) return false;
    final loc = target.targetLocationId;
    if (loc == null) {
      // Operator-wide target: only business-scope actors see these.
      return false;
    }
    return actor.actorAssignedLocationIds.contains(loc);
  }

  /// True iff the actor can mutate [target] (e.g. invite, deactivate,
  /// assign role). Stricter than view: requires the relevant
  /// permission key AND scope match.
  static bool canMutateTarget({
    required TeamScopeActor actor,
    required TeamScopeTarget target,
    required String requiredPermissionKey,
  }) {
    if (!actor.actorPermissions.contains(requiredPermissionKey)) {
      return false;
    }
    return canViewTarget(actor: actor, target: target);
  }

  static bool _isAdminTier(TeamScopeActor actor) {
    return actor.actorRoles.contains('super_admin') ||
        actor.actorRoles.contains('ff_support');
  }
}
