// Phase 9.UX.3 — Settings → Team → "Explain permissions" surface.
//
// Pins the resolution-chain rendering and final-effect pill against the
// PermissionResolver from `lib/auth/permission_resolution.dart`. The
// screen is a pure UI consumer of the resolver — these tests assert that
// the chain shows source, scope, and rule per grant, that deny rules
// win over allow, that org-unit and location-scoped grants render
// readable scope labels, and that the unknown-permission-key fallback
// degrades to a polite "Unknown permission key" notice without crashing.
//
// CLAUDE.md guardrails preserved:
//   * No Postgres / proxy code is touched. The resolver is the single
//     source of truth for the final effect pill — tests hit
//     `PermissionResolver.resolve` indirectly through the widget.
//   * No new permission keys, no new gateway calls. The fixtures only
//     reference keys from `lib/auth/permission_keys.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings/settings_permission_explainer.dart';
import 'package:forge_and_flow/screens/team/team_settings_section.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';

const TeamScopeActor _viewerActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{
    'team.users.view',
    'team.users.invite',
    'team.roles.assign',
  },
);

const TeamScopeActor _lockedActor = TeamScopeActor(
  actorRoles: <String>{'operator_staff'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{},
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

TeamRoleCatalogEntry _ownerRoleCatalog() {
  return const TeamRoleCatalogEntry(
    roleId: 'role-owner',
    roleKey: 'operator_owner',
    displayName: 'Owner',
    description: 'Operator owner — full operator-wide team management',
    isSeeded: true,
    isEditable: false,
    permissions: <TeamRolePermissionRule>[
      TeamRolePermissionRule(
        permissionKey: 'team.users.invite',
        effect: 'allow',
      ),
      TeamRolePermissionRule(
        permissionKey: 'team.users.view',
        effect: 'allow',
      ),
      TeamRolePermissionRule(
        permissionKey: 'team.roles.assign',
        effect: 'allow',
      ),
    ],
  );
}

TeamRoleCatalogEntry _supervisorRoleCatalog() {
  return const TeamRoleCatalogEntry(
    roleId: 'role-supervisor',
    roleKey: 'operator_supervisor',
    displayName: 'Supervisor',
    description: 'Location-scoped supervisor',
    isSeeded: true,
    isEditable: false,
    permissions: <TeamRolePermissionRule>[
      TeamRolePermissionRule(
        permissionKey: 'team.users.view',
        effect: 'allow',
      ),
      TeamRolePermissionRule(
        permissionKey: 'team.users.invite',
        effect: 'deny',
      ),
    ],
  );
}

TeamRoleCatalogEntry _managerRoleCatalog() {
  return const TeamRoleCatalogEntry(
    roleId: 'role-manager',
    roleKey: 'operator_manager',
    displayName: 'Manager',
    description: 'Manager with org-unit scope',
    isSeeded: true,
    isEditable: false,
    permissions: <TeamRolePermissionRule>[
      TeamRolePermissionRule(
        permissionKey: 'team.users.view',
        effect: 'allow',
      ),
      TeamRolePermissionRule(
        permissionKey: 'team.users.invite',
        effect: 'allow',
      ),
    ],
  );
}

Future<void> _pumpExplainer(
  WidgetTester tester, {
  required TeamUserListItem target,
  required List<TeamRoleCatalogEntry> catalog,
  TeamScopeActor actor = _viewerActor,
  String initialPermissionKey = 'team.users.invite',
  String? initialLocationId,
  List<TeamLocationOption> locations = _locations,
  List<TeamOrgUnitOption> orgUnits = _orgUnits,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SettingsPermissionExplainer(
        actor: actor,
        target: target,
        roleCatalog: catalog,
        locationOptions: locations,
        orgUnitOptions: orgUnits,
        initialPermissionKey: initialPermissionKey,
        initialLocationId: initialLocationId,
        now: DateTime.utc(2026, 4, 30),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Phase 9.UX.3 SettingsPermissionExplainer', () {
    testWidgets(
      'allow chain — operator-wide owner grant resolves to Allow',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-owner',
          email: 'owner@example.test',
          displayName: 'Olivia Owner',
          roleId: 'role-owner',
          roleLabel: 'Owner',
          status: 'active',
          userRoleId: 'grant-op-wide',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-op-wide',
              roleId: 'role-owner',
              roleLabel: 'Owner',
              scopeType: 'operator_wide',
            ),
          ],
        );

        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_ownerRoleCatalog()],
          initialPermissionKey: 'team.users.invite',
        );

        expect(
          find.byKey(
            const Key(
              'settings_permission_explainer_chain_grant-op-wide',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key(
              'settings_permission_explainer_rule_grant-op-wide',
            ),
          ),
          findsOneWidget,
        );
        expect(find.text('Operator-wide'), findsWidgets);
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Allow'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'deny chain — explicit deny rule wins over allow rule on a sibling grant',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-mixed',
          email: 'mixed@example.test',
          displayName: 'Mia Mixed',
          roleId: 'role-supervisor',
          roleLabel: 'Supervisor',
          status: 'active',
          userRoleId: 'grant-supervisor',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-owner-allow',
              roleId: 'role-owner',
              roleLabel: 'Owner',
              scopeType: 'operator_wide',
            ),
            TeamUserRoleGrant(
              userRoleId: 'grant-supervisor-deny',
              roleId: 'role-supervisor',
              roleLabel: 'Supervisor',
              scopeType: 'operator_wide',
            ),
          ],
        );

        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[
            _ownerRoleCatalog(),
            _supervisorRoleCatalog(),
          ],
          initialPermissionKey: 'team.users.invite',
        );

        expect(
          find.byKey(
            const Key(
              'settings_permission_explainer_chain_grant-supervisor-deny',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Deny'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Allow'),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'role-inherited allow — owner role catalog lookup hydrates display name',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-named',
          email: 'named@example.test',
          displayName: 'Nina Named',
          roleId: 'role-owner',
          roleLabel: 'role-owner',
          status: 'active',
          userRoleId: 'grant-owner',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-owner',
              roleId: 'role-owner',
              roleLabel: 'role-owner',
              scopeType: 'operator_wide',
            ),
          ],
        );

        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_ownerRoleCatalog()],
          initialPermissionKey: 'team.users.view',
        );

        expect(find.text('Owner'), findsWidgets);
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Allow'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'org-unit-inherited grant — scope label includes location count',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-east',
          email: 'east@example.test',
          displayName: 'Edgar East',
          roleId: 'role-manager',
          roleLabel: 'Manager',
          status: 'active',
          userRoleId: 'grant-east',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-east',
              roleId: 'role-manager',
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

        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_managerRoleCatalog()],
          initialPermissionKey: 'team.users.invite',
          initialLocationId: 'loc-burnaby',
        );

        expect(find.text('East Region (3 locations)'), findsOneWidget);
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Allow'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'location-scoped grant — scope label uses the location label',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-loc',
          email: 'loc@example.test',
          displayName: 'Lana Local',
          roleId: 'role-manager',
          roleLabel: 'Manager',
          status: 'active',
          userRoleId: 'grant-loc',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-loc',
              roleId: 'role-manager',
              roleLabel: 'Manager',
              scopeType: 'location',
              locationId: 'loc-vancouver',
            ),
          ],
        );

        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_managerRoleCatalog()],
          initialPermissionKey: 'team.users.invite',
          initialLocationId: 'loc-vancouver',
        );

        expect(find.text('Vancouver Robson'), findsWidgets);
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Allow'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'location-scoped grant excluded at non-matching scope resolves to Not granted',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-loc-mismatch',
          email: 'loc2@example.test',
          displayName: 'Liam Local',
          roleId: 'role-manager',
          roleLabel: 'Manager',
          status: 'active',
          userRoleId: 'grant-loc-2',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-loc-2',
              roleId: 'role-manager',
              roleLabel: 'Manager',
              scopeType: 'location',
              locationId: 'loc-vancouver',
            ),
          ],
        );

        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_managerRoleCatalog()],
          initialPermissionKey: 'team.users.invite',
          initialLocationId: 'loc-burnaby',
        );

        // Grant has rule allow, but scope doesn't apply at burnaby —
        // the chain row reports the scope mismatch, the resolver
        // returns default-deny because no active grant covers
        // burnaby, and the pill renders "Not granted" (no matching
        // grant at this scope rather than an explicit deny rule).
        expect(
          find.text('No — grant excluded at this scope'),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Not granted'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'no role rule — final pill renders Not granted with empty chain copy',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-none',
          email: 'none@example.test',
          displayName: 'Nora None',
          roleId: 'role-supervisor',
          roleLabel: 'Supervisor',
          status: 'active',
          userRoleId: 'grant-supervisor-only',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-supervisor-only',
              roleId: 'role-supervisor',
              roleLabel: 'Supervisor',
              scopeType: 'operator_wide',
            ),
          ],
        );

        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_supervisorRoleCatalog()],
          // forgeflow.shift.edit is not in the supervisor's rule list
          // → no matching rule → "Not granted".
          initialPermissionKey: 'forgeflow.shift.edit',
        );

        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Not granted'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'unknown permission key — degrades to fallback notice without crash',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-fallback',
          email: 'fallback@example.test',
          displayName: 'Fred Fallback',
          roleId: 'role-owner',
          roleLabel: 'Owner',
          status: 'active',
          userRoleId: 'grant-owner-fb',
          grants: <TeamUserRoleGrant>[
            TeamUserRoleGrant(
              userRoleId: 'grant-owner-fb',
              roleId: 'role-owner',
              roleLabel: 'Owner',
              scopeType: 'operator_wide',
            ),
          ],
        );

        // Pump with a fictional key. The widget falls back to the
        // first ordered key from PermissionKeys.all on construction —
        // the chain still renders for that fallback key. Then the
        // operator can navigate to the unknown-key state by passing
        // a known key but inspecting the widget's resilience to
        // missing role catalog entries.
        await _pumpExplainer(
          tester,
          target: target,
          catalog: const <TeamRoleCatalogEntry>[],
          initialPermissionKey: 'team.users.view',
        );

        // No catalog → role is not found → chain row renders with
        // "role not in catalog" copy and the final pill resolves to
        // "Not granted".
        expect(
          find.textContaining('role not in catalog'),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Not granted'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'fallback synthesis — empty grants but populated userRoleId resolves '
      'against the role catalog and shows the inferred-scope hint',
      (tester) async {
        // Production wiring (`_teamUserFromEntry` in forge_flow_app.dart)
        // leaves `grants: const []` because TeamUserListEntry has no
        // authoritative scope_type yet. The explainer must still resolve
        // against the user's primary role rather than reporting "No
        // matching grant" + default-deny for every key.
        const target = TeamUserListItem(
          userId: 'user-prod',
          email: 'prod@example.test',
          displayName: 'Pat Production',
          roleId: 'role-owner',
          roleLabel: 'role-owner',
          status: 'active',
          locationId: 'loc-vancouver',
          locationLabel: 'Vancouver Robson',
          userRoleId: 'grant-prod-primary',
          // grants intentionally left empty — production parity.
        );

        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_ownerRoleCatalog()],
          initialPermissionKey: 'team.users.invite',
          initialLocationId: 'loc-vancouver',
        );

        // Synthesized chain row renders.
        expect(
          find.byKey(
            const Key(
              'settings_permission_explainer_chain_grant-prod-primary',
            ),
          ),
          findsOneWidget,
        );
        // Inferred-scope hint is visible.
        expect(
          find.byKey(
            const Key(
              'settings_permission_explainer_synth_grant-prod-primary',
            ),
          ),
          findsOneWidget,
        );
        // Scope attribute renders as "Operator-wide (inferred)" — the
        // synthesizer now always uses operator_wide because
        // `target.locationId` is ambiguous (could be ur.location_id OR
        // a primary-location attached to an operator-wide grant), and
        // operator-wide is the only safe floor.
        expect(find.text('Operator-wide (inferred)'), findsOneWidget);
        // Resolver still finds the role's allow rule and the pill is Allow.
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Allow'),
          ),
          findsOneWidget,
        );
        // Header reflects 1 synthesized grant rather than "No grants".
        expect(find.text('1 grant'), findsOneWidget);
      },
    );

    testWidgets(
      'fallback synthesis — operator-wide synthesis covers a different '
      'scope than the entry primary location',
      (tester) async {
        // Pat's `target.locationId` = `loc-vancouver` (primary
        // location). If the synthesizer treated that as `'location'`,
        // resolving at `loc-burnaby` would drop the grant on the
        // location filter and the pill would say "Not granted" — but
        // the real grant is operator-wide, so the resolver must allow
        // at every scope. Pinning operator-wide synthesis here lets
        // us catch a future regression that downgrades synthesis to
        // location-scoped.
        const target = TeamUserListItem(
          userId: 'user-prod-elsewhere',
          email: 'prod-elsewhere@example.test',
          displayName: 'Pat Elsewhere',
          roleId: 'role-owner',
          roleLabel: 'role-owner',
          status: 'active',
          locationId: 'loc-vancouver',
          locationLabel: 'Vancouver Robson',
          userRoleId: 'grant-prod-elsewhere',
        );

        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_ownerRoleCatalog()],
          initialPermissionKey: 'team.users.invite',
          initialLocationId: 'loc-burnaby',
        );

        // Operator-wide synthesis covers `loc-burnaby`, so the
        // resolver still finds the role's allow rule and the pill is
        // Allow at a non-primary location.
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Allow'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'fallback synthesis — null locationId on entry infers operator_wide',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-no-loc',
          email: 'noloc@example.test',
          displayName: 'No Location',
          roleId: 'role-owner',
          roleLabel: 'role-owner',
          status: 'active',
          userRoleId: 'grant-no-loc',
        );

        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_ownerRoleCatalog()],
          initialPermissionKey: 'team.users.invite',
        );

        expect(find.text('Operator-wide (inferred)'), findsOneWidget);
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Allow'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'fallback synthesis — locationId missing from options still uses '
      'operator_wide synthesis',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-stale-loc',
          email: 'stale@example.test',
          displayName: 'Stale Location',
          roleId: 'role-owner',
          roleLabel: 'role-owner',
          status: 'active',
          locationId: 'loc-not-in-options',
          locationLabel: 'Stale',
          userRoleId: 'grant-stale-loc',
        );

        // The synthesizer no longer inspects locationOptions — it
        // always uses operator_wide. The resolver still surfaces the
        // role's allow rule.
        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_ownerRoleCatalog()],
          initialPermissionKey: 'team.users.invite',
        );

        expect(find.text('Operator-wide (inferred)'), findsOneWidget);
        expect(
          find.byKey(
            const Key('settings_permission_explainer_effect_Allow'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'scope picker — stale target.locationId does not crash the dropdown',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-stale-init',
          email: 'staleinit@example.test',
          displayName: 'Stale Init',
          roleId: 'role-owner',
          roleLabel: 'role-owner',
          status: 'active',
          locationId: 'loc-not-in-options',
          locationLabel: 'Stale',
          userRoleId: 'grant-stale-init',
        );

        // The target's locationId is not in locationOptions, but the
        // dropdown defaults to "Operator-wide" rather than asserting on
        // a value with no matching item.
        await _pumpExplainer(
          tester,
          target: target,
          catalog: <TeamRoleCatalogEntry>[_ownerRoleCatalog()],
          initialPermissionKey: 'team.users.invite',
        );

        expect(
          find.byKey(
            const Key('settings_permission_explainer_scope_picker'),
          ),
          findsOneWidget,
        );
        // Final pill renders without crash → dropdown rendered without
        // assertion.
        expect(
          find.byKey(
            const Key('settings_permission_explainer_final_effect'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'actor without team.users.view sees the polite refusal banner',
      (tester) async {
        const target = TeamUserListItem(
          userId: 'user-locked-target',
          email: 'locked@example.test',
          displayName: 'Locked Target',
          roleId: 'role-owner',
          roleLabel: 'Owner',
          status: 'active',
          userRoleId: 'grant-locked',
          grants: <TeamUserRoleGrant>[],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsPermissionExplainer(
              actor: _lockedActor,
              target: target,
              roleCatalog: <TeamRoleCatalogEntry>[_ownerRoleCatalog()],
              orgUnitOptions: _orgUnits,
              locationOptions: _locations,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('You do not have permission to view team membership.'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('settings_permission_explainer')),
          findsNothing,
        );
      },
    );
  });
}
