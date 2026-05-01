// Phase 9.UX.grant-payload — verify the gateway-side
// `TeamUserListEntry.grants` flow into the section-side
// `TeamUserListItem.grants` via the production path.
//
// `_teamUserFromEntry` is a thin wrapper around the public
// `teamUserListItemFromEntry` mapper; this test pins the mapping so the
// section's role-change dialog receives authoritative grant data
// without any demo override.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/screens/team/team_settings_section.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';

void main() {
  group('teamUserListItemFromEntry (Phase 9.UX.grant-payload)', () {
    test(
      'multi-grant entry projects all three scope branches with the '
      'authoritative payload',
      () {
        const entry = TeamUserListEntry(
          userId: 'user-multi',
          email: 'multi@example.test',
          displayName: 'Multi Grant',
          roleId: 'role-owner',
          roleLabel: 'Owner',
          status: 'active',
          locationId: 'loc-vancouver',
          locationLabel: 'Vancouver Robson',
          mfaEnrolled: true,
          userRoleId: 'grant-op-wide',
          grants: <TeamGrantSnapshot>[
            TeamGrantSnapshot(
              userRoleId: 'grant-op-wide',
              roleId: 'role-owner',
              roleLabel: 'Owner',
              scopeType: 'operator_wide',
            ),
            TeamGrantSnapshot(
              userRoleId: 'grant-org-east',
              roleId: 'role-manager',
              roleLabel: 'Manager',
              scopeType: 'org_unit',
              orgUnitId: 'unit-east',
              sourceOrgUnitId: 'unit-east',
              effectiveLocationIds: <String>[
                'loc-vancouver',
                'loc-burnaby',
                'loc-richmond',
              ],
            ),
            TeamGrantSnapshot(
              userRoleId: 'grant-loc-1',
              roleId: 'role-supervisor',
              roleLabel: 'Supervisor',
              scopeType: 'location',
              locationId: 'loc-vancouver',
              effectiveLocationIds: <String>['loc-vancouver'],
            ),
          ],
        );

        // Empty roleOptions on purpose — the gateway-supplied label
        // makes the section's role-catalog load order irrelevant.
        final item = teamUserListItemFromEntry(entry);

        expect(item.grants, hasLength(3));
        final byScope = <String, TeamUserRoleGrant>{
          for (final grant in item.grants) grant.scopeType: grant,
        };
        expect(byScope.keys.toSet(), <String>{
          'operator_wide',
          'org_unit',
          'location',
        });
        expect(byScope['operator_wide']!.userRoleId, equals('grant-op-wide'));
        expect(byScope['operator_wide']!.roleLabel, equals('Owner'));
        expect(byScope['org_unit']!.orgUnitId, equals('unit-east'));
        expect(byScope['org_unit']!.roleLabel, equals('Manager'));
        expect(
          byScope['org_unit']!.effectiveLocationIds,
          equals(<String>['loc-vancouver', 'loc-burnaby', 'loc-richmond']),
        );
        expect(byScope['location']!.locationId, equals('loc-vancouver'));
        expect(byScope['location']!.roleLabel, equals('Supervisor'));
        // Backward-compat fields preserved.
        expect(item.userId, equals('user-multi'));
        expect(item.locationId, equals('loc-vancouver'));
        expect(item.locationLabel, equals('Vancouver Robson'));
      },
    );

    test('zero-grant entry yields zero grants on the resulting item', () {
      const entry = TeamUserListEntry(
        userId: 'user-zero',
        email: 'zero@example.test',
        displayName: 'Zero Grants',
        roleId: 'role-staff',
        roleLabel: 'Staff',
        status: 'active',
      );

      final item = teamUserListItemFromEntry(entry);

      expect(item.grants, isEmpty);
      expect(item.userId, equals('user-zero'));
      expect(item.roleLabel, equals('Staff'));
    });

    test(
      'unknown role-id fallback uses the gateway roleId when no label '
      'is supplied and the role catalog is empty',
      () {
        const entry = TeamUserListEntry(
          userId: 'user-fallback',
          email: 'fallback@example.test',
          displayName: 'Fallback',
          roleId: 'role-primary',
          roleLabel: 'Primary',
          status: 'active',
          grants: <TeamGrantSnapshot>[
            TeamGrantSnapshot(
              userRoleId: 'grant-orphan',
              roleId: 'role-not-in-options',
              // roleLabel intentionally null — emulates an older proxy
              // payload before the additive label rolled out.
              scopeType: 'operator_wide',
            ),
          ],
        );

        final item = teamUserListItemFromEntry(entry);

        // Falls back to the raw roleId so the dialog renders something
        // deterministic even when both gateway and role catalog miss.
        expect(item.grants.single.roleLabel, equals('role-not-in-options'));
      },
    );

    test(
      'role-label race: gateway-supplied label wins even when the '
      'role-catalog is empty (no UUID freeze)',
      () {
        // Reproduces the race the reviewer flagged: Settings starts
        // role loading and user loading concurrently. If listUsers
        // returns first, `roleOptions` is the empty catalog at the
        // moment `_teamUserFromEntry` runs. With the gateway-side
        // label travelling on each grant, the dialog never falls back
        // to a raw UUID.
        const entry = TeamUserListEntry(
          userId: 'user-race',
          email: 'race@example.test',
          displayName: 'Race Condition',
          roleId: 'a1111111-1111-4111-8111-111111111111',
          roleLabel: 'Owner',
          status: 'active',
          grants: <TeamGrantSnapshot>[
            TeamGrantSnapshot(
              userRoleId: 'grant-secondary',
              roleId: 'b2222222-2222-4222-8222-222222222222',
              roleLabel: 'Manager',
              scopeType: 'org_unit',
              orgUnitId: 'unit-east',
            ),
          ],
        );

        // Empty roleOptions emulates the moment the user list arrives
        // before the role catalog has loaded.
        final item = teamUserListItemFromEntry(
          entry,
          roleOptions: const <TeamRoleOption>[],
        );

        expect(item.grants.single.roleLabel, equals('Manager'));
        expect(
          item.grants.single.roleLabel,
          isNot(equals('b2222222-2222-4222-8222-222222222222')),
        );
      },
    );

    test(
      'gateway-supplied label takes precedence over a stale roleOptions '
      'entry (gateway is the source of truth)',
      () {
        // If the gateway emits a fresh label that disagrees with the
        // local catalog snapshot (e.g., admin renamed the role mid-
        // session), the dialog renders the live name.
        const entry = TeamUserListEntry(
          userId: 'user-renamed',
          email: 'renamed@example.test',
          displayName: 'Renamed Role',
          roleId: 'role-primary',
          roleLabel: 'Primary',
          status: 'active',
          grants: <TeamGrantSnapshot>[
            TeamGrantSnapshot(
              userRoleId: 'grant-fresh',
              roleId: 'role-secondary',
              roleLabel: 'Fresh Label',
              scopeType: 'operator_wide',
            ),
          ],
        );

        final item = teamUserListItemFromEntry(
          entry,
          roleOptions: const <TeamRoleOption>[
            TeamRoleOption(roleId: 'role-secondary', label: 'Stale Label'),
          ],
        );

        expect(item.grants.single.roleLabel, equals('Fresh Label'));
      },
    );
  });
}
