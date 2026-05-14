// Phase 11W.1 - Members screen widget tests.
//
// Pins the parity contract section "Members + Invites (11W.1 +
// 11A.12)":
//
//   - filter set: status / role / location / mfa / search
//     (each chip exercised against the fixture, not just rendered)
//   - pagination: 50 rows per page; pagination bar visible
//   - sort order: last_active_at DESC then email ASC
//   - row actions: Suspend, Reactivate, Soft delete, Reset password,
//                  Reset MFA. Force sign-out is deferred to 11W.4.
//   - locked validation copy (all 5 strings) on the invite dialog
//   - permission gate: operator_owner full surface;
//                      operator_admin full surface;
//                      location_manager read-only;
//                      operator_staff -> friendly forbidden;
//                      permission-key snapshot overrides role tier
//   - idempotency replay (same key + same call returns cached result)
//   - demo fixture reset (each fresh gateway re-seeds defaults)
//   - zero em dashes in operator-facing string literals
//     (scan of all 11W.1-owned files)
//
// Tests rely on the in-memory `DemoWebTeamUsersGateway` and the
// shared fixture set so the assertions stay deterministic.

import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/invite_member_dialog.dart';
import 'package:forge_and_flow/operator_web/screens/members_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_users_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  OperatorWebSession sessionWithRole(
    String role, {
    Set<String> permissions = const <String>{},
  }) =>
      OperatorWebSession(
        uid: 'session-$role',
        email: 'sam.owner@demobistro.test',
        displayName: 'Sam Patel',
        operatorId: kDemoOperatorIdFixture,
        businessName: kDemoOperatorBusinessNameFixture,
        primaryLocationId: 'demo-loc-downtown',
        primaryLocationName: 'Downtown',
        roles: <String>[role],
        permissions: permissions,
      );

  Future<void> pumpScreen(
    WidgetTester tester, {
    required OperatorWebSession session,
    DemoWebTeamUsersGateway? gateway,
  }) async {
    await tester.pumpWidget(
      wrap(
        MembersScreen(
          session: session,
          gateway: gateway ?? DemoWebTeamUsersGateway(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openRowActionMenu(
    WidgetTester tester,
    String userId,
  ) async {
    await tester.tap(
      find.byKey(Key('operator_web_members_row_actions_$userId')),
    );
    await tester.pumpAndSettle();
  }

  Future<void> confirmDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('members_confirm_dialog_confirm')));
    await tester.pumpAndSettle();
  }

  group('MembersScreen layout + filter rail rendering', () {
    testWidgets('renders header, filter rail, table, pagination, pending '
        'invites for operator_owner at desktop 1280x800', (tester) async {
      await sizeViewport(tester, const Size(1280, 800));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      expect(
        find.byKey(const Key('operator_web_members_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_filter_rail')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_table')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_pagination')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_pending_invites')),
        findsOneWidget,
      );
    });

    testWidgets('pending invite row exposes Cancel and revokes through the '
        'gateway contract', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = DemoWebTeamUsersGateway();
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
      );

      expect(
        find.byKey(
          const Key('operator_web_pending_invite_demo-invite-pending-1'),
        ),
        findsOneWidget,
      );

      final cancelButton = find.byKey(
        const Key('operator_web_pending_invite_cancel_demo-invite-pending-1'),
      );
      await tester.ensureVisible(cancelButton);
      await tester.tap(cancelButton);
      await tester.pumpAndSettle();
      expect(find.text('Cancel invite'), findsWidgets);

      await confirmDialog(tester);

      expect(
        find.byKey(
          const Key('operator_web_pending_invite_demo-invite-pending-1'),
        ),
        findsNothing,
      );
      expect(
        find.text('Invite cancelled. Send a new invite if needed.'),
        findsOneWidget,
      );
      final invites = await gateway.listInvites(
        const TeamInviteListCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
        ),
      );
      expect(
        invites.invites.any((i) => i.inviteId == 'demo-invite-pending-1'),
        isFalse,
      );
    });

    testWidgets('filter rail surfaces all five locked filter chips', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      expect(
        find.byKey(const Key('operator_web_members_filter_search')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_filter_status')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_filter_role')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_filter_location')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_filter_mfa')),
        findsOneWidget,
      );
    });

    testWidgets('table renders one row per fixture user (six total)', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      for (final fixture in kDemoTeamUsersFixture) {
        expect(
          find.byKey(Key('operator_web_members_row_${fixture.userId}')),
          findsOneWidget,
          reason: 'expected a row for fixture user ${fixture.userId}',
        );
      }
    });

    testWidgets('rows render in last_active_at DESC then email ASC order',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      // Build a list of widget index (top-to-bottom on screen) per
      // user id so we can assert the order matches the locked sort.
      final orderedKeys = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.key)
          .whereType<ValueKey<String>>()
          .map((k) => k.value)
          .where((s) => s.startsWith('operator_web_members_row_'))
          .toList();
      // Drop the table prefix so we're comparing user ids only.
      final userIdsInOrder = orderedKeys
          .map((k) => k.substring('operator_web_members_row_'.length))
          .toList();
      // Owner (last_active 2026-05-05T14:32) is the most recent and
      // sorts first; soft-deleted Floor Captain (2026-03-18) sorts
      // last among rows with timestamps.
      expect(userIdsInOrder.first, 'demo-user-owner');
      expect(userIdsInOrder.last, 'demo-user-downtown-floor-captain');
    });
  });

  group('MembersScreen filter chips narrow the table', () {
    testWidgets('search filter narrows by display name', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await tester.enterText(
        find.byKey(const Key('operator_web_members_filter_search')),
        'Jordan',
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_members_row_demo-user-downtown-manager')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_row_demo-user-owner')),
        findsNothing,
      );
    });

    testWidgets('status filter narrows to suspended rows only', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await tester.tap(
        find.byKey(const Key('operator_web_members_filter_status')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Suspended').last);
      await tester.pumpAndSettle();

      // Morgan Rivers is the lone suspended fixture user.
      expect(
        find.byKey(const Key(
          'operator_web_members_row_demo-user-riverside-supervisor',
        )),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_row_demo-user-owner')),
        findsNothing,
      );
    });

    testWidgets('role filter narrows to a single role catalog entry', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await tester.tap(
        find.byKey(const Key('operator_web_members_filter_role')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Floor Captain').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key(
          'operator_web_members_row_demo-user-downtown-floor-captain',
        )),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_row_demo-user-owner')),
        findsNothing,
      );
    });

    testWidgets('location filter narrows to one fixture location', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await tester.tap(
        find.byKey(const Key('operator_web_members_filter_location')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Riverside').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key(
          'operator_web_members_row_demo-user-riverside-supervisor',
        )),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key(
          'operator_web_members_row_demo-user-riverside-staff',
        )),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key(
          'operator_web_members_row_demo-user-downtown-manager',
        )),
        findsNothing,
      );
    });

    testWidgets('two-factor filter narrows by MFA enrollment state', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await tester.tap(
        find.byKey(const Key('operator_web_members_filter_mfa')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Off').last);
      await tester.pumpAndSettle();

      // Owner has MFA on; Taylor Kim and Casey Brooks and Dakota
      // Singh have MFA off.
      expect(
        find.byKey(const Key('operator_web_members_row_demo-user-owner')),
        findsNothing,
      );
      expect(
        find.byKey(const Key(
          'operator_web_members_row_demo-user-northloop-locmgr',
        )),
        findsOneWidget,
      );
    });
  });

  group('MembersScreen permission gate', () {
    testWidgets('operator_staff lands on the friendly forbidden surface', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      await pumpScreen(tester, session: sessionWithRole('operator_staff'));

      expect(
        find.byKey(const Key('operator_web_members_forbidden')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_table')),
        findsNothing,
      );
    });

    testWidgets('location_manager sees the table but the invite button is '
        'disabled and rows render no action menu', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('location_manager'));

      expect(
        find.byKey(const Key('operator_web_members_table')),
        findsOneWidget,
      );
      final inviteButton = tester.widget<FilledButton>(
        find.byKey(const Key('operator_web_members_invite_button')),
      );
      expect(inviteButton.onPressed, isNull);
      // Each row's action menu is hidden for read-only roles.
      expect(
        find.byKey(const Key(
          'operator_web_members_row_actions_demo-user-owner',
        )),
        findsNothing,
      );
    });

    testWidgets('operator_owner sees an enabled invite button + row actions',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      final inviteButton = tester.widget<FilledButton>(
        find.byKey(const Key('operator_web_members_invite_button')),
      );
      expect(inviteButton.onPressed, isNotNull);
      expect(
        find.byKey(const Key(
          'operator_web_members_row_actions_demo-user-owner',
        )),
        findsOneWidget,
      );
    });

    testWidgets('operator_admin sees an enabled invite button + row actions',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_admin'));

      final inviteButton = tester.widget<FilledButton>(
        find.byKey(const Key('operator_web_members_invite_button')),
      );
      expect(inviteButton.onPressed, isNotNull);
    });

    testWidgets('permission-key snapshot trumps the role-tier fallback', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      // Role says operator_owner (would admit via the role fallback)
      // but the permission snapshot withholds team.users.view -
      // forbidden surface should win.
      await pumpScreen(
        tester,
        session: sessionWithRole(
          'operator_owner',
          permissions: const <String>{'integrations.configure'},
        ),
      );

      expect(
        find.byKey(const Key('operator_web_members_forbidden')),
        findsOneWidget,
      );
    });

    testWidgets('permission-key snapshot admits a member with team.users.view '
        'even when the role is otherwise unrecognised', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(
        tester,
        session: sessionWithRole(
          'custom_floor_captain',
          permissions: const <String>{
            kMembersViewPermissionKey,
          },
        ),
      );

      expect(
        find.byKey(const Key('operator_web_members_table')),
        findsOneWidget,
      );
      // No write keys -> invite button stays disabled.
      final inviteButton = tester.widget<FilledButton>(
        find.byKey(const Key('operator_web_members_invite_button')),
      );
      expect(inviteButton.onPressed, isNull);
    });

    testWidgets('reset-only write permission does not expose invite actions', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(
        tester,
        session: sessionWithRole(
          'custom_floor_captain',
          permissions: const <String>{
            kMembersViewPermissionKey,
            kMembersResetPasswordPermissionKey,
          },
        ),
      );

      final inviteButton = tester.widget<FilledButton>(
        find.byKey(const Key('operator_web_members_invite_button')),
      );
      expect(inviteButton.onPressed, isNull);
      expect(
        find.byKey(
          const Key('operator_web_pending_invite_cancel_demo-invite-pending-1'),
        ),
        findsNothing,
      );
    });

    testWidgets('team.users.invite permission exposes invite actions', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(
        tester,
        session: sessionWithRole(
          'custom_floor_captain',
          permissions: const <String>{
            kMembersViewPermissionKey,
            kMembersInvitePermissionKey,
          },
        ),
      );

      final inviteButton = tester.widget<FilledButton>(
        find.byKey(const Key('operator_web_members_invite_button')),
      );
      expect(inviteButton.onPressed, isNotNull);
      expect(
        find.byKey(
          const Key('operator_web_pending_invite_cancel_demo-invite-pending-1'),
        ),
        findsOneWidget,
      );
    });
  });

  group('MembersScreen pagination', () {
    testWidgets('pagination bar reports the current window of rows', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      expect(
        find.text('Showing 1 to ${kDemoTeamUsersFixture.length} of '
            '${kDemoTeamUsersFixture.length}'),
        findsOneWidget,
      );
      // With six fixture users + page size 50 there is no next page.
      final next = tester.widget<IconButton>(
        find.byKey(const Key('operator_web_members_pagination_next')),
      );
      final prev = tester.widget<IconButton>(
        find.byKey(const Key('operator_web_members_pagination_prev')),
      );
      expect(next.onPressed, isNull);
      expect(prev.onPressed, isNull);
    });

    testWidgets('page size honours the locked 50-row contract', (
      tester,
    ) async {
      expect(kMembersPageSize, 50);
    });
  });

  group('MembersScreen row actions', () {
    testWidgets('suspend action moves the row into the suspended status pill',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = DemoWebTeamUsersGateway();
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
      );

      await openRowActionMenu(tester, 'demo-user-owner');
      await tester.tap(find.byKey(const Key('members_row_action_suspend')));
      await tester.pumpAndSettle();
      await confirmDialog(tester);

      // Status chip flipped to Suspended (visible on the owner row).
      expect(find.text('Suspended'), findsWidgets);
    });

    testWidgets('reactivate action restores the suspended row to active', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = DemoWebTeamUsersGateway();
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
      );

      // Morgan Rivers fixture starts suspended; the row menu should
      // expose Reactivate.
      await openRowActionMenu(tester, 'demo-user-riverside-supervisor');
      await tester.tap(
        find.byKey(const Key('members_row_action_reactivate')),
      );
      await tester.pumpAndSettle();
      await confirmDialog(tester);

      // After reactivation the row's status chip flips Active. We
      // assert via direct gateway query because finding the chip
      // by colour in widget tests is flaky; the screen rebuilds
      // off the fresh listUsers call.
      final users = await gateway.listUsers(
        const TeamUserListCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
        ),
      );
      final morgan = users.users.firstWhere(
        (u) => u.userId == 'demo-user-riverside-supervisor',
      );
      expect(morgan.status, 'active');
    });

    testWidgets('soft delete action removes the row from the active table',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = DemoWebTeamUsersGateway();
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
      );

      await openRowActionMenu(tester, 'demo-user-downtown-manager');
      await tester.tap(
        find.byKey(const Key('members_row_action_soft_delete')),
      );
      await tester.pumpAndSettle();
      await confirmDialog(tester);

      final users = await gateway.listUsers(
        const TeamUserListCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
        ),
      );
      final jordan = users.users.firstWhere(
        (u) => u.userId == 'demo-user-downtown-manager',
      );
      expect(jordan.status, 'soft_deleted');
    });

    testWidgets('reset password action surfaces the queued snackbar copy', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await openRowActionMenu(tester, 'demo-user-downtown-manager');
      await tester.tap(
        find.byKey(const Key('members_row_action_reset_password')),
      );
      await tester.pumpAndSettle();
      await confirmDialog(tester);
      // Pump once more so the SnackBar enters the tree before we
      // assert; pumpAndSettle would hang on the auto-dismiss timer.
      await tester.pump();

      expect(find.text('Password reset email queued.'), findsOneWidget);
    });

    testWidgets('reset MFA action surfaces the delayed-removal snackbar copy',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await openRowActionMenu(tester, 'demo-user-downtown-manager');
      await tester.tap(
        find.byKey(const Key('members_row_action_reset_mfa')),
      );
      await tester.pumpAndSettle();
      await confirmDialog(tester);
      await tester.pump();

      expect(
        find.text(
          'Two-factor sign-in removal started. It will be removed in 24 '
          'hours.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('soft-deleted rows expose no row-action menu', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      // The soft-deleted Floor Captain fixture renders no action
      // menu (Restore lives on the F&F admin path per the contract).
      expect(
        find.byKey(const Key(
          'operator_web_members_row_actions_demo-user-downtown-floor-captain',
        )),
        findsNothing,
      );
    });
  });

  group('MembersScreen invite dialog locked validation copy', () {
    testWidgets('renders all five locked validation copy strings on bad input',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await tester.tap(
        find.byKey(const Key('operator_web_members_invite_button')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invite_member_dialog')), findsOneWidget);

      // 1. Submit empty form -> emailMissing.
      await tester.tap(find.byKey(const Key('invite_member_dialog_submit')));
      await tester.pumpAndSettle();
      expect(
        find.text(InviteMemberDialogCopy.emailMissing),
        findsOneWidget,
      );

      // 2. Type bad email -> emailMalformed.
      await tester.enterText(
        find.byKey(const Key('invite_member_dialog_email_field')),
        'not-an-email',
      );
      await tester.tap(find.byKey(const Key('invite_member_dialog_submit')));
      await tester.pumpAndSettle();
      expect(
        find.text(InviteMemberDialogCopy.emailMalformed),
        findsOneWidget,
      );

      // 3. Type a duplicate email (already on the team) -> emailDuplicate.
      await tester.enterText(
        find.byKey(const Key('invite_member_dialog_email_field')),
        'sam.owner@demobistro.test',
      );
      await tester.tap(find.byKey(const Key('invite_member_dialog_submit')));
      await tester.pumpAndSettle();
      expect(
        find.text(InviteMemberDialogCopy.emailDuplicate),
        findsOneWidget,
      );

      // 4. Type a valid email but no role -> roleMissing.
      await tester.enterText(
        find.byKey(const Key('invite_member_dialog_email_field')),
        'someone.new@demobistro.test',
      );
      await tester.tap(find.byKey(const Key('invite_member_dialog_submit')));
      await tester.pumpAndSettle();
      expect(
        find.text(InviteMemberDialogCopy.roleMissing),
        findsOneWidget,
      );

      // 5. Pick a role but no location -> locationMissing.
      await tester.tap(
        find.byKey(const Key('invite_member_dialog_role_field')),
      );
      await tester.pumpAndSettle();
      // R-2L v2 catalog: "Staff" retired; pick a still-seeded role.
      await tester.tap(find.text('Supervisor').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invite_member_dialog_submit')));
      await tester.pumpAndSettle();
      expect(
        find.text(InviteMemberDialogCopy.locationMissing),
        findsOneWidget,
      );
    });
  });

  group('Demo gateway idempotency replay + reset', () {
    test('suspendUser called twice with the same idempotency key does not '
        're-mutate', () async {
      final gateway = DemoWebTeamUsersGateway();
      const cmd = TeamUserStatusCommand(
        actorUserId: 'actor',
        operatorId: kDemoOperatorIdFixture,
        locationId: 'demo-loc-downtown',
        targetUserId: 'demo-user-owner',
        reason: 'replay-test',
      );
      const key = 'replay-key-1';
      final first = await gateway.suspendUser(cmd, idempotencyKey: key);
      final second = await gateway.suspendUser(cmd, idempotencyKey: key);
      expect(first.updated, isTrue);
      expect(second.updated, isTrue);
      // Both calls return the cached record; the user stays
      // suspended (not flipped twice).
      final users = await gateway.listUsers(
        const TeamUserListCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
        ),
      );
      final owner =
          users.users.firstWhere((u) => u.userId == 'demo-user-owner');
      expect(owner.status, 'suspended');
    });

    test('createInvite called twice with the same idempotency key returns '
        'the same invite id (no duplicate row)', () async {
      final gateway = DemoWebTeamUsersGateway();
      // R-2L v2 catalog: `role-operator-staff` retired and folded into
      // `role-supervisor`. Use the v2 role id for new invites.
      const cmd = TeamInviteCreateCommand(
        actorUserId: 'actor',
        operatorId: kDemoOperatorIdFixture,
        locationId: 'demo-loc-downtown',
        email: 'replay@demobistro.test',
        roleId: 'role-supervisor',
        scopeType: 'location',
        targetLocationId: 'demo-loc-downtown',
      );
      const key = 'replay-invite-key';
      final first = await gateway.createInvite(cmd, idempotencyKey: key);
      final second = await gateway.createInvite(cmd, idempotencyKey: key);
      expect(first.inviteId, second.inviteId);
      final invites = await gateway.listInvites(
        const TeamInviteListCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
        ),
      );
      final replays = invites.invites
          .where((i) => i.email == 'replay@demobistro.test')
          .toList();
      expect(replays, hasLength(1));
    });

    test('a fresh DemoWebTeamUsersGateway re-seeds the fixture defaults '
        'after a previous instance mutated state', () async {
      final firstGateway = DemoWebTeamUsersGateway();
      await firstGateway.suspendUser(
        const TeamUserStatusCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
          targetUserId: 'demo-user-owner',
          reason: 'reset-test',
        ),
        idempotencyKey: 'reset-key-1',
      );
      final freshGateway = DemoWebTeamUsersGateway();
      final users = await freshGateway.listUsers(
        const TeamUserListCommand(
          actorUserId: 'actor',
          operatorId: kDemoOperatorIdFixture,
          locationId: 'demo-loc-downtown',
        ),
      );
      final owner =
          users.users.firstWhere((u) => u.userId == 'demo-user-owner');
      expect(owner.status, 'active');
    });
  });

  group('No em dash regression on 11W.1-owned files', () {
    test('every operator-facing string literal in the 11W.1 file set is '
        'em-dash free', () async {
      const ownedPaths = <String>[
        'lib/operator_web/services/demo_team_fixtures.dart',
        'lib/operator_web/services/demo_team_users_gateway.dart',
        'lib/operator_web/services/web_team_users_gateway.dart',
        'lib/operator_web/screens/members_screen.dart',
        'lib/operator_web/screens/invite_member_dialog.dart',
      ];
      for (final relativePath in ownedPaths) {
        final source = await io.File(relativePath).readAsString();
        // Strip line comments before scanning so author-facing
        // commentary cannot leak through. We do not need a
        // parser-correct strip - the fixture's string literals never
        // contain `//`.
        final stripped = source
            .split('\n')
            .map((line) {
              final commentStart = line.indexOf('//');
              if (commentStart < 0) return line;
              // Conservative: only treat `//` as a comment when not
              // inside a string literal. We avoid any literal
              // containing `//` by convention; scan from left to right.
              var inString = false;
              String? quote;
              for (var i = 0; i < line.length - 1; i++) {
                final c = line[i];
                if (!inString && (c == '"' || c == "'")) {
                  inString = true;
                  quote = c;
                  continue;
                }
                if (inString && c == quote) {
                  inString = false;
                  quote = null;
                  continue;
                }
                if (!inString && c == '/' && line[i + 1] == '/') {
                  return line.substring(0, i);
                }
              }
              return line;
            })
            .join('\n');
        expect(
          stripped.contains('—'),
          isFalse,
          reason: 'em dash (U+2014) found in $relativePath outside comments',
        );
      }
    });
  });
}
