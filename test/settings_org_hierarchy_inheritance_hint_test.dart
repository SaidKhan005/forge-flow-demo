// 9.UX.4 audit — inheritance-hint render in `SettingsOrgHierarchySection`.
//
// The Phase 9 hierarchy migration's `user_effective_locations` cache
// records `source_org_unit_id` so the UI can tell the operator which
// org unit a particular grant inherits from. The audit covers the
// rendering side of that contract: when a non-null source org unit
// is presented to the section's "Add child unit" dialog (the surface
// where the parent unit IS the source of inheritance for the new
// child), the dialog must render the parent's display name so the
// operator can see at a glance which unit they are nesting under.
//
// CLAUDE.md guardrails preserved:
//   * No new permission keys. The dialog is gated on
//     `team.roles.assign` upstream; this test pumps the actor with
//     that key as a precondition for the dialog opening at all.
//   * No `package:postgres` imports. This is a widget-only test.
//   * Lane scope: only `settings_org_hierarchy_section.dart` is read,
//     the role-change dialog in `team_settings_section.dart` is not
//     touched here per Block 2 hard constraints.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings/settings_org_hierarchy_section.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';

const TeamScopeActor _assignActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{
    'team.users.view',
    'team.roles.assign',
  },
);

const TeamOrgUnitEntry _root = TeamOrgUnitEntry(
  orgUnitId: 'unit-root',
  parentOrgUnitId: null,
  unitType: 'corp',
  path: 'acme',
  label: 'ACME',
);

const TeamOrgUnitEntry _eastRegion = TeamOrgUnitEntry(
  orgUnitId: 'unit-east',
  parentOrgUnitId: 'unit-root',
  unitType: 'region',
  path: 'acme.east',
  label: 'East Region',
);

void main() {
  testWidgets(
    'Add-child dialog renders the parent unit name when the parent '
    'corresponds to a non-null source org unit',
    (tester) async {
      // The parent passed into `_AddChildOrgUnitDialog` IS the source
      // org unit for any grant inherited by the new child — the
      // analog of `user_effective_locations.source_org_unit_id` at
      // the rendering layer the section owns.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsOrgHierarchySection(
              actor: _assignActor,
              orgUnits: const <TeamOrgUnitEntry>[_root, _eastRegion],
              locations: const <TeamOrgLocationEntry>[],
              onCreateOrgUnit: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open the add-child dialog under the East Region — the
      // non-trivial parent that the test asserts renders by name.
      await tester.tap(
        find.byKey(const Key('org_unit_add_child_unit-east')),
      );
      await tester.pumpAndSettle();

      // The dialog body must render the parent's display name so the
      // operator sees which unit they are nesting under. The "Under "
      // prefix is part of the existing inheritance-hint copy and is
      // asserted alongside the name to pin the render path (not just
      // any stray label that happens to match).
      expect(find.text('Under East Region'), findsOneWidget);
    },
  );

  testWidgets(
    'Add-child dialog still renders the parent unit name when the '
    'parent is the operator root (corp-level source unit)',
    (tester) async {
      // Sanity case: a root-level parent is still a valid source org
      // unit, so the same render contract holds. Guards against a
      // regression that conditionally skips the prefix when the
      // parent has a null `parentOrgUnitId`.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsOrgHierarchySection(
              actor: _assignActor,
              orgUnits: const <TeamOrgUnitEntry>[_root],
              locations: const <TeamOrgLocationEntry>[],
              onCreateOrgUnit: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('org_unit_add_child_unit-root')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Under ACME'), findsOneWidget);
    },
  );
}
