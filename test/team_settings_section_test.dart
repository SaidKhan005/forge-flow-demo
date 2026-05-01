// Phase 9.UX.3 — Settings → Team user-action menu wiring.
//
// Pins the additive menu entry "Explain permissions" the slice adds to
// `_TeamUserActionMenu` inside `team_settings_section.dart`. The entry
// is gated on the existing `team.users.view` permission and routes to
// the Phase 9.UX.3 explainer screen.
//
// CLAUDE.md guardrails preserved:
//   * No new permission keys. `team.users.view` already exists in
//     `lib/auth/permission_keys.dart` and gates the Team tab itself.
//   * No `package:postgres` imports. Widget-only test.
//   * No mutation of the role-grant flow / MFA flow / other actions —
//     this test only inspects the new entry's visibility and tap
//     behavior.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings/settings_permission_explainer.dart';
import 'package:forge_and_flow/screens/team/team_settings_section.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';

const TeamScopeActor _viewerActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{
    'team.users.view',
    'team.users.invite',
    'team.users.deactivate',
    'team.users.reactivate',
  },
);

const TeamScopeActor _hiddenActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{},
);

const TeamUserListItem _userFixture = TeamUserListItem(
  userId: 'user-fixture',
  email: 'fixture@example.test',
  displayName: 'Fiona Fixture',
  roleId: 'operator_owner',
  roleLabel: 'Owner',
  status: 'active',
  userRoleId: 'grant-fixture',
  grants: <TeamUserRoleGrant>[
    TeamUserRoleGrant(
      userRoleId: 'grant-fixture',
      roleId: 'operator_owner',
      roleLabel: 'Owner',
      scopeType: 'operator_wide',
    ),
  ],
);

Future<void> _pumpTeamSection(
  WidgetTester tester, {
  required TeamScopeActor actor,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TeamSettingsSection(
          actor: actor,
          users: const <TeamUserListItem>[_userFixture],
          onUserAction: (_) async {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Phase 9.UX.3 Team user-action menu — Explain permissions entry', () {
    testWidgets(
      'is offered to actors holding team.users.view',
      (tester) async {
        await _pumpTeamSection(tester, actor: _viewerActor);
        await tester.tap(
          find.byKey(Key('team_user_actions_${_userFixture.userId}')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Explain permissions'), findsOneWidget);
        expect(
          find.byKey(
            Key('team_user_explain_permissions_${_userFixture.userId}'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'is hidden when the actor lacks team.users.view',
      (tester) async {
        await _pumpTeamSection(tester, actor: _hiddenActor);
        // The popup-menu trigger may itself be disabled when the actor
        // has no actions; the explain entry must not surface either
        // way. Probe for it after attempting to open the menu.
        final trigger = find.byKey(
          Key('team_user_actions_${_userFixture.userId}'),
        );
        expect(trigger, findsOneWidget);
        // PopupMenuButton is disabled when actions is empty — tap is
        // a no-op. Either branch is acceptable; the assertion below
        // is the safety property: the entry must never be reachable
        // for an actor without team.users.view.
        await tester.tap(trigger, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text('Explain permissions'), findsNothing);
        expect(
          find.byKey(
            Key('team_user_explain_permissions_${_userFixture.userId}'),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'tapping the entry pushes the SettingsPermissionExplainer route',
      (tester) async {
        await _pumpTeamSection(tester, actor: _viewerActor);
        await tester.tap(
          find.byKey(Key('team_user_actions_${_userFixture.userId}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Explain permissions'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPermissionExplainer), findsOneWidget);
      },
    );
  });
}
