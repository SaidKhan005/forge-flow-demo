// Phase 9.10 - Operator Settings -> Team entrypoint widget.
//
// Gates the Team settings nav item by `team.users.view`. When the
// permission check fails, renders nothing (so the nav item
// disappears entirely from layout, matching the
// `PermissionGate` "fail-closed by hiding" pattern).
//
// The actual Material UI surfaces (Users list, Roles list, Invite
// flow, Audit log viewer) are focused follow-ups consuming the
// controllers in `lib/services/team/`. This entrypoint is the
// single hook the Forge & Flow + Barrio shells use to surface
// "Settings -> Team" without each shell re-implementing the gate.

import 'package:flutter/material.dart';

import '../../services/team/team_scope_visibility_policy.dart';

/// Renders [child] iff the current actor passes the
/// `TeamScopeVisibilityPolicy.canSeeTeamNav` check. Otherwise
/// renders [denied] (defaults to a zero-size widget).
class TeamSettingsEntrypoint extends StatelessWidget {
  const TeamSettingsEntrypoint({
    super.key,
    required this.actor,
    required this.child,
    this.denied,
  });

  final TeamScopeActor actor;
  final Widget child;
  final Widget? denied;

  @override
  Widget build(BuildContext context) {
    if (TeamScopeVisibilityPolicy.canSeeTeamNav(actor)) {
      return child;
    }
    return denied ?? const SizedBox.shrink();
  }
}
