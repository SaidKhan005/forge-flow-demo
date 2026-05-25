// Phase 11A.12 - Members admin screen widget tests.
//
// Coverage focuses on the parity-contract surface area: the locked
// filter set renders, the search field is usable across multiple
// keystrokes (regression test for the previous TextEditingController
// rebuild bug), the locked validation copy is identical to the
// contract, the admin-only actions appear AFTER picking an operator
// and ONLY on the appropriate row state, view-only mode hides every
// mutate affordance, every write path captures the F&F admin's UID +
// a non-empty admin_reason on the audit row, and the page composes
// without overflow at the typical admin shell viewport (1440x1024)
// per the slice runtime acceptance contract.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/invite_member_admin_dialog.dart';
import 'package:forge_and_flow/admin/screens/members_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/operator_picker_screen.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/members_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

import '../../_test_helpers/widget_pump_helpers.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  OperatorPickerResult demoPick() => const OperatorPickerResult(
    operatorId: kDemoDinerOperatorId,
    locationId: kDemoDinerLocationToronto,
    operatorBusinessName: 'Demo Diner Co.',
    locationName: 'Toronto Yorkville',
  );

  /// Sets a wide viewport for tests that need every filter chip + the
  /// member rows to fit without wrap. Smaller viewports are exercised
  /// by the dedicated overflow regression test below.
  void wideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  group('MembersAdminScreen render + filter chips', () {
    testWidgets('renders members + invites table with locked filters', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      );
      await tester.pumpWidget(
        wrap(
          MembersAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      expect(find.byKey(const Key('admin_members_table')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_members_invites_panel')),
        findsOneWidget,
      );
      // Locked filter chips visible.
      expect(
        find.byKey(const Key('admin_members_filter_status')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_members_filter_role')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_members_filter_location')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_members_filter_mfa')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_members_filter_search')),
        findsOneWidget,
      );
      // Web parity (members_screen.dart `_MembersFilterRail`): plain
      // filter rail with no panel title and "Any *" default labels.
      expect(find.text('People filters'), findsNothing);
      expect(find.text('Any status'), findsOneWidget);
      expect(find.text('Any role'), findsOneWidget);
      expect(find.text('Any location'), findsOneWidget);
      // Two-factor default reads "Any" (web verbatim). It is the lone
      // "Any" selected in the closed two-factor dropdown.
      expect(find.text('Any'), findsOneWidget);
      expect(find.text('Visible members'), findsNothing);

      // Demo Diner has 4 seeded members.
      expect(
        find.byKey(const Key('admin_members_row_demo-user-diner-owner')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('admin_members_row_demo-user-diner-staff-archived'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('filter mfa_enrolled = false narrows to unenrolled rows', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      );
      await tester.pumpWidget(
        wrap(
          MembersAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_members_filter_mfa')));
      await pumpEventually(tester);
      // Web-verbatim two-factor option label is "Off" (members_screen.dart).
      await tester.tap(find.text('Off').last);
      await pumpEventually(tester);

      // Owner has MFA on; everyone else (manager / supervisor / archived)
      // is unenrolled.
      expect(
        find.byKey(const Key('admin_members_row_demo-user-diner-owner')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_members_row_demo-user-diner-manager')),
        findsOneWidget,
      );
    });

    testWidgets(
      'search field accepts multi-character typing without losing focus '
      '(regression for stateless-controller rebuild bug)',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        await tester.pumpWidget(
          wrap(
            MembersAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        // Type a multi-character query character-by-character (the
        // previous bug recreated the controller on every parent
        // setState, collapsing the cursor and scrambling the input).
        const query = 'Mira';
        for (final char in query.split('')) {
          await tester.enterText(
            find.byKey(const Key('admin_members_filter_search')),
            // enterText replaces the whole value, so build it up.
            (tester.widget(find.byKey(const Key('admin_members_filter_search')))
                        as TextField)
                    .controller!
                    .text +
                char,
          );
          await pumpEventually(tester);
        }
        await tester.pump(const Duration(milliseconds: 350));
        await pumpEventually(tester);

        // Final typed value matches and the table is filtered to the
        // single matching row.
        final controller =
            (tester.widget(find.byKey(const Key('admin_members_filter_search')))
                    as TextField)
                .controller!;
        expect(controller.text, equals('Mira'));
        expect(
          find.byKey(const Key('admin_members_row_demo-user-diner-manager')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_members_row_demo-user-diner-owner')),
          findsNothing,
        );
      },
    );

    testWidgets('local filters still narrow when the proxy returns all rows', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = _UnfilteredMembersGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      );
      await tester.pumpWidget(
        wrap(
          MembersAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.enterText(
        find.byKey(const Key('admin_members_filter_search')),
        'Mira',
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_members_row_demo-user-diner-manager')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_members_row_demo-user-diner-owner')),
        findsNothing,
      );
    });

    testWidgets('rapid search typing is debounced into one refresh', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = _CountingMembersGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      );
      await tester.pumpWidget(
        wrap(
          MembersAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      expect(gateway.listMembersCalls, 1);

      await tester.enterText(
        find.byKey(const Key('admin_members_filter_search')),
        'M',
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const Key('admin_members_filter_search')),
        'Mi',
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const Key('admin_members_filter_search')),
        'Mira',
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(gateway.listMembersCalls, 1);

      await tester.pump(const Duration(milliseconds: 350));
      await pumpEventually(tester);

      expect(gateway.listMembersCalls, 2);
      expect(gateway.searches.last, 'Mira');
      expect(
        find.byKey(const Key('admin_members_row_demo-user-diner-manager')),
        findsOneWidget,
      );
    });
  });

  group('admin-only action asymmetry vs operator self-service', () {
    testWidgets(
      'Restore soft-deleted action surfaces ONLY on soft-deleted rows',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        await tester.pumpWidget(
          wrap(
            MembersAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        // The archived row exposes Restore; active rows do NOT.
        expect(
          find.byKey(
            const Key(
              'admin_members_action_restore_demo-user-diner-staff-archived',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('admin_members_action_restore_demo-user-diner-owner'),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Override role grant surfaces on active rows but never on soft-deleted',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        await tester.pumpWidget(
          wrap(
            MembersAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        expect(
          find.byKey(
            const Key(
              'admin_members_action_override_role_demo-user-diner-owner',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key(
              'admin_members_action_override_role_demo-user-diner-staff-archived',
            ),
          ),
          findsNothing,
        );
      },
    );

    testWidgets('Override role grant sends custom role_id from role catalog', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = _RecordingOverrideMembersGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      );
      final rolesGateway = InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: const <String, List<RoleAdminRow>>{
          kDemoDinerOperatorId: <RoleAdminRow>[
            RoleAdminRow(
              roleId: 'role-seed-operator-owner',
              roleKey: 'operator_owner',
              displayName: 'Operator owner',
              description: '',
              isSeeded: true,
              permissionKeys: <String>[],
            ),
            RoleAdminRow(
              roleId: '44444444-4444-4444-8444-444444444444',
              roleKey: 'custom.floor_captain',
              displayName: 'Floor Captain',
              description: '',
              isSeeded: false,
              permissionKeys: <String>[],
              operatorId: kDemoDinerOperatorId,
            ),
          ],
        },
      );
      await tester.pumpWidget(
        wrap(
          MembersAdminScreen(
            gateway: gateway,
            rolesGateway: rolesGateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(
        find.byKey(
          const Key('admin_members_action_override_role_demo-user-diner-owner'),
        ),
      );
      await pumpEventually(tester);
      await tester.tap(
        find.byKey(const Key('admin_members_override_role_select')),
      );
      await pumpEventually(tester);
      await tester.tap(find.text('Floor Captain').last);
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_members_override_role_reason')),
        'support-ticket-custom-role',
      );
      await tester.tap(
        find.byKey(const Key('admin_members_override_role_submit')),
      );
      await pumpEventually(tester);

      expect(
        gateway.lastOverrideRoleId,
        equals('44444444-4444-4444-8444-444444444444'),
      );
      expect(gateway.lastOverrideRoleKey, equals('custom.floor_captain'));
    });

    testWidgets(
      'view-only mode hides every mutate affordance across every row',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        await tester.pumpWidget(
          wrap(
            MembersAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-ff-support',
              pickedOperator: demoPick(),
              editingEnabled: false,
            ),
          ),
        );
        await pumpEventually(tester);

        expect(
          find.byKey(const Key('admin_members_readonly_banner')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_members_invite_button')),
          findsNothing,
        );
        // Sweep every row-action key for every seeded user — none
        // should render in view-only mode.
        const userIds = <String>[
          'demo-user-diner-owner',
          'demo-user-diner-manager',
          'demo-user-diner-supervisor',
          'demo-user-diner-staff-archived',
        ];
        const actions = <String>[
          'edit_name',
          'suspend',
          'reactivate',
          'soft_delete',
          'reset_password',
          'reset_mfa',
          'force_logout',
          'restore',
          'override_role',
        ];
        for (final user in userIds) {
          for (final action in actions) {
            expect(
              find.byKey(Key('admin_members_action_${action}_$user')),
              findsNothing,
              reason: 'view-only mode must hide $action affordance on $user',
            );
          }
        }
      },
    );
  });

  group('admin write paths capture admin_reason + forge_admin actor', () {
    testWidgets(
      'Suspend prompts for admin reason and audits forge_admin actor',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        var nextKey = 0;
        await tester.pumpWidget(
          wrap(
            MembersAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
              idempotencyKeyFactory: () {
                nextKey += 1;
                return 'idem-$nextKey';
              },
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.tap(
          find.byKey(
            const Key('admin_members_action_suspend_demo-user-diner-owner'),
          ),
        );
        await pumpEventually(tester);

        // Reason dialog should be visible.
        expect(
          find.byKey(const Key('admin_members_reason_dialog')),
          findsOneWidget,
        );

        // Submit empty - the locked validation copy renders.
        await tester.tap(find.byKey(const Key('admin_members_reason_submit')));
        await pumpEventually(tester);
        expect(find.text('Add a reason before continuing.'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('admin_members_reason_field')),
          'support-ticket-1234',
        );
        await tester.tap(find.byKey(const Key('admin_members_reason_submit')));
        await pumpEventually(tester);

        final events = gateway.capturedAuditEvents;
        expect(events, hasLength(1));
        expect(events.single.action, equals('team.users.deactivate'));
        expect(events.single.actorKind, equals('forge_admin'));
        expect(events.single.actorUserId, equals('demo-super-admin'));
        expect(events.single.adminReason, equals('support-ticket-1234'));
        expect(events.single.targetId, equals('demo-user-diner-owner'));
      },
    );

    testWidgets(
      'Edit display name prompts for reason and updates the team row',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        var nextKey = 0;
        await tester.pumpWidget(
          wrap(
            MembersAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
              idempotencyKeyFactory: () {
                nextKey += 1;
                return 'idem-name-$nextKey';
              },
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.tap(
          find.byKey(
            const Key('admin_members_action_edit_name_demo-user-diner-owner'),
          ),
        );
        await pumpEventually(tester);
        expect(
          find.byKey(const Key('admin_members_display_name_dialog')),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('admin_members_display_name_field')),
          'Diner Owner Updated',
        );
        await tester.enterText(
          find.byKey(const Key('admin_members_display_name_reason')),
          'operator requested display correction',
        );
        await tester.tap(
          find.byKey(const Key('admin_members_display_name_submit')),
        );
        await pumpEventually(tester);

        expect(find.text('Diner Owner Updated'), findsWidgets);
        final events = gateway.capturedAuditEvents;
        expect(events, hasLength(1));
        expect(events.single.action, equals('team.users.update_profile'));
        expect(events.single.actorKind, equals('forge_admin'));
        expect(
          events.single.adminReason,
          equals('operator requested display correction'),
        );
      },
    );

    testWidgets(
      'W-1 — Edit member changes email + display name through updateMember',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        var nextKey = 0;
        await tester.pumpWidget(
          wrap(
            MembersAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
              idempotencyKeyFactory: () {
                nextKey += 1;
                return 'idem-edit-$nextKey';
              },
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.tap(
          find.byKey(
            const Key('admin_members_action_edit_name_demo-user-diner-owner'),
          ),
        );
        await pumpEventually(tester);
        expect(
          find.byKey(const Key('admin_members_display_name_dialog')),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('admin_members_email_field')),
          'diner.new@example.test',
        );
        await tester.pump();
        // Confirm checkbox appears when email is dirty — must be ticked
        // before save enables.
        await tester.tap(find.byKey(const Key('admin_members_email_confirm')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('admin_members_display_name_field')),
          'Diner Owner Updated',
        );
        await tester.enterText(
          find.byKey(const Key('admin_members_display_name_reason')),
          'operator typo fix',
        );
        await tester.tap(
          find.byKey(const Key('admin_members_display_name_submit')),
        );
        await pumpEventually(tester);

        expect(find.text('Diner Owner Updated'), findsWidgets);
        expect(find.text('diner.new@example.test'), findsWidgets);
        final events = gateway.capturedAuditEvents;
        expect(events, hasLength(1));
        expect(events.single.action, equals('team.users.update_profile'));
        expect(events.single.actorKind, equals('forge_admin'));
        final fields = events.single.payload['fields'];
        expect(fields, contains('display_name'));
        expect(fields, contains('email'));
      },
    );

    testWidgets(
      'Cancelling the reason dialog leaves the row unchanged + audit empty',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        await tester.pumpWidget(
          wrap(
            MembersAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.tap(
          find.byKey(
            const Key('admin_members_action_suspend_demo-user-diner-owner'),
          ),
        );
        await pumpEventually(tester);

        await tester.tap(find.byKey(const Key('admin_members_reason_cancel')));
        await pumpEventually(tester);

        // Dialog dismissed without writing.
        expect(
          find.byKey(const Key('admin_members_reason_dialog')),
          findsNothing,
        );
        expect(gateway.capturedAuditEvents, isEmpty);
      },
    );

    testWidgets(
      'Invite member happy path drives gateway.createInvite end-to-end',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        await tester.pumpWidget(
          wrap(
            MembersAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.tap(find.byKey(const Key('admin_members_invite_button')));
        await pumpEventually(tester);

        await tester.enterText(
          find.byKey(const Key('admin_members_invite_email')),
          'newcoach@demo-diner.test',
        );
        await tester.enterText(
          find.byKey(const Key('admin_members_invite_display_name')),
          'Casey Coach',
        );
        await tester.tap(find.byKey(const Key('admin_members_invite_role')));
        await pumpEventually(tester);
        await tester.tap(find.text('General Manager').last);
        await pumpEventually(tester);
        await tester.tap(
          find.byKey(const Key('admin_members_invite_location')),
        );
        await pumpEventually(tester);
        await tester.tap(find.text('Toronto Yorkville').last);
        await pumpEventually(tester);
        await tester.enterText(
          find.byKey(const Key('admin_members_invite_admin_reason')),
          'support-onboarding',
        );
        await tester.tap(find.byKey(const Key('admin_members_invite_submit')));
        await pumpEventually(tester);

        final invites = await gateway.listInvites(
          operatorId: kDemoDinerOperatorId,
        );
        // Demo seed had 1 invite; new invite makes 2.
        expect(invites, hasLength(2));
        final fresh = invites.firstWhere(
          (i) => i.email == 'newcoach@demo-diner.test',
        );
        expect(fresh.displayName, equals('Casey Coach'));
        expect(fresh.roleKey, equals('operator_general_manager'));
        expect(fresh.invitedBy, equals('demo-super-admin'));

        final auditActions = gateway.capturedAuditEvents
            .map((e) => e.action)
            .toList();
        expect(auditActions, contains('team.users.invite'));
        final inviteEvent = gateway.capturedAuditEvents.firstWhere(
          (e) => e.action == 'team.users.invite',
        );
        expect(inviteEvent.adminReason, equals('support-onboarding'));
        expect(inviteEvent.actorKind, equals('forge_admin'));
      },
    );

    testWidgets('Invite member can target the selected business scope', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      );
      await tester.pumpWidget(
        wrap(
          MembersAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_members_invite_button')));
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_members_invite_email')),
        'regional@demo-diner.test',
      );
      await tester.enterText(
        find.byKey(const Key('admin_members_invite_display_name')),
        'Riley Regional',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_role')));
      await pumpEventually(tester);
      await tester.tap(find.text('General Manager').last);
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_members_invite_location')));
      await pumpEventually(tester);
      await tester.tap(find.text('Business / Demo Diner Co.').last);
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_members_invite_admin_reason')),
        'regional manager onboarding',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_submit')));
      await pumpEventually(tester);

      final invites = await gateway.listInvites(
        operatorId: kDemoDinerOperatorId,
      );
      final fresh = invites.firstWhere(
        (i) => i.email == 'regional@demo-diner.test',
      );
      expect(fresh.scopeType, equals('operator_wide'));
      final event = gateway.capturedAuditEvents.firstWhere(
        (e) => e.action == 'team.users.invite',
      );
      expect(event.payload['scope_type'], equals('operator_wide'));
    });

    testWidgets(
      'Wave 2 W-2 — Cancel pending invite drives gateway.cancelInvite '
      'with an admin reason and emits invite.cancel audit',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        await tester.pumpWidget(
          wrap(
            MembersAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        // Demo seed has one pending invite for `newhire@demo-diner.test`.
        expect(
          find.byKey(const Key('admin_members_invite_row_demo-invite-diner-1')),
          findsOneWidget,
        );

        final cancelButton = find.byKey(
          const Key('admin_members_invite_cancel_demo-invite-diner-1'),
        );
        await tester.ensureVisible(cancelButton);
        await pumpEventually(tester);
        await tester.tap(cancelButton);
        await pumpEventually(tester);

        // Plain-English confirmation step + admin-reason gate fan
        // out the call only after the operator confirms intent and
        // writes a reason.
        expect(find.text('Cancel invite'), findsWidgets);
        await tester.tap(
          find.byKey(const Key('admin_members_cancel_invite_confirm_button')),
        );
        await pumpEventually(tester);
        await tester.enterText(
          find.byKey(const Key('admin_members_reason_field')),
          'wrong email, resending',
        );
        await tester.tap(find.byKey(const Key('admin_members_reason_submit')));
        await pumpEventually(tester);

        // Row vanished from the pending list and the audit event
        // carries the proxy-pinned event name `invite.cancel` with
        // the previous email + reason payload.
        expect(
          find.byKey(const Key('admin_members_invite_row_demo-invite-diner-1')),
          findsNothing,
        );
        final invites = await gateway.listInvites(
          operatorId: kDemoDinerOperatorId,
        );
        expect(invites, isEmpty);
        final cancelEvents = gateway.capturedAuditEvents
            .where((e) => e.action == 'invite.cancel')
            .toList();
        expect(cancelEvents, hasLength(1));
        expect(cancelEvents.single.targetKind, equals('team_invite'));
        expect(cancelEvents.single.targetId, equals('demo-invite-diner-1'));
        expect(
          cancelEvents.single.payload['previous_email'],
          equals('newhire@demo-diner.test'),
        );
        expect(
          cancelEvents.single.payload['reason'],
          equals('wrong email, resending'),
        );
        expect(cancelEvents.single.adminReason, isNotEmpty);
        expect(cancelEvents.single.actorKind, equals('forge_admin'));
      },
    );

    testWidgets(
      'Wave 2 W-2 — Cancel pending invite is idempotent: replaying the '
      'same idempotency key does not double-audit',
      (tester) async {
        // Direct gateway-level idempotency assertion — avoids
        // depending on the screen's idempotency-key factory under
        // pumpAndSettle re-entry, which is hard to script cleanly in
        // widget tests.
        final gateway = InMemoryMembersAdminGateway(
          membersByOperator: kDemoMembersByOperator(),
          invitesByOperator: kDemoInvitesByOperator(),
        );
        final first = await gateway.cancelInvite(
          operatorId: kDemoDinerOperatorId,
          inviteId: 'demo-invite-diner-1',
          idempotencyKey: 'idemp-cancel-1',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'wrong email, resending',
          reason: 'wrong email, resending',
        );
        final second = await gateway.cancelInvite(
          operatorId: kDemoDinerOperatorId,
          inviteId: 'demo-invite-diner-1',
          idempotencyKey: 'idemp-cancel-1',
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
          adminReason: 'wrong email, resending',
          reason: 'wrong email, resending',
        );

        expect(first, isTrue);
        expect(second, isTrue);
        // Single audit row even after the retry; matches the proxy
        // `proxy_requests` UNIQUE constraint replay shape.
        final cancelEvents = gateway.capturedAuditEvents
            .where((e) => e.action == 'invite.cancel')
            .toList();
        expect(cancelEvents, hasLength(1));
      },
    );

    testWidgets('duplicate invite can show the existing team row', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      );
      await tester.pumpWidget(
        wrap(
          MembersAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_members_invite_button')));
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_members_invite_email')),
        'owner@demo-diner.test',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_submit')));
      await pumpEventually(tester);

      expect(
        find.text(
          'This email is already on the team. Edit the existing member instead.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_members_invite_existing_email_details')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('admin_members_invite_show_existing_email')),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_members_invite_dialog')),
        findsNothing,
      );
      final search = tester.widget<TextField>(
        find.byKey(const Key('admin_members_filter_search')),
      );
      expect(search.controller?.text, equals('owner@demo-diner.test'));
      expect(
        find.byKey(const Key('admin_members_row_demo-user-diner-owner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_members_row_demo-user-diner-manager')),
        findsNothing,
      );
    });
  });

  group('InviteMemberAdminDialog locked validation copy', () {
    testWidgets('empty email surfaces the contract-locked copy', (
      tester,
    ) async {
      String? captured;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open_dialog'),
                onPressed: () async {
                  final result = await showDialog<InviteMemberAdminDraft>(
                    context: context,
                    builder: (_) => const InviteMemberAdminDialog(
                      operatorBusinessName: 'Demo',
                      locations: <MemberLocationRef>[
                        MemberLocationRef(locationId: 'loc-1', name: 'Loc 1'),
                      ],
                    ),
                  );
                  captured = result?.email;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open_dialog')));
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_members_invite_submit')));
      await pumpEventually(tester);

      expect(find.text('Email address is required.'), findsOneWidget);
      expect(captured, isNull);
    });

    testWidgets('duplicate email surfaces the locked copy', (tester) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open_dialog'),
                onPressed: () => showDialog<InviteMemberAdminDraft>(
                  context: context,
                  builder: (_) => const InviteMemberAdminDialog(
                    operatorBusinessName: 'Demo',
                    locations: <MemberLocationRef>[
                      MemberLocationRef(locationId: 'loc-1', name: 'Loc 1'),
                    ],
                    existingEmails: <String>{'taken@op.test'},
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open_dialog')));
      await pumpEventually(tester);

      await tester.enterText(
        find.byKey(const Key('admin_members_invite_email')),
        'taken@op.test',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_submit')));
      await pumpEventually(tester);

      expect(
        find.text(
          'This email is already on the team. Edit the existing member instead.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('missing role surfaces the locked copy', (tester) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open_dialog'),
                onPressed: () => showDialog<InviteMemberAdminDraft>(
                  context: context,
                  builder: (_) => const InviteMemberAdminDialog(
                    operatorBusinessName: 'Demo',
                    locations: <MemberLocationRef>[
                      MemberLocationRef(locationId: 'loc-1', name: 'Loc 1'),
                    ],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open_dialog')));
      await pumpEventually(tester);

      await tester.enterText(
        find.byKey(const Key('admin_members_invite_email')),
        'new@op.test',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_submit')));
      await pumpEventually(tester);

      expect(find.text('Choose a role for this member.'), findsOneWidget);
    });

    testWidgets('operator-wide invite draft carries no primary location', (
      tester,
    ) async {
      InviteMemberAdminDraft? captured;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open_dialog'),
                onPressed: () async {
                  captured = await showDialog<InviteMemberAdminDraft>(
                    context: context,
                    builder: (_) => const InviteMemberAdminDialog(
                      operatorBusinessName: 'Demo',
                      locations: <MemberLocationRef>[
                        MemberLocationRef(locationId: 'loc-1', name: 'Loc 1'),
                      ],
                      accessScopes: <MemberAccessScopeRef>[
                        MemberAccessScopeRef(
                          scopeType: 'operator_wide',
                          id: 'operator_wide:op-1',
                          label: 'Business / Demo',
                        ),
                        MemberAccessScopeRef(
                          scopeType: 'location',
                          id: 'location:loc-1',
                          label: 'Loc 1',
                          locationId: 'loc-1',
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open_dialog')));
      await pumpEventually(tester);

      await tester.enterText(
        find.byKey(const Key('admin_members_invite_email')),
        'business@op.test',
      );
      await tester.enterText(
        find.byKey(const Key('admin_members_invite_display_name')),
        'Business Invite',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_role')));
      await pumpEventually(tester);
      await tester.tap(find.text('General Manager').last);
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_members_invite_admin_reason')),
        'support-onboarding',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_submit')));
      await pumpEventually(tester);

      expect(captured, isNotNull);
      expect(captured!.scopeType, equals('operator_wide'));
      expect(captured!.primaryLocationId, isEmpty);
      expect(captured!.orgUnitId, isNull);
    });

    testWidgets('org-unit invite draft carries only org-unit scope', (
      tester,
    ) async {
      InviteMemberAdminDraft? captured;
      const orgScope = MemberAccessScopeRef(
        scopeType: 'org_unit',
        id: 'org_unit:unit-1',
        label: 'Org unit / Midtown',
        orgUnitId: 'unit-1',
      );
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open_dialog'),
                onPressed: () async {
                  captured = await showDialog<InviteMemberAdminDraft>(
                    context: context,
                    builder: (_) => const InviteMemberAdminDialog(
                      operatorBusinessName: 'Demo',
                      locations: <MemberLocationRef>[
                        MemberLocationRef(locationId: 'loc-1', name: 'Loc 1'),
                      ],
                      accessScopes: <MemberAccessScopeRef>[
                        orgScope,
                        MemberAccessScopeRef(
                          scopeType: 'location',
                          id: 'location:loc-1',
                          label: 'Loc 1',
                          locationId: 'loc-1',
                        ),
                      ],
                      initialScope: orgScope,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open_dialog')));
      await pumpEventually(tester);

      await tester.enterText(
        find.byKey(const Key('admin_members_invite_email')),
        'regional@op.test',
      );
      await tester.enterText(
        find.byKey(const Key('admin_members_invite_display_name')),
        'Regional Invite',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_role')));
      await pumpEventually(tester);
      await tester.tap(find.text('General Manager').last);
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_members_invite_admin_reason')),
        'support-onboarding',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_submit')));
      await pumpEventually(tester);

      expect(captured, isNotNull);
      expect(captured!.scopeType, equals('org_unit'));
      expect(captured!.primaryLocationId, isEmpty);
      expect(captured!.orgUnitId, equals('unit-1'));
    });

    testWidgets(
      'hierarchy-tree picker renders with plain-English label + helper',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const Key('open_dialog'),
                  onPressed: () => showDialog<InviteMemberAdminDraft>(
                    context: context,
                    builder: (_) => const InviteMemberAdminDialog(
                      operatorBusinessName: 'Demo',
                      locations: <MemberLocationRef>[
                        MemberLocationRef(locationId: 'loc-1', name: 'Loc 1'),
                        MemberLocationRef(locationId: 'loc-2', name: 'Loc 2'),
                      ],
                      accessScopes: <MemberAccessScopeRef>[
                        MemberAccessScopeRef(
                          scopeType: 'operator_wide',
                          id: 'operator_wide:op-1',
                          label: 'Business / Demo',
                        ),
                        MemberAccessScopeRef(
                          scopeType: 'location',
                          id: 'location:loc-1',
                          label: 'Loc 1',
                          locationId: 'loc-1',
                        ),
                        MemberAccessScopeRef(
                          scopeType: 'location',
                          id: 'location:loc-2',
                          label: 'Loc 2',
                          locationId: 'loc-2',
                        ),
                      ],
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('open_dialog')));
        await pumpEventually(tester);

        // Picker mounts under the legacy location-field key so existing
        // tests + screen wiring keep working.
        expect(
          find.byKey(const Key('admin_members_invite_location')),
          findsOneWidget,
        );
        expect(find.text('Choose where this person will work'), findsOneWidget);
        expect(
          find.text(
            'Pick the location, region, or whole business. Higher levels '
            'include everything beneath.',
          ),
          findsOneWidget,
        );
        // Picker tree renders (multi-node hierarchy, not the
        // single-location collapse row).
        expect(
          find.byKey(const Key('admin_members_invite_scope_tree')),
          findsOneWidget,
        );
      },
    );

    testWidgets('picking a location in the tree feeds the location scope', (
      tester,
    ) async {
      // The picker tree + admin reason fields push the dialog past the
      // default 800x600 widget-test viewport. Resize so the Loc 2 row
      // is hit-testable.
      tester.view.physicalSize = const Size(1024, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      InviteMemberAdminDraft? captured;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open_dialog'),
                onPressed: () async {
                  captured = await showDialog<InviteMemberAdminDraft>(
                    context: context,
                    builder: (_) => const InviteMemberAdminDialog(
                      operatorBusinessName: 'Demo',
                      locations: <MemberLocationRef>[
                        MemberLocationRef(locationId: 'loc-1', name: 'Loc 1'),
                        MemberLocationRef(locationId: 'loc-2', name: 'Loc 2'),
                      ],
                      accessScopes: <MemberAccessScopeRef>[
                        MemberAccessScopeRef(
                          scopeType: 'operator_wide',
                          id: 'operator_wide:op-1',
                          label: 'Business / Demo',
                        ),
                        MemberAccessScopeRef(
                          scopeType: 'location',
                          id: 'location:loc-1',
                          label: 'Loc 1',
                          locationId: 'loc-1',
                        ),
                        MemberAccessScopeRef(
                          scopeType: 'location',
                          id: 'location:loc-2',
                          label: 'Loc 2',
                          locationId: 'loc-2',
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open_dialog')));
      await pumpEventually(tester);

      await tester.enterText(
        find.byKey(const Key('admin_members_invite_email')),
        'pat.location@op.test',
      );
      await tester.enterText(
        find.byKey(const Key('admin_members_invite_display_name')),
        'Pat Location',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_role')));
      await pumpEventually(tester);
      await tester.tap(find.text('General Manager').last);
      await pumpEventually(tester);

      // Pick Loc 2 in the hierarchy tree. Scroll it into view first
      // in case the dialog content has overflowed the test viewport.
      await tester.ensureVisible(find.text('Loc 2'));
      await pumpEventually(tester);
      await tester.tap(find.text('Loc 2'));
      await pumpEventually(tester);

      await tester.enterText(
        find.byKey(const Key('admin_members_invite_admin_reason')),
        'support-onboarding',
      );
      await tester.tap(find.byKey(const Key('admin_members_invite_submit')));
      await pumpEventually(tester);

      expect(captured, isNotNull);
      expect(captured!.scopeType, equals('location'));
      expect(captured!.primaryLocationId, equals('loc-2'));
      expect(captured!.orgUnitId, isNull);
    });
  });

  group('merged People/access/roles surface', () {
    testWidgets('renders Ops-shaped role policy without Permission Explainer', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      );
      final rolesGateway = InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: kDemoRolesByOperator(),
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
        locationsByOperator: kDemoHierarchyLocationsByOperator(),
        sessionsByOperator: kDemoSessionsByOperator(),
      );

      await tester.pumpWidget(
        wrap(
          MembersAdminScreen(
            gateway: gateway,
            rolesGateway: rolesGateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_people_access_scope_card')),
        findsOneWidget,
      );
      expect(find.text('Selected business scope'), findsOneWidget);
      expect(find.byKey(const Key('admin_rhs_roles_tab')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_rhs_permission_explainer')),
        findsNothing,
      );
    });

    testWidgets('preserves selected hierarchy scope context', (tester) async {
      wideViewport(tester);
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      );

      await tester.pumpWidget(
        wrap(
          MembersAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            initialScope: const AdminHierarchyScopeIntent.orgUnit(
              operatorId: kDemoDinerOperatorId,
              orgUnitId: kDemoDinerOrgUnitEast,
              operatorName: 'Demo Diner Co.',
              orgUnitName: 'East Region',
            ),
          ),
        ),
      );
      await pumpEventually(tester);

      expect(find.text('Selected org unit scope'), findsOneWidget);
      expect(find.text('Demo Diner Co. / East Region'), findsOneWidget);
    });
  });

  group('viewport regression at typical admin shell size', () {
    testWidgets('composes without overflow at the typical 1440x1024 viewport', (
      tester,
    ) async {
      // Pinned to mirror `debug_console_admin_screen_test.dart` /
      // `health_admin_screen_test.dart` — the typical admin shell
      // viewport. The previous Stack-overlay layout collided
      // "Change operator" with "Invite member" at this size; the
      // header-trailing layout fixes it.
      tester.view.physicalSize = const Size(1440, 1024);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final gateway = InMemoryMembersAdminGateway(
        membersByOperator: kDemoMembersByOperator(),
        invitesByOperator: kDemoInvitesByOperator(),
      );
      await tester.pumpWidget(
        wrap(
          MembersAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            onChangeOperator: () {},
          ),
        ),
      );
      await pumpEventually(tester);
      expect(tester.takeException(), isNull);
      // Both header buttons render side by side without collision.
      expect(
        find.byKey(const Key('admin_members_invite_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_members_change_operator')),
        findsOneWidget,
      );
    });
  });
}

class _UnfilteredMembersGateway extends InMemoryMembersAdminGateway {
  _UnfilteredMembersGateway({
    required super.membersByOperator,
    required super.invitesByOperator,
  });

  @override
  Future<List<MemberAdminRow>> listMembers({
    required String operatorId,
    MemberStatus? status,
    String? roleKey,
    String? locationId,
    String? contextLocationId,
    bool? mfaEnrolled,
    String? search,
  }) {
    return super.listMembers(operatorId: operatorId);
  }
}

class _CountingMembersGateway extends InMemoryMembersAdminGateway {
  _CountingMembersGateway({
    required super.membersByOperator,
    required super.invitesByOperator,
  });

  int listMembersCalls = 0;
  final searches = <String?>[];

  @override
  Future<List<MemberAdminRow>> listMembers({
    required String operatorId,
    MemberStatus? status,
    String? roleKey,
    String? locationId,
    String? contextLocationId,
    bool? mfaEnrolled,
    String? search,
  }) {
    listMembersCalls += 1;
    searches.add(search);
    return super.listMembers(
      operatorId: operatorId,
      status: status,
      roleKey: roleKey,
      locationId: locationId,
      contextLocationId: contextLocationId,
      mfaEnrolled: mfaEnrolled,
      search: search,
    );
  }
}

class _RecordingOverrideMembersGateway extends InMemoryMembersAdminGateway {
  _RecordingOverrideMembersGateway({
    required super.membersByOperator,
    required super.invitesByOperator,
  });

  String? lastOverrideRoleId;
  String? lastOverrideRoleKey;

  @override
  Future<MemberAdminRow> overrideRoleGrant({
    required String operatorId,
    required String userId,
    required String roleId,
    required String roleKey,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
    String scopeType = 'operator_wide',
    String? primaryLocationId,
    String? orgUnitId,
  }) {
    lastOverrideRoleId = roleId;
    lastOverrideRoleKey = roleKey;
    return super.overrideRoleGrant(
      operatorId: operatorId,
      userId: userId,
      roleId: roleId,
      roleKey: roleKey,
      idempotencyKey: idempotencyKey,
      actorUserId: actorUserId,
      actorIsForgeAdmin: actorIsForgeAdmin,
      adminReason: adminReason,
      scopeType: scopeType,
      primaryLocationId: primaryLocationId,
      orgUnitId: orgUnitId,
    );
  }
}
