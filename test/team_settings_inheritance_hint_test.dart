// Phase 9.UX inheritance-hint slice — per-grant hint render in the
// role-change dialog (`_RoleGrantDialog` inside `team_settings_section.dart`).
//
// Pins the three `scope_type` render branches the operator sees when
// they tap "Change role" on a user who already has one or more grants
// in `user_roles`:
//
//   * `operator_wide` -> "Applies operator-wide"
//   * `org_unit`      -> "Inherited via {unit.label} (N locations)" with
//                         singular "1 location" when N == 1
//   * `location`      -> "Direct at {location.label}"
//
// Plus the lookup-miss fallback for stale labels (the unit/location was
// deleted between the gateway fetch and the dialog opening) — must
// degrade to "{scope_type} (unknown)" without crashing.
//
// CLAUDE.md guardrails preserved:
//   * No new permission keys. The existing dialog is gated on
//     `team.roles.assign`; `_fullTeamActor` carries it as a precondition
//     for the dialog opening at all.
//   * No `package:postgres` imports. Widget-only test.
//   * Lane scope: only `team_settings_section.dart` is read; no
//     gateway / repository / migration files are touched.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/team/team_settings_section.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';

const TeamScopeActor _fullTeamActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{
    'team.users.view',
    'team.roles.assign',
    'team.roles.revoke',
  },
);

const List<TeamLocationOption> _locations = <TeamLocationOption>[
  TeamLocationOption(locationId: 'loc-vancouver', label: 'Vancouver Robson'),
  TeamLocationOption(locationId: 'loc-burnaby', label: 'Burnaby'),
  TeamLocationOption(locationId: 'loc-richmond', label: 'Richmond'),
];

const List<TeamOrgUnitOption> _orgUnits = <TeamOrgUnitOption>[
  TeamOrgUnitOption(
    orgUnitId: 'unit-east',
    label: 'East Region',
    path: 'forgeflow.east',
  ),
];

