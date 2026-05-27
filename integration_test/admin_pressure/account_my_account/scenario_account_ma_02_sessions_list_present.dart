// integration_test/admin_pressure/account_my_account/scenario_account_ma_02_sessions_list_present.dart
//
// Lane E — Account/MA-02: the My account route surfaces an "Active
// sessions" card so the admin can review where their account is signed
// in. The card is tagged Key('admin_my_account_active_sessions_card')
// (lib/admin/screens/my_account_admin_screen.dart:1712) and exposes a
// Manage button (Key('admin_my_account_active_sessions_manage'), :1720)
// which opens a dialog (Key('admin_my_account_active_sessions_dialog'),
// :1891) listing the sessions.
//
// This scenario boots the shell, navigates to My account, asserts the
// active-sessions card is present, taps Manage, asserts the dialog
// opens, and asserts the dialog dismisses cleanly via its close button.
// Mirrors the operator-web _qa_runner.js "dialog open + close cleanly"
// pattern.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Account/MA-02: My account exposes an Active sessions card; tapping '
    'Manage opens a session-list dialog that dismisses cleanly',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminMyAccountRouteId);

      // My account screen mounted.
      expect(
        find.byKey(const Key('admin_my_account_screen')),
        findsOneWidget,
        reason: 'My account screen scaffold did not mount.',
      );

      // Active sessions card present (Key from line 1712).
      expect(
        find.byKey(const Key('admin_my_account_active_sessions_card')),
        findsOneWidget,
        reason:
            'Active sessions card (Key=admin_my_account_active_sessions_card) '
            'is missing — operators have no way to review their active '
            'sessions.',
      );

      // Manage button present (Key from line 1720).
      final manageBtn =
          find.byKey(const Key('admin_my_account_active_sessions_manage'));
      expect(
        manageBtn,
        findsOneWidget,
        reason:
            'Manage button (Key=admin_my_account_active_sessions_manage) '
            'missing — sessions are not actionable from the card.',
      );

      // Ensure the Manage button is on screen (scroll into view if the
      // viewport puts the card below the fold). Best-effort: scrollUntil
      // can fail in widget-test mode, so we wrap in a try/catch and fall
      // back to tapping at whatever offset the framework can reach.
      try {
        await tester.scrollUntilVisible(manageBtn, 80,
            scrollable: find.byType(Scrollable).first);
      } catch (_) {
        // Fall through; tap with warnIfMissed: false handles off-screen.
      }
      await tester.tap(manageBtn, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      // Dialog opened (Key from line 1891).
      const dialogKey = Key('admin_my_account_active_sessions_dialog');
      expect(
        find.byKey(dialogKey),
        findsOneWidget,
        reason:
            'Active sessions dialog did not open after tapping Manage — '
            'the affordance is a silent no-op.',
      );

      // Dialog has a close button (Key from line 1897).
      final closeBtn = find
          .byKey(const Key('admin_my_account_active_sessions_dialog_close'));
      expect(
        closeBtn,
        findsOneWidget,
        reason:
            'Active sessions dialog has no close affordance — the dialog '
            'cannot be dismissed.',
      );

      // Close the dialog and verify it dismisses (mirror of operator-web
      // _qa_runner.js interaction pattern: opens AND closes cleanly).
      await tester.tap(closeBtn, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      expect(
        find.byKey(dialogKey),
        findsNothing,
        reason:
            'Active sessions dialog did not dismiss after tapping close — '
            'stuck-dialog regression on the My account surface.',
      );

      // Shell still mounted under the dismissed dialog.
      await expectAdminShellMounted(tester);

      // No overflows during the sessions dialog flow.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Active sessions dialog overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
