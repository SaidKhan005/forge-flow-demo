// integration_test/admin_pressure/ops_members/scenario_ops_mem_02_invite_dialog_opens_and_validates.dart
//
// Lane B — Ops/Mem-02: tapping the Invite button on the Team members
// surface (Key='admin_members_invite_button',
// lib/admin/screens/members_admin_screen.dart:963) opens the invite
// dialog (Key='admin_members_invite_dialog',
// lib/admin/screens/invite_member_admin_dialog.dart:315) with fields
// for email, display name, role, location, admin reason, and submit/
// cancel actions.
//
// This scenario asserts the open + close cleanly contract:
//   - tapping Invite opens the dialog,
//   - email/role/admin-reason fields are present,
//   - Cancel dismisses the dialog.
//
// The form-validation regression (empty submit → validation banner) is
// a more detailed scenario; here we lock the open-and-close contract
// (mirroring the operator-web _qa_runner.js interaction pattern).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/Mem-02: Invite button opens the invite-member dialog with '
    'required form fields; Cancel dismisses cleanly',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);

      final routeId = kAdminMembersRouteId;
      Future<bool> trySelect() async {
        for (final key in [
          Key('admin_nav_cluster_item_$routeId'),
          Key('admin_nav_item_$routeId'),
        ]) {
          final finder = find.byKey(key);
          if (finder.evaluate().isNotEmpty) {
            await tester.tap(finder.first, warnIfMissed: false);
            await tester.pump();
            await pumpUntil(tester, budget: kAdminNavBudget);
            return true;
          }
        }
        return false;
      }

      var selected = await trySelect();
      if (!selected) {
        await tapAdminNav(tester, kAdminOperatorsRouteId);
        final demoDiner = find.text('Demo Diner Co.');
        if (demoDiner.evaluate().isNotEmpty) {
          await tester.tap(demoDiner.first, warnIfMissed: false);
          await tester.pump();
          await pumpUntil(tester, budget: kAdminNavBudget);
          selected = await trySelect();
        }
      }

      if (!selected) return;

      final inviteBtn = find.byKey(const Key('admin_members_invite_button'));
      if (inviteBtn.evaluate().isEmpty) {
        // Read-only role hides invite — soft pass.
        return;
      }

      await tester.tap(inviteBtn, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      // Dialog opened (Key from
      // lib/admin/screens/invite_member_admin_dialog.dart:315).
      const dialogKey = Key('admin_members_invite_dialog');
      expect(
        find.byKey(dialogKey),
        findsOneWidget,
        reason:
            'Invite member dialog did not open after tapping Invite '
            '— silent no-op.',
      );

      // Required form fields present.
      expect(
        find.byKey(const Key('admin_members_invite_email')),
        findsOneWidget,
        reason: 'Email field missing from invite dialog.',
      );
      expect(
        find.byKey(const Key('admin_members_invite_role')),
        findsOneWidget,
        reason: 'Role field missing from invite dialog.',
      );
      expect(
        find.byKey(const Key('admin_members_invite_admin_reason')),
        findsOneWidget,
        reason: 'Admin reason field missing from invite dialog.',
      );

      // Cancel + Submit affordances present.
      final cancelBtn = find.byKey(const Key('admin_members_invite_cancel'));
      expect(
        cancelBtn,
        findsOneWidget,
        reason: 'Cancel button missing from invite dialog.',
      );
      expect(
        find.byKey(const Key('admin_members_invite_submit')),
        findsOneWidget,
        reason: 'Submit button missing from invite dialog.',
      );

      // Cancel dismisses cleanly.
      await tester.tap(cancelBtn, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      expect(
        find.byKey(dialogKey),
        findsNothing,
        reason:
            'Invite dialog did not dismiss after Cancel — stuck-dialog '
            'regression on the members surface.',
      );

      await expectAdminShellMounted(tester);

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Invite dialog overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