Future<void> _openRoleChangeDialog(
  WidgetTester tester,
  TeamUserListItem user, {
  List<TeamOrgUnitOption> orgUnitOptions = _orgUnits,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TeamSettingsSection(
          actor: _fullTeamActor,
          users: <TeamUserListItem>[user],
          locationOptions: _locations,
          orgUnitOptions: orgUnitOptions,
          onUserAction: (_) async {},
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(Key('team_user_actions_${user.userId}')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Change role'));
  await tester.pumpAndSettle();
}

void main() {
  group('Phase 9.UX role-change dialog inheritance hints', () {
    testWidgets(
      'operator_wide grant renders "Applies operator-wide"',
      (tester) async {
        const user = TeamUserListItem(
          userId: 'user-op-wide',
          email: 'opwide@example.test',
          displayName: 'Op Wide',
          roleId: 'operator_owner',
          roleLabel: 'Owner',
          status: 'active',
          userRoleId: 'grant-op-wide',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-op-wide',
              roleId: 'operator_owner',
              roleLabel: 'Owner',
              scopeType: 'operator_wide',
            ),
          ],
        );

        await _openRoleChangeDialog(tester, user);

        expect(
          find.byKey(const Key('team_role_change_grant_grant-op-wide')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('team_role_change_grant_hint_grant-op-wide'),
          ),
          findsOneWidget,
        );
        expect(find.text('Applies operator-wide'), findsOneWidget);
      },
    );

    testWidgets(
      'org_unit grant with 3 effective locations renders plural copy',
      (tester) async {
        const user = TeamUserListItem(
          userId: 'user-org-unit',
          email: 'orgunit@example.test',
          displayName: 'Org Unit',
          roleId: 'operator_manager',
          roleLabel: 'Manager',
          status: 'active',
          userRoleId: 'grant-org-east',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-org-east',
              roleId: 'operator_manager',
              roleLabel: 'Manager',
              scopeType: 'org_unit',
              orgUnitId: 'unit-east',
              effectiveLocationIds: <String>[
                'loc-vancouver',
                'loc-burnaby',
                'loc-richmond',
              ],
            ),
          ],
        );

        await _openRoleChangeDialog(tester, user);

        expect(
          find.text('Inherited via East Region (3 locations)'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'org_unit grant with 1 effective location renders singular "1 location"',
      (tester) async {
        const user = TeamUserListItem(
          userId: 'user-org-unit-single',
          email: 'orgunit-single@example.test',
          displayName: 'Org Unit Single',
          roleId: 'operator_manager',
          roleLabel: 'Manager',
          status: 'active',
          userRoleId: 'grant-org-east-1',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-org-east-1',
              roleId: 'operator_manager',
              roleLabel: 'Manager',
              scopeType: 'org_unit',
              orgUnitId: 'unit-east',
              effectiveLocationIds: <String>['loc-vancouver'],
            ),
          ],
        );

        await _openRoleChangeDialog(tester, user);

        expect(
          find.text('Inherited via East Region (1 location)'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'location grant renders "Direct at {label}"',
      (tester) async {
        const user = TeamUserListItem(
          userId: 'user-location',
          email: 'location@example.test',
          displayName: 'Location User',
          roleId: 'operator_supervisor',
          roleLabel: 'Supervisor',
          status: 'active',
          locationId: 'loc-vancouver',
          locationLabel: 'Vancouver Robson',
          userRoleId: 'grant-loc-1',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-loc-1',
              roleId: 'operator_supervisor',
              roleLabel: 'Supervisor',
              scopeType: 'location',
              locationId: 'loc-vancouver',
            ),
          ],
        );

        await _openRoleChangeDialog(tester, user);

        expect(find.text('Direct at Vancouver Robson'), findsOneWidget);
      },
    );

    testWidgets(
      'multi-grant user renders all three scope branches in one dialog',
      (tester) async {
        const user = TeamUserListItem(
          userId: 'user-multi',
          email: 'multi@example.test',
          displayName: 'Multi Grant',
          roleId: 'operator_owner',
          roleLabel: 'Owner',
          status: 'active',
          locationId: 'loc-vancouver',
          locationLabel: 'Vancouver Robson',
          userRoleId: 'grant-multi-op',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-multi-op',
              roleId: 'operator_owner',
              roleLabel: 'Owner',
              scopeType: 'operator_wide',
            ),
            TeamUserRoleGrant(
              userRoleId: 'grant-multi-org',
              roleId: 'operator_manager',
              roleLabel: 'Manager',
              scopeType: 'org_unit',
              orgUnitId: 'unit-east',
              effectiveLocationIds: <String>[
                'loc-vancouver',
                'loc-burnaby',
                'loc-richmond',
              ],
            ),
            TeamUserRoleGrant(
              userRoleId: 'grant-multi-loc',
              roleId: 'operator_supervisor',
              roleLabel: 'Supervisor',
              scopeType: 'location',
              locationId: 'loc-vancouver',
            ),
          ],
        );

        await _openRoleChangeDialog(tester, user);

        expect(find.text('Applies operator-wide'), findsOneWidget);
        expect(
          find.text('Inherited via East Region (3 locations)'),
          findsOneWidget,
        );
        expect(find.text('Direct at Vancouver Robson'), findsOneWidget);
      },
    );

    testWidgets(
      'org_unit grant whose unit is missing from the loaded options falls '
      'back to "org_unit (unknown)" without crashing',
      (tester) async {
        const user = TeamUserListItem(
          userId: 'user-stale-org',
          email: 'stale@example.test',
          displayName: 'Stale Org',
          roleId: 'operator_manager',
          roleLabel: 'Manager',
          status: 'active',
          userRoleId: 'grant-stale-org',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-stale-org',
              roleId: 'operator_manager',
              roleLabel: 'Manager',
              scopeType: 'org_unit',
              orgUnitId: 'unit-deleted',
              effectiveLocationIds: <String>['loc-vancouver'],
            ),
          ],
        );

        // Pass an empty org-unit option list so the lookup must miss.
        await _openRoleChangeDialog(
          tester,
          user,
          orgUnitOptions: const <TeamOrgUnitOption>[],
        );

        expect(find.text('org_unit (unknown)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'location grant whose location is missing from the loaded options '
      'falls back to "location (unknown)" without crashing',
      (tester) async {
        const user = TeamUserListItem(
          userId: 'user-stale-loc',
          email: 'staleloc@example.test',
          displayName: 'Stale Loc',
          roleId: 'operator_supervisor',
          roleLabel: 'Supervisor',
          status: 'active',
          userRoleId: 'grant-stale-loc',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-stale-loc',
              roleId: 'operator_supervisor',
              roleLabel: 'Supervisor',
              scopeType: 'location',
              locationId: 'loc-removed',
            ),
          ],
        );

        await _openRoleChangeDialog(tester, user);

        expect(find.text('location (unknown)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'user with no grants renders no Active grants block (additive '
      'rendering is opt-in)',
      (tester) async {
        const user = TeamUserListItem(
          userId: 'user-no-grants',
          email: 'nogrants@example.test',
          displayName: 'No Grants',
          roleId: 'operator_owner',
          roleLabel: 'Owner',
          status: 'active',
          userRoleId: 'grant-none',
        );

        await _openRoleChangeDialog(tester, user);

        // Existing assign form is still present.
        expect(
          find.byKey(const Key('team_role_change_role_dropdown')),
          findsOneWidget,
        );
        // No Active-grants container or hint nodes rendered.
        expect(
          find.byKey(const Key('team_role_change_active_grants')),
          findsNothing,
        );
        expect(find.text('Active grants'), findsNothing);
      },
    );
  });
}

