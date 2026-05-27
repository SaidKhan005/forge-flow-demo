// integration_test/admin_pressure/regression/scenario_reg_03_business_suspend_blocks_without_reason.dart
//
// Lane E — Reg-03 (regression): Suspend Business is NOT one-tap. The
// destructive flow MUST surface a reason dialog, MUST reject empty
// submits with a clear error, and the reason field MUST remain
// reachable so the operator can correct course.
//
// Keys come from lib/admin/screens/operator_location_admin_screen.dart:
//   - admin_operator_suspend_button   (:1015 buttonKey)
//   - admin_operator_suspend_dialog   (:628)
//   - admin_operator_suspend_reason   (:629)
//   - admin_operator_suspend_submit   (:630)
//
// This is the regression equivalent of Ops/BA-04, but checks the
// full flow — including the empty-submit guard that prevents
// silent destructive writes. Critical because suspending a
// business is a non-reversible operator-visible state change.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Reg-03 (regression): Suspend Business surfaces a reason dialog and '
    'rejects empty submits with a clear error',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await selectDemoDinerBusinessScope(tester);

      // Tap suspend; dialog opens.
      await tapAdminKey(tester, 'admin_operator_suspend_button');
      expect(
        find.byKey(const Key('admin_operator_suspend_dialog')),
        findsOneWidget,
        reason:
            'Suspend dialog (admin_operator_suspend_dialog) did not open '
            'after tapping Suspend — destructive write fired without a '
            'reason gate.',
      );

      // Reason field must be present.
      expect(
        find.byKey(const Key('admin_operator_suspend_reason')),
        findsOneWidget,
        reason:
            'Reason field missing from the suspend dialog — operator has '
            'no way to satisfy the gate.',
      );

      // Tap submit with empty reason.
      await tapAdminKey(tester, 'admin_operator_suspend_submit');

      // Empty submit must surface a clear error message and the dialog
      // must stay open.
      expect(
        find.text('Add a reason before continuing.'),
        findsOneWidget,
        reason:
            'Empty-submit guard text "Add a reason before continuing." '
            'was not surfaced — the destructive write may have fired or '
            'the error copy regressed.',
      );

      // Dialog stays open so the operator can correct the input.
      expect(
        find.byKey(const Key('admin_operator_suspend_dialog')),
        findsOneWidget,
        reason:
            'Suspend dialog dismissed after empty submit — operator '
            'cannot correct course.',
      );
      expect(
        find.byKey(const Key('admin_operator_suspend_reason')),
        findsOneWidget,
        reason: 'Reason field disappeared after empty submit.',
      );

      // No overflows in the dialog layout.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Suspend dialog overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
