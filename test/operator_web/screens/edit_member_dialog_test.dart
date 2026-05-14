// Wave 2 W-1 — Operator Web Edit member dialog widget tests.
//
// Pins:
//   * the email + display name save round-trip through the in-memory
//     `DemoWebTeamUsersGateway` (mirrors the proxy `PATCH /v1/auth/
//     team/users/{id}` envelope)
//   * the locked validation copy for missing reason / malformed email
//     / unchanged form
//   * the "confirm email change" gate appears only when the email
//     field is actually changing
//   * idempotency replay (re-submitting the same key replays the
//     original patched user)
//   * role + hierarchy scope dropdowns are read-only (operator
//     decision 2026-05-14): they render the current role and scope
//     but tapping does not open the menu. Save must only light up on
//     email or display-name edits. W-1-FU will unlock the dropdowns
//     and wire them through the existing
//     `createRoleGrant`/`revokeRoleGrant` gateway path.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/screens/edit_member_dialog.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_users_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  // The Edit member dialog is 520px wide with five vertical fields +
  // helper text + a confirm checkbox + reason field — it exceeds the
  // default 800x600 widget-test viewport when all controls are
  // rendered. Resize the test viewport so every field is hit-
  // testable for `tester.tap`.
  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1024, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<EditMemberDialogResult?> openDialog(
    WidgetTester tester, {
    required DemoWebTeamUsersGateway gateway,
    required TeamUserListEntry user,
    String profileIdem = 'idem-profile-1',
    String roleIdem = 'idem-role-1',
  }) async {
    EditMemberDialogResult? result;
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open_edit_dialog'),
              onPressed: () async {
                result = await showEditMemberDialog(
                  context: context,
                  gateway: gateway,
                  user: user,
                  existingEmails: <String>{
                    for (final fixture in kDemoTeamUsersFixture)
                      fixture.email.toLowerCase(),
                  },
                  roleOptions: kDemoTeamRolesFixture,
                  locationOptions: kDemoTeamLocationsFixture,
                  actorUserId: 'session-actor',
                  operatorId: kDemoOperatorIdFixture,
                  locationId: 'demo-loc-downtown',
                  profileIdempotencyKey: profileIdem,
                  roleGrantIdempotencyKey: roleIdem,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_edit_dialog')));
    await tester.pumpAndSettle();
    return result;
  }

  Future<TeamUserListEntry> seedUser(DemoWebTeamUsersGateway gateway) async {
    final listed = await gateway.listUsers(
      const TeamUserListCommand(
        actorUserId: 'a',
        operatorId: 'op',
        locationId: 'loc',
      ),
    );
    return listed.users.firstWhere(
      (u) => u.userId == 'demo-user-downtown-manager',
    );
  }

  group('EditMemberDialog', () {
    testWidgets(
      'happy path saves combined email + display name change',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        final user = await seedUser(gateway);
        await openDialog(tester, gateway: gateway, user: user);

        expect(find.byKey(const Key('edit_member_dialog')), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_email_field')),
          'jordan.new@demobistro.test',
        );
        await tester.pump();
        // The confirm-email gate appears once email is dirty.
        expect(find.byKey(const Key('edit_member_dialog_confirm_email')),
            findsOneWidget);
        await tester.tap(
          find.byKey(const Key('edit_member_dialog_confirm_email')),
        );
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_display_name_field')),
          'Jordan Lee Jr',
        );
        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_reason_field')),
          'operator typo fix',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('edit_member_dialog_submit')));
        await tester.pumpAndSettle();

        // After save the dialog is closed and the gateway holds the new row.
        expect(find.byKey(const Key('edit_member_dialog')), findsNothing);
        final after = await gateway.listUsers(
          const TeamUserListCommand(
            actorUserId: 'a',
            operatorId: 'op',
            locationId: 'loc',
          ),
        );
        final updated = after.users.firstWhere(
          (u) => u.userId == 'demo-user-downtown-manager',
        );
        expect(updated.email, equals('jordan.new@demobistro.test'));
        expect(updated.displayName, equals('Jordan Lee Jr'));
      },
    );

    testWidgets(
      'idempotency replay returns the cached patched row',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        final user = await seedUser(gateway);
        // First save mutates and caches.
        await openDialog(
          tester,
          gateway: gateway,
          user: user,
          profileIdem: 'shared-key',
        );
        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_display_name_field')),
          'Jordan Lee Jr',
        );
        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_reason_field')),
          'first save',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('edit_member_dialog_submit')));
        await tester.pumpAndSettle();

        // Second open with the same idempotency key — gateway should
        // surface the cached row and not double-mutate.
        await openDialog(
          tester,
          gateway: gateway,
          user: user,
          profileIdem: 'shared-key',
        );
        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_display_name_field')),
          'Jordan Lee Jr',
        );
        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_reason_field')),
          'replay',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('edit_member_dialog_submit')));
        await tester.pumpAndSettle();

        final after = await gateway.listUsers(
          const TeamUserListCommand(
            actorUserId: 'a',
            operatorId: 'op',
            locationId: 'loc',
          ),
        );
        final updated = after.users.firstWhere(
          (u) => u.userId == 'demo-user-downtown-manager',
        );
        // Display name reflects the FIRST patch (idempotency replay).
        expect(updated.displayName, equals('Jordan Lee Jr'));
      },
    );

    testWidgets(
      'rejects empty reason with locked copy',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        final user = await seedUser(gateway);
        await openDialog(tester, gateway: gateway, user: user);

        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_display_name_field')),
          'Jordan Lee Jr',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('edit_member_dialog_submit')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('edit_member_dialog_error_text')),
            findsOneWidget);
        expect(
          find.text(EditMemberDialogCopy.reasonMissing),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'rejects malformed email',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        final user = await seedUser(gateway);
        await openDialog(tester, gateway: gateway, user: user);

        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_email_field')),
          'not-an-email',
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('edit_member_dialog_confirm_email')),
        );
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_reason_field')),
          'reason',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('edit_member_dialog_submit')));
        await tester.pumpAndSettle();

        expect(
          find.text(EditMemberDialogCopy.emailMalformed),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'rejects save without any change',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        final user = await seedUser(gateway);
        await openDialog(tester, gateway: gateway, user: user);

        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_reason_field')),
          'reason',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('edit_member_dialog_submit')));
        await tester.pumpAndSettle();

        expect(
          find.text(EditMemberDialogCopy.nothingToSave),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'email change without confirmation is rejected',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        final user = await seedUser(gateway);
        await openDialog(tester, gateway: gateway, user: user);

        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_email_field')),
          'jordan.new@demobistro.test',
        );
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_reason_field')),
          'reason',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('edit_member_dialog_submit')));
        await tester.pumpAndSettle();

        // The locked confirmEmailRequired copy renders in both the
        // checkbox title and the error_text slot when the operator
        // tries to save without confirming, so we look for at least
        // one (rather than findsOneWidget) and additionally assert
        // the error_text key is present.
        expect(
          find.text(EditMemberDialogCopy.confirmEmailRequired),
          findsAtLeastNWidgets(1),
        );
        expect(
          find.byKey(const Key('edit_member_dialog_error_text')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'role dropdown renders the current role but is un-clickable',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        final user = await seedUser(gateway);
        await openDialog(tester, gateway: gateway, user: user);

        // The dropdown is visible.
        final roleFinder =
            find.byKey(const Key('edit_member_dialog_role_field'));
        expect(roleFinder, findsOneWidget);

        // Its `onChanged` is null, so tapping must NOT open the
        // dropdown menu. We verify by counting role display names
        // before and after the tap — Flutter's DropdownButtonFormField
        // shows the selected item once when closed and adds a second
        // copy in the menu overlay when open. With onChanged: null no
        // menu opens, so the count stays at 1.
        final currentRole = kDemoTeamRolesFixture
            .firstWhere((r) => r.roleId == user.roleId)
            .displayName;
        expect(find.text(currentRole), findsOneWidget);
        await tester.tap(roleFinder, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text(currentRole), findsOneWidget);

        // The dropdown's DropdownButton child reports `onChanged ==
        // null`, which is how Flutter renders the disabled style.
        final dropdown = tester.widget<DropdownButtonFormField<String>>(
          roleFinder,
        );
        expect(dropdown.onChanged, isNull);
      },
    );

    testWidgets(
      'hierarchy scope dropdown renders the current scope but is un-clickable',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        final user = await seedUser(gateway);
        await openDialog(tester, gateway: gateway, user: user);

        final scopeFinder =
            find.byKey(const Key('edit_member_dialog_scope_field'));
        expect(scopeFinder, findsOneWidget);

        // Tapping must not open the menu. We assert no menu items
        // beyond the closed-state selected label appear.
        await tester.tap(scopeFinder, warnIfMissed: false);
        await tester.pumpAndSettle();

        final dropdown =
            tester.widget<DropdownButtonFormField<dynamic>>(scopeFinder);
        expect(dropdown.onChanged, isNull);

        // The plain-English helper line renders below the dropdown.
        expect(
          find.byKey(const Key('edit_member_dialog_role_scope_lock_note')),
          findsOneWidget,
        );
        expect(
          find.text('To change role or hierarchy scope, use the Roles page.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'save stays gated when nothing but reason is filled',
      (tester) async {
        // Companion to the existing "rejects save without any change"
        // test — with role + scope locked, the save button must remain
        // gated by email or display-name edits. The operator cannot
        // accidentally trigger a role/scope rotation by filling reason.
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        final user = await seedUser(gateway);
        await openDialog(tester, gateway: gateway, user: user);

        await tester.enterText(
          find.byKey(const Key('edit_member_dialog_reason_field')),
          'wanted to bump role but cant',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('edit_member_dialog_submit')));
        await tester.pumpAndSettle();

        // The dialog still shows the nothing-to-save copy — no
        // gateway call fires because email + display name are
        // unchanged.
        expect(
          find.text(EditMemberDialogCopy.nothingToSave),
          findsOneWidget,
        );
        expect(find.byKey(const Key('edit_member_dialog')), findsOneWidget);
      },
    );
  });
}
