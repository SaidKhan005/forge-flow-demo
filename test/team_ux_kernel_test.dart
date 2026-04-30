// Phase 9.10 - Team UX kernel tests.
//
// Covers:
//   * TeamScopeVisibilityPolicy.canSeeTeamNav for every actor tier:
//     super_admin / ff_support always see (admin tier);
//     operator_owner sees with team.users.view;
//     operator_manager sees only when assigned at least one location;
//     operator_supervisor + operator_staff never see.
//   * canViewTarget: cross-tenant refused; admin tier overrides;
//     operator_owner sees own operator everywhere; operator_manager
//     sees own location only.
//   * canMutateTarget layers required-permission-key on top of view.
//   * TeamUsersListController state + filter + pagination behavior.
//   * TeamInviteFormController validation matrix
//     (email / role / scope / location / cross-state guards).
//   * TeamSettingsEntrypoint widget renders child when policy allows
//     and hides it (zero-size) otherwise.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/team/team_settings_entrypoint.dart';
import 'package:forge_and_flow/screens/team/team_settings_section.dart';
import 'package:forge_and_flow/services/team/team_invite_form_controller.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';
import 'package:forge_and_flow/services/team/team_users_list_controller.dart';

void main() {
  group('TeamScopeVisibilityPolicy.canSeeTeamNav', () {
    test('super_admin always sees nav (admin-tier override)', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'super_admin'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{'team.users.view'},
      );
      expect(TeamScopeVisibilityPolicy.canSeeTeamNav(actor), isTrue);
    });

    test('ff_support always sees nav (admin-tier override)', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'ff_support'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{'team.users.view'},
      );
      expect(TeamScopeVisibilityPolicy.canSeeTeamNav(actor), isTrue);
    });

    test('operator_owner sees nav with team.users.view', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'operator_owner'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{'team.users.view'},
      );
      expect(TeamScopeVisibilityPolicy.canSeeTeamNav(actor), isTrue);
    });

    test('operator_owner WITHOUT team.users.view does NOT see nav', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'operator_owner'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{},
      );
      expect(TeamScopeVisibilityPolicy.canSeeTeamNav(actor), isFalse);
    });

    test(
      'operator_manager sees nav only when assigned at least one location',
      () {
        const noLocations = TeamScopeActor(
          actorRoles: <String>{'operator_manager'},
          actorOperatorId: 'op-1',
          actorAssignedLocationIds: <String>{},
          actorPermissions: <String>{'team.users.view'},
        );
        expect(TeamScopeVisibilityPolicy.canSeeTeamNav(noLocations), isFalse);

        const withLocations = TeamScopeActor(
          actorRoles: <String>{'operator_manager'},
          actorOperatorId: 'op-1',
          actorAssignedLocationIds: <String>{'loc-a'},
          actorPermissions: <String>{'team.users.view'},
        );
        expect(TeamScopeVisibilityPolicy.canSeeTeamNav(withLocations), isTrue);
      },
    );

    test('operator_supervisor never sees nav', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'operator_supervisor'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{'loc-a'},
        actorPermissions: <String>{'team.users.view'},
      );
      expect(TeamScopeVisibilityPolicy.canSeeTeamNav(actor), isFalse);
    });

    test('operator_staff never sees nav', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'operator_staff'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{'loc-a'},
        actorPermissions: <String>{'team.users.view'},
      );
      expect(TeamScopeVisibilityPolicy.canSeeTeamNav(actor), isFalse);
    });
  });

  group('TeamScopeVisibilityPolicy.canViewTarget', () {
    test('cross-tenant view refused for non-admin actors', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'operator_owner'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{'team.users.view'},
      );
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actor,
          target: const TeamScopeTarget(targetOperatorId: 'op-OTHER'),
        ),
        isFalse,
      );
    });

    test('cross-tenant view ALLOWED for super_admin', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'super_admin'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{'team.users.view'},
      );
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actor,
          target: const TeamScopeTarget(targetOperatorId: 'op-OTHER'),
        ),
        isTrue,
      );
    });

    test('operator_owner sees both location-scoped and operator-wide '
        'targets in own operator', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'operator_owner'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{'team.users.view'},
      );
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actor,
          target: const TeamScopeTarget(targetOperatorId: 'op-1'),
        ),
        isTrue,
      );
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actor,
          target: const TeamScopeTarget(
            targetOperatorId: 'op-1',
            targetLocationId: 'loc-anywhere',
          ),
        ),
        isTrue,
      );
    });

    test('operator_manager sees ONLY assigned-location targets', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'operator_manager'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{'loc-a'},
        actorPermissions: <String>{'team.users.view'},
      );
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actor,
          target: const TeamScopeTarget(
            targetOperatorId: 'op-1',
            targetLocationId: 'loc-a',
          ),
        ),
        isTrue,
      );
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actor,
          target: const TeamScopeTarget(
            targetOperatorId: 'op-1',
            targetLocationId: 'loc-b',
          ),
        ),
        isFalse,
      );
      // Operator-wide target (location_id null) refused for manager.
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actor,
          target: const TeamScopeTarget(targetOperatorId: 'op-1'),
        ),
        isFalse,
      );
    });
  });

  group('TeamScopeVisibilityPolicy.canMutateTarget', () {
    test('requires the named permission key in addition to view scope', () {
      const actor = TeamScopeActor(
        actorRoles: <String>{'operator_owner'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{'team.users.view'}, // no invite key
      );
      expect(
        TeamScopeVisibilityPolicy.canMutateTarget(
          actor: actor,
          target: const TeamScopeTarget(targetOperatorId: 'op-1'),
          requiredPermissionKey: 'team.users.invite',
        ),
        isFalse,
      );
      const withInvite = TeamScopeActor(
        actorRoles: <String>{'operator_owner'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{'team.users.view', 'team.users.invite'},
      );
      expect(
        TeamScopeVisibilityPolicy.canMutateTarget(
          actor: withInvite,
          target: const TeamScopeTarget(targetOperatorId: 'op-1'),
          requiredPermissionKey: 'team.users.invite',
        ),
        isTrue,
      );
    });
  });

  group('TeamUsersListController', () {
    test('starts with empty filter + page 0', () {
      final controller = TeamUsersListController();
      expect(controller.filter.hasAnyFilter, isFalse);
      expect(controller.pageIndex, equals(0));
      expect(
        controller.pageSize,
        equals(TeamUsersListController.defaultPageSize),
      );
    });

    test('setStatus updates filter + resets page + notifies', () {
      final controller = TeamUsersListController();
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.nextPage();
      controller.nextPage(); // page = 2
      expect(controller.pageIndex, equals(2));

      controller.setStatus('suspended');

      expect(controller.filter.statusFilter, equals('suspended'));
      expect(controller.pageIndex, equals(0));
      expect(notifications, greaterThanOrEqualTo(3));
    });

    test('clearFilter resets every filter + page', () {
      final controller = TeamUsersListController(
        initialFilter: const TeamUsersFilter(
          statusFilter: 'active',
          searchQuery: 'foo',
        ),
      );
      controller.nextPage();
      controller.clearFilter();
      expect(controller.filter.hasAnyFilter, isFalse);
      expect(controller.pageIndex, equals(0));
    });

    test(
      'toQueryParameters omits null filters but includes the present ones',
      () {
        const filter = TeamUsersFilter(
          statusFilter: 'active',
          roleFilter: null,
          locationFilter: 'loc-a',
          mfaEnrolledFilter: true,
          searchQuery: 'jane',
        );
        final params = filter.toQueryParameters();
        expect(params['status'], equals('active'));
        expect(params.containsKey('role_key'), isFalse);
        expect(params['location_id'], equals('loc-a'));
        expect(params['mfa_enrolled'], isTrue);
        expect(params['q'], equals('jane'));
      },
    );

    test('setPageSize rejects non-positive', () {
      final controller = TeamUsersListController();
      expect(() => controller.setPageSize(0), throwsArgumentError);
      expect(() => controller.setPageSize(-5), throwsArgumentError);
    });
  });

  group('TeamInviteFormController', () {
    test('blank form fails with email + role + scope violations', () {
      final controller = TeamInviteFormController();
      final v = controller.validate();
      expect(v, contains(TeamInviteViolation.emailMissing));
      expect(v, contains(TeamInviteViolation.roleMissing));
      expect(v, contains(TeamInviteViolation.scopeMissing));
    });

    test('malformed email surfaces emailMalformed', () {
      final controller = TeamInviteFormController()
        ..setEmail('not-an-email')
        ..setRoleId('role-1')
        ..setScope(TeamInviteScope.operatorWide);
      final v = controller.validate();
      expect(v, contains(TeamInviteViolation.emailMalformed));
    });

    test('location scope requires a location_id', () {
      final controller = TeamInviteFormController()
        ..setEmail('a@b.c')
        ..setRoleId('role-1')
        ..setScope(TeamInviteScope.location);
      final v = controller.validate();
      expect(v, contains(TeamInviteViolation.locationMissingForLocationScope));
    });

    test('operator-wide scope refuses a location_id', () {
      final controller = TeamInviteFormController()
        ..setEmail('a@b.c')
        ..setRoleId('role-1')
        ..setScope(TeamInviteScope.location)
        ..setLocationId('loc-a')
        ..setScope(TeamInviteScope.operatorWide);
      // setScope(operatorWide) clears the locationId — so the form
      // is now valid.
      expect(controller.locationId, isNull);
      expect(controller.validate(), isEmpty);
    });

    test('toRequestPayload returns the payload when validate passes', () {
      final controller = TeamInviteFormController()
        ..setEmail('  jane@example.test  ')
        ..setRoleId('role-1')
        ..setScope(TeamInviteScope.location)
        ..setLocationId('loc-a');
      expect(controller.isReadyToSubmit, isTrue);
      final payload = controller.toRequestPayload();
      expect(payload['email'], equals('jane@example.test'));
      expect(payload['role_id'], equals('role-1'));
      expect(payload['scope_type'], equals('location'));
      expect(payload['location_id'], equals('loc-a'));
    });

    test('toRequestPayload throws when not ready', () {
      final controller = TeamInviteFormController();
      expect(controller.toRequestPayload, throwsStateError);
    });

    test('org-unit scope requires an org_unit_id', () {
      final controller = TeamInviteFormController()
        ..setEmail('a@b.c')
        ..setRoleId('role-1')
        ..setScope(TeamInviteScope.orgUnit);
      final v = controller.validate();
      expect(v, contains(TeamInviteViolation.orgUnitMissingForOrgUnitScope));
    });

    test(
      'org-unit scope payload omits location_id when ready',
      () {
        final controller = TeamInviteFormController()
          ..setEmail('jane@example.test')
          ..setRoleId('role-1')
          ..setScope(TeamInviteScope.orgUnit)
          ..setOrgUnitId('unit-1');
        expect(controller.isReadyToSubmit, isTrue);
        final payload = controller.toRequestPayload();
        expect(payload['scope_type'], equals('org_unit'));
        expect(payload['org_unit_id'], equals('unit-1'));
        expect(payload.containsKey('location_id'), isFalse);
      },
    );

    test('switching from org-unit to operator-wide clears the org unit id', () {
      final controller = TeamInviteFormController()
        ..setEmail('jane@example.test')
        ..setRoleId('role-1')
        ..setScope(TeamInviteScope.orgUnit)
        ..setOrgUnitId('unit-1')
        ..setScope(TeamInviteScope.operatorWide);
      expect(controller.orgUnitId, isNull);
      expect(controller.validate(), isEmpty);
    });
  });

  group('TeamSettingsEntrypoint widget', () {
    testWidgets('renders child when policy allows', (tester) async {
      const actor = TeamScopeActor(
        actorRoles: <String>{'operator_owner'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{'team.users.view'},
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: TeamSettingsEntrypoint(
            actor: actor,
            child: Text('team-nav-shown'),
          ),
        ),
      );
      expect(find.text('team-nav-shown'), findsOneWidget);
    });

    testWidgets('renders zero-size widget when policy denies', (tester) async {
      const actor = TeamScopeActor(
        actorRoles: <String>{'operator_staff'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{},
        actorPermissions: <String>{'team.users.view'},
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: TeamSettingsEntrypoint(
            actor: actor,
            child: Text('team-nav-shown'),
          ),
        ),
      );
      expect(find.text('team-nav-shown'), findsNothing);
    });
  });

  group('TeamSettingsSection widget', () {
    testWidgets('renders users and filters the list from the search field', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeamSettingsSection(
              actor: _ownerActor,
              users: _teamUsers,
              locationOptions: _teamLocations,
            ),
          ),
        ),
      );

      expect(find.text('Jane Owner'), findsOneWidget);
      expect(find.text('Sam Manager'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('team_search_field')), 'sam');
      await tester.pump();

      expect(find.text('Jane Owner'), findsNothing);
      expect(find.text('Sam Manager'), findsOneWidget);
    });

    testWidgets('team dropdown state does not poison nested text scrolling', (
      tester,
    ) async {
      final bucket = PageStorageBucket();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageStorage(
              bucket: bucket,
              child: TeamSettingsSection(
                actor: _fullTeamActor,
                users: _teamUsers,
                locationOptions: _teamLocations,
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('team_search_field')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.enterText(find.byKey(const Key('team_search_field')), 'sam');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Sam Manager'), findsOneWidget);
    });

    testWidgets('submits invite payload when the form is valid', (
      tester,
    ) async {
      final inviteController = TeamInviteFormController()
        ..setEmail('new.user@example.test')
        ..setRoleId('operator_staff')
        ..setScope(TeamInviteScope.operatorWide);
      Map<String, Object?>? submitted;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeamSettingsSection(
              actor: _ownerActor,
              inviteFormController: inviteController,
              locationOptions: _teamLocations,
              onInviteSubmitted: (payload) async {
                submitted = payload;
                return null;
              },
            ),
          ),
        ),
      );

      await tester.ensureVisible(
        find.byKey(const Key('team_invite_submit_button')),
      );
      await tester.tap(find.byKey(const Key('team_invite_submit_button')));
      await tester.pump();

      expect(submitted, isNotNull);
      expect(submitted!['email'], equals('new.user@example.test'));
      expect(submitted!['role_id'], equals('operator_staff'));
      expect(submitted!['scope_type'], equals('operator_wide'));
      expect(submitted!.containsKey('location_id'), isFalse);
    });

    testWidgets('keeps invite submit disabled without invite permission', (
      tester,
    ) async {
      final inviteController = TeamInviteFormController()
        ..setEmail('new.user@example.test')
        ..setRoleId('operator_staff')
        ..setScope(TeamInviteScope.operatorWide);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeamSettingsSection(
              actor: _viewOnlyActor,
              inviteFormController: inviteController,
              onInviteSubmitted: (_) async => null,
            ),
          ),
        ),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const Key('team_invite_submit_button')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('runs reset password from the user action menu', (
      tester,
    ) async {
      TeamUserActionRequest? request;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeamSettingsSection(
              actor: _fullTeamActor,
              users: _teamUsers,
              locationOptions: _teamLocations,
              onUserAction: (next) async => request = next,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('team_user_actions_user-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset password'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send').last);
      await tester.pumpAndSettle();

      expect(request, isNotNull);
      expect(request!.action, TeamUserAction.resetPassword);
      expect(request!.user.userId, 'user-1');
    });

    testWidgets('runs remove 2FA from an enrolled user action menu', (
      tester,
    ) async {
      TeamUserActionRequest? request;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeamSettingsSection(
              actor: _fullTeamActor,
              users: _teamUsers,
              locationOptions: _teamLocations,
              onUserAction: (next) async => request = next,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('team_user_actions_user-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove/reset 2FA'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('It will be removed in 24 hours'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Start removal').last);
      await tester.pumpAndSettle();

      expect(request, isNotNull);
      expect(request!.action, TeamUserAction.resetMfa);
      expect(request!.user.userId, 'user-1');
      expect(
        find.byTooltip('2FA removal pending (24h window)'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('team_user_actions_user-1')));
      await tester.pumpAndSettle();
      expect(find.text('Remove/reset 2FA'), findsNothing);
    });

    testWidgets('runs cancel 2FA removal from a pending user action menu', (
      tester,
    ) async {
      TeamUserActionRequest? request;
      const pendingUsers = <TeamUserListItem>[
        TeamUserListItem(
          userId: 'user-1',
          email: 'jane@example.test',
          displayName: 'Jane Owner',
          roleId: 'operator_owner',
          roleLabel: 'Owner',
          status: 'active',
          mfaEnrolled: true,
          mfaRemovalPending: true,
          mfaRemovalRequestId: 'removal-request-1',
          userRoleId: 'grant-1',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeamSettingsSection(
              actor: _fullTeamActor,
              users: pendingUsers,
              locationOptions: _teamLocations,
              onUserAction: (next) async => request = next,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('team_user_actions_user-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel 2FA removal'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Cancel removal').last,
      );
      await tester.pumpAndSettle();

      expect(request, isNotNull);
      expect(request!.action, TeamUserAction.cancelMfaRemoval);
      expect(request!.user.mfaRemovalRequestId, equals('removal-request-1'));
      expect(find.byTooltip('2FA removal pending (24h window)'), findsNothing);
    });

    testWidgets('shows remove/reset 2FA even when the row MFA flag is stale', (
      tester,
    ) async {
      TeamUserActionRequest? request;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeamSettingsSection(
              actor: _fullTeamActor,
              users: _teamUsers,
              locationOptions: _teamLocations,
              onUserAction: (next) async => request = next,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('team_user_actions_user-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove/reset 2FA'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Start removal').last);
      await tester.pumpAndSettle();

      expect(request, isNotNull);
      expect(request!.action, TeamUserAction.resetMfa);
      expect(request!.user.userId, 'user-2');
    });

    testWidgets('opens role change dialog from the user action menu', (
      tester,
    ) async {
      TeamUserActionRequest? request;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeamSettingsSection(
              actor: _fullTeamActor,
              users: _teamUsers,
              locationOptions: _teamLocations,
              onUserAction: (next) async => request = next,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('team_user_actions_user-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change role'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('team_role_change_submit_button')));
      await tester.pumpAndSettle();

      expect(request, isNotNull);
      expect(request!.action, TeamUserAction.createRoleGrant);
      expect(request!.user.userId, 'user-2');
      expect(request!.replaceUserRoleId, 'grant-2');
    });

    testWidgets(
      'pending org-unit invite renders an org-unit scope pill',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TeamSettingsSection(
                actor: _fullTeamActor,
                pendingInvites: <TeamPendingInviteListItem>[
                  TeamPendingInviteListItem(
                    inviteId: 'invite-org-1',
                    email: 'regional@example.test',
                    roleId: 'operator_manager',
                    roleLabel: 'Manager',
                    scopeType: 'org_unit',
                    orgUnitId: 'unit-east',
                    orgUnitLabel: 'East Region',
                    expiresAt: DateTime.utc(2026, 5, 6),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The org-unit pill text identifies the scope context that
        // location-only renderers used to silently drop.
        expect(
          find.text('Org unit · East Region', skipOffstage: false),
          findsOneWidget,
        );
      },
    );

    testWidgets('revokes pending invite from the invite lane', (tester) async {
      String? revokedInviteId;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeamSettingsSection(
              actor: _fullTeamActor,
              pendingInvites: <TeamPendingInviteListItem>[
                TeamPendingInviteListItem(
                  inviteId: 'invite-1',
                  email: 'new.user@example.test',
                  roleId: 'operator_staff',
                  roleLabel: 'Staff',
                  scopeType: 'operator_wide',
                  expiresAt: DateTime.utc(2026, 5, 6),
                ),
              ],
              onInviteRevoked: (inviteId) async {
                revokedInviteId = inviteId;
              },
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('team_invite_revoke_invite-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();

      expect(revokedInviteId, 'invite-1');
    });
  });
}

const TeamScopeActor _ownerActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{'team.users.view', 'team.users.invite'},
);

const TeamScopeActor _viewOnlyActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{'team.users.view'},
);

const TeamScopeActor _fullTeamActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{
    'team.users.view',
    'team.users.invite',
    'team.users.deactivate',
    'team.users.reactivate',
    'team.users.soft_delete',
    'team.users.reset_password',
    'team.users.reset_mfa',
    'team.roles.assign',
    'team.roles.revoke',
  },
);

const List<TeamLocationOption> _teamLocations = <TeamLocationOption>[
  TeamLocationOption(locationId: 'loc-a', label: 'Water Street'),
  TeamLocationOption(locationId: 'loc-b', label: 'Harbour Drive'),
];

const List<TeamUserListItem> _teamUsers = <TeamUserListItem>[
  TeamUserListItem(
    userId: 'user-1',
    email: 'jane@example.test',
    displayName: 'Jane Owner',
    roleId: 'operator_owner',
    roleLabel: 'Owner',
    status: 'active',
    mfaEnrolled: true,
    userRoleId: 'grant-1',
  ),
  TeamUserListItem(
    userId: 'user-2',
    email: 'sam@example.test',
    displayName: 'Sam Manager',
    roleId: 'operator_manager',
    roleLabel: 'Manager',
    status: 'active',
    locationId: 'loc-a',
    locationLabel: 'Water Street',
    userRoleId: 'grant-2',
  ),
];
