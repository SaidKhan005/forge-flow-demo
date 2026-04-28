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
//   * operator_manager: see/manage assigned locations only when
//     granted team.* perms. operator_manager.scope_type =
//     'location' (per 9.0a) means the manager only manages users
//     whose user_roles row also has scope_type = 'location' AND
//     matches the manager's assigned location_id.
//   * operator_supervisor / operator_staff: cannot see Team nav.

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
  /// `operator_manager`).
  final Set<String> actorRoles;
  final String actorOperatorId;

  /// Location_ids this actor is granted on (location-scope grants
  /// from `user_roles`). Empty for operator_owner (who is
  /// operator-wide and manages every location).
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
  /// Gated by `team.users.view` AND a non-zero scope (operator_owner
  /// or operator_manager with at least one assigned location).
  /// `operator_supervisor` and `operator_staff` are refused even if
  /// they hold the permission key for some reason.
  static bool canSeeTeamNav(TeamScopeActor actor) {
    if (!actor.actorPermissions.contains('team.users.view')) return false;
    if (_isAdminTier(actor)) return true;
    if (actor.actorRoles.contains('operator_owner')) return true;
    if (actor.actorRoles.contains('operator_manager')) {
      // Manager needs at least one assigned location to have
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
    final loc = target.targetLocationId;
    if (loc == null) {
      // Operator-wide target — only operator_owner sees these.
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
