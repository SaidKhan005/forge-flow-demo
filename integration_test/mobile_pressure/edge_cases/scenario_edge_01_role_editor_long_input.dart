// Lane H — Scenario 01: Role editor handles a 150-character display name
// without crash, overflow, or truncation exception.
//
// Boundary input test: long role names may expose layout overflow in the
// dialog header or assertion failures in the text controller.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/settings/settings_role_editor.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'edge-01 — role editor 150-char display name does not crash or overflow',
    (WidgetTester tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchDemoApp(tester);
      await expectAppShellMounted(tester);
      await openSettings(tester);
      expectSettings();

      const role = TeamRoleCatalogEntry(
        roleId: '',
        roleKey: 'long_name_test',
        displayName: '',
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
          permissionKeys: const <String>{'shift.view'},
        ),
      );
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      final displayNameField =
          find.byKey(const Key('settings_role_editor_display_name'));
      expect(displayNameField, findsOneWidget);

      // Build a 150-character name: spaces, hyphens, digits — common edge cases.
      const base = 'Pressure Test Wave 2 Boundary Role - Extra Long Title '
          'With Hyphens And Numbers 1234567890 And More Words ';
      final longName = base.padRight(150, 'X').substring(0, 150);

      await tester.tap(displayNameField);
      await tester.pump();
      await tester.enterText(displayNameField, longName);
      await tester.pump();
      await pumpUntil(tester, budget: kTabBudget);

      // No layout overflow from the long text.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'RenderFlex overflow when displaying a 150-character role name:\n'
            '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
      );

      // Dialog should still be present (not crashed or auto-dismissed).
      expect(
        find.byKey(const Key('settings_role_editor_dialog')),
        findsOneWidget,
        reason:
            'Role editor dialog disappeared after long-name input — '
            'may have crashed.',
      );

      // Attempt save — either succeeds or shows validation, but no crash.
      final saveBtn = find.byKey(const Key('settings_role_editor_save'));
      if (saveBtn.evaluate().isNotEmpty) {
        await tester.tap(saveBtn, warnIfMissed: false);
        await tester.pump();
        await pumpUntil(tester, budget: kTabBudget);
      }

      // No new exceptions from the save attempt.
      expect(
        tap.all,
        isEmpty,
        reason:
            'Exceptions thrown after long-name Save attempt:\n'
            '${tap.all.map((e) => e.exceptionAsString()).join('\n')}',
      );
    },
  );
}
