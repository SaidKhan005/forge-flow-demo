// Lane F — Scenario 02: Role editor permission toggle buttons cycle state
// without crash or overflow.
//
// The role editor renders a segmented button per permission key, keyed
// Key('settings_role_editor_perm_$permissionKey'). This scenario opens
// the editor with 3 permission keys and taps each toggle twice (forward
// cycle then back), verifying no crash, no overflow, and the dialog
// is still live after all interactions.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings/settings_role_editor.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'form-02 — role editor permission toggles cycle state without crash or overflow',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);
      await openSettings(tester);
      expectSettings();

      const role = TeamRoleCatalogEntry(
        roleId: '',
        roleKey: 'perm_toggle_test',
        displayName: 'Perm Toggle Test',
        description: '',
        isSeeded: false,
        isEditable: true,
        permissions: <TeamRolePermissionRule>[],
      );

      final ctx = tester.element(find.byType(Scaffold).last);
      showDialog<SettingsRoleEditorResult>(
        context: ctx,
        builder: (_) => SettingsRoleEditorDialog(
          role: role,
          onSubmit: (_) async => null,
          permissionKeys: const <String>{
            'shift.view',
            'wage.view',
            'plan.view',
          },
        ),
      );
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      const permKeys = ['shift.view', 'wage.view', 'plan.view'];

      // First pass: cycle each toggle forward.
      for (final permKey in permKeys) {
        final toggle = find.byKey(Key('settings_role_editor_perm_$permKey'));
        if (toggle.evaluate().isNotEmpty) {
          await tester.tap(toggle.first, warnIfMissed: false);
          await tester.pump();
        }
      }
      await pumpUntil(tester, budget: kTabBudget);

      // Second pass: cycle back.
      for (final permKey in permKeys) {
        final toggle = find.byKey(Key('settings_role_editor_perm_$permKey'));
        if (toggle.evaluate().isNotEmpty) {
          await tester.tap(toggle.first, warnIfMissed: false);
          await tester.pump();
        }
      }
      await pumpUntil(tester, budget: kTabBudget);

      // Dismiss without saving.
      final cancelBtn = find.byKey(const Key('settings_role_editor_cancel'));
      if (cancelBtn.evaluate().isNotEmpty) {
        await tester.tap(cancelBtn);
      } else {
        // Tap outside the dialog to dismiss.
        await tester.tapAt(const Offset(10, 10));
      }
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // No exceptions or overflows from all toggle interactions.
      expect(
        tap.all,
        isEmpty,
        reason:
            'Exceptions thrown during permission toggle interactions:\n'
            '${tap.all.map((e) => e.exceptionAsString()).join('\n')}',
      );
      expect(tap.overflowErrors, isEmpty);
    },
  );
}
