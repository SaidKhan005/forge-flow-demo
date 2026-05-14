// Wave 2 RP-10 — Operator Web invite member dialog widget tests.
//
// Pins the hierarchy-tree picker swap:
//   * The picker renders inside the dialog with plain-English label
//     and helper copy (no flat location dropdown).
//   * Picking a location enables the Submit action; submit fires the
//     gateway with `scope_type: 'location'` + the location id.
//   * Picking a region grants at the org-unit scope; submit fires the
//     gateway with `scope_type: 'org_unit'` + the org-unit id (no
//     location id leaks into the payload).
//   * Missing-scope validation still surfaces the locked
//     "Choose a primary location" copy.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/screens/invite_member_dialog.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_users_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
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

  const listCommand = TeamUserListCommand(
    actorUserId: 'session-actor',
    operatorId: kDemoOperatorIdFixture,
    locationId: 'demo-loc-downtown',
  );

  Future<InviteMemberDialogResult?> openDialog(
    WidgetTester tester, {
    required DemoWebTeamUsersGateway gateway,
    Set<String> existingEmails = const <String>{},
    String idempotencyKey = 'idem-invite-1',
  }) async {
    InviteMemberDialogResult? result;
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open_invite_dialog'),
              onPressed: () async {
                result = await showInviteMemberDialog(
                  context: context,
                  gateway: gateway,
                  listCommand: listCommand,
                  existingEmails: existingEmails,
                  roleOptions: kDemoTeamRolesFixture,
                  locationOptions: kDemoTeamLocationsFixture,
                  idempotencyKey: idempotencyKey,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_invite_dialog')));
    await tester.pumpAndSettle();
    return result;
  }

  group('InviteMemberDialog hierarchy-tree picker', () {
    testWidgets('renders the picker with plain-English label and helper', (
      tester,
    ) async {
      await sizeViewport(tester);
      final gateway = DemoWebTeamUsersGateway();
      await openDialog(tester, gateway: gateway);

      // The picker replaces the flat DropdownButtonFormField at the
      // location field key.
      expect(
        find.byKey(const Key('invite_member_dialog_location_field')),
        findsOneWidget,
      );
      expect(
        find.text('Choose where this person will work'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Pick the location, region, or whole business. Higher levels '
          'include everything beneath.',
        ),
        findsOneWidget,
      );

      // The legacy flat dropdown for location is gone.
      expect(
        find.byType(DropdownButtonFormField<String>),
        findsOneWidget, // only role remains
      );
    });

    testWidgets('missing scope surfaces the locked validation copy', (
      tester,
    ) async {
      await sizeViewport(tester);
      final gateway = DemoWebTeamUsersGateway();
      await openDialog(tester, gateway: gateway);

      // Enter a valid email + pick a role but skip the location.
      await tester.enterText(
        find.byKey(const Key('invite_member_dialog_email_field')),
        'pat.new@demobistro.test',
      );
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

    testWidgets(
      'picking a location enables Submit and posts location scope',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        InviteMemberDialogResult? result;
        await tester.pumpWidget(
          wrap(
            Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const Key('open_invite_dialog'),
                  onPressed: () async {
                    result = await showInviteMemberDialog(
                      context: context,
                      gateway: gateway,
                      listCommand: listCommand,
                      existingEmails: const <String>{},
                      roleOptions: kDemoTeamRolesFixture,
                      locationOptions: kDemoTeamLocationsFixture,
                      idempotencyKey: 'idem-invite-loc-1',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('open_invite_dialog')));
        await tester.pumpAndSettle();

        // Fill email + role.
        await tester.enterText(
          find.byKey(const Key('invite_member_dialog_email_field')),
          'taylor.new@demobistro.test',
        );
        await tester.tap(
          find.byKey(const Key('invite_member_dialog_role_field')),
        );
        await tester.pumpAndSettle();
        // R-2L v2 catalog: "Staff" retired; pick a still-seeded role.
        await tester.tap(find.text('Supervisor').last);
        await tester.pumpAndSettle();

        // Tap the Downtown location node in the picker tree.
        await tester.tap(find.text('Downtown'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('invite_member_dialog_submit')));
        await tester.pumpAndSettle();

        expect(result, isNotNull);
        // Demo gateway echoes the created invite back into its list;
        // the dialog returns a non-null `InviteMemberDialogResult`.
        expect(result!.created.inviteId, isNotEmpty);

        // Verify the invite that landed in the demo gateway used the
        // location scope (not operator_wide + bare location id).
        final listed = await gateway.listInvites(
          const TeamInviteListCommand(
            actorUserId: 'session-actor',
            operatorId: kDemoOperatorIdFixture,
            locationId: 'demo-loc-downtown',
          ),
        );
        final created = listed.invites.firstWhere(
          (i) => i.email == 'taylor.new@demobistro.test',
        );
        expect(created.scopeType, equals('location'));
        expect(created.locationId, equals('demo-loc-downtown'));
        expect(created.orgUnitId, isNull);
      },
    );

    testWidgets(
      'selection persists across Cancel → Reopen (mid-invite continuity)',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();

        // Open the dialog, pick a region, then Cancel.
        await openDialog(tester, gateway: gateway);
        await tester.tap(find.text('East Region'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('invite_member_dialog_cancel')));
        await tester.pumpAndSettle();

        // Re-open. The hierarchy picker should restore the prior pick
        // so the operator can continue without retracing their steps.
        await tester.tap(find.byKey(const Key('open_invite_dialog')));
        await tester.pumpAndSettle();

        // Filling email + role + submitting should now post the
        // org-unit scope without an extra picker tap, proving the
        // last pick was rehydrated.
        await tester.enterText(
          find.byKey(const Key('invite_member_dialog_email_field')),
          'persistence.check@demobistro.test',
        );
        await tester.tap(
          find.byKey(const Key('invite_member_dialog_role_field')),
        );
        await tester.pumpAndSettle();
        // R-2L v2 catalog: "Manager" renamed to "General Manager".
        await tester.tap(find.text('General Manager').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('invite_member_dialog_submit')));
        await tester.pumpAndSettle();

        final listed = await gateway.listInvites(
          const TeamInviteListCommand(
            actorUserId: 'session-actor',
            operatorId: kDemoOperatorIdFixture,
            locationId: 'demo-loc-downtown',
          ),
        );
        final created = listed.invites.firstWhere(
          (i) => i.email == 'persistence.check@demobistro.test',
        );
        expect(created.scopeType, equals('org_unit'));
        expect(created.orgUnitId, equals('demo-org-east'));
      },
    );

    testWidgets(
      'picking a region grants at the org-unit scope without a location',
      (tester) async {
        await sizeViewport(tester);
        final gateway = DemoWebTeamUsersGateway();
        InviteMemberDialogResult? result;
        await tester.pumpWidget(
          wrap(
            Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const Key('open_invite_dialog'),
                  onPressed: () async {
                    result = await showInviteMemberDialog(
                      context: context,
                      gateway: gateway,
                      listCommand: listCommand,
                      existingEmails: const <String>{},
                      roleOptions: kDemoTeamRolesFixture,
                      locationOptions: kDemoTeamLocationsFixture,
                      idempotencyKey: 'idem-invite-region-1',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('open_invite_dialog')));
        await tester.pumpAndSettle();

        // Fill email + role.
        await tester.enterText(
          find.byKey(const Key('invite_member_dialog_email_field')),
          'morgan.regional@demobistro.test',
        );
        await tester.tap(
          find.byKey(const Key('invite_member_dialog_role_field')),
        );
        await tester.pumpAndSettle();
        // R-2L v2 catalog: "Manager" renamed to "General Manager".
        await tester.tap(find.text('General Manager').last);
        await tester.pumpAndSettle();

        // Tap the East Region node in the picker tree.
        await tester.tap(find.text('East Region'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('invite_member_dialog_submit')));
        await tester.pumpAndSettle();

        expect(result, isNotNull);
        final listed = await gateway.listInvites(
          const TeamInviteListCommand(
            actorUserId: 'session-actor',
            operatorId: kDemoOperatorIdFixture,
            locationId: 'demo-loc-downtown',
          ),
        );
        final created = listed.invites.firstWhere(
          (i) => i.email == 'morgan.regional@demobistro.test',
        );
        expect(created.scopeType, equals('org_unit'));
        expect(created.orgUnitId, equals('demo-org-east'));
        // The form clears the locationId when scope flips to org_unit
        // so the payload never carries a stale id (per the
        // TeamInviteFormController contract).
        expect(created.locationId, isNull);
      },
    );
  });
}
